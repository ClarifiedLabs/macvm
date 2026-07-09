import Foundation

/// Builds and runs `ssh` invocations against a guest VM.
///
/// Guests are ephemeral and re-created often, so host-key checking is relaxed to
/// `accept-new` with a throwaway known-hosts file — otherwise every fresh VM
/// would trip a host-key-changed error.
struct GuestSSH {
    var host: String
    var user: String
    var identityFile: URL?

    /// Assemble the `ssh` argument vector (excluding the `ssh` program itself).
    static func arguments(
        host: String,
        user: String,
        identityFile: URL?,
        remoteCommand: [String] = [],
        allocateTTY: Bool = false,
        batchMode: Bool = false,
        connectTimeout: Int? = nil
    ) -> [String] {
        var args: [String] = []
        if allocateTTY {
            args.append("-t")
        }
        args.append(contentsOf: [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
        ])
        if batchMode {
            args.append(contentsOf: ["-o", "BatchMode=yes"])
        }
        if let connectTimeout {
            args.append(contentsOf: ["-o", "ConnectTimeout=\(connectTimeout)"])
        }
        if let identityFile {
            args.append(contentsOf: ["-i", identityFile.path, "-o", "IdentitiesOnly=yes"])
        }
        args.append("\(user)@\(host)")
        args.append(contentsOf: remoteCommand)
        return args
    }

    /// Run an interactive session or a remote command, inheriting the terminal.
    @discardableResult
    func run(remoteCommand: [String], allocateTTY: Bool) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(
            host: host,
            user: user,
            identityFile: identityFile,
            remoteCommand: remoteCommand,
            allocateTTY: allocateTTY
        )
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Run a remote command without inheriting output. Used by automated setup
    /// stages where the caller reports coarse progress and checks the exit status.
    @discardableResult
    func runQuiet(remoteCommand: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(
            host: host,
            user: user,
            identityFile: identityFile,
            remoteCommand: remoteCommand,
            batchMode: true,
            connectTimeout: 10
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Run a remote command and write combined stdout/stderr to a host-side log.
    /// This is used for long bootstrap commands where retaining the guest output
    /// is more useful than streaming it through the setup UI.
    @discardableResult
    func runLogged(remoteCommand: [String], logFile: URL) throws -> Int32 {
        try FileManager.default.createDirectory(
            at: logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let header = """
        $ ssh \(Self.arguments(host: host, user: user, identityFile: identityFile, remoteCommand: remoteCommand, batchMode: true, connectTimeout: 10).joined(separator: " "))

        """
        _ = FileManager.default.createFile(atPath: logFile.path, contents: Data(header.utf8))
        let logHandle = try FileHandle(forWritingTo: logFile)
        logHandle.seekToEndOfFile()
        defer { logHandle.closeFile() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(
            host: host,
            user: user,
            identityFile: identityFile,
            remoteCommand: remoteCommand,
            batchMode: true,
            connectTimeout: 10
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Poll until a non-interactive SSH connection succeeds or the timeout elapses.
    @discardableResult
    func waitForSSH(timeout: TimeInterval, pollInterval: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probe() {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return probe()
    }

    private func probe() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(
            host: host,
            user: user,
            identityFile: identityFile,
            remoteCommand: ["true"],
            batchMode: true,
            connectTimeout: 5
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
