import Darwin
import Foundation

public final class DockerTransientIdentityFile: @unchecked Sendable {
    public let url: URL

    private let directoryURL: URL
    private let lock = NSLock()
    private var removed = false

    public init(
        privateKey: Data,
        rootDirectory: URL,
        ownerUID: uid_t,
        ownerGID: gid_t
    ) throws {
        guard !privateKey.isEmpty, privateKey.count <= 16_384 else {
            throw DockerGuestCoreError("Invalid transient Docker relay identity.")
        }
        try Self.prepareRootDirectory(rootDirectory)

        let directoryURL = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard mkdir(directoryURL.path, 0o700) == 0 else {
            throw DockerGuestCoreError("Unable to create the transient Docker relay identity directory.")
        }
        self.directoryURL = directoryURL
        self.url = directoryURL.appendingPathComponent("identity", isDirectory: false)

        var initialized = false
        defer {
            if !initialized {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }
        guard chown(directoryURL.path, ownerUID, ownerGID) == 0,
              chmod(directoryURL.path, 0o700) == 0 else {
            throw DockerGuestCoreError("Unable to secure the transient Docker relay identity directory.")
        }

        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw DockerGuestCoreError("Unable to create the transient Docker relay identity.")
        }
        defer { close(descriptor) }
        guard fchown(descriptor, ownerUID, ownerGID) == 0,
              fchmod(descriptor, 0o600) == 0,
              Self.write(privateKey, to: descriptor) == 0,
              fsync(descriptor) == 0 else {
            throw DockerGuestCoreError("Unable to secure the transient Docker relay identity.")
        }
        initialized = true
    }

    deinit {
        try? remove()
    }

    public func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        do {
            try FileManager.default.removeItem(at: directoryURL)
            removed = true
        } catch CocoaError.fileNoSuchFile {
            removed = true
        }
    }

    public static func pruneRootDirectory(_ rootDirectory: URL) throws {
        try prepareRootDirectory(rootDirectory)
        for entry in try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.removeItem(at: entry)
        }
    }

    private static func prepareRootDirectory(_ rootDirectory: URL) throws {
        var metadata = stat()
        if lstat(rootDirectory.path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw DockerGuestCoreError("Unable to inspect the Docker relay identity root.")
            }
            try FileManager.default.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o711]
            )
            guard lstat(rootDirectory.path, &metadata) == 0 else {
                throw DockerGuestCoreError("Unable to inspect the Docker relay identity root.")
            }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(),
              metadata.st_mode & 0o022 == 0,
              chmod(rootDirectory.path, 0o711) == 0 else {
            throw DockerGuestCoreError("The Docker relay identity root is unsafe.")
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) -> Int32 {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return EINVAL }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if count == 0 { return EIO }
                offset += count
            }
            return 0
        }
    }
}
