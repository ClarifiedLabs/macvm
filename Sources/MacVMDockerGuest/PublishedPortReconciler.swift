import Foundation
import NIOCore
import NIOPosix

private struct DockerPublishedPort: Hashable {
    enum ProtocolKind: String, Hashable {
        case tcp
        case udp
    }

    var hostIP: String
    var hostPort: Int
    var guestPort: Int
    var kind: ProtocolKind

    var normalizedHostIP: String {
        switch hostIP {
        case "", "0.0.0.0": return "0.0.0.0"
        case "::": return "::"
        default: return hostIP
        }
    }

    var sidecarPort: SidecarPublishedPort {
        SidecarPublishedPort(port: hostPort, kind: kind)
    }
}

private struct SidecarPublishedPort: Hashable {
    var port: Int
    var kind: DockerPublishedPort.ProtocolKind
}

final class PublishedPortReconciler: @unchecked Sendable {
    private let dockerSocketPath: String
    private let linuxAddress: String
    private let brokerKeyURL: URL
    private let brokerKnownHostsURL: URL
    private let dockerClient: DockerSocketHTTPClient
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let queue = DispatchQueue(label: "dev.macvm.docker-guest.ports", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var listeners: [DockerPublishedPort: Channel] = [:]
    private var configuredSidecarPorts: Set<SidecarPublishedPort> = []
    private var reportedUnsupportedBindings: Set<String> = []
    private var lastWantedBindings: Set<DockerPublishedPort>?
    private var lastReconciliationSucceeded: Bool?
    private var lastSummaryAt = Date.distantPast
    private var reconciliationCount: UInt64 = 0
    private var failedReconciliationCount: UInt64 = 0
    private var consecutiveFailures: UInt64 = 0

    private static let reconciliationInterval: TimeInterval = 2
    private static let healthSummaryInterval: TimeInterval = 5 * 60

    init(
        dockerSocketPath: String,
        linuxAddress: String,
        brokerKeyURL: URL,
        brokerKnownHostsURL: URL
    ) {
        self.dockerSocketPath = dockerSocketPath
        self.linuxAddress = linuxAddress
        self.brokerKeyURL = brokerKeyURL
        self.brokerKnownHostsURL = brokerKnownHostsURL
        self.dockerClient = DockerSocketHTTPClient(socketPath: dockerSocketPath)
    }

    func start() {
        queue.sync {
            do {
                try resetSidecarPorts()
                configuredSidecarPorts.removeAll()
            } catch {
                DockerGuestLog.error(
                    "published-ports reset-failed phase=start error=\(error.localizedDescription)"
                )
            }
        }
        DockerGuestLog.info(
            "published-ports started intervalSeconds=\(Int(Self.reconciliationInterval)) "
                + "transport=in-process-unix-http socket=\(dockerSocketPath)"
        )
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.reconciliationInterval)
        timer.setEventHandler { [weak self] in self?.reconcile() }
        timer.resume()
        self.timer = timer
    }

    func sidecarDidReconnect() {
        queue.async {
            DockerGuestLog.info("published-ports sidecar-reconnected")
            self.configuredSidecarPorts.removeAll()
            do {
                try self.resetSidecarPorts()
            } catch {
                DockerGuestLog.error(
                    "published-ports reset-failed phase=reconnect error=\(error.localizedDescription)"
                )
            }
            self.reconcile()
        }
    }

    func reconcileImmediately() throws {
        let succeeded = queue.sync {
            reconcile()
        }
        guard succeeded else {
            throw GuestHelperError("Docker published-port reconciliation failed.")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            listeners.values.forEach { try? $0.close().wait() }
            listeners.removeAll()
            if !configuredSidecarPorts.isEmpty {
                try? resetSidecarPorts()
            }
            configuredSidecarPorts.removeAll()
            DockerGuestLog.info(
                "published-ports stopped reconciliations=\(reconciliationCount) "
                    + "failures=\(failedReconciliationCount)"
            )
        }
        try? group.syncShutdownGracefully()
    }

    @discardableResult
    private func reconcile() -> Bool {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        reconciliationCount += 1
        let requested: [DockerPublishedPort]
        do {
            requested = try fetchPublishedPorts()
        } catch {
            recordReconciliation(
                requestedCount: nil,
                wanted: lastWantedBindings ?? [],
                succeeded: false,
                details: ["inspect Docker ports: \(error.localizedDescription)"],
                startedAt: startedAt
            )
            return false
        }
        var succeeded = true
        var failureDetails: [String] = []
        let ipv4 = requested.filter { binding in
            guard !binding.hostIP.contains(":") else {
                reportUnsupported("IPv6 Docker publication \(binding.hostIP):\(binding.hostPort)/\(binding.kind.rawValue)")
                return false
            }
            return true
        }
        let grouped = Dictionary(grouping: ipv4, by: \.sidecarPort)
        let ambiguous = Set(grouped.compactMap { port, bindings in
            Set(bindings.map(\.normalizedHostIP)).count > 1 ? port : nil
        })
        for port in ambiguous {
            reportUnsupported("multiple IPv4 bindings for \(port.port)/\(port.kind.rawValue)")
        }
        let wanted = Set(ipv4.filter { !ambiguous.contains($0.sidecarPort) })
        let wantedSidecarPorts = Set(wanted.map(\.sidecarPort))

        for binding in Array(listeners.keys) where !wanted.contains(binding) {
            try? listeners.removeValue(forKey: binding)?.close().wait()
        }
        for port in configuredSidecarPorts.subtracting(wantedSidecarPorts) {
            do {
                try setSidecarPort(port, enabled: false)
                configuredSidecarPorts.remove(port)
            } catch {
                succeeded = false
                failureDetails.append(
                    "remove Linux relay \(port.port)/\(port.kind.rawValue): \(error.localizedDescription)"
                )
            }
        }
        for port in wantedSidecarPorts.subtracting(configuredSidecarPorts) {
            do {
                try setSidecarPort(port, enabled: true)
                configuredSidecarPorts.insert(port)
            } catch {
                succeeded = false
                failureDetails.append(
                    "configure Linux relay \(port.port)/\(port.kind.rawValue): \(error.localizedDescription)"
                )
            }
        }
        for binding in wanted where listeners[binding] == nil
            && configuredSidecarPorts.contains(binding.sidecarPort) {
            do {
                listeners[binding] = try makeListener(for: binding)
            } catch {
                succeeded = false
                failureDetails.append(
                    "create macOS relay \(binding.hostIP):\(binding.hostPort)/\(binding.kind.rawValue): "
                        + error.localizedDescription
                )
            }
        }
        let reconciled = succeeded
            && configuredSidecarPorts == wantedSidecarPorts
            && Set(listeners.keys) == wanted
        recordReconciliation(
            requestedCount: requested.count,
            wanted: wanted,
            succeeded: reconciled,
            details: failureDetails,
            startedAt: startedAt
        )
        return reconciled
    }

    private func fetchPublishedPorts() throws -> [DockerPublishedPort] {
        let data = try dockerClient.get(path: "/containers/json")
        let object = try JSONSerialization.jsonObject(with: data)
        guard let containers = object as? [[String: Any]] else { return [] }
        return containers.flatMap { container -> [DockerPublishedPort] in
            guard let ports = container["Ports"] as? [[String: Any]] else { return [] }
            return ports.compactMap { port in
                guard let privatePort = port["PrivatePort"] as? Int,
                      let publicPort = port["PublicPort"] as? Int,
                      (1...65535).contains(publicPort),
                      let rawKind = port["Type"] as? String,
                      let kind = DockerPublishedPort.ProtocolKind(rawValue: rawKind) else { return nil }
                return DockerPublishedPort(
                    hostIP: (port["IP"] as? String) ?? "0.0.0.0",
                    hostPort: publicPort,
                    guestPort: privatePort,
                    kind: kind
                )
            }
        }
    }

    private func resetSidecarPorts() throws {
        try runSidecarBrokerCommand("reset-ports")
    }

    private func setSidecarPort(_ port: SidecarPublishedPort, enabled: Bool) throws {
        try runSidecarBrokerCommand(
            "\(enabled ? "publish-port" : "unpublish-port") \(port.kind.rawValue) \(port.port)"
        )
    }

    private func runSidecarBrokerCommand(_ command: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", sshKnownHostsOption(brokerKnownHostsURL),
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-i", brokerKeyURL.path,
            "macvm-mount@\(linuxAddress)",
            command,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 30) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
            throw GuestHelperError("sidecar port broker timed out")
        }
        process.terminationHandler = nil
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GuestHelperError(detail?.isEmpty == false ? detail! : "sidecar port broker failed")
        }
    }

    private func makeListener(for binding: DockerPublishedPort) throws -> Channel {
        switch binding.kind {
        case .tcp:
            return try ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 128)
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.autoRead, value: false)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(TCPPortRelayHandler(
                        destinationHost: self.linuxAddress,
                        destinationPort: binding.hostPort
                    ))
                }
                .bind(host: binding.normalizedHostIP, port: binding.hostPort)
                .wait()
        case .udp:
            return try DatagramBootstrap(group: group)
                .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(UDPPortRelayHandler(
                        destinationHost: self.linuxAddress,
                        destinationPort: binding.hostPort
                    ))
                }
                .bind(host: binding.normalizedHostIP, port: binding.hostPort)
                .wait()
        }
    }

    private func reportUnsupported(_ binding: String) {
        guard reportedUnsupportedBindings.insert(binding).inserted else { return }
        DockerGuestLog.error(
            "published-ports unsupported-binding detail=\(binding)"
        )
    }

    private func recordReconciliation(
        requestedCount: Int?,
        wanted: Set<DockerPublishedPort>,
        succeeded: Bool,
        details: [String],
        startedAt: UInt64
    ) {
        if succeeded {
            consecutiveFailures = 0
        } else {
            failedReconciliationCount += 1
            consecutiveFailures += 1
        }

        let now = Date()
        let bindingsChanged = lastWantedBindings != wanted
        let outcomeChanged = lastReconciliationSucceeded != succeeded
        let periodicSummary = now.timeIntervalSince(lastSummaryAt) >= Self.healthSummaryInterval
        let failureSummary = !succeeded
            && (consecutiveFailures == 1 || consecutiveFailures.isMultiple(of: 30))
        defer {
            lastWantedBindings = wanted
            lastReconciliationSucceeded = succeeded
        }
        guard bindingsChanged || outcomeChanged || periodicSummary || failureSummary else {
            return
        }

        let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - startedAt
        let elapsedMilliseconds = Double(elapsedNanoseconds) / 1_000_000
        var message = "published-ports reconcile success=\(succeeded) "
            + "requested=\(requestedCount.map { String($0) } ?? "unknown") "
            + "wanted=\(wanted.count) linuxRelays=\(configuredSidecarPorts.count) "
            + "macOSRelays=\(listeners.count) elapsedMs=\(String(format: "%.2f", elapsedMilliseconds)) "
            + "reconciliations=\(reconciliationCount) failures=\(failedReconciliationCount) "
            + "consecutiveFailures=\(consecutiveFailures)"
        if !details.isEmpty {
            message += " details=\(details.joined(separator: "; "))"
        }
        if succeeded {
            DockerGuestLog.info(message)
        } else {
            DockerGuestLog.error(message)
        }
        lastSummaryAt = now
    }
}

private final class TCPPortRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let destinationHost: String
    private let destinationPort: Int
    private var destination: Channel?

    init(destinationHost: String, destinationPort: Int) {
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    func channelActive(context: ChannelHandlerContext) {
        let source = context.channel
        ClientBootstrap(group: context.eventLoop)
            .connectTimeout(.seconds(10))
            .channelInitializer { channel in
                channel.pipeline.addHandler(TCPPortRelayReturnHandler(source: source))
            }
            .connect(host: destinationHost, port: destinationPort)
            .whenComplete { result in
                switch result {
                case .success(let destination):
                    self.destination = destination
                    source.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in
                        source.close(promise: nil)
                    }
                    source.read()
                case .failure:
                    source.close(promise: nil)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let destination else {
            context.close(promise: nil)
            return
        }
        destination.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        destination?.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        destination?.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class TCPPortRelayReturnHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let source: Channel

    init(source: Channel) { self.source = source }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        source.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        source.close(promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        source.close(promise: nil)
        context.close(promise: nil)
    }
}

private final class UDPPortRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let destinationHost: String
    private let destinationPort: Int
    private var clients: [SocketAddress: UDPClientFlow] = [:]

    init(destinationHost: String, destinationPort: Int) {
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let now = Date()
        for (address, flow) in Array(clients) where now.timeIntervalSince(flow.lastUsed) >= 60 {
            flow.close()
            clients.removeValue(forKey: address)
        }
        if clients.count >= 1_024, clients[envelope.remoteAddress] == nil,
           let oldest = clients.min(by: { $0.value.lastUsed < $1.value.lastUsed }) {
            oldest.value.close()
            clients.removeValue(forKey: oldest.key)
        }
        let flow: UDPClientFlow
        if let existing = clients[envelope.remoteAddress] {
            flow = existing
        } else {
            flow = UDPClientFlow(
                source: context.channel,
                client: envelope.remoteAddress,
                destinationHost: destinationHost,
                destinationPort: destinationPort,
                eventLoop: context.eventLoop
            )
            clients[envelope.remoteAddress] = flow
        }
        flow.send(envelope.data)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        clients.values.forEach { $0.close() }
        clients.removeAll()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private final class UDPClientFlow: @unchecked Sendable {
    private let destination: SocketAddress?
    private var channel: Channel?
    private var pending: [ByteBuffer] = []
    private(set) var lastUsed = Date()

    init(
        source: Channel,
        client: SocketAddress,
        destinationHost: String,
        destinationPort: Int,
        eventLoop: EventLoop
    ) {
        destination = try? SocketAddress(ipAddress: destinationHost, port: destinationPort)
        DatagramBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.pipeline.addHandler(UDPPortRelayReturnHandler(source: source, client: client))
            }
            .connect(host: destinationHost, port: destinationPort)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    self.channel = channel
                    guard let destination = self.destination else {
                        channel.close(promise: nil)
                        return
                    }
                    self.pending.forEach {
                        channel.write(AddressedEnvelope(remoteAddress: destination, data: $0), promise: nil)
                    }
                    self.pending.removeAll()
                    channel.flush()
                case .failure:
                    self.pending.removeAll()
                }
            }
    }

    func send(_ buffer: ByteBuffer) {
        lastUsed = Date()
        guard let destination else { return }
        if let channel {
            channel.writeAndFlush(AddressedEnvelope(remoteAddress: destination, data: buffer), promise: nil)
        } else if pending.count < 4,
                  pending.reduce(0, { $0 + $1.readableBytes }) + buffer.readableBytes <= 64 * 1024 {
            pending.append(buffer)
        }
    }

    func close() {
        channel?.close(promise: nil)
        channel = nil
        pending.removeAll()
    }
}

private final class UDPPortRelayReturnHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let source: Channel
    private let client: SocketAddress

    init(source: Channel, client: SocketAddress) {
        self.source = source
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        source.writeAndFlush(
            AddressedEnvelope(remoteAddress: client, data: envelope.data),
            promise: nil
        )
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}
