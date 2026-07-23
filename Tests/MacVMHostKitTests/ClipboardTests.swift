import Darwin
import Foundation
import MacVMClipboardProtocol
import Testing
@testable import MacVMHostKit

private let clipboardGiB: UInt64 = 1024 * 1024 * 1024

private func makeClipboardTestBundle() throws -> (root: URL, bundle: VMBundle) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macvm-clipboard-tests-\(UUID().uuidString)", isDirectory: true)
    let url = root.appendingPathComponent("test.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return (root, VMBundle(url: url))
}

private func clipboardTestMetadata(
    id: UUID = UUID(),
    automaticSync: Bool? = false
) -> VMMetadata {
    VMMetadata(
        id: id,
        name: "test",
        cpuCount: 2,
        memorySizeBytes: 4 * clipboardGiB,
        diskSizeBytes: 40 * clipboardGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        automaticClipboardSyncEnabled: automaticSync
    )
}

@MainActor
private final class ClipboardRuntimeMock: ClipboardRuntimeAccess {
    var enabled = true
    var onGuestChanged: ((Int, String) -> Void)?
    var onPeerChange: (() -> Void)?
    var onSynchronizationInvalidated: (() -> Void)?
    private(set) var viewerActive = false
    private(set) var monitoring: [Bool] = []
    private(set) var completedMonitoring: [Bool] = []
    private(set) var effectiveMonitoring: Bool?
    private(set) var commits: [(text: String, sourceChangeCount: Int)] = []
    var suspendMonitoringValue: Bool?
    var suspendCommits = false
    private var monitoringContinuation: CheckedContinuation<Void, Never>?
    private var commitContinuation: CheckedContinuation<Void, Never>?

    func setViewerActive(_ active: Bool) {
        viewerActive = active
    }

    func setMonitoring(_ active: Bool) async throws {
        monitoring.append(active)
        if suspendMonitoringValue == active {
            await withCheckedContinuation { continuation in
                monitoringContinuation = continuation
            }
        }
        completedMonitoring.append(active)
        effectiveMonitoring = active
    }

    func commitText(_ text: String, sourceChangeCount: Int) async throws -> Int {
        commits.append((text, sourceChangeCount))
        if suspendCommits {
            await withCheckedContinuation { continuation in
                commitContinuation = continuation
            }
        }
        return sourceChangeCount
    }

    var hasSuspendedMonitoring: Bool {
        monitoringContinuation != nil
    }

    func resumeMonitoring() {
        suspendMonitoringValue = nil
        monitoringContinuation?.resume()
        monitoringContinuation = nil
    }

    var hasSuspendedCommit: Bool {
        commitContinuation != nil
    }

    func resumeCommit() {
        suspendCommits = false
        commitContinuation?.resume()
        commitContinuation = nil
    }

    func emitGuestChange(changeCount: Int, text: String) {
        onGuestChanged?(changeCount, text)
    }

    func emitPeerChange() {
        onPeerChange?()
    }
}

@MainActor
private final class ClipboardPasteboardMock: ClipboardPasteboardAccess {
    private(set) var changeCount = 1
    private var text: String? = "initial"

    func string() -> String? {
        text
    }

    func writeString(_ text: String) -> Int {
        changeCount += 1
        self.text = text
        return changeCount
    }

    func replaceLocally(with text: String?) {
        changeCount += 1
        self.text = text
    }
}

@Test
func clipboardGuestMonitoringRejectsSnapshotOverlappingRemoteWrite() {
    var state = ClipboardGuestMonitoringState()
    state.setMonitoring(true, baselineChangeCount: 10)
    let staleToken = state.beginPoll()
    #expect(staleToken != nil)

    state.beginRemoteWrite()
    state.completeRemoteWrite(changeCount: 11)
    let acceptedStaleSnapshot = state.completePoll(staleToken!, changeCount: 10)
    #expect(!acceptedStaleSnapshot)

    let freshToken = state.beginPoll()
    #expect(freshToken != nil)
    let acceptedFreshSnapshot = state.completePoll(freshToken!, changeCount: 12)
    #expect(acceptedFreshSnapshot)
}

@Test
func clipboardPayloadEnforcesExactUTF8ByteLimit() throws {
    let exact = String(repeating: "a", count: ClipboardProtocolConstants.maximumTextBytes)
    let encoded = try ClipboardPayload.encodeText(exact)
    #expect(try ClipboardPayload.decodeText(encoded) == exact)

    let tooLarge = String(repeating: "a", count: ClipboardProtocolConstants.maximumTextBytes + 1)
    #expect(throws: ClipboardProtocolError.textTooLarge(ClipboardProtocolConstants.maximumTextBytes + 1)) {
        try ClipboardPayload.encodeText(tooLarge)
    }

    let invalidUTF8 = Data([0, 0, 0, 2, 0xff, 0xff])
    #expect(throws: ClipboardProtocolError.invalidUTF8) {
        try ClipboardPayload.decodeText(invalidUTF8)
    }
}

@Test
func clipboardFrameDecoderHandlesFragmentationAndCoalescing() throws {
    let key = Data(repeating: 0x41, count: ClipboardProtocolConstants.pairingSecretBytes)
    let outgoing = ClipboardFrameAuthentication(key: key, direction: .hostToGuest)
    let incoming = ClipboardFrameAuthentication(key: key, direction: .hostToGuest)
    let first = ClipboardFrame(type: .ping, id: 7, sequence: 1, payload: Data([1, 2, 3]))
    let second = ClipboardFrame(type: .pong, id: 8, sequence: 2, payload: Data([4, 5]))
    let firstWire = try first.encoded(authentication: outgoing)
    let secondWire = try second.encoded(authentication: outgoing)

    var fragmented = ClipboardFrameDecoder()
    var decoded: [ClipboardFrame] = []
    for byte in firstWire {
        decoded.append(contentsOf: try fragmented.append(Data([byte]), authentication: incoming))
    }
    #expect(decoded == [first])
    #expect(fragmented.bufferedByteCount == 0)

    var coalesced = ClipboardFrameDecoder()
    #expect(try coalesced.append(firstWire + secondWire, authentication: incoming) == [first, second])
}

@Test
func clipboardFrameAuthenticationRejectsTamperingReplayAndReordering() throws {
    let key = Data(repeating: 0x22, count: ClipboardProtocolConstants.pairingSecretBytes)
    let authentication = ClipboardFrameAuthentication(key: key, direction: .guestToHost)
    let frame = ClipboardFrame(type: .guestChanged, id: 12, sequence: 1, payload: Data([9]))
    let wire = try frame.encoded(authentication: authentication)

    var tampered = wire
    tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
    var tamperDecoder = ClipboardFrameDecoder()
    #expect(throws: ClipboardProtocolError.invalidAuthenticationTag) {
        try tamperDecoder.append(tampered, authentication: authentication)
    }

    var wrongDirectionDecoder = ClipboardFrameDecoder()
    #expect(throws: ClipboardProtocolError.invalidAuthenticationTag) {
        try wrongDirectionDecoder.append(
            wire,
            authentication: ClipboardFrameAuthentication(key: key, direction: .hostToGuest)
        )
    }

    var replayDecoder = ClipboardFrameDecoder()
    #expect(try replayDecoder.append(wire, authentication: authentication) == [frame])
    #expect(throws: ClipboardProtocolError.invalidSequence(expected: 2, actual: 1)) {
        try replayDecoder.append(wire, authentication: authentication)
    }

    let reordered = ClipboardFrame(type: .pong, sequence: 2)
    var reorderDecoder = ClipboardFrameDecoder()
    #expect(throws: ClipboardProtocolError.invalidSequence(expected: 1, actual: 2)) {
        try reorderDecoder.append(
            reordered.encoded(authentication: authentication),
            authentication: authentication
        )
    }
}

@Test
func clipboardFrameDecoderRejectsMalformedAndOversizedHeaders() throws {
    var invalidLengthDecoder = ClipboardFrameDecoder()
    #expect(throws: ClipboardProtocolError.invalidLength(4_294_967_295)) {
        try invalidLengthDecoder.append(Data([0xff, 0xff, 0xff, 0xff]))
    }

    let hello = ClipboardFrame(type: .clientHello, payload: Data(repeating: 0, count: ClipboardClientHello.encodedLength))
    var wire = try hello.encoded()
    wire[4] = 0
    var invalidMagicDecoder = ClipboardFrameDecoder()
    #expect(throws: ClipboardProtocolError.invalidMagic) {
        try invalidMagicDecoder.append(wire)
    }
}

@Test
func clipboardDescriptorIOHandlesFragmentationEOFDeadlinesAndInvalidLengths() async throws {
    var fragmentedDescriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fragmentedDescriptors) == 0)
    guard fragmentedDescriptors.allSatisfy({ $0 >= 0 }) else { return }
    defer {
        close(fragmentedDescriptors[0])
        close(fragmentedDescriptors[1])
    }
    let expected = Data("fragmented descriptor data".utf8)
    let fragmentedReader = fragmentedDescriptors[0]
    let fragmentedWriter = fragmentedDescriptors[1]
    let writer = Task.detached {
        try ClipboardDescriptorIO.writeAll(expected.prefix(3), to: fragmentedWriter)
        try await Task.sleep(for: .milliseconds(10))
        try ClipboardDescriptorIO.writeAll(expected.dropFirst(3), to: fragmentedWriter)
    }
    #expect(try ClipboardDescriptorIO.readExactly(
        from: fragmentedReader,
        count: expected.count,
        deadline: Date().addingTimeInterval(1)
    ) == expected)
    try await writer.value

    var eofDescriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &eofDescriptors) == 0)
    guard eofDescriptors.allSatisfy({ $0 >= 0 }) else { return }
    defer { close(eofDescriptors[0]) }
    try ClipboardDescriptorIO.writeAll(Data([1, 2]), to: eofDescriptors[1])
    close(eofDescriptors[1])
    #expect(throws: ClipboardProtocolError.connectionClosed) {
        try ClipboardDescriptorIO.readExactly(from: eofDescriptors[0], count: 3)
    }

    var deadlineDescriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &deadlineDescriptors) == 0)
    guard deadlineDescriptors.allSatisfy({ $0 >= 0 }) else { return }
    defer {
        close(deadlineDescriptors[0])
        close(deadlineDescriptors[1])
    }
    #expect(throws: ClipboardProtocolError.timedOut) {
        try ClipboardDescriptorIO.readExactly(
            from: deadlineDescriptors[0],
            count: 1,
            deadline: Date().addingTimeInterval(0.01)
        )
    }

    var backpressureDescriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &backpressureDescriptors) == 0)
    guard backpressureDescriptors.allSatisfy({ $0 >= 0 }) else { return }
    defer {
        close(backpressureDescriptors[0])
        close(backpressureDescriptors[1])
    }
    var sendBufferBytes: Int32 = 4_096
    #expect(setsockopt(
        backpressureDescriptors[0],
        SOL_SOCKET,
        SO_SNDBUF,
        &sendBufferBytes,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0)
    var originalSendTimeout = timeval(tv_sec: 2, tv_usec: 345_678)
    #expect(setsockopt(
        backpressureDescriptors[0],
        SOL_SOCKET,
        SO_SNDTIMEO,
        &originalSendTimeout,
        socklen_t(MemoryLayout<timeval>.size)
    ) == 0)
    let writeStartedAt = Date()
    #expect(throws: ClipboardProtocolError.timedOut) {
        try ClipboardDescriptorIO.writeAll(
            Data(repeating: 0xA5, count: ClipboardProtocolConstants.maximumTextBytes),
            to: backpressureDescriptors[0],
            deadline: Date().addingTimeInterval(0.05)
        )
    }
    #expect(Date().timeIntervalSince(writeStartedAt) < 1)
    var restoredSendTimeout = timeval()
    var restoredSendTimeoutLength = socklen_t(MemoryLayout<timeval>.size)
    #expect(getsockopt(
        backpressureDescriptors[0],
        SOL_SOCKET,
        SO_SNDTIMEO,
        &restoredSendTimeout,
        &restoredSendTimeoutLength
    ) == 0)
    #expect(restoredSendTimeout.tv_sec == originalSendTimeout.tv_sec)
    #expect(restoredSendTimeout.tv_usec == originalSendTimeout.tv_usec)

    var invalidDescriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &invalidDescriptors) == 0)
    guard invalidDescriptors.allSatisfy({ $0 >= 0 }) else { return }
    defer {
        close(invalidDescriptors[0])
        close(invalidDescriptors[1])
    }
    try ClipboardDescriptorIO.writeAll(Data([0, 0, 0, 1]), to: invalidDescriptors[1])
    #expect(throws: ClipboardProtocolError.invalidLength(1)) {
        try ClipboardDescriptorIO.readWireFrame(from: invalidDescriptors[0])
    }
}

@Test
func clipboardPeerCancellationBeforeContinuationInsertionSendsNoFrame() async throws {
    var descriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    guard descriptors.allSatisfy({ $0 >= 0 }) else { return }
    let guestDescriptor = descriptors[1]
    defer { close(guestDescriptor) }

    let peer = try ClipboardPeerConnection(
        authenticatedDescriptor: descriptors[0],
        sessionKey: Data(repeating: 0x71, count: ClipboardProtocolConstants.pairingSecretBytes)
    )
    peer.start()
    defer { peer.close() }

    let request = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await peer.setMonitoring(true, timeout: 0.1)
    }
    do {
        try await request.value
        Issue.record("A request made by an already-cancelled task unexpectedly succeeded")
    } catch {
        #expect(error is CancellationError)
    }

    var pollDescriptor = pollfd(fd: guestDescriptor, events: Int16(POLLIN), revents: 0)
    #expect(Darwin.poll(&pollDescriptor, 1, 50) == 0)
}

@Test
func clipboardPeerCloseResumesAllPendingRequestsExactlyOnce() async throws {
    var descriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    guard descriptors.allSatisfy({ $0 >= 0 }) else { return }
    let guestDescriptor = descriptors[1]
    defer { close(guestDescriptor) }

    let sessionKey = Data(repeating: 0x72, count: ClipboardProtocolConstants.pairingSecretBytes)
    let peer = try ClipboardPeerConnection(
        authenticatedDescriptor: descriptors[0],
        sessionKey: sessionKey
    )
    peer.start()
    let requests = (0..<3).map { index in
        Task { try await peer.setMonitoring(index.isMultiple(of: 2), timeout: 1) }
    }
    var requestDecoder = ClipboardFrameDecoder()
    var requestIDs = Set<UInt64>()
    for _ in requests {
        let wire = try await Task.detached {
            try ClipboardDescriptorIO.readWireFrame(
                from: guestDescriptor,
                deadline: Date().addingTimeInterval(1)
            )
        }.value
        let requestFrame = try #require(requestDecoder.append(
            wire,
            authentication: ClipboardFrameAuthentication(key: sessionKey, direction: .hostToGuest)
        ).first)
        #expect(requestFrame.type == .setMonitoring)
        #expect(requestFrame.id != 0)
        requestIDs.insert(requestFrame.id)
    }
    #expect(requestIDs.count == requests.count)

    peer.close()
    peer.close()
    for request in requests {
        do {
            try await request.value
            Issue.record("Closing a peer with pending requests unexpectedly succeeded")
        } catch {
            #expect(error as? ClipboardProtocolError == .connectionClosed)
        }
    }
}

@Test
func clipboardPeerIgnoresAValidLateResponseAndKeepsTheSessionUsable() async throws {
    var descriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    guard descriptors.allSatisfy({ $0 >= 0 }) else { return }
    let guestDescriptor = descriptors[1]
    defer { close(guestDescriptor) }

    let sessionKey = Data(repeating: 0x73, count: ClipboardProtocolConstants.pairingSecretBytes)
    let peer = try ClipboardPeerConnection(
        authenticatedDescriptor: descriptors[0],
        sessionKey: sessionKey
    )
    peer.start()
    defer { peer.close() }
    var requestDecoder = ClipboardFrameDecoder()
    let hostAuthentication = ClipboardFrameAuthentication(key: sessionKey, direction: .hostToGuest)
    let guestAuthentication = ClipboardFrameAuthentication(key: sessionKey, direction: .guestToHost)

    let firstRequest = Task { try await peer.setMonitoring(true, timeout: 0.05) }
    let firstWire = try await Task.detached {
        try ClipboardDescriptorIO.readWireFrame(
            from: guestDescriptor,
            deadline: Date().addingTimeInterval(1)
        )
    }.value
    let firstFrame = try #require(requestDecoder.append(
        firstWire,
        authentication: hostAuthentication
    ).first)
    do {
        try await firstRequest.value
        Issue.record("The first request unexpectedly completed before its response")
    } catch let error as ClipboardProtocolError {
        #expect(error == .timedOut)
    }

    try ClipboardDescriptorIO.writeAll(
        try ClipboardFrame(
            type: .baselineAcknowledgement,
            id: firstFrame.id,
            sequence: 1
        ).encoded(authentication: guestAuthentication),
        to: guestDescriptor
    )

    let secondRequest = Task { try await peer.setMonitoring(false, timeout: 1) }
    let secondWire = try await Task.detached {
        try ClipboardDescriptorIO.readWireFrame(
            from: guestDescriptor,
            deadline: Date().addingTimeInterval(1)
        )
    }.value
    let secondFrame = try #require(requestDecoder.append(
        secondWire,
        authentication: hostAuthentication
    ).first)
    try ClipboardDescriptorIO.writeAll(
        try ClipboardFrame(
            type: .baselineAcknowledgement,
            id: secondFrame.id,
            sequence: 2
        ).encoded(authentication: guestAuthentication),
        to: guestDescriptor
    )
    try await secondRequest.value
}

@Test
func clipboardPeerRejectsZeroAndDuplicateResponseIDs() async throws {
    var zeroDescriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &zeroDescriptors) == 0)
    guard zeroDescriptors.allSatisfy({ $0 >= 0 }) else { return }
    let zeroGuestDescriptor = zeroDescriptors[1]
    defer { close(zeroGuestDescriptor) }

    let sessionKey = Data(repeating: 0x75, count: ClipboardProtocolConstants.pairingSecretBytes)
    let guestAuthentication = ClipboardFrameAuthentication(key: sessionKey, direction: .guestToHost)
    let hostAuthentication = ClipboardFrameAuthentication(key: sessionKey, direction: .hostToGuest)
    let zeroPeer = try ClipboardPeerConnection(
        authenticatedDescriptor: zeroDescriptors[0],
        sessionKey: sessionKey
    )
    zeroPeer.start()
    defer { zeroPeer.close() }
    let zeroRequest = Task { try await zeroPeer.setMonitoring(true, timeout: 1) }
    _ = try await Task.detached {
        try ClipboardDescriptorIO.readWireFrame(
            from: zeroGuestDescriptor,
            deadline: Date().addingTimeInterval(1)
        )
    }.value
    try ClipboardDescriptorIO.writeAll(
        try ClipboardFrame(
            type: .baselineAcknowledgement,
            id: 0,
            sequence: 1
        ).encoded(authentication: guestAuthentication),
        to: zeroGuestDescriptor
    )
    do {
        try await zeroRequest.value
        Issue.record("A response with a zero request ID unexpectedly succeeded")
    } catch let error as ClipboardProtocolError {
        #expect(error == .invalidPayload("response request ID is zero"))
    }

    var duplicateDescriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &duplicateDescriptors) == 0)
    guard duplicateDescriptors.allSatisfy({ $0 >= 0 }) else { return }
    let duplicateGuestDescriptor = duplicateDescriptors[1]
    defer { close(duplicateGuestDescriptor) }
    let duplicatePeer = try ClipboardPeerConnection(
        authenticatedDescriptor: duplicateDescriptors[0],
        sessionKey: sessionKey
    )
    duplicatePeer.start()
    defer { duplicatePeer.close() }
    var requestDecoder = ClipboardFrameDecoder()

    let firstRequest = Task { try await duplicatePeer.setMonitoring(true, timeout: 1) }
    let firstWire = try await Task.detached {
        try ClipboardDescriptorIO.readWireFrame(
            from: duplicateGuestDescriptor,
            deadline: Date().addingTimeInterval(1)
        )
    }.value
    let firstFrame = try #require(requestDecoder.append(
        firstWire,
        authentication: hostAuthentication
    ).first)
    let firstResponse = try ClipboardFrame(
        type: .baselineAcknowledgement,
        id: firstFrame.id,
        sequence: 1
    ).encoded(authentication: guestAuthentication)
    try ClipboardDescriptorIO.writeAll(firstResponse, to: duplicateGuestDescriptor)
    try await firstRequest.value

    let secondRequest = Task { try await duplicatePeer.setMonitoring(false, timeout: 1) }
    _ = try await Task.detached {
        try ClipboardDescriptorIO.readWireFrame(
            from: duplicateGuestDescriptor,
            deadline: Date().addingTimeInterval(1)
        )
    }.value
    let duplicateResponse = try ClipboardFrame(
        type: .baselineAcknowledgement,
        id: firstFrame.id,
        sequence: 2
    ).encoded(authentication: guestAuthentication)
    try ClipboardDescriptorIO.writeAll(duplicateResponse, to: duplicateGuestDescriptor)
    do {
        try await secondRequest.value
        Issue.record("A duplicate response ID did not close the peer")
    } catch let error as ClipboardProtocolError {
        #expect(error == .invalidPayload("response request ID is not pending"))
    }
}

@Test
func clipboardPeerPropagatesMalformedAuthenticatedResponseErrors() async throws {
    var descriptors: [Int32] = [-1, -1]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    guard descriptors.allSatisfy({ $0 >= 0 }) else { return }
    let guestDescriptor = descriptors[1]
    defer { close(guestDescriptor) }

    let sessionKey = Data(repeating: 0x74, count: ClipboardProtocolConstants.pairingSecretBytes)
    let peer = try ClipboardPeerConnection(
        authenticatedDescriptor: descriptors[0],
        sessionKey: sessionKey
    )
    peer.start()
    defer { peer.close() }

    let request = Task { try await peer.setMonitoring(true, timeout: 1) }
    _ = try await Task.detached {
        try ClipboardDescriptorIO.readWireFrame(
            from: guestDescriptor,
            deadline: Date().addingTimeInterval(1)
        )
    }.value
    try ClipboardDescriptorIO.writeAll(
        try ClipboardFrame(
            type: .error,
            id: 1,
            sequence: 1,
            payload: Data([0xFF])
        ).encoded(authentication: ClipboardFrameAuthentication(
            key: sessionKey,
            direction: .guestToHost
        )),
        to: guestDescriptor
    )

    do {
        try await request.value
        Issue.record("A malformed authenticated error response unexpectedly succeeded")
    } catch let error as ClipboardProtocolError {
        guard case .invalidPayload = error else {
            Issue.record("Expected invalidPayload, received \(error)")
            return
        }
    }
}

@Test
func clipboardHandshakeBindsVMVersionNoncesAndBuilds() throws {
    let secret = Data(repeating: 0x33, count: ClipboardProtocolConstants.pairingSecretBytes)
    let transcript = try ClipboardHandshakeTranscript(
        vmID: UUID(),
        guestVersions: ClipboardVersionRange(minimum: 1, maximum: 2),
        hostVersions: ClipboardVersionRange(minimum: 1, maximum: 1),
        helperBuildVersion: 4,
        hostBuildVersion: 8,
        selectedVersion: 1,
        guestNonce: Data(repeating: 0x10, count: ClipboardProtocolConstants.nonceBytes),
        hostNonce: Data(repeating: 0x20, count: ClipboardProtocolConstants.nonceBytes)
    )
    let hostProof = try ClipboardAuthentication.hostProof(secret: secret, transcript: transcript)
    let guestProof = try ClipboardAuthentication.guestProof(secret: secret, transcript: transcript)
    #expect(try ClipboardAuthentication.verifyHostProof(hostProof, secret: secret, transcript: transcript))
    #expect(try ClipboardAuthentication.verifyGuestProof(guestProof, secret: secret, transcript: transcript))
    #expect(hostProof != guestProof)

    var otherVM = transcript
    otherVM.vmID = UUID()
    #expect(!(try ClipboardAuthentication.verifyHostProof(hostProof, secret: secret, transcript: otherVM)))
    #expect(try ClipboardAuthentication.sessionKey(secret: secret, transcript: transcript) != secret)
    #expect(ClipboardVersionRange(minimum: 2, maximum: 3).negotiatedVersion(
        with: ClipboardVersionRange(minimum: 1, maximum: 1)
    ) == nil)
}

@Test
func clipboardHelloMessagesRoundTripAndRejectInvalidVersionFields() throws {
    let vmID = UUID()
    let nonce = Data(repeating: 0x44, count: ClipboardProtocolConstants.nonceBytes)
    let proof = Data(repeating: 0x55, count: ClipboardProtocolConstants.authenticationTagBytes)
    let client = try ClipboardClientHello(
        vmID: vmID,
        versions: ClipboardVersionRange(minimum: 1, maximum: 2),
        helperBuildVersion: 7,
        guestNonce: nonce
    )
    #expect(try ClipboardClientHello.decode(client.encoded()) == client)

    let server = try ClipboardServerHello(
        versions: ClipboardVersionRange(minimum: 1, maximum: 2),
        selectedVersion: 2,
        hostBuildVersion: 8,
        hostNonce: nonce,
        hostProof: proof
    )
    #expect(try ClipboardServerHello.decode(server.encoded()) == server)

    #expect(throws: (any Error).self) {
        try ClipboardClientHello(
            vmID: vmID,
            versions: ClipboardVersionRange(minimum: 2, maximum: 1),
            helperBuildVersion: 7,
            guestNonce: nonce
        )
    }
    #expect(throws: (any Error).self) {
        try ClipboardServerHello(
            versions: ClipboardVersionRange(minimum: 1, maximum: 2),
            selectedVersion: 3,
            hostBuildVersion: 8,
            hostNonce: nonce,
            hostProof: proof
        )
    }
    var nonzeroReserved = server.encoded()
    nonzeroReserved[6] = 1
    #expect(throws: ClipboardProtocolError.invalidReservedField) {
        try ClipboardServerHello.decode(nonzeroReserved)
    }
}

@Test
func clipboardSecureRandomHandlesZeroAndRejectsNegativeCounts() throws {
    #expect(try ClipboardAuthentication.randomBytes(count: 0).isEmpty)
    #expect(try ClipboardAuthentication.randomBytes(count: 32).count == 32)
    #expect(throws: (any Error).self) {
        try ClipboardAuthentication.randomBytes(count: -1)
    }
}

@Test
func clipboardRequestTrackerCapsAndRejectsDuplicates() throws {
    var tracker = ClipboardRequestTracker(maximumPending: 2)
    try tracker.insert(1)
    do {
        try tracker.insert(1)
        Issue.record("A duplicate request ID was accepted")
    } catch let error as ClipboardProtocolError {
        #expect(error == .invalidPayload("request ID is already pending"))
    }
    try tracker.insert(2)
    do {
        try tracker.insert(3)
        Issue.record("The pending request cap was not enforced")
    } catch let error as ClipboardProtocolError {
        #expect(error == .requestLimitExceeded)
    }
    let removedKnownRequest = tracker.remove(1)
    let removedUnknownRequest = tracker.remove(99)
    #expect(removedKnownRequest)
    #expect(!removedUnknownRequest)
}

@Test
func oldMetadataDefaultsAutomaticClipboardSyncOff() throws {
    let (root, bundle) = try makeClipboardTestBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    try bundle.writeMetadata(clipboardTestMetadata())
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: bundle.metadataURL)) as? [String: Any]
    )
    object.removeValue(forKey: "automaticClipboardSyncEnabled")
    try JSONSerialization.data(withJSONObject: object).write(to: bundle.metadataURL)

    let decoded = try bundle.readMetadata()
    #expect(!decoded.isAutomaticClipboardSyncEnabled)
}

@Test
func clipboardPairingStoreCreatesStableOwnerOnlySecret() async throws {
    let (root, bundle) = try makeClipboardTestBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardPairingStore(bundle: bundle)

    let values = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
        for _ in 0..<8 {
            group.addTask { try store.ensureSecret() }
        }
        var result: [Data] = []
        for try await value in group { result.append(value) }
        return result
    }
    let first = try #require(values.first)
    #expect(first.count == ClipboardProtocolConstants.pairingSecretBytes)
    #expect(values.allSatisfy { $0 == first })
    #expect(try store.readSecret() == first)

    let directoryMode = try #require(
        FileManager.default.attributesOfItem(atPath: bundle.secretsDirectoryURL.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    let keyMode = try #require(
        FileManager.default.attributesOfItem(atPath: bundle.clipboardPairingKeyURL.path)[.posixPermissions] as? NSNumber
    ).intValue & 0o777
    #expect(directoryMode == 0o700)
    #expect(keyMode == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundle.secretsDirectoryURL.path) == ["clipboard-pairing.key"])
}

@Test
func clipboardPairingStoreRejectsInsecureFilesAndSymlinks() throws {
    let (root, bundle) = try makeClipboardTestBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ClipboardPairingStore(bundle: bundle)
    _ = try store.ensureSecret()

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: bundle.clipboardPairingKeyURL.path
    )
    #expect(throws: (any Error).self) { try store.readSecret() }

    try FileManager.default.removeItem(at: bundle.clipboardPairingKeyURL)
    let target = root.appendingPathComponent("attacker-controlled.key")
    try Data(repeating: 0x55, count: ClipboardProtocolConstants.pairingSecretBytes).write(to: target)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    try FileManager.default.createSymbolicLink(at: bundle.clipboardPairingKeyURL, withDestinationURL: target)
    #expect(throws: (any Error).self) { try store.readSecret() }
}

@Test
func invalidClipboardPairingNeedsExplicitRepair() throws {
    let (root, bundle) = try makeClipboardTestBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: bundle.secretsDirectoryURL, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: bundle.clipboardPairingKeyURL)
    let store = ClipboardPairingStore(bundle: bundle)

    #expect(throws: (any Error).self) { try store.ensureSecret() }
    let repaired = try store.ensureSecret(repairInvalid: true)
    #expect(repaired.count == ClipboardProtocolConstants.pairingSecretBytes)
    #expect(try Data(contentsOf: bundle.clipboardPairingKeyURL) == repaired)
}

@Test
func metadataUpdatesSerializeReadModifyWrite() async throws {
    let (root, bundle) = try makeClipboardTestBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    try bundle.writeMetadata(clipboardTestMetadata())

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<20 {
            group.addTask {
                _ = try bundle.updateMetadata { metadata in
                    metadata.cpuCount += 1
                }
            }
        }
        try await group.waitForAll()
    }
    #expect(try bundle.readMetadata().cpuCount == 22)
}

@Test
func clipboardKnownHostsBindsOnlyValidatedEnrolledKeys() throws {
    let enrolled = Data("ssh-ed25519 AAAA\necdsa-sha2-nistp256 AQID\n".utf8)
    let rendered = try ClipboardKnownHosts.render(enrolledKeys: enrolled, host: "192.0.2.42")
    #expect(String(decoding: rendered, as: UTF8.self) == """
    192.0.2.42 ssh-ed25519 AAAA
    192.0.2.42 ecdsa-sha2-nistp256 AQID

    """)

    #expect(throws: (any Error).self) {
        try ClipboardKnownHosts.render(enrolledKeys: enrolled, host: "192.0.2.42\nattacker")
    }
    #expect(throws: (any Error).self) {
        try ClipboardKnownHosts.render(enrolledKeys: Data("ssh-dss AAAA\n".utf8), host: "192.0.2.42")
    }
    #expect(throws: (any Error).self) {
        try ClipboardKnownHosts.render(enrolledKeys: Data("ssh-ed25519 !!!\n".utf8), host: "192.0.2.42")
    }
}

@Test
func clipboardGuestArtifactsUseBoundIdentityAndSecurePaths() throws {
    let vmID = UUID()
    let home = "/Users/developer"
    let configuration = try JSONDecoder().decode(
        ClipboardGuestInstaller.Configuration.self,
        from: ClipboardGuestInstaller.configurationData(vmID: vmID, homeDirectory: home)
    )
    #expect(configuration.vmID == vmID)
    #expect(configuration.pairingKeyPath == "\(home)/Library/Application Support/MacVM/Clipboard/pairing.key")

    let marker = try JSONDecoder().decode(
        ClipboardGuestInstaller.InstallationMarker.self,
        from: ClipboardGuestInstaller.installationMarkerData()
    )
    #expect(marker.helperVersion == ClipboardGuestInstaller.helperVersion)
    #expect(marker.protocolVersion == ClipboardProtocolConstants.applicationVersion)

    let plist = try #require(
        PropertyListSerialization.propertyList(
            from: ClipboardGuestInstaller.launchAgentData(homeDirectory: home),
            options: [],
            format: nil
        ) as? [String: Any]
    )
    #expect(plist["Label"] as? String == "dev.macvm.clipboard-guest")
    #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
    #expect(plist["ProgramArguments"] as? [String] == ["/usr/local/libexec/macvm-clipboard-guest"])
}

@Test
func clipboardGuestInstallScriptIsTransactionalAndPermissioned() throws {
    let script = ClipboardGuestInstaller.installScript(
        user: "developer",
        homeDirectory: "/Users/developer",
        remoteStage: "/Users/developer/.macvm-clipboard-stage"
    )
    #expect(script.contains("set -euo pipefail"))
    #expect(script.contains("trap 'rollback $?' ERR"))
    #expect(script.contains("trap 'rollback 130' INT"))
    #expect(script.contains("trap 'rollback 143' TERM"))
    #expect(script.contains("Keep the journal and backup stage after a failed install"))
    #expect(script.contains("rm -f \"$previous.result\""))
    #expect(script.contains("install -m 0600"))
    #expect(script.contains("install -d -m 0700"))
    #expect(script.contains("sudo install -o root -g wheel -m 0755"))
    #expect(script.contains("launchctl print \"gui/$uid\""))
    #expect(script.contains("launchctl bootstrap"))
    #expect(script.contains("Persist the complete backup and write-ahead journal"))
    #expect(script.components(separatedBy: "/bin/sync").count >= 5)
    #expect(script.contains("trap - ERR INT TERM"))

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macvm-clipboard-script-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let scriptURL = root.appendingPathComponent("install.sh")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    let syntaxCheck = Process()
    syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/bash")
    syntaxCheck.arguments = ["-n", scriptURL.path]
    let diagnostics = Pipe()
    syntaxCheck.standardError = diagnostics
    try syntaxCheck.run()
    syntaxCheck.waitUntilExit()
    if syntaxCheck.terminationStatus != 0 {
        let output = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        Issue.record("Generated clipboard installer is not valid Bash: \(output)")
    }
}

@Test
func setupDefaultsToInstallingClipboardHelperButSupportsOptOut() {
    #expect(SetupOptions().installClipboardHelper)
    #expect(!SetupOptions(installClipboardHelper: false).installClipboardHelper)
}

@Test
func clipboardPayloadDecodingSupportsNonZeroBasedDataSlices() throws {
    let changedPayload = try ClipboardPayload.encodeChangedText(changeCount: 42, text: "from slice")
    var framedChangedPayload = Data([0xFF])
    framedChangedPayload.append(changedPayload)
    let changed = try ClipboardPayload.decodeChangedText(framedChangedPayload.dropFirst())
    #expect(changed.changeCount == 42)
    #expect(changed.text == "from slice")

    let requestError = ClipboardRequestError.rejected("rejected from slice")
    var framedRequestError = Data([0xFF])
    framedRequestError.append(try requestError.encoded())
    #expect(try ClipboardRequestError.decode(framedRequestError.dropFirst()) == requestError)
}

@Test
@MainActor
func clipboardOneShotFallbackAllowsOnlyTransportUnavailability() {
    #expect(VMViewerController.shouldFallbackToClipboardVNC(
        for: ClipboardHelperUnavailableError.unavailable(.disconnected)
    ))
    #expect(VMViewerController.shouldFallbackToClipboardVNC(
        for: ClipboardProtocolError.timedOut
    ))
    #expect(VMViewerController.shouldFallbackToClipboardVNC(
        for: POSIXError(.ECONNRESET)
    ))
    #expect(!VMViewerController.shouldFallbackToClipboardVNC(
        for: ClipboardHelperUnavailableError.unavailable(.unpaired)
    ))
    #expect(!VMViewerController.shouldFallbackToClipboardVNC(
        for: ClipboardProtocolError.invalidAuthenticationTag
    ))
    #expect(!VMViewerController.shouldFallbackToClipboardVNC(
        for: ClipboardProtocolError.invalidPayload("malformed response")
    ))
}

@Test
@MainActor
func clipboardSyncBaselinesTransfersAndSuppressesGuestEcho() async {
    let runtime = ClipboardRuntimeMock()
    let pasteboard = ClipboardPasteboardMock()
    let coordinator = ClipboardSyncCoordinator(runtime: runtime, pasteboard: pasteboard)
    coordinator.activate(generation: 1)
    defer { coordinator.deactivate(generation: 1) }

    for _ in 0..<10 where runtime.monitoring.last != true {
        await Task.yield()
    }
    #expect(runtime.viewerActive)
    #expect(runtime.monitoring.last == true)
    #expect(runtime.commits.isEmpty)

    pasteboard.replaceLocally(with: "from host")
    await coordinator.synchronizeNow()
    #expect(runtime.commits.count == 1)
    #expect(runtime.commits[0].text == "from host")
    #expect(runtime.commits[0].sourceChangeCount == pasteboard.changeCount)

    runtime.emitGuestChange(changeCount: 41, text: "from guest")
    await coordinator.synchronizeNow()
    #expect(pasteboard.string() == "from guest")
    #expect(runtime.commits.count == 2)
    #expect(runtime.commits[1].text == "from guest")
    #expect(runtime.commits[1].sourceChangeCount == 41)

    await coordinator.synchronizeNow()
    #expect(runtime.commits.count == 2)
}

@Test
@MainActor
func clipboardSyncSerializesMonitorOffAfterDelayedMonitorOn() async {
    let runtime = ClipboardRuntimeMock()
    runtime.suspendMonitoringValue = true
    let coordinator = ClipboardSyncCoordinator(runtime: runtime, pasteboard: ClipboardPasteboardMock())
    coordinator.activate(generation: 7)

    for _ in 0..<20 where !runtime.hasSuspendedMonitoring {
        await Task.yield()
    }
    #expect(runtime.hasSuspendedMonitoring)

    coordinator.deactivate(generation: 7)
    for _ in 0..<20 { await Task.yield() }
    #expect(runtime.monitoring == [true])
    #expect(runtime.effectiveMonitoring == nil)

    runtime.resumeMonitoring()
    for _ in 0..<20 where runtime.effectiveMonitoring != false {
        await Task.yield()
    }
    #expect(runtime.completedMonitoring == [true, false])
    #expect(runtime.effectiveMonitoring == false)
}

@Test
@MainActor
func clipboardSyncSimultaneousChangesConvergeOnTheSerializedGuestWinner() async {
    let runtime = ClipboardRuntimeMock()
    let pasteboard = ClipboardPasteboardMock()
    let coordinator = ClipboardSyncCoordinator(runtime: runtime, pasteboard: pasteboard)
    coordinator.activate(generation: 8)
    defer { coordinator.deactivate(generation: 8) }
    for _ in 0..<10 where runtime.monitoring.last != true {
        await Task.yield()
    }

    pasteboard.replaceLocally(with: "simultaneous host")
    runtime.emitGuestChange(changeCount: 91, text: "simultaneous guest")
    await coordinator.synchronizeNow()

    #expect(pasteboard.string() == "simultaneous guest")
    #expect(runtime.commits.last?.text == "simultaneous guest")
    #expect(runtime.commits.last?.sourceChangeCount == 91)
}

@Test
@MainActor
func clipboardSyncReconnectAndUnsupportedPasteboardsEstablishFreshBaselines() async {
    let runtime = ClipboardRuntimeMock()
    let pasteboard = ClipboardPasteboardMock()
    let coordinator = ClipboardSyncCoordinator(runtime: runtime, pasteboard: pasteboard)
    coordinator.activate(generation: 9)
    defer { coordinator.deactivate(generation: 9) }
    for _ in 0..<10 where runtime.monitoring.last != true {
        await Task.yield()
    }

    pasteboard.replaceLocally(with: "stale across reconnect")
    runtime.emitPeerChange()
    await coordinator.synchronizeNow()
    #expect(runtime.commits.isEmpty)

    pasteboard.replaceLocally(with: nil)
    await coordinator.synchronizeNow()
    await coordinator.synchronizeNow()
    #expect(runtime.commits.isEmpty)

    pasteboard.replaceLocally(with: String(
        repeating: "x",
        count: ClipboardProtocolConstants.maximumTextBytes + 1
    ))
    await coordinator.synchronizeNow()
    await coordinator.synchronizeNow()
    #expect(runtime.commits.isEmpty)
}

@Test
@MainActor
func clipboardSyncInvalidationPreventsTransfersAfterInFlightHostCommit() async {
    let runtime = ClipboardRuntimeMock()
    let pasteboard = ClipboardPasteboardMock()
    let coordinator = ClipboardSyncCoordinator(runtime: runtime, pasteboard: pasteboard)
    coordinator.activate(generation: 10)
    for _ in 0..<10 where runtime.monitoring.last != true {
        await Task.yield()
    }

    runtime.suspendCommits = true
    pasteboard.replaceLocally(with: "in flight")
    let transfer = Task { await coordinator.synchronizeNow() }
    for _ in 0..<10 where !runtime.hasSuspendedCommit {
        await Task.yield()
    }
    #expect(runtime.hasSuspendedCommit)

    coordinator.deactivate(generation: 10)
    runtime.resumeCommit()
    await transfer.value
    pasteboard.replaceLocally(with: "after deactivation")
    await coordinator.synchronizeNow()
    #expect(runtime.commits.map(\.text) == ["in flight"])
    #expect(!runtime.viewerActive)
}

@Test
@MainActor
func clipboardSyncGuestBurstReestablishesBaselineWithoutReplayingStaleEvents() async {
    let runtime = ClipboardRuntimeMock()
    let pasteboard = ClipboardPasteboardMock()
    let coordinator = ClipboardSyncCoordinator(runtime: runtime, pasteboard: pasteboard)
    coordinator.activate(generation: 11)
    defer { coordinator.deactivate(generation: 11) }
    for _ in 0..<10 where runtime.monitoring.last != true {
        await Task.yield()
    }

    for changeCount in 1...200 {
        runtime.emitGuestChange(changeCount: changeCount, text: "event-\(changeCount)")
    }
    await coordinator.synchronizeNow()
    for _ in 0..<10 where runtime.monitoring.count < 2 {
        await Task.yield()
    }

    #expect(pasteboard.string() == "initial")
    #expect(runtime.commits.isEmpty)
    #expect(runtime.monitoring.count >= 2)
    #expect(runtime.monitoring.last == true)
}

@Test
@MainActor
func clipboardActivationCoordinatorRevokesPreviousViewerAndUsesGenerations() {
    let coordinator = ClipboardActivationCoordinator.shared
    coordinator.deactivateAll()
    defer { coordinator.deactivateAll() }
    let first = UUID()
    let second = UUID()
    var revoked = false

    let firstGeneration = coordinator.activate(ownerID: first) { revoked = true }
    let secondGeneration = coordinator.activate(ownerID: second) {}
    #expect(revoked)
    #expect(secondGeneration > firstGeneration)

    coordinator.deactivate(ownerID: first, generation: firstGeneration)
    let thirdGeneration = coordinator.activate(ownerID: first) {}
    #expect(thirdGeneration > secondGeneration)
}
