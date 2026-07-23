import Darwin
import Foundation
import MacVMClipboardProtocol

final class ClipboardOperationLock: @unchecked Sendable {
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
    var secretsDirectoryURL: URL {
        url.appendingPathComponent("Secrets", isDirectory: true)
    }

    var clipboardPairingKeyURL: URL {
        secretsDirectoryURL.appendingPathComponent("clipboard-pairing.key", isDirectory: false)
    }

    var clipboardOperationLockURL: URL {
        let resolvedBundleURL = url.resolvingSymlinksInPath().standardizedFileURL
        return resolvedBundleURL.deletingLastPathComponent().appendingPathComponent(
            ".\(resolvedBundleURL.lastPathComponent).clipboard.lock",
            isDirectory: false
        )
    }

    var clipboardKnownHostsURL: URL {
        setupDirectoryURL.appendingPathComponent("clipboard-known-hosts", isDirectory: false)
    }

    func acquireClipboardOperationLock(
        operation: String,
        nonblocking: Bool = true
    ) throws -> ClipboardOperationLock {
        try FileManager.default.createDirectory(
            at: clipboardOperationLockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(clipboardOperationLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MacVMError.message(
                "Couldn't lock clipboard state for '\(url.lastPathComponent)' while attempting to \(operation): \(String(cString: strerror(errno)))"
            )
        }
        let flags = nonblocking ? LOCK_EX | LOCK_NB : LOCK_EX
        guard flock(descriptor, flags) == 0 else {
            let detail = String(cString: strerror(errno))
            _ = close(descriptor)
            throw MacVMError.message(
                "Another clipboard operation is already in progress for '\(url.lastPathComponent)' (\(detail))."
            )
        }
        return ClipboardOperationLock(descriptor: descriptor)
    }
}

struct ClipboardPairingStore: Sendable {
    let bundle: VMBundle

    func readSecret() throws -> Data {
        let url = bundle.clipboardPairingKeyURL
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0 else {
            throw missingPairingKeyError
        }
        guard pathStatus.st_mode & S_IFMT == S_IFREG,
              pathStatus.st_uid == getuid(),
              pathStatus.st_mode & 0o777 == 0o600,
              pathStatus.st_size == off_t(ClipboardProtocolConstants.pairingSecretBytes) else {
            throw invalidPairingKeyError
        }

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw invalidPairingKeyError
        }
        defer { Darwin.close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              openedStatus.st_mode & S_IFMT == S_IFREG,
              openedStatus.st_uid == getuid(),
              openedStatus.st_mode & 0o777 == 0o600,
              openedStatus.st_size == off_t(ClipboardProtocolConstants.pairingSecretBytes) else {
            throw invalidPairingKeyError
        }
        do {
            return try ClipboardDescriptorIO.readExactly(
                from: descriptor,
                count: ClipboardProtocolConstants.pairingSecretBytes
            )
        } catch {
            throw invalidPairingKeyError
        }
    }

    private var missingPairingKeyError: MacVMError {
        .message(
            "Automatic Clipboard Sync is unpaired because the host pairing key is missing. Run `macvm clipboard install \(bundle.url.deletingPathExtension().lastPathComponent)` to repair it."
        )
    }

    private var invalidPairingKeyError: MacVMError {
        .message(
            "Automatic Clipboard Sync is unpaired because the host pairing key is invalid or insecure. Run `macvm clipboard install \(bundle.url.deletingPathExtension().lastPathComponent)` to repair it."
        )
    }

    /// Return the existing secret, or publish a fresh owner-only secret when absent.
    /// Corruption is never rotated by ordinary runtime startup; only an explicit
    /// install path passes `repairInvalid: true`.
    func ensureSecret(repairInvalid: Bool = false) throws -> Data {
        if FileManager.default.fileExists(atPath: bundle.clipboardPairingKeyURL.path) {
            do {
                return try readSecret()
            } catch where !repairInvalid {
                throw error
            } catch {
                // Repair is serialized below and replaces both host and guest keys.
            }
        }

        let operationLock = try bundle.acquireClipboardOperationLock(
            operation: repairInvalid ? "repair clipboard pairing" : "create clipboard pairing",
            nonblocking: false
        )
        defer { withExtendedLifetime(operationLock) {} }

        if FileManager.default.fileExists(atPath: bundle.clipboardPairingKeyURL.path) {
            do {
                return try readSecret()
            } catch where !repairInvalid {
                throw error
            } catch {
                try FileManager.default.removeItem(at: bundle.clipboardPairingKeyURL)
            }
        }

        let secret = try ClipboardAuthentication.randomBytes(
            count: ClipboardProtocolConstants.pairingSecretBytes
        )
        try publish(secret)
        return secret
    }

    /// Explicit installers hold the operation lock for their entire transaction.
    /// Reuse every valid active key; generate a replacement only when the active
    /// host state was already missing or corrupt, so a failed upgrade cannot unpair
    /// a previously authenticated helper.
    func ensureSecretWhileHoldingOperationLock(repairInvalid: Bool) throws -> Data {
        if FileManager.default.fileExists(atPath: bundle.clipboardPairingKeyURL.path) {
            do {
                return try readSecret()
            } catch where !repairInvalid {
                throw error
            } catch {
                try FileManager.default.removeItem(at: bundle.clipboardPairingKeyURL)
            }
        }
        let secret = try ClipboardAuthentication.randomBytes(
            count: ClipboardProtocolConstants.pairingSecretBytes
        )
        try publish(secret)
        return secret
    }

    private func publish(_ secret: Data) throws {
        guard secret.count == ClipboardProtocolConstants.pairingSecretBytes else {
            throw MacVMError.message("A clipboard pairing key must be exactly 32 bytes.")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: bundle.secretsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: bundle.secretsDirectoryURL.path
        )

        let temporaryURL = bundle.secretsDirectoryURL.appendingPathComponent(
            ".clipboard-pairing.\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporaryURL.path,
            O_CREAT | O_EXCL | O_WRONLY,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw MacVMError.message("Couldn't create the clipboard pairing key: \(String(cString: strerror(errno)))")
        }
        var publicationError: Error?
        do {
            try secret.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    guard count > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            publicationError = error
        }
        _ = close(descriptor)
        if let publicationError {
            try? fileManager.removeItem(at: temporaryURL)
            throw publicationError
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }

        // Hard-link publication is atomic and refuses to replace an existing key.
        guard link(temporaryURL.path, bundle.clipboardPairingKeyURL.path) == 0 else {
            if errno == EEXIST { return }
            throw MacVMError.message("Couldn't publish the clipboard pairing key: \(String(cString: strerror(errno)))")
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: bundle.clipboardPairingKeyURL.path
        )
        let directoryDescriptor = open(bundle.secretsDirectoryURL.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            _ = close(directoryDescriptor)
        }
    }
}
