import Darwin
import Foundation
import MacVMDockerGuestCore

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
    private var stderrMonitor: DockerGuestSSHStderrMonitor?
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
            if let process {
                process.terminationHandler = nil
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }
            self.process = nil
            stderrMonitor?.stop()
            stderrMonitor = nil
            try? FileManager.default.removeItem(atPath: forwardSocket)
            DockerGuestLog.info(
                "ssh-forward stopped generations=\(connectionGeneration)"
            )
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
        let stderrMonitor = DockerGuestSSHStderrMonitor(label: "docker-forward")
        process.standardError = stderrMonitor.pipe
        stderrMonitor.start()
        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            self.queue.async {
                guard self.process === process, !self.stopping else { return }
                self.process = nil
                self.stderrMonitor?.stop()
                self.stderrMonitor = nil
                try? FileManager.default.removeItem(atPath: self.forwardSocket)
                DockerGuestLog.error(
                    "ssh-forward exited status=\(process.terminationStatus) "
                        + "generation=\(self.connectionGeneration)"
                )
                self.scheduleRestart()
            }
        }
        do {
            try process.run()
        } catch {
            stderrMonitor.stop()
            throw error
        }
        self.process = process
        self.stderrMonitor = stderrMonitor

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !process.isRunning {
                self.process = nil
                self.stderrMonitor = nil
                stderrMonitor.stop()
                throw GuestHelperError("Docker SSH forward exited with status \(process.terminationStatus).")
            }
            if FileManager.default.fileExists(atPath: forwardSocket) {
                chmod(forwardSocket, 0o600)
                restartAttempt = 0
                connectionGeneration += 1
                if connectionGeneration > 1 {
                    reconnectHandler?()
                }
                DockerGuestLog.info(
                    "ssh-forward connected generation=\(connectionGeneration) "
                        + "linuxAddress=\(configuration.privateLinuxAddress)"
                )
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.terminationHandler = nil
        process.terminate()
        process.waitUntilExit()
        self.process = nil
        self.stderrMonitor = nil
        stderrMonitor.stop()
        throw GuestHelperError("Timed out creating the private Docker SSH forward.")
    }

    private func scheduleRestart() {
        guard !stopping else { return }
        restartAttempt += 1
        let delay = min(pow(2.0, Double(restartAttempt - 1)), 30)
        DockerGuestLog.info(
            "ssh-forward restart-scheduled attempt=\(restartAttempt) delaySeconds=\(Int(delay))"
        )
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping, self.process == nil else { return }
            do {
                try self.launchForward()
            } catch {
                DockerGuestLog.error(
                    "ssh-forward restart-failed attempt=\(self.restartAttempt) "
                        + "error=\(error.localizedDescription)"
                )
                self.scheduleRestart()
            }
        }
    }
}

private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let result = try DockerGuestProcessRunner.run(
        executableURL: URL(fileURLWithPath: executable),
        arguments: arguments,
        standardOutput: .capture
    )
    guard result.terminationStatus == 0 else {
        let detail = String(data: result.standardError.data, encoding: .utf8) ?? ""
        throw GuestHelperError("\(executable) failed: \(detail)")
    }
    return String(data: result.standardOutput?.data ?? Data(), encoding: .utf8) ?? ""
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
        chmod(url.path, name == "mount_broker_known_hosts" ? 0o644 : 0o600)
    }
}

private func configurationPath() -> String {
    if let index = CommandLine.arguments.firstIndex(of: "--config"),
       CommandLine.arguments.indices.contains(index + 1) {
        return CommandLine.arguments[index + 1]
    }
    return "/Library/Application Support/MacVM/docker-guest.json"
}

private func loadConfiguration() throws -> GuestHelperConfiguration {
    try JSONDecoder().decode(
        GuestHelperConfiguration.self,
        from: Data(contentsOf: URL(fileURLWithPath: configurationPath()))
    )
}

private func runCredentialDroppedCommandIfRequested() throws {
    guard let mode = CommandLine.arguments.firstIndex(of: "--execute-as-user") else { return }
    guard CommandLine.arguments.indices.contains(mode + 1),
          let separator = CommandLine.arguments[(mode + 2)...].firstIndex(of: "--"),
          CommandLine.arguments.indices.contains(separator + 1) else {
        throw GuestHelperError("Invalid credential-dropped command arguments.")
    }
    let username = CommandLine.arguments[mode + 1]
    let executable = CommandLine.arguments[separator + 1]
    let arguments = Array(CommandLine.arguments.dropFirst(separator + 2))
    try DockerCredentialDrop.executeAsUser(
        username: username,
        executablePath: executable,
        arguments: arguments
    )
}

private func runExportServerIfRequested() throws -> Bool {
    guard let mode = CommandLine.arguments.firstIndex(of: "--serve-export") else { return false }
    guard CommandLine.arguments.indices.contains(mode + 1) else {
        throw GuestHelperError("Missing Docker export filesystem ID.")
    }
    let configuration = try loadConfiguration()
    let stateDirectory = URL(fileURLWithPath: configuration.stateDirectoryPath, isDirectory: true)
    let capability = try GuestExportManager.loadCapability(
        filesystemID: CommandLine.arguments[mode + 1],
        stateDirectory: stateDirectory
    )
    try DockerSFTPServer(capability: capability).run()
    return true
}

private func main() throws {
    try runCredentialDroppedCommandIfRequested()
    if try runExportServerIfRequested() { return }
    guard geteuid() == 0 else {
        throw GuestHelperError("macvm-docker-guest must run as root from its launch daemon.")
    }
    let termination = DockerGuestTerminationCoordinator()
    signal(SIGTERM, SIG_IGN)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    signalSource.setEventHandler { termination.requestTermination() }
    signalSource.resume()
    defer { signalSource.cancel() }

    let configuration = try loadConfiguration()
    DockerGuestLog.info(
        "runtime-starting pid=\(getpid()) macOSAddress=\(configuration.privateMacOSAddress) "
            + "linuxAddress=\(configuration.privateLinuxAddress)"
    )
    try configurePrivateInterface(configuration)
    try pinSidecarHostKey(configuration)
    DockerGuestLog.info("runtime-bootstrap-complete")
    guard !termination.isTerminationRequested else { return }
    let stateDirectory = URL(fileURLWithPath: configuration.stateDirectoryPath, isDirectory: true)
    let supervisor = SSHForwardSupervisor(configuration: configuration)
    termination.registerCleanup { supervisor.stop() }
    defer { supervisor.stop() }
    guard !termination.isTerminationRequested else { return }
    try supervisor.start()
    guard !termination.isTerminationRequested else { return }

    let brokerKeyURL = URL(fileURLWithPath: configuration.mountBrokerKeyPath)
    let brokerKnownHostsURL = stateDirectory.appendingPathComponent("mount_broker_known_hosts")
    let socketRelaySupervisor = try SocketRelaySupervisor(
        privateLinuxAddress: configuration.privateLinuxAddress,
        brokerKeyURL: brokerKeyURL,
        brokerKnownHostsURL: brokerKnownHostsURL,
        setupUsername: configuration.setupUsername
    )
    defer { socketRelaySupervisor.stop() }
    guard !termination.isTerminationRequested else { return }
    let mapper = try GuestFilesystemMapper(
        stateURL: stateDirectory.appendingPathComponent("mounts.json"),
        privateLinuxAddress: configuration.privateLinuxAddress,
        setupUsername: configuration.setupUsername,
        brokerKeyURL: brokerKeyURL,
        brokerKnownHostsURL: brokerKnownHostsURL,
        socketRelaySupervisor: socketRelaySupervisor,
        configurationPath: configurationPath()
    )
    mapper.reconcileSidecarMounts()
    guard !termination.isTerminationRequested else { return }
    let portReconciler = PublishedPortReconciler(
        dockerSocketPath: "/var/run/macvm-docker-forward.sock",
        linuxAddress: configuration.privateLinuxAddress,
        brokerKeyURL: brokerKeyURL,
        brokerKnownHostsURL: brokerKnownHostsURL
    )
    let proxy = DockerAPIProxy(
        mapper: mapper,
        socketGroupName: configuration.socketGroupName,
        publishedPortsDidChange: {
            try portReconciler.reconcileImmediately()
        }
    )
    portReconciler.start()
    defer { portReconciler.stop() }
    supervisor.setReconnectHandler {
        mapper.reconcileSidecarMounts()
        portReconciler.sidecarDidReconnect()
    }
    termination.registerCleanup { proxy.shutdown() }
    guard !termination.isTerminationRequested else { return }
    DockerGuestLog.info("runtime-ready")
    try proxy.run()
    DockerGuestLog.info("runtime-stopping reason=proxy-returned")
}

do {
    try main()
} catch {
    DockerGuestLog.error("runtime-failed error=\(error.localizedDescription)")
    exit(1)
}
