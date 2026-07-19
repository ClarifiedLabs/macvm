import Darwin
import Foundation
import Virtualization

final class DockerIgnitionServer: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    static let port: UInt32 = 1024
    private static let maximumRequestBytes = 16 * 1024

    let listener = VZVirtioSocketListener()
    private let ignitionData: Data
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: VZVirtioSocketConnection] = [:]

    init(ignitionData: Data) {
        self.ignitionData = ignitionData
        super.init()
        listener.delegate = self
    }

    func install(on virtualMachine: VZVirtualMachine) throws {
        guard let socketDevice = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw MacVMError.message("Docker sidecar configuration did not create a virtio socket device for Ignition.")
        }
        socketDevice.setSocketListener(listener, forPort: Self.port)
    }

    func stop() {
        listener.delegate = nil
        let retained = lock.withLock {
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }
        retained.forEach { $0.close() }
    }

    nonisolated func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        retain(connection)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
        guard descriptor >= 0 else { return }
        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal))
        ) == 0 else { return }

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while request.count < Self.maximumRequestBytes {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { return }
            request.append(buffer, count: count)
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard request.count <= Self.maximumRequestBytes,
              let requestLine = String(data: request, encoding: .utf8)?.split(separator: "\r\n").first,
              requestLine.hasPrefix("GET ") else {
            writeResponse(status: "400 Bad Request", body: Data(), to: descriptor)
            return
        }
        writeResponse(status: "200 OK", body: ignitionData, to: descriptor)
    }

    private func writeResponse(status: String, body: Data, to descriptor: Int32) {
        let header = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
        )
        writeAll(header, to: descriptor)
        writeAll(body, to: descriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                guard count > 0 else { return }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
    }

    private func retain(_ connection: VZVirtioSocketConnection) {
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
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
