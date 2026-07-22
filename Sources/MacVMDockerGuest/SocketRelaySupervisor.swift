import Darwin
import Foundation

/// Maintains remote OpenSSH stream-local forwards from sidecar socket paths to
/// Unix sockets in the macOS guest. A separate SSH connection per source keeps
/// relay failures isolated and lets OpenSSH provide byte-stream backpressure and
/// half-close handling.
final class SocketRelaySupervisor: @unchecked Sendable {
    private struct RelayState {
        var macOSSocketPath: String
        var process: Process?
        var restartAttempt = 0
    }

    private let privateLinuxAddress: String
    private let brokerKeyURL: URL
    private let brokerKnownHostsURL: URL
    private let queue = DispatchQueue(label: "dev.macvm.docker-guest.socket-relays")
    private var relays: [String: RelayState] = [:]
    private var stopping = false

    init(
        privateLinuxAddress: String,
        brokerKeyURL: URL,
        brokerKnownHostsURL: URL
    ) {
        self.privateLinuxAddress = privateLinuxAddress
        self.brokerKeyURL = brokerKeyURL
        self.brokerKnownHostsURL = brokerKnownHostsURL
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
            if let process = relays.removeValue(forKey: filesystemID)?.process {
                process.terminationHandler = nil
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }
            try? runBrokerCommand("remove-socket \(filesystemID)", timeout: 15)
        }
    }

    func stop() {
        queue.sync {
            stopping = true
            let processes = relays.values.compactMap(\.process)
            relays.removeAll()
            for process in processes {
                process.terminationHandler = nil
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }
        }
    }

    private func launchRelay(filesystemID: String) throws {
        guard var relay = relays[filesystemID] else { return }
        try runBrokerCommand("prepare-socket \(filesystemID)", timeout: 15)

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
            "-o", sshKnownHostsOption(brokerKnownHostsURL),
            "-o", "StreamLocalBindUnlink=yes",
            "-i", brokerKeyURL.path,
            "-R", "\(DockerGuestFileUtilities.socketRelayPath(filesystemID: filesystemID)):\(relay.macOSSocketPath)",
            "macvm-mount@\(privateLinuxAddress)",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self, weak process] _ in
            guard let self, let process else { return }
            self.queue.async {
                self.relayDidExit(filesystemID: filesystemID, process: process)
            }
        }
        try process.run()
        relay.process = process
        relays[filesystemID] = relay

        do {
            try runBrokerCommand("wait-socket \(filesystemID)", timeout: 15)
        } catch {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            relay.process = nil
            relays[filesystemID] = relay
            throw GuestHelperError(
                "Unable to establish Docker socket relay for \(relay.macOSSocketPath): \(error.localizedDescription)"
            )
        }

        relay.restartAttempt = 0
        relays[filesystemID] = relay
    }

    private func relayDidExit(filesystemID: String, process: Process) {
        guard var relay = relays[filesystemID], relay.process === process else { return }
        relay.process = nil
        relays[filesystemID] = relay
        guard !stopping else { return }
        scheduleRestart(filesystemID: filesystemID)
    }

    private func scheduleRestart(filesystemID: String) {
        guard var relay = relays[filesystemID], relay.process == nil, !stopping else { return }
        relay.restartAttempt += 1
        let attempt = relay.restartAttempt
        relays[filesystemID] = relay
        let delay = min(pow(2.0, Double(attempt - 1)), 30)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  !self.stopping,
                  let current = self.relays[filesystemID],
                  current.process == nil,
                  current.restartAttempt == attempt else { return }
            do {
                try self.launchRelay(filesystemID: filesystemID)
            } catch {
                FileHandle.standardError.write(Data(
                    "macvm-docker-guest: socket relay restart failed for \(current.macOSSocketPath): \(error.localizedDescription)\n".utf8
                ))
                self.scheduleRestart(filesystemID: filesystemID)
            }
        }
    }

    private func runBrokerCommand(_ command: String, timeout: TimeInterval) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", sshKnownHostsOption(brokerKnownHostsURL),
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-i", brokerKeyURL.path,
            "macvm-mount@\(privateLinuxAddress)",
            command,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            throw GuestHelperError("Sidecar socket broker timed out.")
        }
        process.terminationHandler = nil
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestHelperError(
                detail?.isEmpty == false ? detail! : "Sidecar socket broker failed."
            )
        }
    }
}
