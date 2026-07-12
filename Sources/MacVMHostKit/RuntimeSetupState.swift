import Foundation

/// Runtime marker published while `macvm setup` or the manager setup flow owns a
/// VM. It lets other clients distinguish setup from a plain headless run and
/// rebuild a useful progress view after reconnecting.
public struct VMSetupRuntimeState: Codable, Equatable, Sendable {
    public var username: String
    public var fullName: String
    public var phaseIndex: Int?
    public var phaseCount: Int
    public var phases: [SetupPhase]
    public var statusMessage: String?
    public var logMessages: [String]
    public var failureMessage: String?
    public var ipAddress: String?
    public var sshReady: Bool
    public var activeLog: SetupLogArtifact?
    public var installsXcode: Bool
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        username: String,
        fullName: String,
        phaseIndex: Int? = nil,
        phaseCount: Int,
        phases: [SetupPhase] = [],
        statusMessage: String? = nil,
        logMessages: [String] = [],
        failureMessage: String? = nil,
        ipAddress: String? = nil,
        sshReady: Bool = false,
        activeLog: SetupLogArtifact? = nil,
        installsXcode: Bool = false,
        pid: Int32,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.username = username
        self.fullName = fullName
        self.phaseIndex = phaseIndex
        self.phaseCount = phaseCount
        self.phases = phases
        self.statusMessage = statusMessage
        self.logMessages = logMessages
        self.failureMessage = failureMessage
        self.ipAddress = ipAddress
        self.sshReady = sshReady
        self.activeLog = activeLog
        self.installsXcode = installsXcode
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case username
        case fullName
        case phaseIndex
        case phaseCount
        case phases
        case statusMessage
        case logMessages
        case failureMessage
        case ipAddress
        case sshReady
        case activeLog
        case installsXcode
        case pid
        case startedAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        username = try values.decode(String.self, forKey: .username)
        fullName = try values.decode(String.self, forKey: .fullName)
        phaseIndex = try values.decodeIfPresent(Int.self, forKey: .phaseIndex)
        phaseCount = try values.decode(Int.self, forKey: .phaseCount)
        phases = try values.decodeIfPresent([SetupPhase].self, forKey: .phases) ?? []
        statusMessage = try values.decodeIfPresent(String.self, forKey: .statusMessage)
        logMessages = try values.decodeIfPresent([String].self, forKey: .logMessages) ?? []
        failureMessage = try values.decodeIfPresent(String.self, forKey: .failureMessage)
        ipAddress = try values.decodeIfPresent(String.self, forKey: .ipAddress)
        sshReady = try values.decodeIfPresent(Bool.self, forKey: .sshReady) ?? false
        activeLog = try values.decodeIfPresent(SetupLogArtifact.self, forKey: .activeLog)
        installsXcode = try values.decode(Bool.self, forKey: .installsXcode)
        pid = try values.decode(Int32.self, forKey: .pid)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public var isLive: Bool {
        processExists(pid: pid)
    }
}
