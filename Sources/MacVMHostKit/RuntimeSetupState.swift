import Foundation

/// Runtime marker published while `macvm setup` or the manager setup flow owns a
/// VM. It lets other clients distinguish setup from a plain headless run and
/// rebuild a useful progress view after reconnecting.
public struct VMSetupRuntimeState: Codable, Equatable, Sendable {
    public var username: String
    public var fullName: String
    public var phaseIndex: Int?
    public var phaseCount: Int
    public var failureMessage: String?
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date

    public init(
        username: String,
        fullName: String,
        phaseIndex: Int? = nil,
        phaseCount: Int,
        failureMessage: String? = nil,
        pid: Int32,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.username = username
        self.fullName = fullName
        self.phaseIndex = phaseIndex
        self.phaseCount = phaseCount
        self.failureMessage = failureMessage
        self.pid = pid
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    public var isLive: Bool {
        processExists(pid: pid)
    }
}
