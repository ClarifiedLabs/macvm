import Foundation

/// Pure encoders/decoders for the RFB (VNC) 3.8 wire protocol subset we need:
/// pixel format, the handshake init structures, the client→server messages, and
/// the framebuffer-update rectangle header. All multi-byte integer fields are
/// big-endian on the wire; pixel bytes follow the negotiated pixel format.
///
/// Everything here is value-in/value-out so it can be unit-tested without a socket.
enum RFB {
    // Client→server message types.
    static let setPixelFormatType: UInt8 = 0
    static let setEncodingsType: UInt8 = 2
    static let framebufferUpdateRequestType: UInt8 = 3
    static let keyEventType: UInt8 = 4
    static let pointerEventType: UInt8 = 5
    static let clientCutTextType: UInt8 = 6

    // Server→client message types.
    static let framebufferUpdateType: UInt8 = 0
    static let setColourMapEntriesType: UInt8 = 1
    static let bellType: UInt8 = 2
    static let serverCutTextType: UInt8 = 3

    // Encodings. _VZVNCServer requires the client to advertise DesktopSize; with a
    // Raw-only list it hits an internal FIXME and drops the connection.
    static let rawEncoding: Int32 = 0
    static let desktopSizeEncoding: Int32 = -223
    static let cursorEncoding: Int32 = -239
    static let lastRectEncoding: Int32 = -224

    /// The encodings we advertise: Raw pixels plus the pseudo-encodings the server
    /// expects. We only decode Raw pixels; the pseudo-encoding rects are handled or
    /// skipped in the framebuffer-update loop.
    static let clientEncodings: [Int32] = [rawEncoding, desktopSizeEncoding, cursorEncoding, lastRectEncoding]

    // Security types.
    static let securityNone: UInt8 = 1
    static let securityVNCAuth: UInt8 = 2
}

struct RFBPixelFormat: Equatable {
    var bitsPerPixel: UInt8
    var depth: UInt8
    var bigEndian: Bool
    var trueColor: Bool
    var redMax: UInt16
    var greenMax: UInt16
    var blueMax: UInt16
    var redShift: UInt8
    var greenShift: UInt8
    var blueShift: UInt8

    /// 32bpp true-color where each little-endian pixel is 0x00RRGGBB, i.e. bytes
    /// laid out B, G, R, X in memory — matching `Framebuffer`'s BGRA buffer.
    static let bgra32 = RFBPixelFormat(
        bitsPerPixel: 32,
        depth: 24,
        bigEndian: false,
        trueColor: true,
        redMax: 255,
        greenMax: 255,
        blueMax: 255,
        redShift: 16,
        greenShift: 8,
        blueShift: 0
    )

    var bytesPerPixel: Int { Int(bitsPerPixel) / 8 }

    /// The 16-byte on-the-wire representation.
    var encoded: [UInt8] {
        var bytes: [UInt8] = [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColor ? 1 : 0]
        bytes.appendBigEndian(redMax)
        bytes.appendBigEndian(greenMax)
        bytes.appendBigEndian(blueMax)
        bytes.append(contentsOf: [redShift, greenShift, blueShift, 0, 0, 0])
        return bytes
    }

    init(
        bitsPerPixel: UInt8,
        depth: UInt8,
        bigEndian: Bool,
        trueColor: Bool,
        redMax: UInt16,
        greenMax: UInt16,
        blueMax: UInt16,
        redShift: UInt8,
        greenShift: UInt8,
        blueShift: UInt8
    ) {
        self.bitsPerPixel = bitsPerPixel
        self.depth = depth
        self.bigEndian = bigEndian
        self.trueColor = trueColor
        self.redMax = redMax
        self.greenMax = greenMax
        self.blueMax = blueMax
        self.redShift = redShift
        self.greenShift = greenShift
        self.blueShift = blueShift
    }

    /// Parse the 16-byte pixel format found in ServerInit.
    init?(bytes: [UInt8]) {
        guard bytes.count >= 16 else { return nil }
        bitsPerPixel = bytes[0]
        depth = bytes[1]
        bigEndian = bytes[2] != 0
        trueColor = bytes[3] != 0
        redMax = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        greenMax = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        blueMax = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        redShift = bytes[10]
        greenShift = bytes[11]
        blueShift = bytes[12]
    }
}

/// A framebuffer-update rectangle header (12 bytes: x, y, w, h, encoding).
struct RFBRectangleHeader: Equatable {
    var x: UInt16
    var y: UInt16
    var width: UInt16
    var height: UInt16
    var encoding: Int32

    init(x: UInt16, y: UInt16, width: UInt16, height: UInt16, encoding: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.encoding = encoding
    }

    init?(bytes: [UInt8]) {
        guard bytes.count >= 12 else { return nil }
        x = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        y = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        width = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        height = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        encoding = Int32(bitPattern:
            UInt32(bytes[8]) << 24 | UInt32(bytes[9]) << 16 | UInt32(bytes[10]) << 8 | UInt32(bytes[11]))
    }
}

/// Builders for the client→server messages.
enum RFBMessage {
    static func clientInit(shared: Bool) -> [UInt8] {
        [shared ? 1 : 0]
    }

    static func setPixelFormat(_ format: RFBPixelFormat) -> [UInt8] {
        var bytes: [UInt8] = [RFB.setPixelFormatType, 0, 0, 0]
        bytes.append(contentsOf: format.encoded)
        return bytes
    }

    static func setEncodings(_ encodings: [Int32]) -> [UInt8] {
        var bytes: [UInt8] = [RFB.setEncodingsType, 0]
        bytes.appendBigEndian(UInt16(encodings.count))
        for encoding in encodings {
            bytes.appendBigEndian(UInt32(bitPattern: encoding))
        }
        return bytes
    }

    static func framebufferUpdateRequest(
        incremental: Bool,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) -> [UInt8] {
        var bytes: [UInt8] = [RFB.framebufferUpdateRequestType, incremental ? 1 : 0]
        bytes.appendBigEndian(x)
        bytes.appendBigEndian(y)
        bytes.appendBigEndian(width)
        bytes.appendBigEndian(height)
        return bytes
    }

    static func keyEvent(keysym: UInt32, down: Bool) -> [UInt8] {
        var bytes: [UInt8] = [RFB.keyEventType, down ? 1 : 0, 0, 0]
        bytes.appendBigEndian(keysym)
        return bytes
    }

    static func pointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [RFB.pointerEventType, buttonMask]
        bytes.appendBigEndian(x)
        bytes.appendBigEndian(y)
        return bytes
    }

    static func clientCutText(_ text: String) -> [UInt8] {
        let textBytes = [UInt8](text.utf8)
        var bytes: [UInt8] = [RFB.clientCutTextType, 0, 0, 0]
        bytes.appendBigEndian(UInt32(textBytes.count))
        bytes.append(contentsOf: textBytes)
        return bytes
    }
}

extension Array where Element == UInt8 {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8 & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(value >> 24 & 0xff))
        append(UInt8(value >> 16 & 0xff))
        append(UInt8(value >> 8 & 0xff))
        append(UInt8(value & 0xff))
    }
}
