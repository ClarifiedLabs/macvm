import Darwin
import Foundation

public struct ClipboardFrameAuthentication: Sendable {
    public var key: Data
    public var direction: ClipboardDirection

    public init(key: Data, direction: ClipboardDirection) {
        self.key = key
        self.direction = direction
    }
}

public struct ClipboardFrame: Equatable, Sendable {
    public var type: ClipboardMessageType
    public var flags: UInt16
    public var id: UInt64
    public var sequence: UInt64
    public var payload: Data

    public init(
        type: ClipboardMessageType,
        flags: UInt16 = 0,
        id: UInt64 = 0,
        sequence: UInt64 = 0,
        payload: Data = Data()
    ) {
        self.type = type
        self.flags = flags
        self.id = id
        self.sequence = sequence
        self.payload = payload
    }

    public func encoded(authentication: ClipboardFrameAuthentication? = nil) throws -> Data {
        guard flags == 0 else { throw ClipboardProtocolError.invalidFlags(flags) }
        if type.isHandshake {
            guard authentication == nil, sequence == 0 else {
                throw ClipboardProtocolError.unexpectedAuthenticationTag
            }
        } else {
            guard authentication != nil else { throw ClipboardProtocolError.authenticationRequired }
            guard sequence > 0 else {
                throw ClipboardProtocolError.invalidSequence(expected: 1, actual: sequence)
            }
        }

        let tagLength = type.isHandshake ? 0 : ClipboardProtocolConstants.authenticationTagBytes
        let (bodyLength, overflow) = ClipboardProtocolConstants.fixedHeaderBytes
            .addingReportingOverflow(payload.count)
        guard !overflow else { throw ClipboardProtocolError.invalidLength(Int.max) }
        let (totalBodyLength, tagOverflow) = bodyLength.addingReportingOverflow(tagLength)
        guard !tagOverflow,
              totalBodyLength >= ClipboardProtocolConstants.fixedHeaderBytes,
              totalBodyLength <= ClipboardProtocolConstants.maximumFrameBodyBytes,
              let wireLength = UInt32(exactly: totalBodyLength) else {
            throw ClipboardProtocolError.invalidLength(totalBodyLength)
        }

        var data = Data()
        data.appendInteger(wireLength)
        data.append(contentsOf: [0x4d, 0x56, 0x43, 0x42]) // MVCB
        data.append(ClipboardProtocolConstants.framingVersion)
        data.append(type.rawValue)
        data.appendInteger(flags)
        data.appendInteger(UInt32(0))
        data.appendInteger(id)
        data.appendInteger(sequence)
        data.append(payload)

        if let authentication {
            let tag = ClipboardAuthentication.frameTag(
                key: authentication.key,
                direction: authentication.direction,
                authenticatedBytes: data
            )
            data.append(tag)
        }
        return data
    }
}

public struct ClipboardFrameDecoder: Sendable {
    private var buffer = Data()
    private var expectedSequence: UInt64

    public init(expectedSequence: UInt64 = 1) {
        self.expectedSequence = expectedSequence
    }

    public mutating func append(
        _ data: Data,
        authentication: ClipboardFrameAuthentication? = nil
    ) throws -> [ClipboardFrame] {
        buffer.append(data)
        var frames: [ClipboardFrame] = []

        while buffer.count >= 4 {
            let bodyLength = try Self.decodeLength(buffer.prefix(4))
            guard bodyLength >= ClipboardProtocolConstants.fixedHeaderBytes,
                  bodyLength <= ClipboardProtocolConstants.maximumFrameBodyBytes else {
                buffer.removeAll(keepingCapacity: false)
                throw ClipboardProtocolError.invalidLength(bodyLength)
            }
            let (frameLength, overflow) = bodyLength.addingReportingOverflow(4)
            guard !overflow else {
                buffer.removeAll(keepingCapacity: false)
                throw ClipboardProtocolError.invalidLength(bodyLength)
            }
            guard buffer.count >= frameLength else { break }

            let wireFrame = Data(buffer.prefix(frameLength))
            buffer.removeFirst(frameLength)
            let frame = try decodeFrame(wireFrame, authentication: authentication)
            frames.append(frame)
        }
        return frames
    }

    public mutating func reset(expectedSequence: UInt64 = 1) {
        buffer.removeAll(keepingCapacity: false)
        self.expectedSequence = expectedSequence
    }

    public var bufferedByteCount: Int { buffer.count }

    private static func decodeLength(_ data: Data.SubSequence) throws -> Int {
        guard data.count == 4 else { throw ClipboardProtocolError.invalidLength(data.count) }
        return data.reduce(0) { ($0 << 8) | Int($1) }
    }

    private mutating func decodeFrame(
        _ wireFrame: Data,
        authentication: ClipboardFrameAuthentication?
    ) throws -> ClipboardFrame {
        let bodyLength = try Self.decodeLength(wireFrame.prefix(4))
        var reader = ClipboardPayloadReader(Data(wireFrame.dropFirst(4)))
        let magic = try reader.readData(count: 4)
        guard magic == Data([0x4d, 0x56, 0x43, 0x42]) else {
            throw ClipboardProtocolError.invalidMagic
        }
        let framing: UInt8 = try reader.readInteger()
        guard framing == ClipboardProtocolConstants.framingVersion else {
            throw ClipboardProtocolError.incompatibleFramingVersion(framing)
        }
        let rawType: UInt8 = try reader.readInteger()
        guard let type = ClipboardMessageType(rawValue: rawType) else {
            throw ClipboardProtocolError.unknownMessageType(rawType)
        }
        let flags: UInt16 = try reader.readInteger()
        guard flags == 0 else { throw ClipboardProtocolError.invalidFlags(flags) }
        let reserved: UInt32 = try reader.readInteger()
        guard reserved == 0 else { throw ClipboardProtocolError.invalidReservedField }
        let id: UInt64 = try reader.readInteger()
        let sequence: UInt64 = try reader.readInteger()

        let tagLength = type.isHandshake ? 0 : ClipboardProtocolConstants.authenticationTagBytes
        guard bodyLength >= ClipboardProtocolConstants.fixedHeaderBytes + tagLength else {
            throw ClipboardProtocolError.invalidLength(bodyLength)
        }
        let payloadLength = bodyLength - ClipboardProtocolConstants.fixedHeaderBytes - tagLength
        let payload = try reader.readData(count: payloadLength)

        if type.isHandshake {
            guard sequence == 0 else {
                throw ClipboardProtocolError.invalidSequence(expected: 0, actual: sequence)
            }
        } else {
            guard let authentication else { throw ClipboardProtocolError.authenticationRequired }
            let tag = try reader.readData(count: ClipboardProtocolConstants.authenticationTagBytes)
            let authenticatedBytes = Data(wireFrame.dropLast(ClipboardProtocolConstants.authenticationTagBytes))
            guard ClipboardAuthentication.verifyFrameTag(
                tag,
                key: authentication.key,
                direction: authentication.direction,
                authenticatedBytes: authenticatedBytes
            ) else {
                throw ClipboardProtocolError.invalidAuthenticationTag
            }
            guard sequence == expectedSequence else {
                throw ClipboardProtocolError.invalidSequence(expected: expectedSequence, actual: sequence)
            }
            let (next, overflow) = expectedSequence.addingReportingOverflow(1)
            guard !overflow else {
                throw ClipboardProtocolError.invalidSequence(expected: expectedSequence, actual: sequence)
            }
            expectedSequence = next
        }
        guard reader.remainingCount == 0 else {
            throw ClipboardProtocolError.invalidPayload("frame contains trailing bytes")
        }

        return ClipboardFrame(type: type, flags: flags, id: id, sequence: sequence, payload: payload)
    }
}

public struct ClipboardSequenceState: Sendable {
    private(set) public var nextOutbound: UInt64 = 1

    public init() {}

    public mutating func takeOutbound() throws -> UInt64 {
        let value = nextOutbound
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else {
            throw ClipboardProtocolError.invalidSequence(expected: value, actual: value)
        }
        nextOutbound = next
        return value
    }
}

public enum ClipboardDescriptorIO {
    public static func readExactly(
        from descriptor: Int32,
        count: Int,
        deadline: Date? = nil
    ) throws -> Data {
        guard count >= 0, count <= ClipboardProtocolConstants.maximumFrameBodyBytes else {
            throw ClipboardProtocolError.invalidLength(count)
        }
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw ClipboardProtocolError.timedOut }
                var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let milliseconds = Int32(min(ceil(remaining * 1_000), Double(Int32.max)))
                let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
                if pollResult == 0 { throw ClipboardProtocolError.timedOut }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard pollDescriptor.revents & Int16(POLLNVAL) == 0 else {
                    throw ClipboardProtocolError.connectionClosed
                }
            }

            let result = data.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
            }
            if result == 0 { throw ClipboardProtocolError.connectionClosed }
            if result < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += result
        }
        return data
    }

    public static func readWireFrame(from descriptor: Int32, deadline: Date? = nil) throws -> Data {
        let prefix = try readExactly(from: descriptor, count: 4, deadline: deadline)
        let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard length >= ClipboardProtocolConstants.fixedHeaderBytes,
              length <= ClipboardProtocolConstants.maximumFrameBodyBytes else {
            throw ClipboardProtocolError.invalidLength(length)
        }
        var result = prefix
        result.append(try readExactly(from: descriptor, count: length, deadline: deadline))
        return result
    }

    public static func writeAll(
        _ data: Data,
        to descriptor: Int32,
        deadline: Date? = nil
    ) throws {
        let originalTimeout = try deadline.map { _ in try sendTimeout(for: descriptor) }
        defer {
            if var originalTimeout {
                _ = setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_SNDTIMEO,
                    &originalTimeout,
                    socklen_t(MemoryLayout<timeval>.size)
                )
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                if let deadline {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { throw ClipboardProtocolError.timedOut }
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let milliseconds = Int32(min(ceil(remaining * 1_000), Double(Int32.max)))
                    let pollResult = Darwin.poll(&pollDescriptor, 1, milliseconds)
                    if pollResult == 0 { throw ClipboardProtocolError.timedOut }
                    if pollResult < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard pollDescriptor.revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0 else {
                        throw ClipboardProtocolError.connectionClosed
                    }
                    try setSendTimeout(remaining, for: descriptor)
                }

                let result = Darwin.send(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    if deadline != nil, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if result == 0 { throw ClipboardProtocolError.connectionClosed }
                offset += result
            }
        }
    }

    private static func sendTimeout(for descriptor: Int32) throws -> timeval {
        var timeout = timeval()
        var length = socklen_t(MemoryLayout<timeval>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, &length) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return timeout
    }

    private static func setSendTimeout(_ interval: TimeInterval, for descriptor: Int32) throws {
        let bounded = min(max(interval, 0.000_001), Double(Int32.max))
        let seconds = floor(bounded)
        let microseconds = min(ceil((bounded - seconds) * 1_000_000), 999_999)
        var timeout = timeval(
            tv_sec: numericCast(Int(seconds)),
            tv_usec: numericCast(Int(microseconds))
        )
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
