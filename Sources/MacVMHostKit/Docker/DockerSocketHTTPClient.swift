import Darwin
import Foundation

/// A small synchronous HTTP/1.1 client for Docker's local Unix-domain socket.
///
/// The Docker guest helper calls this from its dedicated reconciliation queue.
/// Keeping the transport in-process avoids launching `/usr/bin/curl` every two
/// seconds and removes the resulting process and DYLD shared-region churn.
struct DockerSocketHTTPClient: Sendable {
    private static let maximumHeaderSize = 64 * 1024
    private static let maximumTransferOverhead = 1024 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    private static let lineTerminator = Data("\r\n".utf8)

    let socketPath: String
    let timeout: TimeInterval
    let maximumResponseBodySize: Int

    init(
        socketPath: String,
        timeout: TimeInterval = 2,
        maximumResponseBodySize: Int = 16 * 1024 * 1024
    ) {
        self.socketPath = socketPath
        self.timeout = timeout
        self.maximumResponseBodySize = maximumResponseBodySize
    }

    func get(path: String) throws -> Data {
        guard maximumResponseBodySize > 0 else {
            throw DockerSocketHTTPClientError("Maximum response body size must be positive.")
        }
        let descriptor = try connect()
        defer { Darwin.close(descriptor) }

        try writeAll(Self.makeGETRequest(path: path), to: descriptor)
        let response = try readResponse(from: descriptor)
        return try Self.parseResponse(
            response,
            maximumBodySize: maximumResponseBodySize
        )
    }

    static func makeGETRequest(path: String) throws -> Data {
        guard path.hasPrefix("/"),
              !path.contains("\r"),
              !path.contains("\n") else {
            throw DockerSocketHTTPClientError("Invalid Docker API request path.")
        }
        let request = [
            "GET \(path) HTTP/1.1",
            "Host: localhost",
            "Accept: application/json",
            "Connection: close",
            "User-Agent: macvm-docker-guest",
            "",
            "",
        ].joined(separator: "\r\n")
        return Data(request.utf8)
    }

    static func parseResponse(
        _ response: Data,
        maximumBodySize: Int
    ) throws -> Data {
        guard maximumBodySize > 0 else {
            throw DockerSocketHTTPClientError("Maximum response body size must be positive.")
        }
        guard let headerRange = response.range(of: headerTerminator) else {
            throw DockerSocketHTTPClientError("Docker API returned an incomplete HTTP response.")
        }
        guard headerRange.lowerBound <= maximumHeaderSize else {
            throw DockerSocketHTTPClientError("Docker API response headers exceeded 64 KiB.")
        }

        let headerData = response[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw DockerSocketHTTPClientError("Docker API returned invalid HTTP headers.")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw DockerSocketHTTPClientError("Docker API returned no HTTP status line.")
        }
        let statusFields = statusLine.split(whereSeparator: \.isWhitespace)
        guard statusFields.count >= 2,
              statusFields[0].hasPrefix("HTTP/"),
              let statusCode = Int(statusFields[1]) else {
            throw DockerSocketHTTPClientError("Docker API returned an invalid HTTP status line.")
        }
        guard (200...299).contains(statusCode) else {
            throw DockerSocketHTTPClientError("Docker API returned HTTP \(statusCode).")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw DockerSocketHTTPClientError("Docker API returned a malformed HTTP header.")
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let encodedBody = Data(response[headerRange.upperBound...])
        if headers["transfer-encoding"]?
            .split(separator: ",")
            .contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("chunked") == .orderedSame })
            == true {
            return try decodeChunkedBody(encodedBody, maximumBodySize: maximumBodySize)
        }

        if let rawLength = headers["content-length"] {
            guard let length = Int(rawLength), length >= 0 else {
                throw DockerSocketHTTPClientError("Docker API returned an invalid Content-Length.")
            }
            guard length <= maximumBodySize else {
                throw DockerSocketHTTPClientError("Docker API response exceeded \(maximumBodySize) bytes.")
            }
            guard encodedBody.count >= length else {
                throw DockerSocketHTTPClientError("Docker API response body ended early.")
            }
            return Data(encodedBody.prefix(length))
        }

        guard encodedBody.count <= maximumBodySize else {
            throw DockerSocketHTTPClientError("Docker API response exceeded \(maximumBodySize) bytes.")
        }
        return encodedBody
    }

    private func connect() throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw posixError("Unable to create Docker API socket")
        }
        do {
            try configure(descriptor)

            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8) + [0]
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw DockerSocketHTTPClientError(
                    "Docker API socket path exceeds the macOS Unix-socket limit."
                )
            }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                pathBytes.withUnsafeBytes { source in
                    destination.baseAddress?.copyMemory(
                        from: source.baseAddress!,
                        byteCount: source.count
                    )
                }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        descriptor,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard result == 0 else {
                throw posixError("Unable to connect to Docker API socket at \(socketPath)")
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func configure(_ descriptor: Int32) throws {
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw posixError("Unable to configure Docker API socket")
        }

        let bounded = min(max(timeout, 0.001), Double(Int32.max))
        let seconds = floor(bounded)
        let microseconds = min(ceil((bounded - seconds) * 1_000_000), 999_999)
        var socketTimeout = timeval(
            tv_sec: numericCast(Int(seconds)),
            tv_usec: numericCast(Int(microseconds))
        )
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &socketTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0,
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &socketTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw posixError("Unable to configure Docker API socket timeout")
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if count > 0 {
                    written += count
                    continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                throw posixError("Unable to write Docker API request")
            }
        }
    }

    private func readResponse(from descriptor: Int32) throws -> Data {
        let maximumWireSize = maximumResponseBodySize
            + Self.maximumHeaderSize
            + Self.maximumTransferOverhead
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                guard response.count <= maximumWireSize - count else {
                    throw DockerSocketHTTPClientError(
                        "Docker API wire response exceeded \(maximumWireSize) bytes."
                    )
                }
                response.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                throw DockerSocketHTTPClientError(
                    "Timed out waiting for the Docker API response."
                )
            }
            throw posixError("Unable to read Docker API response")
        }

        guard !response.isEmpty else {
            throw DockerSocketHTTPClientError("Docker API closed without a response.")
        }
        return response
    }

    private static func decodeChunkedBody(
        _ encodedBody: Data,
        maximumBodySize: Int
    ) throws -> Data {
        var cursor = encodedBody.startIndex
        var body = Data()

        while true {
            guard let lineRange = encodedBody.range(
                of: lineTerminator,
                in: cursor..<encodedBody.endIndex
            ) else {
                throw DockerSocketHTTPClientError("Docker API returned an incomplete chunk header.")
            }
            let sizeData = encodedBody[cursor..<lineRange.lowerBound]
            guard let sizeLine = String(data: sizeData, encoding: .ascii),
                  let sizeField = sizeLine.split(separator: ";", maxSplits: 1).first,
                  let chunkSize = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16),
                  chunkSize >= 0 else {
                throw DockerSocketHTTPClientError("Docker API returned an invalid chunk size.")
            }
            cursor = lineRange.upperBound

            if chunkSize == 0 {
                return body
            }
            guard chunkSize <= maximumBodySize - body.count else {
                throw DockerSocketHTTPClientError(
                    "Docker API response exceeded \(maximumBodySize) bytes."
                )
            }
            guard chunkSize <= encodedBody.distance(from: cursor, to: encodedBody.endIndex) else {
                throw DockerSocketHTTPClientError("Docker API chunk ended early.")
            }
            let chunkEnd = encodedBody.index(cursor, offsetBy: chunkSize)
            body.append(encodedBody[cursor..<chunkEnd])
            guard encodedBody.distance(from: chunkEnd, to: encodedBody.endIndex) >= 2,
                  encodedBody[chunkEnd..<encodedBody.index(chunkEnd, offsetBy: 2)] == lineTerminator else {
                throw DockerSocketHTTPClientError("Docker API chunk terminator was missing.")
            }
            cursor = encodedBody.index(chunkEnd, offsetBy: 2)
        }
    }

    private func posixError(_ operation: String) -> DockerSocketHTTPClientError {
        DockerSocketHTTPClientError("\(operation): \(String(cString: strerror(errno)))")
    }
}

private struct DockerSocketHTTPClientError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
