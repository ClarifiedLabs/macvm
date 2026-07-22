import Darwin
import Foundation

public struct FedoraCoreOSImage: Codable, Equatable, Sendable {
    public let stream: String
    public let architecture: String
    public let platform: String
    public let format: String
    public let release: String
    public let downloadURL: URL
    public let compressedSHA256: String
    public let uncompressedSHA256: String

    public init(
        stream: String,
        architecture: String,
        platform: String,
        format: String,
        release: String,
        downloadURL: URL,
        compressedSHA256: String,
        uncompressedSHA256: String
    ) {
        self.stream = stream
        self.architecture = architecture
        self.platform = platform
        self.format = format
        self.release = release
        self.downloadURL = downloadURL
        self.compressedSHA256 = compressedSHA256.lowercased()
        self.uncompressedSHA256 = uncompressedSHA256.lowercased()
    }
}

public struct FedoraCoreOSCachedImage: Equatable, Sendable {
    public let image: FedoraCoreOSImage
    public let rawImageURL: URL
    public let refreshedAt: Date

    public init(image: FedoraCoreOSImage, rawImageURL: URL, refreshedAt: Date) {
        self.image = image
        self.rawImageURL = rawImageURL
        self.refreshedAt = refreshedAt
    }
}

struct DockerSidecarMetadata: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentIgnitionVersion = 4

    var schemaVersion: Int
    var createdAt: Date
    var image: FedoraCoreOSImage
    var ignitionVersion: Int
    var genericMachineIdentifierDigest: String
    var dataDiskBlockIdentifier: String
    /// Identifies a staged replacement so interrupted atomic exchanges can be recovered.
    var replacementCandidateID: UUID?

    init(
        schemaVersion: Int = currentSchemaVersion,
        createdAt: Date = Date(),
        image: FedoraCoreOSImage,
        ignitionVersion: Int = currentIgnitionVersion,
        genericMachineIdentifierDigest: String,
        dataDiskBlockIdentifier: String = DockerSidecarBundle.dataDiskBlockIdentifier,
        replacementCandidateID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.image = image
        self.ignitionVersion = ignitionVersion
        self.genericMachineIdentifierDigest = genericMachineIdentifierDigest
        self.dataDiskBlockIdentifier = dataDiskBlockIdentifier
        self.replacementCandidateID = replacementCandidateID
    }

    func requiresUpdate(to image: FedoraCoreOSImage) -> Bool {
        self.image.uncompressedSHA256 != image.uncompressedSHA256
            || ignitionVersion != Self.currentIgnitionVersion
    }
}

public enum DockerSidecarState: String, Codable, CaseIterable, Equatable, Sendable {
    case disabled
    case preparing
    case pendingGuestProvisioning
    case stopped
    case starting
    case ready
    case degraded
    case corrupt
}

public struct DockerSidecarStatus: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var state: DockerSidecarState
    public var updatedAt: Date
    public var ownerPID: Int32?
    public var fcosVersion: String?
    public var mobyVersion: String?
    public var cpuCount: Int?
    public var memorySizeBytes: UInt64?
    public var dataDiskSizeBytes: UInt64?
    public var dataDiskAllocatedBytes: UInt64?
    public var amd64Requested: Bool
    public var amd64Available: Bool
    public var lastError: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        state: DockerSidecarState,
        updatedAt: Date = Date(),
        ownerPID: Int32? = nil,
        fcosVersion: String? = nil,
        mobyVersion: String? = nil,
        cpuCount: Int? = nil,
        memorySizeBytes: UInt64? = nil,
        dataDiskSizeBytes: UInt64? = nil,
        dataDiskAllocatedBytes: UInt64? = nil,
        amd64Requested: Bool = false,
        amd64Available: Bool = false,
        lastError: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.updatedAt = updatedAt
        self.ownerPID = ownerPID
        self.fcosVersion = fcosVersion
        self.mobyVersion = mobyVersion
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.dataDiskSizeBytes = dataDiskSizeBytes
        self.dataDiskAllocatedBytes = dataDiskAllocatedBytes
        self.amd64Requested = amd64Requested
        self.amd64Available = amd64Available
        self.lastError = lastError
    }
}

struct DockerSidecarRuntimeDescriptor: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var state: DockerSidecarState
    var pid: Int32
    var startedAt: Date
    var updatedAt: Date
    var fcosVersion: String
    var mobyVersion: String?
    var amd64Available: Bool
    var lastError: String?

    var isLive: Bool {
        guard [.preparing, .starting, .pendingGuestProvisioning, .ready, .degraded].contains(state),
              pid > 0,
              abs(Date().timeIntervalSince(updatedAt)) <= 30 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
