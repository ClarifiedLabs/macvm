import Darwin
import Foundation
import MacVMClipboardProtocol
import Virtualization

enum ClipboardPeerFailure: Error, Sendable {
    case unpaired
    case outdatedHelper
    case hostUpdateRequired
    case unavailable(String)
}

final class ClipboardPeerConnection: @unchecked Sendable {
    static let hostBuildVersion: UInt32 = 1
    static let supportedVersions = ClipboardVersionRange()

    let helperBuildVersion: UInt32

    private let connection: VZVirtioSocketConnection?
    private let descriptor: Int32
    private let sessionKey: Data
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var outboundSequence = ClipboardSequenceState()
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<ClipboardFrame, Error>] = [:]
    private var ignoredResponseIDs = Set<UInt64>()
    private var ignoredResponseOrder: [UInt64] = []
    private var reservedRequestSlots = 0
    private var closed = false
    private var lastFrameAt = Date()
    private var heartbeatTask: Task<Void, Never>?

    var onGuestChanged: (@Sendable (Int, String) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    private init(
        connection: VZVirtioSocketConnection,
        descriptor: Int32,
        sessionKey: Data,
        helperBuildVersion: UInt32
    ) {
        self.connection = connection
        self.descriptor = descriptor
        self.sessionKey = sessionKey
        self.helperBuildVersion = helperBuildVersion
    }

    init(
        authenticatedDescriptor descriptor: Int32,
        sessionKey: Data,
        helperBuildVersion: UInt32 = 1
    ) throws {
        guard sessionKey.count == ClipboardProtocolConstants.pairingSecretBytes else {
            throw ClipboardProtocolError.invalidPayload("invalid session key length")
        }
        self.connection = nil
        self.descriptor = descriptor
        self.sessionKey = sessionKey
        self.helperBuildVersion = helperBuildVersion
    }

    static func authenticate(
        connection: VZVirtioSocketConnection,
        expectedVMID: UUID,
        secret: Data
    ) throws -> ClipboardPeerConnection {
        let descriptor = connection.fileDescriptor
        guard descriptor >= 0 else {
            throw ClipboardPeerFailure.unavailable("The clipboard socket has no file descriptor.")
        }
        try configure(descriptor: descriptor)
        let handshakeDeadline = Date().addingTimeInterval(ClipboardProtocolConstants.handshakeTimeout)

        let helloWire = try ClipboardDescriptorIO.readWireFrame(
            from: descriptor,
            deadline: handshakeDeadline
        )
        var handshakeDecoder = ClipboardFrameDecoder()
        let helloFrames = try handshakeDecoder.append(helloWire)
        guard helloFrames.count == 1,
              helloFrames[0].type == .clientHello,
              helloFrames[0].id == 0 else {
            throw ClipboardPeerFailure.unpaired
        }
        let clientHello = try ClipboardClientHello.decode(helloFrames[0].payload)
        guard clientHello.vmID == expectedVMID else {
            throw ClipboardPeerFailure.unpaired
        }

        let selected = clientHello.versions.negotiatedVersion(with: supportedVersions) ?? 0
        let hostNonce = try ClipboardAuthentication.randomBytes(
            count: ClipboardProtocolConstants.nonceBytes
        )
        let transcript = try ClipboardHandshakeTranscript(
            vmID: expectedVMID,
            guestVersions: clientHello.versions,
            hostVersions: supportedVersions,
            helperBuildVersion: clientHello.helperBuildVersion,
            hostBuildVersion: hostBuildVersion,
            selectedVersion: selected,
            guestNonce: clientHello.guestNonce,
            hostNonce: hostNonce
        )
        let proof = try ClipboardAuthentication.hostProof(secret: secret, transcript: transcript)
        let serverHello = try ClipboardServerHello(
            versions: supportedVersions,
            selectedVersion: selected,
            hostBuildVersion: hostBuildVersion,
            hostNonce: hostNonce,
            hostProof: proof
        )
        try ClipboardDescriptorIO.writeAll(
            try ClipboardFrame(type: .serverHello, payload: serverHello.encoded()).encoded(),
            to: descriptor,
            deadline: handshakeDeadline
        )

        guard selected != 0 else {
            let key = try ClipboardAuthentication.sessionKey(secret: secret, transcript: transcript)
            let errorPayload = try ClipboardPayload.encodeText("No compatible clipboard application protocol version.")
            let frame = ClipboardFrame(type: .error, sequence: 1, payload: errorPayload)
            try? ClipboardDescriptorIO.writeAll(
                try frame.encoded(authentication: ClipboardFrameAuthentication(key: key, direction: .hostToGuest)),
                to: descriptor,
                deadline: handshakeDeadline
            )
            if clientHello.versions.maximum < supportedVersions.minimum {
                throw ClipboardPeerFailure.outdatedHelper
            }
            throw ClipboardPeerFailure.hostUpdateRequired
        }

        let proofWire = try ClipboardDescriptorIO.readWireFrame(
            from: descriptor,
            deadline: handshakeDeadline
        )
        let proofFrames = try handshakeDecoder.append(proofWire)
        guard proofFrames.count == 1,
              proofFrames[0].type == .clientProof,
              proofFrames[0].id == 0,
              proofFrames[0].payload.count == ClipboardProtocolConstants.authenticationTagBytes,
              try ClipboardAuthentication.verifyGuestProof(
                proofFrames[0].payload,
                secret: secret,
                transcript: transcript
              ) else {
            throw ClipboardPeerFailure.unpaired
        }

        try clearHandshakeReceiveTimeout(descriptor: descriptor)
        return ClipboardPeerConnection(
            connection: connection,
            descriptor: descriptor,
            sessionKey: try ClipboardAuthentication.sessionKey(secret: secret, transcript: transcript),
            helperBuildVersion: clientHello.helperBuildVersion
        )
    }

    func start() {
        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(ClipboardProtocolConstants.heartbeatInterval))
                if Task.isCancelled { return }
                let lastFrameAt = self.stateLock.withLock { self.lastFrameAt }
                guard Date().timeIntervalSince(lastFrameAt) < ClipboardProtocolConstants.heartbeatTimeout else {
                    self.close()
                    return
                }
                do {
                    try self.send(type: .ping, id: 0, payload: Data())
                } catch {
                    self.close(error: error)
                    return
                }
            }
        }
        let shouldStart = stateLock.withLock { () -> Bool in
            guard !closed, heartbeatTask == nil else { return false }
            heartbeatTask = task
            return true
        }
        guard shouldStart else {
            task.cancel()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readLoop()
        }
    }

    func setMonitoring(_ active: Bool, timeout: TimeInterval = 3) async throws {
        let response = try await request(
            type: .setMonitoring,
            payload: ClipboardPayload.encodeBoolean(active),
            timeout: timeout
        )
        guard response.type == .baselineAcknowledgement else {
            throw ClipboardProtocolError.invalidPayload("monitoring request received an unexpected response")
        }
    }

    func readText(timeout: TimeInterval) async throws -> String {
        let response = try await request(type: .explicitReadRequest, payload: Data(), timeout: timeout)
        guard response.type == .explicitReadResponse else {
            throw ClipboardProtocolError.invalidPayload("read request received an unexpected response")
        }
        return try ClipboardPayload.decodeText(response.payload)
    }

    @discardableResult
    func writeText(_ text: String, timeout: TimeInterval) async throws -> Int {
        let response = try await request(
            type: .explicitWriteRequest,
            payload: ClipboardPayload.encodeText(text),
            timeout: timeout
        )
        guard response.type == .explicitWriteResponse else {
            throw ClipboardProtocolError.invalidPayload("write request received an unexpected response")
        }
        return try ClipboardPayload.decodeChangeCount(response.payload)
    }

    @discardableResult
    func commitText(_ text: String, sourceChangeCount: Int, timeout: TimeInterval = 3) async throws -> Int {
        let response = try await request(
            type: .clipboardCommit,
            payload: ClipboardPayload.encodeChangedText(changeCount: sourceChangeCount, text: text),
            timeout: timeout
        )
        guard response.type == .explicitWriteResponse else {
            throw ClipboardProtocolError.invalidPayload("clipboard commit received an unexpected response")
        }
        return try ClipboardPayload.decodeChangeCount(response.payload)
    }

    func close(error: Error = ClipboardProtocolError.connectionClosed) {
        let retained: ([CheckedContinuation<ClipboardFrame, Error>], Task<Void, Never>?, Bool) = stateLock.withLock {
            guard !closed else { return ([], nil, false) }
            closed = true
            let values = Array(pending.values)
            pending.removeAll()
            let heartbeat = heartbeatTask
            heartbeatTask = nil
            return (values, heartbeat, true)
        }
        guard retained.2 else { return }
        retained.1?.cancel()
        writeLock.withLock {
            if let connection {
                connection.close()
            } else {
                Darwin.close(descriptor)
            }
        }
        retained.0.forEach { $0.resume(throwing: error) }
    }

    private func request(type: ClipboardMessageType, payload: Data, timeout: TimeInterval) async throws -> ClipboardFrame {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        let requestID: UInt64 = try stateLock.withLock {
            guard !closed else { throw ClipboardProtocolError.connectionClosed }
            guard pending.count + reservedRequestSlots < ClipboardProtocolConstants.maximumPendingRequests else {
                throw ClipboardProtocolError.requestLimitExceeded
            }
            let id = nextRequestID
            let (next, overflow) = nextRequestID.addingReportingOverflow(1)
            guard !overflow, next != 0 else { throw ClipboardProtocolError.requestLimitExceeded }
            reservedRequestSlots += 1
            nextRequestID = next
            return id
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let inserted = stateLock.withLock { () -> Bool in
                    reservedRequestSlots -= 1
                    guard !closed else { return false }
                    pending[requestID] = continuation
                    return true
                }
                guard inserted else {
                    continuation.resume(throwing: ClipboardProtocolError.connectionClosed)
                    return
                }
                guard !Task.isCancelled else {
                    failRequest(requestID, error: CancellationError(), expectLateResponse: true)
                    return
                }
                Task.detached { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, timeout)))
                    self?.failRequest(
                        requestID,
                        error: ClipboardProtocolError.timedOut,
                        expectLateResponse: true
                    )
                }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    guard stateLock.withLock({ pending[requestID] != nil }) else { return }
                    do {
                        try send(type: type, id: requestID, payload: payload, deadline: deadline)
                    } catch {
                        failRequest(requestID, error: error)
                        close(error: error)
                    }
                }
            }
        } onCancel: {
            self.failRequest(requestID, error: CancellationError(), expectLateResponse: true)
        }
    }

    private func send(
        type: ClipboardMessageType,
        id: UInt64,
        payload: Data,
        deadline: Date = Date().addingTimeInterval(3)
    ) throws {
        guard writeLock.lock(before: deadline) else {
            throw ClipboardProtocolError.timedOut
        }
        defer { writeLock.unlock() }
        guard !stateLock.withLock({ closed }) else {
            throw ClipboardProtocolError.connectionClosed
        }
        let sequence = try outboundSequence.takeOutbound()
        let frame = ClipboardFrame(type: type, id: id, sequence: sequence, payload: payload)
        try ClipboardDescriptorIO.writeAll(
            try frame.encoded(authentication: ClipboardFrameAuthentication(
                key: sessionKey,
                direction: .hostToGuest
            )),
            to: descriptor,
            deadline: deadline
        )
    }

    private func readLoop() {
        var decoder = ClipboardFrameDecoder()
        let authentication = ClipboardFrameAuthentication(key: sessionKey, direction: .guestToHost)
        do {
            while !stateLock.withLock({ closed }) {
                let wire = try ClipboardDescriptorIO.readWireFrame(from: descriptor)
                let frames = try decoder.append(wire, authentication: authentication)
                for frame in frames {
                    stateLock.withLock { lastFrameAt = Date() }
                    try handle(frame)
                }
            }
        } catch {
            close(error: error)
            onDisconnect?()
        }
    }

    private func handle(_ frame: ClipboardFrame) throws {
        switch frame.type {
        case .guestChanged:
            let changed = try ClipboardPayload.decodeChangedText(frame.payload)
            onGuestChanged?(changed.changeCount, changed.text)
        case .ping:
            try send(type: .pong, id: frame.id, payload: Data())
        case .pong:
            break
        case .baselineAcknowledgement, .explicitReadResponse, .explicitWriteResponse, .error:
            guard frame.id != 0 else {
                if frame.type == .error { return }
                throw ClipboardProtocolError.invalidPayload("response request ID is zero")
            }
            // Decode before removing the waiter. If the payload is malformed,
            // readLoop closes the connection and resumes every pending request.
            // Removing first would orphan this continuation forever.
            let requestError: ClipboardRequestError? = if frame.type == .error {
                try ClipboardRequestError.decode(frame.payload)
            } else {
                nil
            }
            let resolved = stateLock.withLock { () -> (CheckedContinuation<ClipboardFrame, Error>?, Bool) in
                if let continuation = pending.removeValue(forKey: frame.id) {
                    return (continuation, false)
                }
                if ignoredResponseIDs.remove(frame.id) != nil {
                    ignoredResponseOrder.removeAll { $0 == frame.id }
                    return (nil, true)
                }
                return (nil, false)
            }
            if resolved.1 { return }
            guard let continuation = resolved.0 else {
                throw ClipboardProtocolError.invalidPayload("response request ID is not pending")
            }
            if let requestError {
                continuation.resume(throwing: requestError.protocolError)
            } else {
                continuation.resume(returning: frame)
            }
        default:
            throw ClipboardProtocolError.invalidPayload("unexpected helper message \(frame.type)")
        }
    }

    private func failRequest(
        _ id: UInt64,
        error: Error,
        expectLateResponse: Bool = false
    ) {
        let continuation = stateLock.withLock { () -> CheckedContinuation<ClipboardFrame, Error>? in
            guard let continuation = pending.removeValue(forKey: id) else { return nil }
            if expectLateResponse {
                ignoredResponseIDs.insert(id)
                ignoredResponseOrder.append(id)
                let maximumIgnored = ClipboardProtocolConstants.maximumPendingRequests * 4
                while ignoredResponseOrder.count > maximumIgnored {
                    ignoredResponseIDs.remove(ignoredResponseOrder.removeFirst())
                }
            }
            return continuation
        }
        continuation?.resume(throwing: error)
    }

    private static func configure(descriptor: Int32) throws {
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func clearHandshakeReceiveTimeout(descriptor: Int32) throws {
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
