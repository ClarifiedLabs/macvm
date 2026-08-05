import Darwin
import Foundation

/// Retains an exclusive advisory lock for a VM's disk lifecycle.
///
/// The descriptor must remain open for the lock's full lifetime. Keeping it
/// private and immutable makes sharing the handle across concurrency domains
/// safe; the lock is released only after the last reference is destroyed.
final class VMDiskLifecycleLock: @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

extension VMBundle {
    /// A stable inode outside the removable bundle, shared by every symlinked
    /// or non-standardized path that resolves to this bundle.
    var diskLifecycleLockURL: URL {
        let resolvedBundleURL = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return resolvedBundleURL.deletingLastPathComponent().appendingPathComponent(
            ".\(resolvedBundleURL.lastPathComponent).disk.lock",
            isDirectory: false
        )
    }

    /// Acquires the disk lifecycle lock without waiting, reporting contention
    /// as an operation-specific, user-facing error.
    func acquireDiskLifecycleLock(operation: String) throws -> VMDiskLifecycleLock {
        guard let lock = try tryAcquireDiskLifecycleLock(operation: operation) else {
            throw MacVMError.message(
                "Another disk operation is already in progress for '\(url.lastPathComponent)'. "
                    + "Wait for it to finish before attempting to \(operation)."
            )
        }
        return lock
    }

    /// Attempts to acquire the disk lifecycle lock without waiting.
    ///
    /// Returns `nil` only when another descriptor holds the lock. Other open
    /// or locking failures remain actionable errors.
    func tryAcquireDiskLifecycleLock(
        operation: String = "use the disk"
    ) throws -> VMDiskLifecycleLock? {
        let lockURL = diskLifecycleLockURL
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            let detail = String(cString: strerror(errno))
            throw MacVMError.message(
                "Couldn't lock the disk for '\(url.lastPathComponent)' while attempting to \(operation): \(detail)"
            )
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                return nil
            }
            let detail = String(cString: strerror(code))
            throw MacVMError.message(
                "Couldn't lock the disk for '\(url.lastPathComponent)' while attempting to \(operation): \(detail)"
            )
        }

        return VMDiskLifecycleLock(descriptor: descriptor)
    }

    /// The caller must already retain `VMDiskLifecycleLock`; this avoids a
    /// second flock attempt while bringing an interrupted resize to a coherent
    /// source or target state before a boot/clone operation observes Disk.img.
    func recoverDiskResizeWhileHoldingLifecycleLock() throws -> VMMetadata {
        try DiskResizeTransaction().recoverIfNeeded(bundle: self)
    }

    /// Removal is the one operation allowed to discard an incomplete candidate,
    /// because it discards the whole VM bundle after detaching any exact image.
    /// The caller must already retain `VMDiskLifecycleLock`.
    func discardDiskResizeWhileHoldingLifecycleLock() throws {
        try DiskResizeTransaction().discardForRemoval(bundle: self)
    }
}
