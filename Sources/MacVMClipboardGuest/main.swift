import AppKit
import Darwin
import Foundation
import MacVMClipboardProtocol

private func readOwnerOnlyRegularFile(at url: URL, maximumBytes: Int) throws -> Data {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_uid == getuid(),
          status.st_mode & 0o777 == 0o600 else {
        throw ClipboardProtocolError.invalidPayload("\(url.lastPathComponent) must be an owner-only regular file")
    }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }

    var openedStatus = stat()
    guard fstat(descriptor, &openedStatus) == 0,
          openedStatus.st_dev == status.st_dev,
          openedStatus.st_ino == status.st_ino,
          openedStatus.st_size >= 0,
          openedStatus.st_size <= maximumBytes else {
        throw ClipboardProtocolError.invalidPayload("\(url.lastPathComponent) changed or is too large")
    }
    return try ClipboardDescriptorIO.readExactly(from: descriptor, count: Int(openedStatus.st_size))
}

private struct ClipboardGuestConfiguration: Codable {
    var vmID: UUID
    var pairingKeyPath: String

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacVM/Clipboard", isDirectory: true)
            .appendingPathComponent("configuration.json", isDirectory: false)
    }
}

private final class ClipboardGuestSession: @unchecked Sendable {
    private let descriptor: Int32
    private let sessionKey: Data
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var outboundSequence = ClipboardSequenceState()
    private var closed = false
    private var monitoringState = ClipboardGuestMonitoringState()
    private var pollTask: Task<Void, Never>?

    init(configuration: ClipboardGuestConfiguration) throws {
        let secret = try readOwnerOnlyRegularFile(
            at: URL(fileURLWithPath: configuration.pairingKeyPath),
            maximumBytes: ClipboardProtocolConstants.pairingSecretBytes
        )
        guard secret.count == ClipboardProtocolConstants.pairingSecretBytes else {
            throw ClipboardProtocolError.invalidPayload("the installed pairing key is invalid")
        }
        descriptor = try Self.connectToHost()
        do {
            try Self.configure(descriptor: descriptor)
            sessionKey = try Self.handshake(
                descriptor: descriptor,
                vmID: configuration.vmID,
                secret: secret
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    func run() async throws {
        pollTask = Task.detached(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self.pollPasteboard()
            }
        }
        defer {
            pollTask?.cancel()
            close()
        }

        var decoder = ClipboardFrameDecoder()
        let authentication = ClipboardFrameAuthentication(key: sessionKey, direction: .hostToGuest)
        while !stateLock.withLock({ closed }) {
            let wire = try ClipboardDescriptorIO.readWireFrame(from: descriptor)
            for frame in try decoder.append(wire, authentication: authentication) {
                try await handle(frame)
            }
        }
    }

    private func handle(_ frame: ClipboardFrame) async throws {
        switch frame.type {
        case .setMonitoring:
            let active = try ClipboardPayload.decodeBoolean(frame.payload)
            let changeCount = active
                ? await MainActor.run { NSPasteboard.general.changeCount }
                : 0
            stateLock.withLock {
                monitoringState.setMonitoring(active, baselineChangeCount: changeCount)
            }
            try send(type: .baselineAcknowledgement, id: frame.id, payload: ClipboardPayload.encodeChangeCount(changeCount))

        case .explicitReadRequest:
            let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
            guard let text else {
                try sendError(id: frame.id, error: .rejected("The guest pasteboard does not contain plain text."))
                return
            }
            do {
                try send(type: .explicitReadResponse, id: frame.id, payload: ClipboardPayload.encodeText(text))
            } catch ClipboardProtocolError.invalidUTF8 {
                try sendError(id: frame.id, error: .invalidUTF8)
            } catch ClipboardProtocolError.textTooLarge(let count) {
                try sendError(id: frame.id, error: .textTooLarge(count))
            }

        case .explicitWriteRequest:
            let text = try ClipboardPayload.decodeText(frame.payload)
            let produced = await writePasteboard(text)
            try send(type: .explicitWriteResponse, id: frame.id, payload: ClipboardPayload.encodeChangeCount(produced))

        case .clipboardCommit:
            let changed = try ClipboardPayload.decodeChangedText(frame.payload)
            let produced = await writePasteboard(changed.text)
            try send(type: .explicitWriteResponse, id: frame.id, payload: ClipboardPayload.encodeChangeCount(produced))

        case .ping:
            try send(type: .pong, id: frame.id, payload: Data())
        case .pong:
            break
        case .error:
            throw ClipboardProtocolError.invalidPayload(
                (try? ClipboardPayload.decodeText(frame.payload)) ?? "the host rejected the clipboard session"
            )
        default:
            throw ClipboardProtocolError.invalidPayload("unexpected host message \(frame.type)")
        }
    }

    private func writePasteboard(_ text: String) async -> Int {
        stateLock.withLock { monitoringState.beginRemoteWrite() }
        let changeCount = await MainActor.run { () -> Int in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return pasteboard.changeCount
        }
        stateLock.withLock {
            monitoringState.completeRemoteWrite(changeCount: changeCount)
        }
        return changeCount
    }

    private func pollPasteboard() async {
        guard let token = stateLock.withLock({ monitoringState.beginPoll() }) else { return }
        let snapshot = await MainActor.run { () -> (Int, String?) in
            let pasteboard = NSPasteboard.general
            return (pasteboard.changeCount, pasteboard.string(forType: .string))
        }
        let decision = stateLock.withLock {
            monitoringState.completePoll(token, changeCount: snapshot.0)
        }
        guard decision, let text = snapshot.1 else { return }
        do {
            let payload = try ClipboardPayload.encodeChangedText(changeCount: snapshot.0, text: text)
            try send(type: .guestChanged, id: 0, payload: payload)
        } catch ClipboardProtocolError.invalidUTF8 {
            // Unsupported automatic clipboard values are ignored without dropping
            // an otherwise healthy authenticated session.
        } catch ClipboardProtocolError.textTooLarge {
        } catch {
            // A partial or failed authenticated write makes the stream unusable.
            close()
        }
    }

    private func sendError(id: UInt64, error: ClipboardRequestError) throws {
        try send(type: .error, id: id, payload: error.encoded())
    }

    private func send(type: ClipboardMessageType, id: UInt64, payload: Data) throws {
        let deadline = Date().addingTimeInterval(3)
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
                direction: .guestToHost
            )),
            to: descriptor,
            deadline: deadline
        )
    }

    private func close() {
        let shouldClose = stateLock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        _ = writeLock.withLock { Darwin.close(descriptor) }
    }

    private static func connectToHost() throws -> Int32 {
        let descriptor = Darwin.socket(AF_VSOCK, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = ClipboardProtocolConstants.socketPort
        address.svm_cid = UInt32(VMADDR_CID_HOST)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private static func configure(descriptor: Int32) throws {
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func handshake(descriptor: Int32, vmID: UUID, secret: Data) throws -> Data {
        let guestVersions = ClipboardVersionRange()
        let guestNonce = try ClipboardAuthentication.randomBytes(count: ClipboardProtocolConstants.nonceBytes)
        let clientHello = try ClipboardClientHello(
            vmID: vmID,
            versions: guestVersions,
            helperBuildVersion: 1,
            guestNonce: guestNonce
        )
        let handshakeDeadline = Date().addingTimeInterval(ClipboardProtocolConstants.handshakeTimeout)
        try ClipboardDescriptorIO.writeAll(
            try ClipboardFrame(type: .clientHello, payload: clientHello.encoded()).encoded(),
            to: descriptor,
            deadline: handshakeDeadline
        )

        var decoder = ClipboardFrameDecoder()
        let serverWire = try ClipboardDescriptorIO.readWireFrame(
            from: descriptor,
            deadline: handshakeDeadline
        )
        let frames = try decoder.append(serverWire)
        guard frames.count == 1,
              frames[0].type == .serverHello,
              frames[0].id == 0 else {
            throw ClipboardProtocolError.invalidPayload("the host did not send a valid server hello")
        }
        let serverHello = try ClipboardServerHello.decode(frames[0].payload)
        let negotiatedVersion = guestVersions.negotiatedVersion(with: serverHello.versions) ?? 0
        guard serverHello.selectedVersion == negotiatedVersion else {
            throw ClipboardProtocolError.invalidPayload("the host selected an invalid application protocol version")
        }
        let transcript = try ClipboardHandshakeTranscript(
            vmID: vmID,
            guestVersions: guestVersions,
            hostVersions: serverHello.versions,
            helperBuildVersion: 1,
            hostBuildVersion: serverHello.hostBuildVersion,
            selectedVersion: serverHello.selectedVersion,
            guestNonce: guestNonce,
            hostNonce: serverHello.hostNonce
        )
        guard try ClipboardAuthentication.verifyHostProof(
            serverHello.hostProof,
            secret: secret,
            transcript: transcript
        ) else {
            throw ClipboardProtocolError.invalidAuthenticationTag
        }
        let sessionKey = try ClipboardAuthentication.sessionKey(secret: secret, transcript: transcript)
        guard serverHello.selectedVersion != 0 else {
            let errorWire = try ClipboardDescriptorIO.readWireFrame(
                from: descriptor,
                deadline: handshakeDeadline
            )
            let authentication = ClipboardFrameAuthentication(key: sessionKey, direction: .hostToGuest)
            var errorDecoder = ClipboardFrameDecoder()
            _ = try errorDecoder.append(errorWire, authentication: authentication)
            throw ClipboardProtocolError.incompatibleApplicationVersion
        }

        let guestProof = try ClipboardAuthentication.guestProof(secret: secret, transcript: transcript)
        try ClipboardDescriptorIO.writeAll(
            try ClipboardFrame(type: .clientProof, payload: guestProof).encoded(),
            to: descriptor,
            deadline: handshakeDeadline
        )
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return sessionKey
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

@main
private struct MacVMClipboardGuest {
    static func main() async {
        let configuration: ClipboardGuestConfiguration
        do {
            let data = try readOwnerOnlyRegularFile(
                at: ClipboardGuestConfiguration.defaultURL,
                maximumBytes: 64 * 1_024
            )
            configuration = try JSONDecoder().decode(ClipboardGuestConfiguration.self, from: data)
        } catch {
            fputs("macvm clipboard helper is not configured\n", stderr)
            return
        }

        var delay = 0.5
        while !Task.isCancelled {
            let connectedAt = Date()
            do {
                let session = try ClipboardGuestSession(configuration: configuration)
                try await session.run()
            } catch {
                fputs("macvm clipboard helper disconnected: \(error.localizedDescription)\n", stderr)
            }
            if Date().timeIntervalSince(connectedAt) >= 30 {
                delay = 0.5
            }
            let jitter = Double.random(in: 0...(delay * 0.25))
            try? await Task.sleep(for: .seconds(delay + jitter))
            delay = min(delay * 2, 10)
        }
    }
}
