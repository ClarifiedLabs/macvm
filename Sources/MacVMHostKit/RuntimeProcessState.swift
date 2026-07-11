import Foundation

public enum VMProcessRuntimeRole: String, Codable, Sendable {
    case viewer
    case headless
    /// A VM hosted in the multi-VM MacVM Manager process. External stop
    /// commands must never terminate this process to stop a single guest.
    case manager
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
