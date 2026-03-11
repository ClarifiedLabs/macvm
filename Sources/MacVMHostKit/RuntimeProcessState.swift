import Foundation

public enum VMProcessRuntimeRole: String, Codable, Sendable {
    case viewer
    case headless
}

public struct VMProcessRuntimeState: Codable, Equatable, Sendable {
    public var role: VMProcessRuntimeRole
    public var pid: Int32
    public var startedAt: Date
    public var logPath: String?

    public init(
        role: VMProcessRuntimeRole,
        pid: Int32,
        startedAt: Date,
        logPath: String? = nil
    ) {
        self.role = role
        self.pid = pid
        self.startedAt = startedAt
        self.logPath = logPath
    }

    public var isLive: Bool {
        processExists(pid: pid)
    }
}
