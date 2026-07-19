import CryptoKit
import Darwin
import Foundation
import Virtualization

struct DockerSidecarBundle {
    static let dataDiskBlockIdentifier = "macvm-docker-data"

    let url: URL

    var metadataURL: URL { url.appendingPathComponent("Metadata.json") }
    var systemDiskURL: URL { url.appendingPathComponent("SystemDisk.raw") }
    var dataDiskURL: URL { url.appendingPathComponent("DataDisk.raw") }
    var efiVariableStoreURL: URL { url.appendingPathComponent("EFIVariableStore") }
    var genericMachineIdentifierURL: URL { url.appendingPathComponent("GenericMachineIdentifier") }
    var identityDirectoryURL: URL { url.appendingPathComponent("Identity", isDirectory: true) }
    var dockerAuthorizedKeyURL: URL { identityDirectoryURL.appendingPathComponent("docker_authorized_key.pub") }
    var pendingDockerPrivateKeyURL: URL { identityDirectoryURL.appendingPathComponent("docker_pending_ed25519") }
    var pendingDockerPublicKeyURL: URL { identityDirectoryURL.appendingPathComponent("docker_pending_ed25519.pub") }
    var mountBrokerAuthorizedKeyURL: URL { identityDirectoryURL.appendingPathComponent("mount_broker_authorized_key.pub") }
    var pendingMountBrokerPrivateKeyURL: URL { identityDirectoryURL.appendingPathComponent("mount_broker_pending_ed25519") }
    var pendingMountBrokerPublicKeyURL: URL { identityDirectoryURL.appendingPathComponent("mount_broker_pending_ed25519.pub") }
    var linuxHostPrivateKeyURL: URL { identityDirectoryURL.appendingPathComponent("ssh_host_ed25519_key") }
    var linuxHostPublicKeyURL: URL { identityDirectoryURL.appendingPathComponent("ssh_host_ed25519_key.pub") }
    var ignitionDirectoryURL: URL { url.appendingPathComponent("Ignition", isDirectory: true) }
    var initialIgnitionURL: URL { ignitionDirectoryURL.appendingPathComponent("initial.ign") }

    var requiredFileURLs: [URL] {
        [
            metadataURL,
            systemDiskURL,
            dataDiskURL,
            efiVariableStoreURL,
            genericMachineIdentifierURL,
            dockerAuthorizedKeyURL,
            mountBrokerAuthorizedKeyURL,
            linuxHostPrivateKeyURL,
            linuxHostPublicKeyURL,
            initialIgnitionURL,
        ]
    }

    var isPresent: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func createDirectories() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: identityDirectoryURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: ignitionDirectoryURL, withIntermediateDirectories: false)
    }

    func missingRequiredFiles() -> [URL] {
        requiredFileURLs.filter { !FileManager.default.fileExists(atPath: $0.path) }
    }

    func validateIntegrity() throws -> DockerSidecarMetadata {
        let missing = missingRequiredFiles()
        guard missing.isEmpty else {
            let names = missing.map(\.lastPathComponent).joined(separator: ", ")
            throw MacVMError.message("Docker sidecar at \(url.path) is incomplete; missing: \(names). Run `macvm docker reset --force` to repair it.")
        }
        let metadata = try readMetadata()
        guard metadata.schemaVersion == DockerSidecarMetadata.currentSchemaVersion else {
            throw MacVMError.message(
                "Docker sidecar metadata version \(metadata.schemaVersion) is unsupported (expected \(DockerSidecarMetadata.currentSchemaVersion))."
            )
        }
        let machineIdentifier = try loadGenericMachineIdentifier()
        let machineDigest = Self.sha256Hex(machineIdentifier.dataRepresentation)
        guard machineDigest == metadata.genericMachineIdentifierDigest else {
            throw MacVMError.message(
                "Docker sidecar generic machine identity does not match its metadata. Run `macvm docker reset --force` to repair it."
            )
        }
        return metadata
    }

    func writeMetadata(_ metadata: DockerSidecarMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    func readMetadata() throws -> DockerSidecarMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(DockerSidecarMetadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.schemaVersion > 0 else {
            throw MacVMError.message("Docker sidecar metadata at \(metadataURL.path) has an invalid schema version.")
        }
        return metadata
    }

    @discardableResult
    func createGenericMachineIdentifier() throws -> VZGenericMachineIdentifier {
        let identifier = VZGenericMachineIdentifier()
        try identifier.dataRepresentation.write(to: genericMachineIdentifierURL, options: .atomic)
        return identifier
    }

    func loadGenericMachineIdentifier() throws -> VZGenericMachineIdentifier {
        let data = try Data(contentsOf: genericMachineIdentifierURL)
        guard let identifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
            throw MacVMError.message("Couldn't load the Docker sidecar machine identifier at \(genericMachineIdentifierURL.path).")
        }
        return identifier
    }

    func refreshGenericMachineIdentifier() throws -> String {
        let identifier = try createGenericMachineIdentifier()
        return Self.sha256Hex(identifier.dataRepresentation)
    }

    func createEFIVariableStore() throws {
        _ = try VZEFIVariableStore(
            creatingVariableStoreAt: efiVariableStoreURL,
            options: []
        )
    }

    func loadEFIVariableStore() -> VZEFIVariableStore {
        VZEFIVariableStore(url: efiVariableStoreURL)
    }

    func createSparseDataDisk(sizeBytes: UInt64) throws {
        guard !FileManager.default.fileExists(atPath: dataDiskURL.path) else {
            try growDataDisk(to: sizeBytes)
            return
        }
        try truncateFile(at: dataDiskURL, sizeBytes: sizeBytes)
    }

    func growDataDisk(to sizeBytes: UInt64) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: dataDiskURL.path)
        let currentSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard sizeBytes >= currentSize else {
            throw MacVMError.message(
                "Docker data disk cannot be shrunk from \(VMText.gibLabel(for: currentSize)) to \(VMText.gibLabel(for: sizeBytes)); use `macvm docker reset --force` for a smaller fresh disk."
            )
        }
        guard sizeBytes > currentSize else { return }
        try truncateFile(at: dataDiskURL, sizeBytes: sizeBytes)
    }

    func logicalDataDiskSize() -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: dataDiskURL.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }

    func allocatedSizeBytes() -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .isRegularFileKey,
            ]), values.isRegularFile == true else { continue }
            let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0
            total += UInt64(max(0, size))
        }
        return total
    }

    func remove(preservingIdentity: Bool = false) throws {
        guard isPresent else { return }
        if preservingIdentity, FileManager.default.fileExists(atPath: identityDirectoryURL.path) {
            let temporaryIdentity = url.deletingLastPathComponent().appendingPathComponent(
                ".docker-identity-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: identityDirectoryURL, to: temporaryIdentity)
            defer { try? FileManager.default.removeItem(at: temporaryIdentity) }
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: temporaryIdentity, to: identityDirectoryURL)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func truncateFile(at fileURL: URL, sizeBytes: UInt64) throws {
        guard sizeBytes > 0, sizeBytes <= UInt64(Int64.max) else {
            throw MacVMError.message("Invalid Docker data disk size: \(sizeBytes) bytes.")
        }
        let descriptor = open(fileURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw posixError("Couldn't create Docker data disk", path: fileURL.path)
        }
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(sizeBytes)) == 0 else {
            throw posixError("Couldn't resize Docker data disk", path: fileURL.path)
        }
        guard fsync(descriptor) == 0 else {
            throw posixError("Couldn't synchronize Docker data disk", path: fileURL.path)
        }
    }

    private func posixError(_ operation: String, path: String) -> MacVMError {
        MacVMError.message("\(operation) at \(path): \(String(cString: strerror(errno)))")
    }
}
