import Foundation

public enum ClipboardProtocolConstants {
    public static let socketPort: UInt32 = 42_042
    public static let framingVersion: UInt8 = 1
    public static let applicationVersion: UInt16 = 1
    public static let maximumTextBytes = 1_048_576
    public static let fixedHeaderBytes = 28
    public static let authenticationTagBytes = 32
    public static let maximumFrameBodyBytes = 1_048_700
    public static let nonceBytes = 32
    public static let pairingSecretBytes = 32
    public static let maximumPendingRequests = 16
    public static let maximumPendingHandshakes = 4
    public static let handshakeTimeout: TimeInterval = 3
    public static let heartbeatInterval: TimeInterval = 10
    public static let heartbeatTimeout: TimeInterval = 30
    public static let guestPollInterval: TimeInterval = 0.25
}

public enum ClipboardProtocolError: Error, LocalizedError, Equatable, Sendable {
    case invalidLength(Int)
    case invalidMagic
    case incompatibleFramingVersion(UInt8)
    case unknownMessageType(UInt8)
    case invalidFlags(UInt16)
    case invalidReservedField
    case authenticationRequired
    case unexpectedAuthenticationTag
    case invalidAuthenticationTag
    case invalidSequence(expected: UInt64, actual: UInt64)
    case invalidPayload(String)
    case invalidUTF8
    case textTooLarge(Int)
    case incompatibleApplicationVersion
    case requestLimitExceeded
    case connectionClosed
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidLength(let length):
            return "Invalid clipboard frame length: \(length)."
        case .invalidMagic:
            return "Invalid clipboard frame magic."
        case .incompatibleFramingVersion(let version):
            return "Unsupported clipboard framing version \(version)."
        case .unknownMessageType(let type):
            return "Unknown clipboard message type \(type)."
        case .invalidFlags(let flags):
            return "Invalid clipboard frame flags \(flags)."
        case .invalidReservedField:
            return "The clipboard frame reserved field is not zero."
        case .authenticationRequired:
            return "The clipboard frame requires authentication."
        case .unexpectedAuthenticationTag:
            return "The clipboard handshake frame must not contain an authentication tag."
        case .invalidAuthenticationTag:
            return "Clipboard frame authentication failed."
        case .invalidSequence(let expected, let actual):
            return "Invalid clipboard frame sequence (expected \(expected), received \(actual))."
        case .invalidPayload(let detail):
            return "Invalid clipboard payload: \(detail)."
        case .invalidUTF8:
            return "Clipboard text is not valid UTF-8."
        case .textTooLarge(let count):
            return "Clipboard text is \(count) UTF-8 bytes; the maximum is 1 MiB."
        case .incompatibleApplicationVersion:
            return "The clipboard helper and host protocol versions are incompatible."
        case .requestLimitExceeded:
            return "Too many clipboard requests are pending."
        case .connectionClosed:
            return "The clipboard connection closed unexpectedly."
        case .timedOut:
            return "The clipboard operation timed out."
        }
    }
}

public struct ClipboardVersionRange: Equatable, Sendable {
    public var minimum: UInt16
    public var maximum: UInt16

    public init(minimum: UInt16 = ClipboardProtocolConstants.applicationVersion, maximum: UInt16 = ClipboardProtocolConstants.applicationVersion) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func negotiatedVersion(with other: ClipboardVersionRange) -> UInt16? {
        let lower = Swift.max(minimum, other.minimum)
        let upper = Swift.min(maximum, other.maximum)
        return lower <= upper ? upper : nil
    }
}

public enum ClipboardMessageType: UInt8, CaseIterable, Sendable {
    case clientHello = 1
    case serverHello = 2
    case clientProof = 3
    case error = 4
    case setMonitoring = 10
    case baselineAcknowledgement = 11
    case guestChanged = 12
    case clipboardCommit = 13
    case explicitReadRequest = 14
    case explicitReadResponse = 15
    case explicitWriteRequest = 16
    case explicitWriteResponse = 17
    case ping = 18
    case pong = 19

    public var isHandshake: Bool {
        switch self {
        case .clientHello, .serverHello, .clientProof:
            return true
        default:
            return false
        }
    }
}

public struct ClipboardClientHello: Equatable, Sendable {
    public static let encodedLength = 56

    public var vmID: UUID
    public var versions: ClipboardVersionRange
    public var helperBuildVersion: UInt32
    public var guestNonce: Data

    public init(vmID: UUID, versions: ClipboardVersionRange = ClipboardVersionRange(), helperBuildVersion: UInt32, guestNonce: Data) throws {
        guard versions.minimum <= versions.maximum else {
            throw ClipboardProtocolError.invalidPayload("the guest version range is invalid")
        }
        guard guestNonce.count == ClipboardProtocolConstants.nonceBytes else {
            throw ClipboardProtocolError.invalidPayload("the guest nonce must be 32 bytes")
        }
        self.vmID = vmID
        self.versions = versions
        self.helperBuildVersion = helperBuildVersion
        self.guestNonce = guestNonce
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendUUID(vmID)
        data.appendInteger(versions.minimum)
        data.appendInteger(versions.maximum)
        data.appendInteger(helperBuildVersion)
        data.append(guestNonce)
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count == encodedLength else {
            throw ClipboardProtocolError.invalidPayload("client hello has an invalid length")
        }
        var reader = ClipboardPayloadReader(data)
        return try ClipboardClientHello(
            vmID: reader.readUUID(),
            versions: ClipboardVersionRange(minimum: reader.readInteger(), maximum: reader.readInteger()),
            helperBuildVersion: reader.readInteger(),
            guestNonce: reader.readData(count: ClipboardProtocolConstants.nonceBytes)
        )
    }
}

public struct ClipboardServerHello: Equatable, Sendable {
    public static let encodedLength = 76

    public var versions: ClipboardVersionRange
    public var selectedVersion: UInt16
    public var hostBuildVersion: UInt32
    public var hostNonce: Data
    public var hostProof: Data

    public init(
        versions: ClipboardVersionRange = ClipboardVersionRange(),
        selectedVersion: UInt16,
        hostBuildVersion: UInt32,
        hostNonce: Data,
        hostProof: Data
    ) throws {
        guard versions.minimum <= versions.maximum else {
            throw ClipboardProtocolError.invalidPayload("the host version range is invalid")
        }
        guard selectedVersion == 0 || (versions.minimum...versions.maximum).contains(selectedVersion) else {
            throw ClipboardProtocolError.invalidPayload("the selected version is outside the host version range")
        }
        guard hostNonce.count == ClipboardProtocolConstants.nonceBytes else {
            throw ClipboardProtocolError.invalidPayload("the host nonce must be 32 bytes")
        }
        guard hostProof.count == ClipboardProtocolConstants.authenticationTagBytes else {
            throw ClipboardProtocolError.invalidPayload("the host proof must be 32 bytes")
        }
        self.versions = versions
        self.selectedVersion = selectedVersion
        self.hostBuildVersion = hostBuildVersion
        self.hostNonce = hostNonce
        self.hostProof = hostProof
    }

    public func encoded() -> Data {
        var data = Data()
        data.appendInteger(versions.minimum)
        data.appendInteger(versions.maximum)
        data.appendInteger(selectedVersion)
        data.appendInteger(UInt16(0))
        data.appendInteger(hostBuildVersion)
        data.append(hostNonce)
        data.append(hostProof)
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count == encodedLength else {
            throw ClipboardProtocolError.invalidPayload("server hello has an invalid length")
        }
        var reader = ClipboardPayloadReader(data)
        let versions = ClipboardVersionRange(
            minimum: try reader.readInteger(),
            maximum: try reader.readInteger()
        )
        let selected: UInt16 = try reader.readInteger()
        let reserved: UInt16 = try reader.readInteger()
        guard reserved == 0 else { throw ClipboardProtocolError.invalidReservedField }
        return try ClipboardServerHello(
            versions: versions,
            selectedVersion: selected,
            hostBuildVersion: reader.readInteger(),
            hostNonce: reader.readData(count: ClipboardProtocolConstants.nonceBytes),
            hostProof: reader.readData(count: ClipboardProtocolConstants.authenticationTagBytes)
        )
    }
}

/// Lock-protected state used by the guest helper to reject pasteboard snapshots
/// that overlap a monitoring transition or a host-originated write.
public struct ClipboardGuestMonitoringState: Sendable {
    public struct PollToken: Equatable, Sendable {
        fileprivate var revision: UInt64
    }

    private var monitoring = false
    private var baselineChangeCount: Int?
    private var remoteWriteChangeCount: Int?
    private var remoteWriteInProgress = false
    private var revision: UInt64 = 0

    public init() {}

    public mutating func setMonitoring(_ active: Bool, baselineChangeCount: Int) {
        advanceRevision()
        monitoring = active
        self.baselineChangeCount = active ? baselineChangeCount : nil
        remoteWriteChangeCount = nil
        remoteWriteInProgress = false
    }

    public mutating func beginRemoteWrite() {
        advanceRevision()
        remoteWriteInProgress = true
    }

    public mutating func completeRemoteWrite(changeCount: Int) {
        advanceRevision()
        remoteWriteChangeCount = changeCount
        baselineChangeCount = changeCount
        remoteWriteInProgress = false
    }

    public func beginPoll() -> PollToken? {
        guard monitoring, !remoteWriteInProgress else { return nil }
        return PollToken(revision: revision)
    }

    /// Returns true only when the completed snapshot is a new local guest value.
    /// A revision mismatch means a host write or monitoring transition overlapped
    /// the asynchronous pasteboard read, so the stale snapshot must be discarded.
    public mutating func completePoll(_ token: PollToken, changeCount: Int) -> Bool {
        guard monitoring,
              !remoteWriteInProgress,
              token.revision == revision,
              changeCount != baselineChangeCount else { return false }
        advanceRevision()
        baselineChangeCount = changeCount
        if changeCount == remoteWriteChangeCount {
            remoteWriteChangeCount = nil
            return false
        }
        return true
    }

    private mutating func advanceRevision() {
        revision &+= 1
    }
}

public enum ClipboardPayload {
    public static func encodeText(_ text: String) throws -> Data {
        let count = text.utf8.count
        guard count <= ClipboardProtocolConstants.maximumTextBytes else {
            throw ClipboardProtocolError.textTooLarge(count)
        }
        guard let length = UInt32(exactly: count) else {
            throw ClipboardProtocolError.textTooLarge(count)
        }
        var data = Data()
        data.appendInteger(length)
        data.append(contentsOf: text.utf8)
        return data
    }

    public static func decodeText(_ data: Data) throws -> String {
        var reader = ClipboardPayloadReader(data)
        let declared: UInt32 = try reader.readInteger()
        let count = Int(declared)
        guard count <= ClipboardProtocolConstants.maximumTextBytes else {
            throw ClipboardProtocolError.textTooLarge(count)
        }
        guard reader.remainingCount == count else {
            throw ClipboardProtocolError.invalidPayload("text length does not match its frame")
        }
        let bytes = try reader.readData(count: count)
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ClipboardProtocolError.invalidUTF8
        }
        return text
    }

    public static func encodeBoolean(_ value: Bool) -> Data {
        Data([value ? 1 : 0])
    }

    public static func decodeBoolean(_ data: Data) throws -> Bool {
        guard data.count == 1, let byte = data.first, byte <= 1 else {
            throw ClipboardProtocolError.invalidPayload("boolean must be encoded as zero or one")
        }
        return byte == 1
    }

    public static func encodeChangeCount(_ count: Int) throws -> Data {
        guard let value = Int64(exactly: count) else {
            throw ClipboardProtocolError.invalidPayload("change count is out of range")
        }
        var data = Data()
        data.appendInteger(UInt64(bitPattern: value))
        return data
    }

    public static func decodeChangeCount(_ data: Data) throws -> Int {
        guard data.count == MemoryLayout<UInt64>.size else {
            throw ClipboardProtocolError.invalidPayload("change count has an invalid length")
        }
        var reader = ClipboardPayloadReader(data)
        let raw: UInt64 = try reader.readInteger()
        guard let result = Int(exactly: Int64(bitPattern: raw)) else {
            throw ClipboardProtocolError.invalidPayload("change count is out of range")
        }
        return result
    }

    public static func encodeChangedText(changeCount: Int, text: String) throws -> Data {
        var data = try encodeChangeCount(changeCount)
        data.append(try encodeText(text))
        return data
    }

    public static func decodeChangedText(_ data: Data) throws -> (changeCount: Int, text: String) {
        guard data.count >= 12 else {
            throw ClipboardProtocolError.invalidPayload("changed text is too short")
        }
        let count = try decodeChangeCount(data.prefix(8))
        let text = try decodeText(data.dropFirst(8))
        return (count, text)
    }
}

public enum ClipboardRequestError: Equatable, Sendable {
    case invalidUTF8
    case textTooLarge(Int)
    case rejected(String)

    public func encoded() throws -> Data {
        var data = Data()
        switch self {
        case .invalidUTF8:
            data.append(1)
            data.appendInteger(UInt64(0))
            data.append(try ClipboardPayload.encodeText("Clipboard text is not valid UTF-8."))
        case .textTooLarge(let count):
            data.append(2)
            data.appendInteger(UInt64(clamping: count))
            data.append(try ClipboardPayload.encodeText("Clipboard text exceeds the 1 MiB limit."))
        case .rejected(let message):
            data.append(3)
            data.appendInteger(UInt64(0))
            data.append(try ClipboardPayload.encodeText(message))
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ClipboardRequestError {
        guard data.count >= 13, let code = data.first else {
            throw ClipboardProtocolError.invalidPayload("request error payload is too short")
        }
        var reader = ClipboardPayloadReader(data.dropFirst())
        let rawCount: UInt64 = try reader.readInteger()
        let detail = try ClipboardPayload.decodeText(data.dropFirst(9))
        switch code {
        case 1:
            return .invalidUTF8
        case 2:
            guard let count = Int(exactly: rawCount) else {
                throw ClipboardProtocolError.invalidPayload("request error byte count is out of range")
            }
            return .textTooLarge(count)
        case 3:
            return .rejected(detail)
        default:
            throw ClipboardProtocolError.invalidPayload("unknown request error code \(code)")
        }
    }

    public var protocolError: ClipboardProtocolError {
        switch self {
        case .invalidUTF8:
            return .invalidUTF8
        case .textTooLarge(let count):
            return .textTooLarge(count)
        case .rejected(let message):
            return .invalidPayload(message)
        }
    }
}

public struct ClipboardRequestTracker: Sendable {
    private var pending = Set<UInt64>()
    public let maximumPending: Int

    public init(maximumPending: Int = ClipboardProtocolConstants.maximumPendingRequests) {
        self.maximumPending = maximumPending
    }

    public mutating func insert(_ requestID: UInt64) throws {
        guard requestID != 0 else {
            throw ClipboardProtocolError.invalidPayload("request ID zero is reserved")
        }
        guard pending.count < maximumPending || pending.contains(requestID) else {
            throw ClipboardProtocolError.requestLimitExceeded
        }
        guard pending.insert(requestID).inserted else {
            throw ClipboardProtocolError.invalidPayload("request ID is already pending")
        }
    }

    @discardableResult
    public mutating func remove(_ requestID: UInt64) -> Bool {
        pending.remove(requestID) != nil
    }

    public var count: Int { pending.count }
}

struct ClipboardPayloadReader {
    private let data: Data
    private var cursor: Data.Index

    init(_ data: Data) {
        self.data = data
        self.cursor = data.startIndex
    }

    var remainingCount: Int { data.distance(from: cursor, to: data.endIndex) }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0,
              let end = data.index(cursor, offsetBy: count, limitedBy: data.endIndex) else {
            throw ClipboardProtocolError.invalidPayload("payload ended early")
        }
        defer { cursor = end }
        return Data(data[cursor..<end])
    }

    mutating func readInteger<T: FixedWidthInteger>() throws -> T {
        let bytes = try readData(count: MemoryLayout<T>.size)
        return bytes.reduce(T.zero) { ($0 << 8) | T($1) }
    }

    mutating func readUUID() throws -> UUID {
        let bytes = try readData(count: 16)
        let values = Array(bytes)
        return UUID(uuid: (
            values[0], values[1], values[2], values[3],
            values[4], values[5], values[6], values[7],
            values[8], values[9], values[10], values[11],
            values[12], values[13], values[14], values[15]
        ))
    }
}

extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { append(contentsOf: $0) }
    }
}
