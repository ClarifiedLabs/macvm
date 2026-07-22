import Darwin
import Foundation

func sshKnownHostsOption(_ url: URL) -> String {
    let escapedPath = url.path
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "UserKnownHostsFile=\"\(escapedPath)\""
}

private struct GuestHelperConfiguration: Codable {
    var privateMacOSAddress: String
    var privateLinuxAddress: String
    var privateMacOSMACAddress: String
    var sidecarHostPublicKey: String
    var setupUsername: String
    var dockerForwardKeyPath: String
    var mountBrokerKeyPath: String
    var stateDirectoryPath: String
    var socketGroupName: String
}

private final class SSHForwardSupervisor: @unchecked Sendable {
    private let configuration: GuestHelperConfiguration
    private let queue = DispatchQueue(label: "dev.macvm.docker-guest.ssh-forward")
    private let forwardSocket = "/var/run/macvm-docker-forward.sock"
    private var process: Process?
    private var stopping = false
    private var restartAttempt = 0
    private var connectionGeneration = 0
    private var reconnectHandler: (@Sendable () -> Void)?

    init(configuration: GuestHelperConfiguration) {
        self.configuration = configuration
    }

    func start() throws {
        try queue.sync {
            stopping = false
            restartAttempt = 0
            try launchForward()
        }
    }

    func setReconnectHandler(_ handler: @escaping @Sendable () -> Void) {
        queue.sync { reconnectHandler = handler }
    }

    func stop() {
        queue.sync {
            stopping = true
            guard let process else { return }
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            self.process = nil
            try? FileManager.default.removeItem(atPath: forwardSocket)
        }
    }

    private func launchForward() throws {
        let stateDirectory = URL(fileURLWithPath: configuration.stateDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: forwardSocket)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            "-o", sshKnownHostsOption(stateDirectory.appendingPathComponent("sidecar_known_hosts")),
            "-o", "StreamLocalBindUnlink=yes",
            "-i", configuration.dockerForwardKeyPath,
            "-L", "\(forwardSocket):127.0.0.1:2375",
            "-R", "127.0.0.1:2222:127.0.0.1:22",
            "macvm-docker@\(configuration.privateLinuxAddress)",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            self.queue.async {
                guard self.process === process, !self.stopping else { return }
                self.process = nil
                try? FileManager.default.removeItem(atPath: self.forwardSocket)
                self.scheduleRestart()
            }
        }
        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !process.isRunning {
                self.process = nil
                throw GuestHelperError("Docker SSH forward exited with status \(process.terminationStatus).")
            }
            if FileManager.default.fileExists(atPath: forwardSocket) {
                chmod(forwardSocket, 0o600)
                restartAttempt = 0
                connectionGeneration += 1
                if connectionGeneration > 1 {
                    reconnectHandler?()
                }
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.terminationHandler = nil
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        throw GuestHelperError("Timed out creating the private Docker SSH forward.")
    }

    private func scheduleRestart() {
        guard !stopping else { return }
        restartAttempt += 1
        let delay = min(pow(2.0, Double(restartAttempt - 1)), 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping, self.process == nil else { return }
            do {
                try self.launchForward()
            } catch {
                FileHandle.standardError.write(Data(
                    "macvm-docker-guest: Docker SSH forward restart failed: \(error.localizedDescription)\n".utf8
                ))
                self.scheduleRestart()
            }
        }
    }
}

private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw GuestHelperError("\(executable) failed: \(detail)")
    }
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

private func configurePrivateInterface(_ configuration: GuestHelperConfiguration) throws {
    let interfaces = try run("/sbin/ifconfig", ["-l"])
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
    let expected = configuration.privateMacOSMACAddress.lowercased()
    guard let interface = try interfaces.first(where: { name in
        try run("/sbin/ifconfig", [name]).lowercased().contains("ether \(expected)")
    }) else {
        throw GuestHelperError("Couldn't find the private Docker interface with MAC \(expected).")
    }
    _ = try run("/sbin/ifconfig", [
        interface,
        "inet", configuration.privateMacOSAddress,
        "netmask", "255.255.255.252",
        "up",
    ])
}

private func pinSidecarHostKey(_ configuration: GuestHelperConfiguration) throws {
    let fields = configuration.sidecarHostPublicKey.split(whereSeparator: { $0.isWhitespace })
    guard fields.count >= 2, fields[0] == "ssh-ed25519" else {
        throw GuestHelperError("The Docker sidecar host key is invalid.")
    }
    let stateDirectory = URL(fileURLWithPath: configuration.stateDirectoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    let entry = "\(configuration.privateLinuxAddress) \(fields[0]) \(fields[1])\n"
    for name in ["sidecar_known_hosts", "mount_broker_known_hosts"] {
        let url = stateDirectory.appendingPathComponent(name)
        try entry.write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o600)
    }
}

private func installSidecarFilesystemKey(_ configuration: GuestHelperConfiguration) throws {
    let stateDirectory = URL(fileURLWithPath: configuration.stateDirectoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    let publicKey = try run("/usr/bin/ssh", [
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", sshKnownHostsOption(stateDirectory.appendingPathComponent("mount_broker_known_hosts")),
        "-i", configuration.mountBrokerKeyPath,
        "macvm-mount@\(configuration.privateLinuxAddress)",
        "public-key",
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard publicKey.hasPrefix("ssh-ed25519 "),
          publicKey.contains(DockerGuestFileUtilities.filesystemKeyMarker) else {
        throw GuestHelperError("The Docker sidecar returned an invalid filesystem public key.")
    }
    guard let account = getpwnam(configuration.setupUsername) else {
        throw GuestHelperError("Couldn't find setup account '\(configuration.setupUsername)'.")
    }
    let home = String(cString: account.pointee.pw_dir)
    let sshDirectory = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".ssh", isDirectory: true)
    let authorizedKeys = sshDirectory.appendingPathComponent("authorized_keys")
    try FileManager.default.createDirectory(at: sshDirectory, withIntermediateDirectories: true)
    let existing = (try? String(contentsOf: authorizedKeys, encoding: .utf8)) ?? ""
    let contents = DockerGuestFileUtilities.replacingFilesystemAuthorizedKey(
        in: existing,
        with: publicKey
    )
    try contents.write(to: authorizedKeys, atomically: true, encoding: .utf8)

    let mountKnownHosts = stateDirectory.appendingPathComponent("mount_broker_known_hosts")
    let sidecarKnownHosts = stateDirectory.appendingPathComponent("sidecar_known_hosts")
    try Data(contentsOf: mountKnownHosts).write(to: sidecarKnownHosts, options: .atomic)
    chmod(mountKnownHosts.path, 0o600)
    chmod(sidecarKnownHosts.path, 0o600)
    chmod(sshDirectory.path, 0o700)
    chmod(authorizedKeys.path, 0o600)
    chown(sshDirectory.path, account.pointee.pw_uid, account.pointee.pw_gid)
    chown(authorizedKeys.path, account.pointee.pw_uid, account.pointee.pw_gid)
}

private func loadConfiguration() throws -> GuestHelperConfiguration {
    let path: String
    if let index = CommandLine.arguments.firstIndex(of: "--config"),
       CommandLine.arguments.indices.contains(index + 1) {
        path = CommandLine.arguments[index + 1]
    } else {
        path = "/Library/Application Support/MacVM/docker-guest.json"
    }
    return try JSONDecoder().decode(
        GuestHelperConfiguration.self,
        from: Data(contentsOf: URL(fileURLWithPath: path))
    )
}

private func main() throws {
    guard geteuid() == 0 else {
        throw GuestHelperError("macvm-docker-guest must run as root from its launch daemon.")
    }
    let configuration = try loadConfiguration()
    try configurePrivateInterface(configuration)
    try pinSidecarHostKey(configuration)
    try installSidecarFilesystemKey(configuration)
    let stateDirectory = URL(fileURLWithPath: configuration.stateDirectoryPath, isDirectory: true)
    let supervisor = SSHForwardSupervisor(configuration: configuration)
    try supervisor.start()
    defer { supervisor.stop() }

    let brokerKeyURL = URL(fileURLWithPath: configuration.mountBrokerKeyPath)
    let brokerKnownHostsURL = stateDirectory.appendingPathComponent("mount_broker_known_hosts")
    let socketRelaySupervisor = SocketRelaySupervisor(
        privateLinuxAddress: configuration.privateLinuxAddress,
        brokerKeyURL: brokerKeyURL,
        brokerKnownHostsURL: brokerKnownHostsURL
    )
    defer { socketRelaySupervisor.stop() }
    let mapper = GuestFilesystemMapper(
        stateURL: stateDirectory.appendingPathComponent("mounts.json"),
        privateLinuxAddress: configuration.privateLinuxAddress,
        setupUsername: configuration.setupUsername,
        brokerKeyURL: brokerKeyURL,
        brokerKnownHostsURL: brokerKnownHostsURL,
        socketRelaySupervisor: socketRelaySupervisor
    )
    mapper.reconcileSidecarMounts()
    let proxy = DockerAPIProxy(mapper: mapper, socketGroupName: configuration.socketGroupName)
    let portReconciler = PublishedPortReconciler(
        dockerSocketPath: "/var/run/macvm-docker-forward.sock",
        linuxAddress: configuration.privateLinuxAddress,
        brokerKeyURL: brokerKeyURL,
        brokerKnownHostsURL: brokerKnownHostsURL
    )
    portReconciler.start()
    defer { portReconciler.stop() }
    supervisor.setReconnectHandler {
        mapper.reconcileSidecarMounts()
        portReconciler.sidecarDidReconnect()
    }
    signal(SIGTERM, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    signalSource.setEventHandler { proxy.shutdown() }
    signalSource.resume()
    try proxy.run()
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("macvm-docker-guest: \(error.localizedDescription)\n".utf8))
    exit(1)
}
