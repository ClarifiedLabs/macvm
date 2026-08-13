import Darwin
import Foundation
import Virtualization

struct DockerIgnitionRequestPolicy {
    enum Decision: Equatable {
        case serve
        case badRequest
        case requestTooLarge
    }

    static let maximumRequestBytes = 16 * 1024
    static let maximumIgnitionBytes = 16 * 1024 * 1024

    static func evaluate(_ request: Data) -> Decision {
        guard request.count <= maximumRequestBytes else { return .requestTooLarge }
        let terminator = Data("\r\n\r\n".utf8)
        guard let headerRange = request.range(of: terminator),
              headerRange.upperBound == request.endIndex,
              let text = String(data: request[..<headerRange.lowerBound], encoding: .isoLatin1) else {
            return .badRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        guard lines.first == "GET / HTTP/1.1" else { return .badRequest }

        var headers: [String: String] = [:]
        let permittedHeaders: Set<String> = [
            "accept", "accept-encoding", "connection", "host", "user-agent",
        ]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), separator != line.startIndex else {
                return .badRequest
            }
            let name = String(line[..<separator]).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard permittedHeaders.contains(name),
                  headers.updateValue(value, forKey: name) == nil,
                  !value.isEmpty,
                  value.utf8.allSatisfy({ $0 == 9 || $0 >= 32 }) else {
                return .badRequest
            }
        }
        return headers["host"] == "d" && headers["accept"] == "application/json"
            ? .serve
            : .badRequest
    }
}

final class DockerIgnitionServer: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    static let port: UInt32 = 1024
    static let maximumConcurrentConnections = 4
    private static let socketTimeout: TimeInterval = 5

    let listener = VZVirtioSocketListener()
    private let queue = DispatchQueue(
        label: "dev.macvm.docker-ignition",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var ignitionData: Data?
    private weak var socketDevice: VZVirtioSocketDevice?
    private var connections: [ObjectIdentifier: VZVirtioSocketConnection] = [:]
    private var sealed = false

    init(ignitionData: Data) throws {
        guard ignitionData.count <= DockerIgnitionRequestPolicy.maximumIgnitionBytes else {
            throw MacVMError.message("Docker sidecar Ignition data exceeds 16 MiB.")
        }
        self.ignitionData = ignitionData
        super.init()
        listener.delegate = self
    }

    var isSealed: Bool {
        lock.withLock { sealed }
    }

    func install(on virtualMachine: VZVirtualMachine) throws {
        guard !isSealed else {
            throw MacVMError.message("Docker sidecar Ignition server was already sealed.")
        }
        guard let socketDevice = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw MacVMError.message("Docker sidecar configuration did not create a virtio socket device for Ignition.")
        }
        socketDevice.setSocketListener(listener, forPort: Self.port)
        lock.withLock { self.socketDevice = socketDevice }
    }

    /// Permanently removes the listener and releases the boot-only configuration.
    /// Sealing is intentionally irreversible for one runtime instance.
    func seal() {
        listener.delegate = nil
        let cleanup = lock.withLock { () -> ([VZVirtioSocketConnection], VZVirtioSocketDevice?) in
            guard !sealed else { return ([], nil) }
            sealed = true
            ignitionData = nil
            let values = Array(connections.values)
            connections.removeAll()
            let device = socketDevice
            socketDevice = nil
            return (values, device)
        }
        cleanup.1?.removeSocketListener(forPort: Self.port)
        cleanup.0.forEach { $0.close() }
    }

    func stop() {
        seal()
    }

    nonisolated func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let accepted = lock.withLock {
            guard !sealed, connections.count < Self.maximumConcurrentConnections else {
                return false
            }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
        guard accepted else { return false }
        queue.async { [weak self] in
            self?.serve(connection)
        }
        return true
    }

    private func serve(_ connection: VZVirtioSocketConnection) {
        defer {
            connection.close()
            release(connection)
        }
        let descriptor = connection.fileDescriptor
        guard descriptor >= 0, configure(descriptor) else { return }
        let requestDeadline = Self.deadline()

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let terminator = Data("\r\n\r\n".utf8)
        while request.range(of: terminator) == nil {
            guard request.count < DockerIgnitionRequestPolicy.maximumRequestBytes else {
                writeResponse(status: "413 Payload Too Large", body: Data(), to: descriptor)
                return
            }
            let maximumRead = min(
                buffer.count,
                DockerIgnitionRequestPolicy.maximumRequestBytes + 1 - request.count
            )
            guard setTimeout(on: descriptor, option: SO_RCVTIMEO, deadline: requestDeadline) else {
                return
            }
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, maximumRead)
            }
            if count > 0 {
                request.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0, errno == EINTR { continue }
            return
        }

        switch DockerIgnitionRequestPolicy.evaluate(request) {
        case .serve:
            guard let body = lock.withLock({ sealed ? nil : ignitionData }) else { return }
            writeResponse(status: "200 OK", body: body, to: descriptor)
        case .badRequest:
            writeResponse(status: "400 Bad Request", body: Data(), to: descriptor)
        case .requestTooLarge:
            writeResponse(status: "413 Payload Too Large", body: Data(), to: descriptor)
        }
    }

    private func configure(_ descriptor: Int32) -> Bool {
        var noSignal: Int32 = 1
        return setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0
    }

    private static func deadline() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(socketTimeout * 1_000_000_000)
    }

    private func setTimeout(on descriptor: Int32, option: Int32, deadline: UInt64) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { return false }
        let remaining = deadline - now
        var timeout = timeval(
            tv_sec: Int(remaining / 1_000_000_000),
            tv_usec: Int32(max(1, (remaining % 1_000_000_000) / 1_000))
        )
        return setsockopt(
            descriptor,
            SOL_SOCKET,
            option,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        ) == 0
    }

    private func writeResponse(status: String, body: Data, to descriptor: Int32) {
        let header = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        let deadline = Self.deadline()
        guard writeAll(header, to: descriptor, deadline: deadline) else { return }
        _ = writeAll(body, to: descriptor, deadline: deadline)
    }

    @discardableResult
    private func writeAll(_ data: Data, to descriptor: Int32, deadline: UInt64) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var written = 0
            while written < bytes.count {
                guard setTimeout(on: descriptor, option: SO_SNDTIMEO, deadline: deadline) else {
                    return false
                }
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                if count > 0 {
                    written += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private func release(_ connection: VZVirtioSocketConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
