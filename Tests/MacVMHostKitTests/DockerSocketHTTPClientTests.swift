import Darwin
import Foundation
import Testing
@testable import MacVMHostKit

private struct DockerSocketHTTPTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class DockerUnixHTTPTestServer: @unchecked Sendable {
    let socketPath: String

    private let response: Data
    private let lock = NSLock()
    private let completed = DispatchSemaphore(value: 0)
    private var listeningDescriptor: Int32
    private var acceptedDescriptor: Int32 = -1
    private var request = Data()
    private var stopped = false

    init(response: Data) throws {
        let socketPath = "/tmp/macvm-docker-http-\(UUID().uuidString).sock"
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DockerSocketHTTPTestError(message: "Unable to create test socket.")
        }
        var closeDescriptor = true
        defer {
            if closeDescriptor {
                Darwin.close(descriptor)
                Darwin.unlink(socketPath)
            }
        }

        Darwin.unlink(socketPath)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw DockerSocketHTTPTestError(message: "Test socket path was too long.")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.baseAddress?.copyMemory(
                    from: source.baseAddress!,
                    byteCount: source.count
                )
            }
        }
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindStatus == 0, Darwin.listen(descriptor, 1) == 0 else {
            throw DockerSocketHTTPTestError(message: "Unable to listen on test socket.")
        }

        self.socketPath = socketPath
        self.response = response
        self.listeningDescriptor = descriptor
        closeDescriptor = false
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        let descriptor = listeningDescriptor
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.serveOneRequest(on: descriptor)
        }
    }

    func waitForRequest(timeout: TimeInterval = 2) -> Data? {
        guard completed.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let listener = listeningDescriptor
        listeningDescriptor = -1
        let accepted = acceptedDescriptor
        lock.unlock()

        if accepted >= 0 {
            Darwin.shutdown(accepted, SHUT_RDWR)
        }
        if listener >= 0 {
            Darwin.close(listener)
        }
        Darwin.unlink(socketPath)
    }

    private func serveOneRequest(on listeningDescriptor: Int32) {
        let descriptor = Darwin.accept(listeningDescriptor, nil, nil)
        guard descriptor >= 0 else {
            completed.signal()
            return
        }
        lock.lock()
        acceptedDescriptor = descriptor
        let shouldStop = stopped
        lock.unlock()
        guard !shouldStop else {
            Darwin.close(descriptor)
            completed.signal()
            return
        }

        defer {
            Darwin.close(descriptor)
            lock.lock()
            acceptedDescriptor = -1
            lock.unlock()
            completed.signal()
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        let terminator = Data("\r\n\r\n".utf8)
        while received.range(of: terminator) == nil, received.count <= 64 * 1024 {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else { return }
            received.append(contentsOf: buffer.prefix(count))
        }

        lock.lock()
        request = received
        lock.unlock()

        response.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                guard count > 0 else { return }
                written += count
            }
        }
    }
}

@Test
func dockerSocketHTTPClientFormatsContainerListRequest() throws {
    let request = try DockerSocketHTTPClient.makeGETRequest(path: "/containers/json")
    let expected = [
        "GET /containers/json HTTP/1.1",
        "Host: localhost",
        "Accept: application/json",
        "Connection: close",
        "User-Agent: macvm-docker-guest",
        "",
        "",
    ].joined(separator: "\r\n")

    #expect(String(data: request, encoding: .ascii) == expected)
}

@Test
func dockerSocketHTTPClientParsesContentLengthResponse() throws {
    let response = Data(
        "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world".utf8
    )

    #expect(
        try DockerSocketHTTPClient.parseResponse(response, maximumBodySize: 1024)
            == Data("hello world".utf8)
    )
}

@Test
func dockerSocketHTTPClientParsesChunkedResponse() throws {
    let response = Data(
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            .appending("5\r\nhello\r\n6;source=test\r\n world\r\n0\r\n\r\n")
            .utf8
    )

    #expect(
        try DockerSocketHTTPClient.parseResponse(response, maximumBodySize: 1024)
            == Data("hello world".utf8)
    )
}

@Test
func dockerSocketHTTPClientRejectsFailuresAndOversizedBodies() {
    let failure = Data("HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n".utf8)
    let oversized = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)

    #expect(throws: (any Error).self) {
        try DockerSocketHTTPClient.parseResponse(failure, maximumBodySize: 1024)
    }
    #expect(throws: (any Error).self) {
        try DockerSocketHTTPClient.parseResponse(oversized, maximumBodySize: 4)
    }
}

@Test
func dockerSocketHTTPClientPerformsInProcessUnixSocketRequest() throws {
    let body = Data(#"[{"Id":"container-1","Ports":[]}]"#.utf8)
    var response = Data(
        "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
    )
    response.append(body)
    let server = try DockerUnixHTTPTestServer(response: response)
    defer { server.stop() }
    server.start()

    let result = try DockerSocketHTTPClient(
        socketPath: server.socketPath,
        timeout: 1,
        maximumResponseBodySize: 1024
    ).get(path: "/containers/json")
    let request = try #require(server.waitForRequest())

    #expect(result == body)
    #expect(
        String(data: request, encoding: .ascii)?
            .hasPrefix("GET /containers/json HTTP/1.1\r\n") == true
    )
}
