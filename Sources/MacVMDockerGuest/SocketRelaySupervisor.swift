import Foundation
import MacVMDockerGuestCore

/// Maintains remote OpenSSH stream-local forwards from sidecar socket paths to
/// Unix sockets in the macOS guest. A separate SSH connection per source keeps
/// relay failures isolated and lets OpenSSH provide byte-stream backpressure and
/// half-close handling.
final class SocketRelaySupervisor: @unchecked Sendable {
    private struct RelayState {
        var macOSSocketPath: String
        var process: Process? = nil
        var stderrMonitor: DockerGuestSSHStderrMonitor? = nil
        var restartAttempt = 0
    }

    private let privateLinuxAddress: String
    private let brokerKeyURL: URL
    private let brokerKnownHostsURL: URL
    private let setupUsername: String
    private let helperExecutablePath: String
    private let relayIdentityRootURL: URL
    private let setupUID: uid_t
    private let setupGID: gid_t
    private let queue = DispatchQueue(label: "dev.macvm.docker-guest.socket-relays")
    private var relays: [String: RelayState] = [:]
    private var stopping = false

    init(
        privateLinuxAddress: String,
        brokerKeyURL: URL,
        brokerKnownHostsURL: URL,
        setupUsername: String,
        helperExecutablePath: String = CommandLine.arguments[0]
    ) throws {
        self.privateLinuxAddress = privateLinuxAddress
        self.brokerKeyURL = brokerKeyURL
        self.brokerKnownHostsURL = brokerKnownHostsURL
        self.setupUsername = setupUsername
        self.helperExecutablePath = helperExecutablePath
        guard let account = getpwnam(setupUsername) else {
            throw GuestHelperError("Couldn't find setup account '\(setupUsername)'.")
        }
        self.setupUID = account.pointee.pw_uid
        self.setupGID = account.pointee.pw_gid
        self.relayIdentityRootURL = brokerKnownHostsURL.deletingLastPathComponent()
            .appendingPathComponent("RelayIdentities", isDirectory: true)
        try DockerTransientIdentityFile.pruneRootDirectory(relayIdentityRootURL)
    }

    func ensureRelay(filesystemID: String, macOSSocketPath: String) throws -> String {
        try queue.sync {
            if let existing = relays[filesystemID] {
                guard existing.macOSSocketPath == macOSSocketPath else {
                    throw GuestHelperError("Conflicting Docker socket relay mapping for \(filesystemID).")
                }
                if existing.process?.isRunning == true {
                    return DockerGuestFileUtilities.socketRelayPath(filesystemID: filesystemID)
                }
            } else {
                relays[filesystemID] = RelayState(macOSSocketPath: macOSSocketPath)
            }

            do {
                try launchRelay(filesystemID: filesystemID)
            } catch {
                relays.removeValue(forKey: filesystemID)
                throw error
            }
            return DockerGuestFileUtilities.socketRelayPath(filesystemID: filesystemID)
        }
    }

    func removeRelay(filesystemID: String) {
        queue.sync {
            if let relay = relays.removeValue(forKey: filesystemID) {
                if let process = relay.process {
                    process.terminationHandler = nil
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                    }
                }
                relay.stderrMonitor?.stop()
            }
            try? runBrokerCommand(.removeSocket(filesystemID: filesystemID), timeout: 15)
            DockerGuestLog.info("socket-relay removed filesystemID=\(filesystemID)")
        }
    }

    func stop() {
        queue.sync {
            stopping = true
            let states = Array(relays.values)
            relays.removeAll()
            for state in states {
                if let process = state.process {
                    process.terminationHandler = nil
                    if process.isRunning {
                        process.terminate()
                        process.waitUntilExit()
                    }
                }
                state.stderrMonitor?.stop()
            }
            DockerGuestLog.info("socket-relays stopped count=\(states.count)")
        }
    }

    private func launchRelay(filesystemID: String) throws {
        guard var relay = relays[filesystemID] else { return }
        try runBrokerCommand(.prepareSocket(filesystemID: filesystemID), timeout: 15)

        let identity = try DockerTransientIdentityFile(
            privateKey: Data(contentsOf: brokerKeyURL),
            rootDirectory: relayIdentityRootURL,
            ownerUID: setupUID,
            ownerGID: setupGID
        )
        defer { try? identity.remove() }
        guard chmod(brokerKnownHostsURL.path, 0o644) == 0 else {
            throw GuestHelperError("Unable to make the pinned Docker host key readable by the setup account.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperExecutablePath)
        process.arguments = [
            "--execute-as-user", setupUsername, "--",
            "/usr/bin/ssh",
            "-N", "-T",
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=yes",
            "-o", sshKnownHostsOption(brokerKnownHostsURL),
            "-o", "StreamLocalBindUnlink=yes",
            "-i", identity.url.path,
            "-R", "\(DockerGuestFileUtilities.socketRelayPath(filesystemID: filesystemID)):\(relay.macOSSocketPath)",
            "macvm-mount@\(privateLinuxAddress)",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderrMonitor = DockerGuestSSHStderrMonitor(label: "socket-relay-\(filesystemID)")
        process.standardError = stderrMonitor.pipe
        stderrMonitor.start()
        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            self.queue.async {
                self.relayDidExit(filesystemID: filesystemID, process: process)
            }
        }
        do {
            try process.run()
        } catch {
            stderrMonitor.stop()
            if process.isRunning { process.terminate() }
            throw error
        }
        relay.process = process
        relay.stderrMonitor = stderrMonitor
        relays[filesystemID] = relay

        do {
            try runBrokerCommand(.waitSocket(filesystemID: filesystemID), timeout: 15)
        } catch {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            relay.process = nil
            relay.stderrMonitor = nil
            stderrMonitor.stop()
            relays[filesystemID] = relay
            throw GuestHelperError(
                "Unable to establish Docker socket relay for \(relay.macOSSocketPath): \(error.localizedDescription)"
            )
        }

        do {
            try identity.remove()
        } catch {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            relay.process = nil
            relay.stderrMonitor = nil
            stderrMonitor.stop()
            relays[filesystemID] = relay
            throw GuestHelperError("Unable to revoke the transient Docker socket relay key.")
        }

        relay.restartAttempt = 0
        relays[filesystemID] = relay
        DockerGuestLog.info(
            "socket-relay connected filesystemID=\(filesystemID) "
                + "macOSSocketPath=\(relay.macOSSocketPath)"
        )
    }

    private func relayDidExit(filesystemID: String, process: Process) {
        guard var relay = relays[filesystemID], relay.process === process else { return }
        relay.process = nil
        relay.stderrMonitor?.stop()
        relay.stderrMonitor = nil
        relays[filesystemID] = relay
        guard !stopping else { return }
        DockerGuestLog.error(
            "socket-relay exited filesystemID=\(filesystemID) status=\(process.terminationStatus)"
        )
        scheduleRestart(filesystemID: filesystemID)
    }

    private func scheduleRestart(filesystemID: String) {
        guard var relay = relays[filesystemID], relay.process == nil, !stopping else { return }
        relay.restartAttempt += 1
        let attempt = relay.restartAttempt
        relays[filesystemID] = relay
        let delay = min(pow(2.0, Double(attempt - 1)), 30)
        DockerGuestLog.info(
            "socket-relay restart-scheduled filesystemID=\(filesystemID) "
                + "attempt=\(attempt) delaySeconds=\(Int(delay))"
        )
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  !self.stopping,
                  let current = self.relays[filesystemID],
                  current.process == nil,
                  current.restartAttempt == attempt else { return }
            do {
                try self.launchRelay(filesystemID: filesystemID)
            } catch {
                DockerGuestLog.error(
                    "socket-relay restart-failed filesystemID=\(filesystemID) "
                        + "macOSSocketPath=\(current.macOSSocketPath) "
                        + "error=\(error.localizedDescription)"
                )
                self.scheduleRestart(filesystemID: filesystemID)
            }
        }
    }

    private func runBrokerCommand(_ command: DockerMountBrokerCommand, timeout: TimeInterval) throws {
        let result = try DockerGuestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "IdentitiesOnly=yes",
                "-o", "StrictHostKeyChecking=yes",
                "-o", sshKnownHostsOption(brokerKnownHostsURL),
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=3",
                "-i", brokerKeyURL.path,
                "macvm-mount@\(privateLinuxAddress)",
                command.rendered,
            ],
            standardOutput: .discard,
            timeout: timeout
        )
        guard !result.didTimeOut else {
            throw GuestHelperError("Sidecar socket broker timed out.")
        }
        guard result.terminationStatus == 0 else {
            let detail = String(
                data: result.standardError.data,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestHelperError(
                detail?.isEmpty == false ? detail! : "Sidecar socket broker failed."
            )
        }
    }
}
