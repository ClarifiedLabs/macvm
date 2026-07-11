import Foundation

/// Descriptor for a live VNC session, published by every VM owner so
/// entitlement-free client commands (`screenshot`/`type`/`keys`/…) can attach to
/// the loopback RFB port without owning the `VZVirtualMachine`.
public struct VNCSession: Codable, Equatable, Sendable {
    public var port: Int
    public var password: String?
    public var pid: Int32
    public var startedAt: Date
    public var ownerRole: VMProcessRuntimeRole

    public init(
        port: Int,
        password: String?,
        pid: Int32,
        startedAt: Date,
        ownerRole: VMProcessRuntimeRole = .headless
    ) {
        self.port = port
        self.password = password
        self.pid = pid
        self.startedAt = startedAt
        self.ownerRole = ownerRole
    }

    /// The loopback `vnc://` URL clients can hand to the system VNC handler.
    public var vncURLString: String {
        let credentials = password.map { ":\($0)@" } ?? ""
        return "vnc://\(credentials)127.0.0.1:\(port)"
    }

    /// True if the process that published this session is still alive. `kill(pid, 0)`
    /// returns EPERM (not ESRCH) when the pid exists but is owned by another user,
    /// which still means "live".
    public var isLive: Bool {
        processExists(pid: pid)
    }
}
