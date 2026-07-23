import Foundation
import MacVMClipboardProtocol
@preconcurrency import Virtualization

public enum ClipboardHelperConnectionState: String, Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    case unpaired
    case outdatedHelper
    case hostUpdateRequired
    case unavailable

    public var displayName: String {
        switch self {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .unpaired: "Unpaired"
        case .outdatedHelper: "Helper update required"
        case .hostUpdateRequired: "Host update required"
        case .unavailable: "Unavailable"
        }
    }
}

final class ClipboardSocketServer: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    let listener = VZVirtioSocketListener()

    private let vmID: UUID
    private let secret: Data
    private let lock = NSLock()
    private var pendingConnections: [ObjectIdentifier: VZVirtioSocketConnection] = [:]
    private var authenticatedPeer: ClipboardPeerConnection?
    private var stopped = false

    var onStateChange: (@Sendable (ClipboardHelperConnectionState) -> Void)?
    var onGuestChanged: (@Sendable (Int, String) -> Void)?
    var onAuthenticatedPeerChange: (@Sendable () -> Void)?

    init(vmID: UUID, secret: Data) {
        self.vmID = vmID
        self.secret = secret
        super.init()
        listener.delegate = self
    }

    func install(on virtualMachine: VZVirtualMachine) throws {
        guard let socketDevice = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw MacVMError.message(
                "Automatic Clipboard Sync is unavailable because this VM boot does not have a virtio socket device. Shut down the VM completely, then start it again."
            )
        }
        socketDevice.setSocketListener(listener, forPort: ClipboardProtocolConstants.socketPort)
        onStateChange?(.connecting)
    }

    var peer: ClipboardPeerConnection? {
        lock.withLock { authenticatedPeer }
    }

    func disconnect(_ peer: ClipboardPeerConnection) {
        let removed = lock.withLock { () -> Bool in
            guard authenticatedPeer === peer else { return false }
            authenticatedPeer = nil
            return true
        }
        guard removed else { return }
        peer.close()
        onStateChange?(.disconnected)
        onAuthenticatedPeerChange?()
    }

    func stop() {
        let retained: ([VZVirtioSocketConnection], ClipboardPeerConnection?) = lock.withLock {
            guard !stopped else { return ([], nil) }
            stopped = true
            listener.delegate = nil
            let pending = Array(pendingConnections.values)
            pendingConnections.removeAll()
            let peer = authenticatedPeer
            authenticatedPeer = nil
            return (pending, peer)
        }
        retained.0.forEach { $0.close() }
        retained.1?.close()
    }

    nonisolated func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard !stopped,
                  pendingConnections.count < ClipboardProtocolConstants.maximumPendingHandshakes else {
                return false
            }
            pendingConnections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard accepted else { return false }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.authenticate(connection)
        }
        return true
    }

    private func authenticate(_ connection: VZVirtioSocketConnection) {
        let identifier = ObjectIdentifier(connection)
        defer {
            _ = lock.withLock { pendingConnections.removeValue(forKey: identifier) }
        }

        do {
            let candidate = try ClipboardPeerConnection.authenticate(
                connection: connection,
                expectedVMID: vmID,
                secret: secret
            )
            candidate.onGuestChanged = { [weak self, weak candidate] changeCount, text in
                guard let self, let candidate,
                      self.lock.withLock({ self.authenticatedPeer === candidate }) else { return }
                self.onGuestChanged?(changeCount, text)
            }
            candidate.onDisconnect = { [weak self, weak candidate] in
                guard let self, let candidate else { return }
                let removed = self.lock.withLock { () -> Bool in
                    guard self.authenticatedPeer === candidate else { return false }
                    self.authenticatedPeer = nil
                    return true
                }
                if removed {
                    self.onStateChange?(.disconnected)
                    self.onAuthenticatedPeerChange?()
                }
            }

            let previous: ClipboardPeerConnection? = lock.withLock {
                guard !stopped else { return candidate }
                let old = authenticatedPeer
                authenticatedPeer = candidate
                return old
            }
            guard previous !== candidate else {
                candidate.close()
                return
            }
            previous?.close()
            // Publish the generation before its read loop can observe immediate EOF;
            // otherwise a disconnect followed by a stale connected event is possible.
            onStateChange?(.connected)
            onAuthenticatedPeerChange?()
            candidate.start()
        } catch ClipboardPeerFailure.unpaired {
            connection.close()
            publishInvalidAttemptState(.unpaired)
        } catch ClipboardPeerFailure.outdatedHelper {
            connection.close()
            publishInvalidAttemptState(.outdatedHelper)
        } catch ClipboardPeerFailure.hostUpdateRequired {
            connection.close()
            publishInvalidAttemptState(.hostUpdateRequired)
        } catch {
            connection.close()
            publishInvalidAttemptState(.unavailable)
        }
    }

    private func publishInvalidAttemptState(_ state: ClipboardHelperConnectionState) {
        // An unauthenticated attempt never evicts or visually downgrades a healthy peer.
        guard lock.withLock({ authenticatedPeer == nil && !stopped }) else { return }
        onStateChange?(state)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
