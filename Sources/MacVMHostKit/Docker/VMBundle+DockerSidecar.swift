import Darwin
import Foundation

final class DockerSidecarOperationLock: @unchecked Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

extension VMBundle {
    var dockerSidecarDirectoryURL: URL {
        url.appendingPathComponent("DockerSidecar", isDirectory: true)
    }

    var dockerSidecarBundle: DockerSidecarBundle {
        DockerSidecarBundle(url: dockerSidecarDirectoryURL)
    }

    var dockerSidecarRuntimeURL: URL {
        runtimeDirectoryURL.appendingPathComponent("docker-sidecar.json")
    }

    var dockerSidecarOperationLockURL: URL {
        // Keep the inode outside the removable bundle. Resolve aliases so every
        // path to one bundle also contends on the same stable sibling inode.
        let resolvedBundleURL = url.resolvingSymlinksInPath().standardizedFileURL
        return resolvedBundleURL.deletingLastPathComponent().appendingPathComponent(
            ".\(resolvedBundleURL.lastPathComponent).docker-sidecar.lock",
            isDirectory: false
        )
    }

    var dockerGuestKnownHostsURL: URL {
        setupDirectoryURL.appendingPathComponent("docker-known-hosts")
    }

    func acquireDockerSidecarOperationLock(operation: String) throws -> DockerSidecarOperationLock {
        try FileManager.default.createDirectory(
            at: dockerSidecarOperationLockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(dockerSidecarOperationLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MacVMError.message(
                "Couldn't lock Docker state for '\(url.lastPathComponent)' while attempting to \(operation): \(String(cString: strerror(errno)))"
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let detail = String(cString: strerror(errno))
            _ = close(descriptor)
            throw MacVMError.message(
                "Another Docker operation is already in progress for '\(url.lastPathComponent)' (\(detail))."
            )
        }
        return DockerSidecarOperationLock(descriptor: descriptor)
    }

    func writeDockerSidecarRuntimeDescriptor(_ descriptor: DockerSidecarRuntimeDescriptor) throws {
        try FileManager.default.createDirectory(at: runtimeDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(descriptor).write(to: dockerSidecarRuntimeURL, options: .atomic)
    }

    func readDockerSidecarRuntimeDescriptor() -> DockerSidecarRuntimeDescriptor? {
        guard let data = try? Data(contentsOf: dockerSidecarRuntimeURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DockerSidecarRuntimeDescriptor.self, from: data)
    }

    func liveDockerSidecarRuntimeDescriptor() -> DockerSidecarRuntimeDescriptor? {
        guard let descriptor = readDockerSidecarRuntimeDescriptor(),
              descriptor.isLive else {
            return nil
        }
        return descriptor
    }

    func clearDockerSidecarRuntimeDescriptor() {
        try? FileManager.default.removeItem(at: dockerSidecarRuntimeURL)
    }

    func dockerSidecarAllocatedSizeBytes() -> UInt64 {
        dockerSidecarBundle.allocatedSizeBytes()
    }

    func removeDockerSidecar(preservingIdentity: Bool = false) throws {
        clearDockerSidecarRuntimeDescriptor()
        try dockerSidecarBundle.remove(preservingIdentity: preservingIdentity)
    }
}
