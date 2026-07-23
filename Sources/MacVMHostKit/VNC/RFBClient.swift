import Foundation
import MacVMClipboardProtocol
import Network

struct RFBTraceEvent: Sendable {
    let kind: String
    let connectionID: String
    let purpose: String
    let fields: [String: String]
}

enum RFBError: LocalizedError {
    case connectionClosed
    case handshakeFailed(String)
    case authenticationFailed(String)
    case noSupportedSecurityType
    case passwordRequired
    case notConnected
    case framebufferTimeout
    case handshakeTimeout
    case clipboardTimeout
    case invalidClipboardText
    case clipboardTextTooLarge(Int)
    case unsupportedEncoding(Int32)
    case unexpectedMessage(UInt8)

    var errorDescription: String? {
        switch self {
        case .connectionClosed:
            return "The VNC connection closed unexpectedly."
        case .handshakeFailed(let detail):
            return "VNC handshake failed: \(detail)"
        case .authenticationFailed(let detail):
            return "VNC authentication failed: \(detail)"
        case .noSupportedSecurityType:
            return "The VNC server offered no security type this client supports."
        case .passwordRequired:
            return "The VNC server requires a password but none was provided."
        case .notConnected:
            return "The VNC client is not connected."
        case .framebufferTimeout:
            return "Timed out waiting for a VNC framebuffer update."
        case .handshakeTimeout:
            return "Timed out while connecting to the VNC server."
        case .clipboardTimeout:
            return "Timed out waiting for the VM pasteboard to publish text."
        case .invalidClipboardText:
            return "The VM pasteboard update was not valid UTF-8 text."
        case .clipboardTextTooLarge(let count):
            return "The VM pasteboard update is \(count) UTF-8 bytes; the maximum is 1 MiB."
        case .unsupportedEncoding(let encoding):
            return "The VNC server used an unsupported encoding (\(encoding)). Only Raw is supported."
        case .unexpectedMessage(let type):
            return "The VNC server sent an unexpected message type (\(type))."
        }
    }
}

/// A minimal RFB (VNC) 3.8 client over loopback: enough to capture the framebuffer
/// and inject keyboard/pointer events. Raw is the only pixel encoding.
actor RFBClient {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.twt.macvm.rfb-client")
    private var framebufferWidth: Int?
    private var framebufferHeight: Int?
    private var started = false
    private var nudgeToggle = false
    private let connectionID: String
    private let purpose: String
    private let trace: (@Sendable (RFBTraceEvent) -> Void)?
    private var lastCaptureSize: (width: Int, height: Int)?
    private var lastCaptureHadPixels = false

    init(
        host: String = "127.0.0.1",
        port: Int,
        purpose: String = "unspecified",
        trace: (@Sendable (RFBTraceEvent) -> Void)? = nil
    ) {
        let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? 5900
        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: .tcp
        )
        connectionID = String(UUID().uuidString.prefix(8))
        self.purpose = purpose
        self.trace = trace
    }

    /// Open a short-lived shared RFB connection, capture one full framebuffer, and
    /// close it. OCR polling uses this to force the server to send a clean full
    /// frame even when the long-lived control connection has seen a dimmed screen.
    static func captureOnce(
        host: String = "127.0.0.1",
        port: Int,
        password: String?,
        timeout: TimeInterval? = nil,
        purpose: String = "capture",
        trace: (@Sendable (RFBTraceEvent) -> Void)? = nil
    ) async throws -> Framebuffer {
        try await withConnection(
            host: host,
            port: port,
            password: password,
            purpose: purpose,
            trace: trace
        ) { client in
            try await client.captureFramebuffer(timeout: timeout)
        }
    }

    /// Open a short-lived shared RFB connection for one operation, then close it.
    /// Some VNC servers route input from the newest client, so OCR-driven actions
    /// use fresh clients for both capture and input.
    static func withConnection<T>(
        host: String = "127.0.0.1",
        port: Int,
        password: String?,
        purpose: String = "operation",
        trace: (@Sendable (RFBTraceEvent) -> Void)? = nil,
        _ body: (RFBClient) async throws -> T
    ) async throws -> T {
        let client = RFBClient(host: host, port: port, purpose: purpose, trace: trace)
        do {
            try await client.connect(password: password)
            let result = try await body(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    /// Open the newest shared connection, wake the display, and negotiate/capture
    /// its current framebuffer before allowing any coordinate-based action.
    static func withActionFramebuffer<T>(
        host: String = "127.0.0.1",
        port: Int,
        password: String?,
        framebufferTimeout: TimeInterval? = nil,
        purpose: String,
        trace: (@Sendable (RFBTraceEvent) -> Void)? = nil,
        _ body: (RFBClient, Framebuffer) async throws -> T
    ) async throws -> T {
        try await withConnection(
            host: host,
            port: port,
            password: password,
            purpose: purpose,
            trace: trace
        ) { client in
            try? await client.nudgePointer()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let framebuffer = try await client.captureFramebuffer(timeout: framebufferTimeout)
            return try await body(client, framebuffer)
        }
    }

    /// Framebuffer dimensions reported by the server (available after `connect`).
    var framebufferSize: (width: Int, height: Int)? {
        guard let framebufferWidth, let framebufferHeight else { return nil }
        return (framebufferWidth, framebufferHeight)
    }

    var traceIdentity: (connectionID: String, purpose: String) {
        (connectionID, purpose)
    }

    /// Perform the full RFB 3.8 handshake: version, security/auth, init, then set
    /// our pixel format (BGRA32) and Raw encoding.
    func connect(password: String?, timeout: TimeInterval = 10) async throws {
        emit("connection_open")
        let deadline = Date().addingTimeInterval(timeout)
        try await startConnection(deadline: deadline)

        _ = try await receive(exactly: 12, deadline: deadline, timeoutError: .handshakeTimeout)
        try await send(Array("RFB 003.008\n".utf8), deadline: deadline, timeoutError: .handshakeTimeout)

        let securityCount = Int(try await receive(
            exactly: 1,
            deadline: deadline,
            timeoutError: .handshakeTimeout
        )[0])
        if securityCount == 0 {
            let reasonLength = Int(try await readUInt32(deadline: deadline, timeoutError: .handshakeTimeout))
            guard reasonLength <= ClipboardProtocolConstants.maximumTextBytes else {
                throw RFBError.handshakeFailed("the failure reason is too large")
            }
            let reason = try await receive(
                exactly: reasonLength,
                deadline: deadline,
                timeoutError: .handshakeTimeout
            )
            throw RFBError.handshakeFailed(String(decoding: reason, as: UTF8.self))
        }
        let securityTypes = try await receive(
            exactly: securityCount,
            deadline: deadline,
            timeoutError: .handshakeTimeout
        )

        let chosen = try selectSecurityType(from: securityTypes, hasPassword: password != nil)
        try await send([chosen], deadline: deadline, timeoutError: .handshakeTimeout)

        if chosen == RFB.securityVNCAuth {
            guard let password else { throw RFBError.passwordRequired }
            let challenge = try await receive(exactly: 16, deadline: deadline, timeoutError: .handshakeTimeout)
            try await send(
                RFBAuth.response(challenge: challenge, password: password),
                deadline: deadline,
                timeoutError: .handshakeTimeout
            )
        }

        // SecurityResult (RFB 3.8 sends it for every security type, including None).
        let result = try await readUInt32(deadline: deadline, timeoutError: .handshakeTimeout)
        if result != 0 {
            let reasonLength = Int(try await readUInt32(deadline: deadline, timeoutError: .handshakeTimeout))
            guard reasonLength <= ClipboardProtocolConstants.maximumTextBytes else {
                throw RFBError.authenticationFailed("the failure reason is too large")
            }
            let reason = try await receive(
                exactly: reasonLength,
                deadline: deadline,
                timeoutError: .handshakeTimeout
            )
            throw RFBError.authenticationFailed(String(decoding: reason, as: UTF8.self))
        }

        try await send(RFBMessage.clientInit(shared: true), deadline: deadline, timeoutError: .handshakeTimeout)

        // ServerInit: width(2) height(2) pixelFormat(16) nameLength(4) then name.
        let header = try await receive(exactly: 24, deadline: deadline, timeoutError: .handshakeTimeout)
        framebufferWidth = Int(UInt16(header[0]) << 8 | UInt16(header[1]))
        framebufferHeight = Int(UInt16(header[2]) << 8 | UInt16(header[3]))
        emit("server_init", fields: [
            "width": String(framebufferWidth ?? 0),
            "height": String(framebufferHeight ?? 0),
        ])
        let nameLength = Int(
            UInt32(header[20]) << 24 | UInt32(header[21]) << 16 | UInt32(header[22]) << 8 | UInt32(header[23])
        )
        guard nameLength <= ClipboardProtocolConstants.maximumTextBytes else {
            throw RFBError.handshakeFailed("the server name is too large")
        }
        _ = try await receive(exactly: nameLength, deadline: deadline, timeoutError: .handshakeTimeout)

        try await send(RFBMessage.setPixelFormat(.bgra32), deadline: deadline, timeoutError: .handshakeTimeout)
        try await send(
            RFBMessage.setEncodings(RFB.clientEncodings),
            deadline: deadline,
            timeoutError: .handshakeTimeout
        )
    }

    /// Request and decode a full (non-incremental) framebuffer update. The server
    /// may answer an initial request with only a DesktopSize rect (announcing the
    /// real dimensions) and no pixels, so retry until Raw pixels actually arrive.
    func captureFramebuffer() async throws -> Framebuffer {
        try await captureFramebuffer(timeout: nil)
    }

    func captureFramebuffer(timeout: TimeInterval?) async throws -> Framebuffer {
        guard let width = framebufferWidth, let height = framebufferHeight else {
            throw RFBError.notConnected
        }

        let startedAt = Date()
        let deadline = timeout.map { startedAt.addingTimeInterval($0) }
        var framebuffer = Framebuffer(width: width, height: height)
        do {
            for attempt in 1...6 {
                let requestWidth = UInt16(framebufferWidth ?? width)
                let requestHeight = UInt16(framebufferHeight ?? height)
                emit("framebuffer_request", fields: [
                    "attempt": String(attempt),
                    "width": String(requestWidth),
                    "height": String(requestHeight),
                ])
                try await send(RFBMessage.framebufferUpdateRequest(
                    incremental: false, x: 0, y: 0, width: requestWidth, height: requestHeight
                ))
                let gotPixels = try await readOneUpdate(into: &framebuffer, deadline: deadline)
                if gotPixels {
                    lastCaptureSize = (framebuffer.width, framebuffer.height)
                    lastCaptureHadPixels = true
                    emit("framebuffer_result", fields: [
                        "width": String(framebuffer.width),
                        "height": String(framebuffer.height),
                        "hasRawPixels": "true",
                    ])
                    return framebuffer
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch RFBError.framebufferTimeout {
            emit("framebuffer_timeout", fields: [
                "elapsedMilliseconds": String(Int(Date().timeIntervalSince(startedAt) * 1_000)),
                "width": String(framebufferWidth ?? width),
                "height": String(framebufferHeight ?? height),
            ])
            throw RFBError.framebufferTimeout
        }
        lastCaptureSize = (framebuffer.width, framebuffer.height)
        lastCaptureHadPixels = false
        emit("framebuffer_result", fields: [
            "width": String(framebuffer.width),
            "height": String(framebuffer.height),
            "hasRawPixels": "false",
        ])
        return framebuffer
    }

    /// Read server messages until one FramebufferUpdate is consumed. Returns whether
    /// any Raw pixels were written (false if the update carried only pseudo-encodings).
    private func readOneUpdate(into framebuffer: inout Framebuffer, deadline: Date?) async throws -> Bool {
        while true {
            let messageType = try await receiveFramebuffer(exactly: 1, deadline: deadline)[0]
            switch messageType {
            case RFB.framebufferUpdateType:
                return try await readRectangles(into: &framebuffer, deadline: deadline)

            case RFB.setColourMapEntriesType:
                _ = try await receiveFramebuffer(exactly: 3, deadline: deadline)
                let colourCount = Int(try await readFramebufferUInt16(deadline: deadline))
                _ = try await receiveFramebuffer(exactly: colourCount * 6, deadline: deadline)

            case RFB.bellType:
                break

            case RFB.serverCutTextType:
                _ = try await receiveFramebuffer(exactly: 3, deadline: deadline)
                let length = Int(try await readFramebufferUInt32(deadline: deadline))
                guard length <= ClipboardProtocolConstants.maximumTextBytes else {
                    throw RFBError.clipboardTextTooLarge(length)
                }
                _ = try await receiveFramebuffer(exactly: length, deadline: deadline)

            default:
                throw RFBError.unexpectedMessage(messageType)
            }
        }
    }

    private func readRectangles(into framebuffer: inout Framebuffer, deadline: Date?) async throws -> Bool {
        _ = try await receiveFramebuffer(exactly: 1, deadline: deadline)
        let rectangleCount = Int(try await readFramebufferUInt16(deadline: deadline))
        // 0xffff means "unknown count, read until a LastRect pseudo-encoding".
        let readUntilLastRect = rectangleCount == 0xffff
        var index = 0
        var gotPixels = false

        while readUntilLastRect || index < rectangleCount {
            guard let rectangle = RFBRectangleHeader(bytes: try await receiveFramebuffer(
                exactly: 12,
                deadline: deadline
            )) else {
                throw RFBError.connectionClosed
            }
            index += 1

            switch rectangle.encoding {
            case RFB.rawEncoding:
                let byteCount = Int(rectangle.width) * Int(rectangle.height) * 4
                let pixels = try await receiveFramebuffer(exactly: byteCount, deadline: deadline)
                framebuffer.blit(
                    pixels,
                    x: Int(rectangle.x), y: Int(rectangle.y),
                    width: Int(rectangle.width), height: Int(rectangle.height)
                )
                if byteCount > 0 { gotPixels = true }

            case RFB.cursorEncoding:
                // Cursor bitmap + 1bpp mask; x/y are the hotspot, not a screen position.
                let pixelBytes = Int(rectangle.width) * Int(rectangle.height) * 4
                let maskBytes = ((Int(rectangle.width) + 7) / 8) * Int(rectangle.height)
                _ = try await receiveFramebuffer(exactly: pixelBytes + maskBytes, deadline: deadline)

            case RFB.desktopSizeEncoding:
                // No pixel data; w/h are the new framebuffer dimensions.
                let newWidth = Int(rectangle.width)
                let newHeight = Int(rectangle.height)
                framebufferWidth = newWidth
                framebufferHeight = newHeight
                emit("desktop_size", fields: [
                    "width": String(newWidth),
                    "height": String(newHeight),
                ])
                if newWidth != framebuffer.width || newHeight != framebuffer.height {
                    framebuffer = Framebuffer(width: newWidth, height: newHeight)
                }

            case RFB.lastRectEncoding:
                return gotPixels

            default:
                throw RFBError.unsupportedEncoding(rectangle.encoding)
            }
        }

        return gotPixels
    }

    private func receiveFramebuffer(exactly count: Int, deadline: Date?) async throws -> [UInt8] {
        if let deadline {
            return try await receive(exactly: count, deadline: deadline, timeoutError: .framebufferTimeout)
        }
        return try await receive(exactly: count)
    }

    private func readFramebufferUInt16(deadline: Date?) async throws -> UInt16 {
        let bytes = try await receiveFramebuffer(exactly: 2, deadline: deadline)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func readFramebufferUInt32(deadline: Date?) async throws -> UInt32 {
        let bytes = try await receiveFramebuffer(exactly: 4, deadline: deadline)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    func sendKey(keysym: UInt32, down: Bool) async throws {
        try await send(RFBMessage.keyEvent(keysym: keysym, down: down))
    }

    /// Tap a key while holding `modifiers` (down, tap, up in reverse). Small settle
    /// delays are inserted between transitions because macOS can miss a modifier
    /// state that changes too quickly over VNC.
    func pressKey(_ keysym: UInt32, modifiers: [UInt32] = []) async throws {
        let settle: UInt64 = 40_000_000
        for modifier in modifiers {
            try await sendKey(keysym: modifier, down: true)
            try? await Task.sleep(nanoseconds: settle)
        }
        try await sendKey(keysym: keysym, down: true)
        try? await Task.sleep(nanoseconds: settle)
        try await sendKey(keysym: keysym, down: false)
        try? await Task.sleep(nanoseconds: settle)
        for modifier in modifiers.reversed() {
            try await sendKey(keysym: modifier, down: false)
            try? await Task.sleep(nanoseconds: settle)
        }
    }

    /// Type `text` one character at a time with an explicit key-hold and a gap
    /// between characters. macOS over VNC drops and even reorders keystrokes sent too
    /// quickly, so this is deliberately slow: press, hold, release, then pause before
    /// the next character.
    func typeText(_ text: String, holdDelay: UInt64 = 35_000_000, gapDelay: UInt64 = 90_000_000) async throws {
        for stroke in Keysym.keystrokes(forTyping: text) {
            try await sendKey(keysym: stroke.keysym, down: stroke.down)
            try? await Task.sleep(nanoseconds: stroke.down ? holdDelay : gapDelay)
        }
    }

    /// Replace the guest-side VNC cut buffer with plain UTF-8 text. The guest may
    /// expose that as its pasteboard depending on the server/guest integration.
    func setClipboardText(_ text: String) async throws {
        try await setClipboardText(text, timeout: 10)
    }

    func setClipboardText(_ text: String, timeout: TimeInterval) async throws {
        let count = text.utf8.count
        guard count <= ClipboardProtocolConstants.maximumTextBytes else {
            throw RFBError.clipboardTextTooLarge(count)
        }
        try await send(
            RFBMessage.clientCutText(text),
            deadline: Date().addingTimeInterval(timeout),
            timeoutError: .clipboardTimeout
        )
    }

    /// Wait for the guest VNC server to publish a clipboard update. RFB has no
    /// request-current-clipboard message, so callers use this to observe the next
    /// ServerCutText event.
    func waitForClipboardText(timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            let messageType = try await receive(exactly: 1, deadline: deadline)[0]
            switch messageType {
            case RFB.serverCutTextType:
                return try await readServerCutText(deadline: deadline)

            case RFB.framebufferUpdateType:
                try await discardFramebufferUpdate(deadline: deadline)

            case RFB.setColourMapEntriesType:
                _ = try await receive(exactly: 3, deadline: deadline) // padding + first-colour high byte
                let colourCount = Int(try await readUInt16(deadline: deadline))
                _ = try await receive(exactly: colourCount * 6, deadline: deadline)

            case RFB.bellType:
                break

            default:
                throw RFBError.unexpectedMessage(messageType)
            }
        }
    }

    /// Wake the guest display so OCR sees content. A headless guest sleeps/dims its
    /// display after inactivity, which blanks the framebuffer. Pointer moves alone
    /// don't reliably wake it, so this also taps a modifier key — a keyboard HID
    /// event wakes the display and, being Shift alone, never types or activates a
    /// control.
    func nudgePointer() async throws {
        nudgeToggle.toggle()
        let x: UInt16 = nudgeToggle ? 120 : 320
        try await send(RFBMessage.pointerEvent(buttonMask: 0, x: x, y: 40))
        try await sendKey(keysym: Keysym.shift, down: true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        try await sendKey(keysym: Keysym.shift, down: false)
    }

    /// Move to (x, y) and click `button` (1 = left).
    func click(x: Int, y: Int, button: UInt8 = 1) async throws {
        let mask = UInt8(1 << (button - 1))
        let px = UInt16(clamping: x)
        let py = UInt16(clamping: y)
        var fields = [
            "x": String(px),
            "y": String(py),
            "button": String(button),
            "negotiatedWidth": String(framebufferWidth ?? 0),
            "negotiatedHeight": String(framebufferHeight ?? 0),
            "lastCaptureHadPixels": String(lastCaptureHadPixels),
        ]
        if let lastCaptureSize {
            fields["captureWidth"] = String(lastCaptureSize.width)
            fields["captureHeight"] = String(lastCaptureSize.height)
        }
        emit("pointer_click", fields: fields)
        try await send(RFBMessage.pointerEvent(buttonMask: 0, x: px, y: py))
        try? await Task.sleep(nanoseconds: 30_000_000)
        try await send(RFBMessage.pointerEvent(buttonMask: mask, x: px, y: py))
        try? await Task.sleep(nanoseconds: 80_000_000)
        try await send(RFBMessage.pointerEvent(buttonMask: 0, x: px, y: py))
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    func close() {
        emit("connection_close")
        connection.cancel()
    }

    private func emit(_ kind: String, fields: [String: String] = [:]) {
        trace?(RFBTraceEvent(kind: kind, connectionID: connectionID, purpose: purpose, fields: fields))
    }

    // MARK: - Connection plumbing

    private func selectSecurityType(from types: [UInt8], hasPassword: Bool) throws -> UInt8 {
        if hasPassword, types.contains(RFB.securityVNCAuth) {
            return RFB.securityVNCAuth
        }
        if types.contains(RFB.securityNone) {
            return RFB.securityNone
        }
        if hasPassword, let first = types.first {
            return first
        }
        throw RFBError.noSupportedSecurityType
    }

    private func startConnection(deadline: Date) async throws {
        guard !started else { return }
        started = true

        let timeout = deadline.timeIntervalSinceNow
        guard timeout > 0 else { throw RFBError.handshakeTimeout }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OneShot()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.fire() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    if resumed.fire() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.fire() { continuation.resume(throwing: RFBError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.fire() { continuation.resume(throwing: RFBError.handshakeTimeout) }
            }
        }
    }

    private func send(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func send(_ bytes: [UInt8], deadline: Date, timeoutError: RFBError) async throws {
        let timeout = deadline.timeIntervalSinceNow
        guard timeout > 0 else { throw timeoutError }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OneShot()
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    if resumed.fire() { continuation.resume(throwing: error) }
                } else if resumed.fire() {
                    continuation.resume()
                }
            })
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.fire() { continuation.resume(throwing: timeoutError) }
            }
        }
    }

    private func receive(exactly count: Int) async throws -> [UInt8] {
        if count == 0 { return [] }
        var result = [UInt8]()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try await receiveChunk(maximum: count - result.count)
            if chunk.isEmpty { throw RFBError.connectionClosed }
            result.append(contentsOf: chunk)
        }
        return result
    }

    private func receive(
        exactly count: Int,
        deadline: Date,
        timeoutError: RFBError = .clipboardTimeout
    ) async throws -> [UInt8] {
        if count == 0 { return [] }
        var result = [UInt8]()
        result.reserveCapacity(count)
        while result.count < count {
            let chunk = try await receiveChunk(
                maximum: count - result.count,
                timeout: deadline.timeIntervalSinceNow,
                timeoutError: timeoutError
            )
            if chunk.isEmpty { throw RFBError.connectionClosed }
            result.append(contentsOf: chunk)
        }
        return result
    }

    private func receiveChunk(maximum: Int) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data.map { [UInt8]($0) } ?? [])
                }
            }
        }
    }

    private func receiveChunk(
        maximum: Int,
        timeout: TimeInterval,
        timeoutError: RFBError
    ) async throws -> [UInt8] {
        guard timeout > 0 else {
            throw timeoutError
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            let resumed = OneShot()
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
                if let error {
                    if resumed.fire() { continuation.resume(throwing: error) }
                } else {
                    if resumed.fire() { continuation.resume(returning: data.map { [UInt8]($0) } ?? []) }
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                if resumed.fire() { continuation.resume(throwing: timeoutError) }
            }
        }
    }

    private func readUInt16() async throws -> UInt16 {
        let bytes = try await receive(exactly: 2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func readUInt32() async throws -> UInt32 {
        let bytes = try await receive(exactly: 4)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private func readUInt16(
        deadline: Date,
        timeoutError: RFBError = .clipboardTimeout
    ) async throws -> UInt16 {
        let bytes = try await receive(exactly: 2, deadline: deadline, timeoutError: timeoutError)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func readUInt32(
        deadline: Date,
        timeoutError: RFBError = .clipboardTimeout
    ) async throws -> UInt32 {
        let bytes = try await receive(exactly: 4, deadline: deadline, timeoutError: timeoutError)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private func readServerCutText(deadline: Date) async throws -> String {
        _ = try await receive(exactly: 3, deadline: deadline) // padding
        let length = Int(try await readUInt32(deadline: deadline))
        guard length <= ClipboardProtocolConstants.maximumTextBytes else {
            throw RFBError.clipboardTextTooLarge(length)
        }
        let bytes = try await receive(exactly: length, deadline: deadline)
        let data = Data(bytes)

        guard let text = String(data: data, encoding: .utf8) else {
            throw RFBError.invalidClipboardText
        }
        return text
    }

    private func discardFramebufferUpdate(deadline: Date) async throws {
        _ = try await receive(exactly: 1, deadline: deadline) // padding
        let rectangleCount = Int(try await readUInt16(deadline: deadline))
        let readUntilLastRect = rectangleCount == 0xffff
        var index = 0

        while readUntilLastRect || index < rectangleCount {
            guard let rectangle = RFBRectangleHeader(bytes: try await receive(exactly: 12, deadline: deadline)) else {
                throw RFBError.connectionClosed
            }
            index += 1

            switch rectangle.encoding {
            case RFB.rawEncoding:
                let byteCount = Int(rectangle.width) * Int(rectangle.height) * 4
                _ = try await receive(exactly: byteCount, deadline: deadline)

            case RFB.cursorEncoding:
                let pixelBytes = Int(rectangle.width) * Int(rectangle.height) * 4
                let maskBytes = ((Int(rectangle.width) + 7) / 8) * Int(rectangle.height)
                _ = try await receive(exactly: pixelBytes + maskBytes, deadline: deadline)

            case RFB.desktopSizeEncoding:
                framebufferWidth = Int(rectangle.width)
                framebufferHeight = Int(rectangle.height)

            case RFB.lastRectEncoding:
                return

            default:
                throw RFBError.unsupportedEncoding(rectangle.encoding)
            }
        }
    }
}

/// Ensures a continuation is resumed exactly once from a multi-fire callback.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
