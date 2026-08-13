import Darwin
import Foundation
import MacVMDockerGuestCore

struct GuestExportInstallationRollback {
    fileprivate let filesystemID: String
    fileprivate let previousDescriptor: Data?
    fileprivate let authorizedKeysExisted: Bool
    fileprivate let previousAuthorizedKeys: String
    let replacedExistingCapability: Bool
}

final class GuestExportManager {
    static let executablePath = "/usr/local/libexec/macvm-docker-guest"

    private let exportsDirectory: URL
    private let configurationPath: String
    private let accountUID: uid_t
    private let accountGID: gid_t
    private let homeDirectoryPath: String
    private let lock = NSLock()

    init(
        stateDirectory: URL,
        configurationPath: String,
        setupUsername: String,
        retainingFilesystemIDs: Set<String>
    ) throws {
        guard let account = getpwnam(setupUsername) else {
            throw GuestHelperError("Couldn't find setup account '\(setupUsername)'.")
        }
        self.exportsDirectory = stateDirectory.appendingPathComponent("Exports", isDirectory: true)
        self.configurationPath = configurationPath
        self.accountUID = account.pointee.pw_uid
        self.accountGID = account.pointee.pw_gid
        self.homeDirectoryPath = String(cString: account.pointee.pw_dir)

        try FileManager.default.createDirectory(
            at: exportsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o711]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o711], ofItemAtPath: exportsDirectory.path)
        try updateAuthorizedKeys { contents in
            DockerExportCapability.removingLegacyAndUnknownExportKeys(
                from: contents,
                retaining: retainingFilesystemIDs
            )
        }
        try pruneDescriptors(retaining: retainingFilesystemIDs)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func install(
        filesystemID: String,
        sourcePath: String,
        kind: DockerExportKind,
        publicKey: String
    ) throws -> GuestExportInstallationRollback {
        try withLock {
            let capability = try DockerExportCapability(
                filesystemID: filesystemID,
                sourcePath: sourcePath,
                kind: kind
            )
            let descriptorURL = self.descriptorURL(filesystemID: filesystemID)
            let line = try capability.authorizedKeyLine(
                publicKey: publicKey,
                executablePath: Self.executablePath,
                configurationPath: configurationPath
            )
            let previousDescriptor = try dataIfPresent(at: descriptorURL)
            let authorizedKeys = try readAuthorizedKeysSnapshot()
            let rollback = GuestExportInstallationRollback(
                filesystemID: filesystemID,
                previousDescriptor: previousDescriptor,
                authorizedKeysExisted: authorizedKeys.existed,
                previousAuthorizedKeys: authorizedKeys.contents,
                replacedExistingCapability: previousDescriptor != nil
                    || DockerExportCapability.containsAuthorizedKey(
                        in: authorizedKeys.contents,
                        filesystemID: filesystemID
                    )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encodedCapability = try encoder.encode(capability)

            try DockerExportInstallTransaction.perform(
                installDescriptor: {
                    try self.writeDescriptor(encodedCapability, to: descriptorURL)
                },
                installAuthorization: {
                    try self.updateAuthorizedKeys { contents in
                        try DockerExportCapability.replacingAuthorizedKey(
                            in: contents,
                            filesystemID: filesystemID,
                            with: line
                        )
                    }
                },
                restoreAuthorization: {
                    try self.restoreAuthorizedKeys(rollback)
                },
                restoreDescriptor: {
                    try self.restoreDescriptor(rollback)
                }
            )
            return rollback
        }
    }

    func restore(_ rollback: GuestExportInstallationRollback) throws {
        try withLock {
            var rollbackErrors: [String] = []
            do {
                try restoreDescriptor(rollback)
            } catch {
                rollbackErrors.append("restore descriptor: \(error.localizedDescription)")
            }
            do {
                try restoreAuthorizedKeys(rollback)
            } catch {
                rollbackErrors.append("restore authorization: \(error.localizedDescription)")
            }
            guard rollbackErrors.isEmpty else {
                throw GuestHelperError(
                    "Couldn't restore the previous Docker export capability: "
                        + rollbackErrors.joined(separator: "; ")
                )
            }
        }
    }

    func remove(filesystemID: String) throws {
        try withLock {
            var firstError: (any Error)?
            do {
                try updateAuthorizedKeys { contents in
                    try DockerExportCapability.replacingAuthorizedKey(
                        in: contents,
                        filesystemID: filesystemID,
                        with: nil
                    )
                }
            } catch {
                firstError = error
            }
            do {
                try FileManager.default.removeItem(at: descriptorURL(filesystemID: filesystemID))
            } catch CocoaError.fileNoSuchFile {
                // An absent descriptor is already revoked.
            } catch {
                if firstError == nil { firstError = error }
            }
            if let firstError { throw firstError }
        }
    }

    static func loadCapability(
        filesystemID: String,
        stateDirectory: URL
    ) throws -> DockerExportCapability {
        guard DockerMountBrokerCommand.isValidFilesystemID(filesystemID) else {
            throw GuestHelperError("Invalid Docker export filesystem ID.")
        }
        let url = stateDirectory
            .appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent("\(filesystemID).json", isDirectory: false)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0 else {
            throw GuestHelperError("Docker export capability is missing or unsafe.")
        }
        let capability = try JSONDecoder().decode(
            DockerExportCapability.self,
            from: Data(contentsOf: url)
        )
        try capability.validate()
        guard capability.filesystemID == filesystemID else {
            throw GuestHelperError("Docker export capability ID does not match its filename.")
        }
        return capability
    }

    private func descriptorURL(filesystemID: String) -> URL {
        exportsDirectory.appendingPathComponent("\(filesystemID).json", isDirectory: false)
    }

    private func dataIfPresent(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private func writeDescriptor(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: url.path
        )
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // The desired prior state is already restored.
        }
    }

    private func restoreDescriptor(_ rollback: GuestExportInstallationRollback) throws {
        let url = descriptorURL(filesystemID: rollback.filesystemID)
        if let previousDescriptor = rollback.previousDescriptor {
            try writeDescriptor(previousDescriptor, to: url)
        } else {
            try removeIfPresent(url)
        }
    }

    private func pruneDescriptors(retaining filesystemIDs: Set<String>) throws {
        for url in try FileManager.default.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) where url.pathExtension == "json" {
            let identifier = url.deletingPathExtension().lastPathComponent
            if !filesystemIDs.contains(identifier) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func readAuthorizedKeysSnapshot() throws -> (existed: Bool, contents: String) {
        try withSecureSSHDirectory { directory in
            try readAuthorizedKeys(in: directory)
        }
    }

    private func restoreAuthorizedKeys(_ rollback: GuestExportInstallationRollback) throws {
        if rollback.authorizedKeysExisted {
            try withSecureSSHDirectory { directory in
                try writeAuthorizedKeys(rollback.previousAuthorizedKeys, in: directory)
            }
        } else {
            try removeAuthorizedKeysIfPresent()
        }
    }

    private func updateAuthorizedKeys(_ transform: (String) throws -> String) throws {
        try withSecureSSHDirectory { directory in
            let existing = try readAuthorizedKeys(in: directory).contents
            try writeAuthorizedKeys(try transform(existing), in: directory)
        }
    }

    private func removeAuthorizedKeysIfPresent() throws {
        try withSecureSSHDirectory { directory in
            let result = "authorized_keys".withCString { unlinkat(directory, $0, 0) }
            guard result == 0 || errno == ENOENT else {
                throw posixFailure("remove Docker export authorization")
            }
            guard fsync(directory) == 0 else {
                throw posixFailure("synchronize Docker export authorization directory")
            }
        }
    }

    private func withSecureSSHDirectory<T>(_ body: (Int32) throws -> T) throws -> T {
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        let homeDescriptor = homeDirectoryPath.withCString { open($0, directoryFlags) }
        guard homeDescriptor >= 0 else {
            throw posixFailure("open the setup account home directory")
        }
        defer { close(homeDescriptor) }

        var homeMetadata = stat()
        guard fstat(homeDescriptor, &homeMetadata) == 0,
              homeMetadata.st_mode & S_IFMT == S_IFDIR,
              homeMetadata.st_uid == accountUID else {
            throw GuestHelperError("The setup account home directory is unsafe for Docker export authorization.")
        }

        var createdDirectory = false
        let createResult = ".ssh".withCString { mkdirat(homeDescriptor, $0, 0o700) }
        if createResult == 0 {
            createdDirectory = true
        } else if errno != EEXIST {
            throw posixFailure("create the setup account SSH directory")
        }

        let sshDescriptor = ".ssh".withCString { openat(homeDescriptor, $0, directoryFlags) }
        guard sshDescriptor >= 0 else {
            throw posixFailure("open the setup account SSH directory")
        }
        defer { close(sshDescriptor) }

        var sshMetadata = stat()
        guard fstat(sshDescriptor, &sshMetadata) == 0,
              sshMetadata.st_mode & S_IFMT == S_IFDIR,
              sshMetadata.st_uid == accountUID || (createdDirectory && sshMetadata.st_uid == geteuid()) else {
            throw GuestHelperError("The setup account SSH directory is unsafe for Docker export authorization.")
        }
        if sshMetadata.st_uid != accountUID,
           fchown(sshDescriptor, accountUID, accountGID) != 0 {
            throw posixFailure("set setup account SSH directory ownership")
        }
        guard fchmod(sshDescriptor, 0o700) == 0 else {
            throw posixFailure("secure the setup account SSH directory")
        }

        let result = try body(sshDescriptor)
        var linkedMetadata = stat()
        let statResult = ".ssh".withCString {
            fstatat(homeDescriptor, $0, &linkedMetadata, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0,
              linkedMetadata.st_mode & S_IFMT == S_IFDIR,
              linkedMetadata.st_dev == sshMetadata.st_dev,
              linkedMetadata.st_ino == sshMetadata.st_ino else {
            throw GuestHelperError("The setup account SSH directory changed during Docker export authorization.")
        }
        return result
    }

    private func readAuthorizedKeys(in directory: Int32) throws -> (existed: Bool, contents: String) {
        let descriptor = "authorized_keys".withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT {
            return (false, "")
        }
        guard descriptor >= 0 else {
            throw posixFailure("open Docker export authorization")
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == accountUID,
              metadata.st_mode & 0o022 == 0 else {
            close(descriptor)
            throw GuestHelperError("The setup account authorized_keys file is unsafe.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try handle.readToEnd() ?? Data()
        guard let contents = String(data: data, encoding: .utf8) else {
            throw GuestHelperError("The setup account authorized_keys file is not UTF-8.")
        }
        return (true, contents)
    }

    private func writeAuthorizedKeys(_ contents: String, in directory: Int32) throws {
        let temporaryName = ".authorized_keys.macvm-\(UUID().uuidString)"
        let descriptor = temporaryName.withCString {
            openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw posixFailure("create Docker export authorization")
        }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary {
                _ = temporaryName.withCString { unlinkat(directory, $0, 0) }
            }
        }

        guard fchown(descriptor, accountUID, accountGID) == 0,
              fchmod(descriptor, 0o600) == 0 else {
            throw posixFailure("secure Docker export authorization")
        }
        try write(contents.data(using: .utf8) ?? Data(), to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw posixFailure("synchronize Docker export authorization")
        }
        let renameResult = temporaryName.withCString { temporaryPath in
            "authorized_keys".withCString { destinationPath in
                renameat(directory, temporaryPath, directory, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw posixFailure("publish Docker export authorization")
        }
        removeTemporary = false
        guard fsync(directory) == 0 else {
            throw posixFailure("synchronize Docker export authorization directory")
        }
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw posixFailure("write Docker export authorization")
                }
                offset += count
            }
        }
    }

    private func posixFailure(_ action: String, code: Int32 = errno) -> GuestHelperError {
        GuestHelperError("Unable to \(action): \(String(cString: strerror(code))).")
    }
}
