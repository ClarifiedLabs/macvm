import CryptoKit
import Darwin
import Foundation

struct GuestFilesystemMapping: Codable, Equatable {
    enum Transport: String, Codable {
        case sshfs
    }

    var filesystemID: String
    var macOSMountRoot: String
    var linuxMountRoot: String
    var transport: Transport
}

final class GuestFilesystemMapper: @unchecked Sendable {
    private let stateURL: URL
    private let privateLinuxAddress: String
    private let setupUsername: String
    private let brokerKeyURL: URL
    private let brokerKnownHostsURL: URL
    private let lock = NSLock()
    private let mountOperationLock = NSLock()
    private var mappings: [GuestFilesystemMapping]
    private var remountedFilesystemIDs: Set<String> = []

    init(
        stateURL: URL,
        privateLinuxAddress: String,
        setupUsername: String,
        brokerKeyURL: URL,
        brokerKnownHostsURL: URL
    ) {
        self.stateURL = stateURL
        self.privateLinuxAddress = privateLinuxAddress
        self.setupUsername = setupUsername
        self.brokerKeyURL = brokerKeyURL
        self.brokerKnownHostsURL = brokerKnownHostsURL
        // Filesystem-wide mappings from early builds are deliberately discarded:
        // every current mapping is scoped to one requested bind source subtree.
        self.mappings = ((try? Self.readMappings(from: stateURL)) ?? [])
            .filter { $0.filesystemID.hasPrefix("path-") }
    }

    func mapMacOSPath(_ source: String) throws -> String {
        guard source.hasPrefix("/") else { return source }
        let resolved = try Self.resolvedExistingPath(source)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
            throw GuestHelperError("Docker bind source does not exist in the macOS guest: \(source)")
        }
        let exportRoot = isDirectory.boolValue
            ? resolved
            : URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        let filesystemID = try Self.mappingID(for: exportRoot)

        let mapping = try mountOperationLock.withLock { () throws -> GuestFilesystemMapping in
            if let existing = lock.withLock({
                mappings
                    .filter { Self.isPath(resolved, under: $0.macOSMountRoot) }
                    .max(by: { $0.macOSMountRoot.count < $1.macOSMountRoot.count })
            }) {
                let mounted = try ensureSidecarMount(existing)
                return try lock.withLock {
                    if let index = mappings.firstIndex(where: { $0.filesystemID == mounted.filesystemID }),
                       mounted != mappings[index] {
                        mappings[index] = mounted
                        try persistMappings()
                    }
                    return mounted
                }
            }

            let transport = try makeSidecarMount(filesystemID: filesystemID, exportRoot: exportRoot)
            let persisted = GuestFilesystemMapping(
                filesystemID: filesystemID,
                macOSMountRoot: exportRoot,
                linuxMountRoot: "/run/macvm-macos/\(filesystemID)",
                transport: transport
            )
            return try lock.withLock {
                mappings.append(persisted)
                remountedFilesystemIDs.insert(filesystemID)
                try persistMappings()
                return persisted
            }
        }
        return Self.join(
            root: mapping.linuxMountRoot,
            relative: Self.relativePath(resolved, under: mapping.macOSMountRoot)
        )
    }

    func reconcileSidecarMounts() {
        mountOperationLock.withLock {
            remountedFilesystemIDs.removeAll()
            let persisted: [GuestFilesystemMapping]
            do {
                persisted = try pruneMissingMappings()
            } catch {
                FileHandle.standardError.write(Data(
                    "macvm-docker-guest: unable to prune stale bind mappings: \(error.localizedDescription)\n".utf8
                ))
                return
            }
            for mapping in persisted {
                do {
                    let mounted = try ensureSidecarMount(mapping)
                    try lock.withLock {
                        if let index = mappings.firstIndex(where: { $0.filesystemID == mounted.filesystemID }) {
                            mappings[index] = mounted
                            try persistMappings()
                        }
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "macvm-docker-guest: unable to restore \(mapping.macOSMountRoot) after sidecar reconnect: \(error.localizedDescription)\n".utf8
                    ))
                }
            }
        }
    }

    func mapLinuxPath(_ source: String) -> String {
        lock.withLock {
            guard let mapping = mappings
                .sorted(by: { $0.linuxMountRoot.count > $1.linuxMountRoot.count })
                .first(where: { Self.isPath(source, under: $0.linuxMountRoot) }) else {
                return source
            }
            return Self.join(
                root: mapping.macOSMountRoot,
                relative: Self.relativePath(source, under: mapping.linuxMountRoot)
            )
        }
    }

    private func pruneMissingMappings() throws -> [GuestFilesystemMapping] {
        let result = try lock.withLock { () throws -> (retained: [GuestFilesystemMapping], removed: [GuestFilesystemMapping]) in
            let retained = mappings.filter {
                // Foundation can return a stale `true` for deleted descendants
                // of a VirtioFS mount. POSIX metadata reflects the live source.
                DockerGuestFileUtilities.pathExists($0.macOSMountRoot)
            }
            guard retained.count != mappings.count else { return (mappings, []) }
            let previous = mappings
            let retainedIDs = Set(retained.map(\.filesystemID))
            let removed = mappings.filter { !retainedIDs.contains($0.filesystemID) }
            mappings = retained
            do {
                try persistMappings()
            } catch {
                mappings = previous
                throw error
            }
            return (retained, removed)
        }
        for mapping in result.removed {
            FileHandle.standardError.write(Data(
                "macvm-docker-guest: pruned stale bind mapping for \(mapping.macOSMountRoot)\n".utf8
            ))
        }
        return result.retained
    }

    private func ensureSidecarMount(_ mapping: GuestFilesystemMapping) throws -> GuestFilesystemMapping {
        guard !remountedFilesystemIDs.contains(mapping.filesystemID) else { return mapping }
        try? requestSidecarMount("unmount \(mapping.filesystemID)")
        let transport = try makeSidecarMount(
            filesystemID: mapping.filesystemID,
            exportRoot: mapping.macOSMountRoot
        )
        remountedFilesystemIDs.insert(mapping.filesystemID)
        var updated = mapping
        updated.transport = transport
        return updated
    }

    private func makeSidecarMount(
        filesystemID: String,
        exportRoot: String
    ) throws -> GuestFilesystemMapping.Transport {
        try requestSidecarMount(
            "mount-sshfs \(filesystemID) \(setupUsername) \(exportRoot)"
        )
        return .sshfs
    }

    private func requestSidecarMount(_ command: String) throws {
        let directory = brokerKnownHostsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.run("/usr/bin/ssh", [
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", sshKnownHostsOption(brokerKnownHostsURL),
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-i", brokerKeyURL.path,
            "macvm-mount@\(privateLinuxAddress)",
            command,
        ])
    }

    private func persistMappings() throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(mappings)
        try data.write(to: stateURL, options: .atomic)
    }

    private static func readMappings(from url: URL) throws -> [GuestFilesystemMapping] {
        try JSONDecoder().decode([GuestFilesystemMapping].self, from: Data(contentsOf: url))
    }

    private static func resolvedExistingPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw GuestHelperError(
                "Docker bind source does not exist in the macOS guest: \(path) (\(String(cString: strerror(errno))))"
            )
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func mappingID(for exportRoot: String) throws -> String {
        var value = statfs()
        guard statfs(exportRoot, &value) == 0 else {
            throw GuestHelperError(
                "Unable to inspect filesystem for \(exportRoot): \(String(cString: strerror(errno)))"
            )
        }
        let identity = "\(value.f_fsid.val.0):\(value.f_fsid.val.1):\(exportRoot)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "path-\(digest)"
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
            throw GuestHelperError("\(executable) timed out.")
        }
        process.terminationHandler = nil
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestHelperError(
                "\(executable) failed (\(process.terminationStatus)): \(detail ?? "unknown error")"
            )
        }
    }

    private static func relativePath(_ path: String, under root: String) -> String {
        guard root != "/" else { return String(path.dropFirst()) }
        guard path != root else { return "" }
        return String(path.dropFirst(root.count + 1))
    }

    private static func join(root: String, relative: String) -> String {
        relative.isEmpty ? root : root + "/" + relative
    }

    private static func isPath(_ path: String, under root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

struct GuestHelperError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
