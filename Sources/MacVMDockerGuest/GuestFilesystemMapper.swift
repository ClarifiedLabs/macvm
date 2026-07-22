import CryptoKit
import Darwin
import Foundation

struct GuestFilesystemMapping: Codable, Equatable {
    enum Transport: String, Codable {
        case sshfs
        case streamSocket
    }

    var filesystemID: String
    /// The exact macOS source root represented by this mapping.
    var macOSMountRoot: String
    var linuxMountRoot: String
    var transport: Transport
    /// The directory presented to SSHFS. File mappings use an isolated directory
    /// containing one symlink rather than exposing the source file's parent.
    var remoteExportRoot: String?
    var linuxRelativePath: String?
    var followsRemoteSymlinks: Bool?

    var effectiveRemoteExportRoot: String {
        remoteExportRoot ?? macOSMountRoot
    }

    var effectiveLinuxSourceRoot: String {
        let relative = linuxRelativePath ?? ""
        return relative.isEmpty ? linuxMountRoot : linuxMountRoot + "/" + relative
    }

    var shouldFollowRemoteSymlinks: Bool {
        followsRemoteSymlinks ?? false
    }
}

final class GuestFilesystemMapper: @unchecked Sendable {
    private let stateURL: URL
    private let privateLinuxAddress: String
    private let setupUsername: String
    private let brokerKeyURL: URL
    private let brokerKnownHostsURL: URL
    private let socketRelaySupervisor: SocketRelaySupervisor
    private let lock = NSLock()
    private let mountOperationLock = NSLock()
    private var mappings: [GuestFilesystemMapping]
    private var remountedFilesystemIDs: Set<String> = []

    init(
        stateURL: URL,
        privateLinuxAddress: String,
        setupUsername: String,
        brokerKeyURL: URL,
        brokerKnownHostsURL: URL,
        socketRelaySupervisor: SocketRelaySupervisor
    ) {
        self.stateURL = stateURL
        self.privateLinuxAddress = privateLinuxAddress
        self.setupUsername = setupUsername
        self.brokerKeyURL = brokerKeyURL
        self.brokerKnownHostsURL = brokerKnownHostsURL
        self.socketRelaySupervisor = socketRelaySupervisor
        // Filesystem-wide mappings from early builds are deliberately discarded:
        // every current mapping is scoped to one requested bind source subtree.
        let persistedMappings = ((try? Self.readMappings(from: stateURL)) ?? [])
            .filter { $0.filesystemID.hasPrefix("path-") || $0.filesystemID.hasPrefix("socket-") }
            .filter { mapping in
                guard mapping.transport == .sshfs,
                      (try? DockerGuestFileUtilities.bindSourceKind(at: mapping.macOSMountRoot)) == .streamSocket else {
                    return true
                }
                // Socket paths incorrectly persisted as SSHFS exact-file
                // mappings by earlier builds cannot transport socket traffic.
                return false
            }
        var restoredSocketPaths: Set<String> = []
        self.mappings = persistedMappings.filter { mapping in
            guard mapping.transport == .streamSocket else { return true }
            // A filesystem ID can change across guest boots when it includes a
            // volatile statfs identifier. Restore only one relay per source.
            return restoredSocketPaths.insert(mapping.macOSMountRoot).inserted
        }
    }

    func mapMacOSPath(_ source: String) throws -> String {
        guard source.hasPrefix("/") else { return source }
        let resolved = try Self.resolvedExistingPath(source)
        let sourceKind = try DockerGuestFileUtilities.bindSourceKind(at: resolved)
        if sourceKind == .streamSocket {
            return try mapStreamSocket(resolved)
        }
        guard sourceKind == .directory || sourceKind == .regularFile else {
            throw GuestHelperError(
                "Docker bind source at \(source) is a special file that MacVM cannot transport. Only directories, regular files, and Unix stream sockets are supported."
            )
        }
        let filesystemID = try Self.mappingID(for: resolved)
        let exportPlan = DockerGuestFileUtilities.filesystemExportPlan(
            sourcePath: resolved,
            isDirectory: sourceKind == .directory,
            stateDirectoryPath: stateURL.deletingLastPathComponent().path,
            filesystemID: filesystemID
        )

        let mapping = try mountOperationLock.withLock { () throws -> GuestFilesystemMapping in
            try prepareExport(plan: exportPlan, sourcePath: resolved)
            if let existing = lock.withLock({
                mappings
                    .filter { mapping in
                        if sourceKind == .directory {
                            return Self.isPath(resolved, under: mapping.macOSMountRoot)
                        }
                        // Never satisfy an exact-file request through a broader
                        // directory mount, even if that directory was bound first.
                        return mapping.macOSMountRoot == resolved
                            && mapping.remoteExportRoot != nil
                            && mapping.linuxRelativePath != nil
                            && mapping.shouldFollowRemoteSymlinks
                    }
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

            let transport = try makeSidecarMount(
                filesystemID: filesystemID,
                exportRoot: exportPlan.remoteExportRoot,
                followsRemoteSymlinks: exportPlan.followsRemoteSymlinks
            )
            let persisted = GuestFilesystemMapping(
                filesystemID: filesystemID,
                macOSMountRoot: resolved,
                linuxMountRoot: "/run/macvm-macos/\(filesystemID)",
                transport: transport,
                remoteExportRoot: exportPlan.remoteExportRoot == resolved ? nil : exportPlan.remoteExportRoot,
                linuxRelativePath: exportPlan.linuxRelativePath.isEmpty ? nil : exportPlan.linuxRelativePath,
                followsRemoteSymlinks: exportPlan.followsRemoteSymlinks ? true : nil
            )
            return try lock.withLock {
                mappings.append(persisted)
                remountedFilesystemIDs.insert(filesystemID)
                try persistMappings()
                return persisted
            }
        }
        return Self.join(
            root: mapping.effectiveLinuxSourceRoot,
            relative: Self.relativePath(resolved, under: mapping.macOSMountRoot)
        )
    }

    private func mapStreamSocket(_ resolved: String) throws -> String {
        return try mountOperationLock.withLock {
            if let existing = lock.withLock({
                mappings.first {
                    $0.transport == .streamSocket
                        && $0.macOSMountRoot == resolved
                }
            }) {
                _ = try socketRelaySupervisor.ensureRelay(
                    filesystemID: existing.filesystemID,
                    macOSSocketPath: resolved
                )
                return existing.effectiveLinuxSourceRoot
            }

            let filesystemID = DockerGuestFileUtilities.socketFilesystemID(
                forCanonicalPath: resolved
            )
            let linuxPath = try socketRelaySupervisor.ensureRelay(
                filesystemID: filesystemID,
                macOSSocketPath: resolved
            )
            let mapping = GuestFilesystemMapping(
                filesystemID: filesystemID,
                macOSMountRoot: resolved,
                linuxMountRoot: "\(DockerGuestFileUtilities.socketRelayDirectory)/\(filesystemID)",
                transport: .streamSocket,
                remoteExportRoot: nil,
                linuxRelativePath: DockerGuestFileUtilities.fileExportName,
                followsRemoteSymlinks: nil
            )
            do {
                try lock.withLock {
                    mappings.append(mapping)
                    try persistMappings()
                }
            } catch {
                socketRelaySupervisor.removeRelay(filesystemID: filesystemID)
                throw error
            }
            return linuxPath
        }
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
                        "macvm-docker-guest: unable to restore Docker bind for \(mapping.macOSMountRoot) after sidecar reconnect: \(error.localizedDescription)\n".utf8
                    ))
                }
            }
        }
    }

    func mapLinuxPath(_ source: String) -> String {
        lock.withLock {
            guard let mapping = mappings
                .sorted(by: { $0.effectiveLinuxSourceRoot.count > $1.effectiveLinuxSourceRoot.count })
                .first(where: { Self.isPath(source, under: $0.effectiveLinuxSourceRoot) }) else {
                return source
            }
            return Self.join(
                root: mapping.macOSMountRoot,
                relative: Self.relativePath(source, under: mapping.effectiveLinuxSourceRoot)
            )
        }
    }

    private func pruneMissingMappings() throws -> [GuestFilesystemMapping] {
        let result = try lock.withLock { () throws -> (retained: [GuestFilesystemMapping], removed: [GuestFilesystemMapping]) in
            let retained = mappings.filter {
                if $0.transport == .streamSocket {
                    // Socket-producing daemons commonly replace their socket
                    // path during restart. Keep the listener so new connections
                    // recover automatically when the source returns.
                    return true
                }
                // Foundation can return a stale `true` for deleted descendants
                // of a VirtioFS mount. POSIX metadata reflects the live source.
                return DockerGuestFileUtilities.pathExists($0.macOSMountRoot)
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
            if mapping.transport == .streamSocket {
                socketRelaySupervisor.removeRelay(filesystemID: mapping.filesystemID)
            } else if mapping.remoteExportRoot != nil {
                try? FileManager.default.removeItem(atPath: mapping.effectiveRemoteExportRoot)
            }
            FileHandle.standardError.write(Data(
                "macvm-docker-guest: pruned stale bind mapping for \(mapping.macOSMountRoot)\n".utf8
            ))
        }
        return result.retained
    }

    private func ensureSidecarMount(_ mapping: GuestFilesystemMapping) throws -> GuestFilesystemMapping {
        if mapping.transport == .streamSocket {
            _ = try socketRelaySupervisor.ensureRelay(
                filesystemID: mapping.filesystemID,
                macOSSocketPath: mapping.macOSMountRoot
            )
            return mapping
        }
        try restorePersistedExportIfNeeded(mapping)
        guard !remountedFilesystemIDs.contains(mapping.filesystemID) else { return mapping }
        try? requestSidecarMount("unmount \(mapping.filesystemID)")
        let transport = try makeSidecarMount(
            filesystemID: mapping.filesystemID,
            exportRoot: mapping.effectiveRemoteExportRoot,
            followsRemoteSymlinks: mapping.shouldFollowRemoteSymlinks
        )
        remountedFilesystemIDs.insert(mapping.filesystemID)
        var updated = mapping
        updated.transport = transport
        return updated
    }

    private func makeSidecarMount(
        filesystemID: String,
        exportRoot: String,
        followsRemoteSymlinks: Bool
    ) throws -> GuestFilesystemMapping.Transport {
        let action = followsRemoteSymlinks ? "mount-sshfs-file" : "mount-sshfs"
        try requestSidecarMount(
            "\(action) \(filesystemID) \(setupUsername) \(exportRoot)"
        )
        return .sshfs
    }

    private func restorePersistedExportIfNeeded(_ mapping: GuestFilesystemMapping) throws {
        guard mapping.shouldFollowRemoteSymlinks else { return }
        let plan = DockerGuestFileUtilities.filesystemExportPlan(
            sourcePath: mapping.macOSMountRoot,
            isDirectory: false,
            stateDirectoryPath: stateURL.deletingLastPathComponent().path,
            filesystemID: mapping.filesystemID
        )
        guard plan.remoteExportRoot == mapping.effectiveRemoteExportRoot,
              plan.linuxRelativePath == mapping.linuxRelativePath else {
            throw GuestHelperError("Persisted exact-file Docker bind mapping is invalid.")
        }
        try prepareExport(plan: plan, sourcePath: mapping.macOSMountRoot)
    }

    private func prepareExport(
        plan: DockerGuestFilesystemExportPlan,
        sourcePath: String
    ) throws {
        guard plan.followsRemoteSymlinks else { return }
        let exportRoot = URL(fileURLWithPath: plan.remoteExportRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exportRoot.path)
        let linkURL = exportRoot.appendingPathComponent(plan.linuxRelativePath, isDirectory: false)
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
           destination == sourcePath {
            return
        }
        try? FileManager.default.removeItem(at: linkURL)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: sourcePath)
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

    private static func mappingID(for exportRoot: String, prefix: String = "path") throws -> String {
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
        return "\(prefix)-\(digest)"
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
