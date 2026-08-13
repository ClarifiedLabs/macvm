import Darwin
import Foundation
import MacVMDockerGuestCore
import NIOCore
import NIOPosix

final class DockerAPIProxy: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let threadPool: NIOThreadPool
    private let mapper: GuestFilesystemMapper
    private let publicSocketPath: String
    private let privateSocketPath: String
    private let socketGroupName: String
    private let publishedPortsDidChange: @Sendable () throws -> Void
    private var serverChannel: Channel?

    init(
        mapper: GuestFilesystemMapper,
        publicSocketPath: String = "/var/run/docker.sock",
        privateSocketPath: String = "/var/run/macvm-docker-forward.sock",
        socketGroupName: String = "docker",
        publishedPortsDidChange: @escaping @Sendable () throws -> Void = {}
    ) {
        self.mapper = mapper
        self.publicSocketPath = publicSocketPath
        self.privateSocketPath = privateSocketPath
        self.socketGroupName = socketGroupName
        self.publishedPortsDidChange = publishedPortsDidChange
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.threadPool = NIOThreadPool(numberOfThreads: max(2, System.coreCount / 2))
    }

    func run() throws {
        threadPool.start()
        try? FileManager.default.removeItem(atPath: publicSocketPath)
        let mapper = self.mapper
        let privateSocketPath = self.privateSocketPath
        let threadPool = self.threadPool
        let publishedPortsDidChange = self.publishedPortsDidChange
        serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(
                ChannelOptions.writeBufferWaterMark,
                value: WriteBufferWaterMark(
                    low: DockerRawProxyPolicy.writeBufferLowWaterMark,
                    high: DockerRawProxyPolicy.writeBufferHighWaterMark
                )
            )
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RawDockerProxyHandler(
                    mapper: mapper,
                    privateSocketPath: privateSocketPath,
                    threadPool: threadPool,
                    publishedPortsDidChange: publishedPortsDidChange
                ))
            }
            .bind(unixDomainSocketPath: publicSocketPath)
            .wait()
        chmod(publicSocketPath, 0o660)
        if let group = getgrnam(socketGroupName) {
            chown(publicSocketPath, 0, group.pointee.gr_gid)
        }
        try serverChannel?.closeFuture.wait()
    }

    func shutdown() {
        try? serverChannel?.close().wait()
        try? threadPool.syncShutdownGracefully()
        try? group.syncShutdownGracefully()
    }
}

private struct HTTPMessageHead {
    enum BodyMode {
        case none
        case fixed(Int)
        case chunked
        case untilClose
        case invalid(String)
    }

    var firstLine: String
    var headerLines: [DockerHTTPHeaderField]
    var encodedLength: Int
    var bodyMode: BodyMode

    var headers: [String: String] {
        Dictionary(headerLines.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
    }

    func headerContainsToken(_ name: String, token: String) -> Bool {
        headerLines
            .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .flatMap { $0.value.split(separator: ",") }
            .contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame }
    }

    func replacingBody(with body: Data, removingExpect: Bool = false) -> Data {
        var result = firstLine + "\r\n"
        for header in headerLines {
            let lower = header.name.lowercased()
            guard lower != "content-length",
                  lower != "transfer-encoding",
                  lower != "trailer",
                  !removingExpect || lower != "expect" else { continue }
            result += "\(header.name): \(header.value)\r\n"
        }
        result += "Content-Length: \(body.count)\r\n\r\n"
        var data = Data(result.utf8)
        data.append(body)
        return data
    }
}

private struct ProxyRequestContext {
    var method: String
    var uri: String
    var requestedUpgrade: String?
}

private final class ResponseContextQueue {
    private var values: [ProxyRequestContext] = []

    func append(_ value: ProxyRequestContext) -> Bool {
        guard values.count < DockerRawProxyPolicy.maximumInFlightRequests else { return false }
        values.append(value)
        return true
    }

    func removeFirst() -> ProxyRequestContext? { values.isEmpty ? nil : values.removeFirst() }
}

private enum HTTPBodyStreamState {
    case fixed(Int)
    case chunkSize
    case chunkData(Int)
    case chunkDataTerminator
    case chunkTrailers(Int)

    static func make(for mode: HTTPMessageHead.BodyMode) -> HTTPBodyStreamState? {
        switch mode {
        case .fixed(let length): return .fixed(length)
        case .chunked: return .chunkSize
        case .none, .untilClose, .invalid: return nil
        }
    }

    mutating func consume(from input: inout Data) -> HTTPBodyConsumption {
        var consumed = Data()
        while true {
            switch self {
            case .fixed(let remaining):
                let count = min(remaining, input.count)
                consumed.append(takePrefix(count, from: &input))
                if count == remaining { return HTTPBodyConsumption(data: consumed, status: .complete) }
                self = .fixed(remaining - count)
                return HTTPBodyConsumption(data: consumed, status: .incomplete)

            case .chunkSize:
                switch DockerRawProxyPolicy.inspectChunkSizeLine(input) {
                case .incomplete:
                    return HTTPBodyConsumption(data: consumed, status: .incomplete)
                case .complete(let size, let encodedLength):
                    consumed.append(takePrefix(encodedLength, from: &input))
                    self = size == 0 ? .chunkTrailers(0) : .chunkData(size)
                case .rejected(let reason):
                    return HTTPBodyConsumption(data: consumed, status: .malformed(reason))
                }

            case .chunkData(let remaining):
                let count = min(remaining, input.count)
                consumed.append(takePrefix(count, from: &input))
                if count < remaining {
                    self = .chunkData(remaining - count)
                    return HTTPBodyConsumption(data: consumed, status: .incomplete)
                }
                self = .chunkDataTerminator

            case .chunkDataTerminator:
                guard input.count >= 2 else {
                    return HTTPBodyConsumption(data: consumed, status: .incomplete)
                }
                guard input.prefix(2) == Data("\r\n".utf8) else {
                    return HTTPBodyConsumption(data: consumed, status: .malformed("Missing chunk terminator."))
                }
                consumed.append(takePrefix(2, from: &input))
                self = .chunkSize

            case .chunkTrailers(let consumedTrailerBytes):
                guard let lineEnd = input.range(of: Data("\r\n".utf8)) else {
                    if consumedTrailerBytes + input.count > DockerRawProxyPolicy.maximumTrailerBytes {
                        return HTTPBodyConsumption(data: consumed, status: .malformed("Chunk trailers are too large."))
                    }
                    return HTTPBodyConsumption(data: consumed, status: .incomplete)
                }
                let lineLength = input.distance(from: input.startIndex, to: lineEnd.upperBound)
                guard consumedTrailerBytes + lineLength <= DockerRawProxyPolicy.maximumTrailerBytes else {
                    return HTTPBodyConsumption(data: consumed, status: .malformed("Chunk trailers are too large."))
                }
                let isFinalLine = lineLength == 2
                consumed.append(takePrefix(lineLength, from: &input))
                if isFinalLine { return HTTPBodyConsumption(data: consumed, status: .complete) }
                self = .chunkTrailers(consumedTrailerBytes + lineLength)
            }
        }
    }
}

private struct HTTPBodyConsumption {
    enum Status {
        case incomplete
        case complete
        case malformed(String)
    }

    var data: Data
    var status: Status
}

private func takePrefix(_ count: Int, from data: inout Data) -> Data {
    guard count > 0 else { return Data() }
    let prefix = Data(data.prefix(count))
    data.removeFirst(count)
    return prefix
}

private struct BufferedRequest {
    var head: HTTPMessageHead
    var context: ProxyRequestContext
    var message: Data
    var bodyState: HTTPBodyStreamState
}

private enum RequestProcessingState {
    case head
    case rawBody(HTTPBodyStreamState)
    case buffered(BufferedRequest)
}

private struct BufferedResponse {
    var head: HTTPMessageHead
    var request: ProxyRequestContext
    var status: Int
    var message: Data
    var bodyState: HTTPBodyStreamState?
}

private enum ResponseProcessingState {
    case head
    case rawBody(HTTPBodyStreamState)
    case buffered(BufferedResponse)
    case rawUntilClose
    case bufferedUntilClose(BufferedResponse)
}

/// A frame-aware raw HTTP relay. Unknown Docker endpoints, chunked bodies, and
/// hijacked/upgrade streams are forwarded byte-for-byte. Only finite JSON bodies
/// on the explicitly supported bind-bearing endpoints are reconstructed.
private final class RawDockerProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    fileprivate static let maximumMappedBodyBytes = 16 * 1024 * 1024
    fileprivate static let maximumHeadBytes = DockerRawProxyPolicy.maximumHeadBytes

    private let mapper: GuestFilesystemMapper
    private let privateSocketPath: String
    private let threadPool: NIOThreadPool
    private let publishedPortsDidChange: @Sendable () throws -> Void
    private let responseQueue = ResponseContextQueue()
    private var backend: Channel?
    private var pendingWrites: [ByteBuffer] = []
    private var input = Data()
    private var processingState = RequestProcessingState.head
    private var tunnelMode = false
    private var rewriteInProgress = false
    private var inputClosed = false
    private var connectQueueOverflowed = false

    init(
        mapper: GuestFilesystemMapper,
        privateSocketPath: String,
        threadPool: NIOThreadPool,
        publishedPortsDidChange: @escaping @Sendable () throws -> Void
    ) {
        self.mapper = mapper
        self.privateSocketPath = privateSocketPath
        self.threadPool = threadPool
        self.publishedPortsDidChange = publishedPortsDidChange
    }

    func channelActive(context: ChannelHandlerContext) {
        let client = context.channel
        ClientBootstrap(group: context.eventLoop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(
                ChannelOptions.writeBufferWaterMark,
                value: WriteBufferWaterMark(
                    low: DockerRawProxyPolicy.writeBufferLowWaterMark,
                    high: DockerRawProxyPolicy.writeBufferHighWaterMark
                )
            )
            .channelInitializer { channel in
                channel.pipeline.addHandler(RawDockerBackendHandler(
                    client: client,
                    mapper: self.mapper,
                    responseQueue: self.responseQueue,
                    threadPool: self.threadPool,
                    publishedPortsDidChange: self.publishedPortsDidChange
                ))
            }
            .connect(unixDomainSocketPath: privateSocketPath)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    self.backend = channel
                    guard !self.connectQueueOverflowed else {
                        channel.close(promise: nil)
                        client.close(promise: nil)
                        return
                    }
                    self.pendingWrites.forEach { channel.write($0, promise: nil) }
                    self.pendingWrites.removeAll()
                    channel.flush()
                    channel.setOption(ChannelOptions.autoRead, value: client.isWritable).whenFailure { _ in
                        client.close(promise: nil)
                    }
                    if self.inputClosed {
                        channel.close(mode: .output, promise: nil)
                    } else {
                        self.updateClientAutoRead(client)
                    }
                case .failure(let error):
                    self.sendError(error.localizedDescription, status: "502 Bad Gateway", channel: client)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if tunnelMode {
            forward(&buffer)
            return
        }
        input.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        processInput(channel: context.channel)
        if connectQueueOverflowed { context.close(promise: nil) }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, case .inputClosed = channelEvent {
            inputClosed = true
            backend?.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        backend?.close(promise: nil)
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        backend?.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in
            context.close(promise: nil)
        }
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        backend?.close(promise: nil)
        context.close(promise: nil)
    }

    private func processInput(channel: Channel) {
        guard !rewriteInProgress else { return }
        while !input.isEmpty {
            switch processingState {
            case .head:
                switch DockerRawProxyPolicy.inspectHead(input) {
                case .incomplete:
                    return
                case .rejected:
                    sendError("Docker API request headers exceed 64 KiB.", status: "431 Request Header Fields Too Large", channel: channel)
                    return
                case .complete:
                    break
                }
                guard let head = Self.parseRequestHead(from: input) else {
                    sendError("Malformed Docker API request headers.", status: "400 Bad Request", channel: channel)
                    return
                }
                if head.encodedLength > Self.maximumHeadBytes {
                    sendError("Docker API request headers exceed 64 KiB.", status: "431 Request Header Fields Too Large", channel: channel)
                    return
                }
                if case .invalid(let reason) = head.bodyMode {
                    sendError(reason, status: "400 Bad Request", channel: channel)
                    return
                }
                let methodAndURI = head.firstLine.split(separator: " ", maxSplits: 2).map(String.init)
                guard methodAndURI.count >= 2 else {
                    sendError("Malformed Docker API request line.", status: "400 Bad Request", channel: channel)
                    return
                }
                let method = methodAndURI[0]
                let uri = methodAndURI[1]
                let requestedUpgrade: String?
                switch DockerRawProxyPolicy.requestUpgrade(method: method, uri: uri, headers: head.headerLines) {
                case .none:
                    requestedUpgrade = nil
                case .requested(let value):
                    requestedUpgrade = value
                case .rejected(let reason):
                    sendError(reason, status: "400 Bad Request", channel: channel)
                    return
                }
                let request = ProxyRequestContext(method: method, uri: uri, requestedUpgrade: requestedUpgrade)
                let encodedHead = takePrefix(head.encodedLength, from: &input)

                if requestedUpgrade != nil {
                    guard responseQueue.append(request) else {
                        sendError("Too many pipelined Docker API requests.", status: "429 Too Many Requests", channel: channel)
                        return
                    }
                    forward(encodedHead, allocator: channel.allocator)
                    if !input.isEmpty {
                        forward(input, allocator: channel.allocator)
                        input.removeAll()
                    }
                    tunnelMode = true
                    return
                }

                guard DockerAPIPathRewriter.rewritesRequest(method: method, uri: uri) else {
                    guard responseQueue.append(request) else {
                        sendError("Too many pipelined Docker API requests.", status: "429 Too Many Requests", channel: channel)
                        return
                    }
                    forward(encodedHead, allocator: channel.allocator)
                    switch head.bodyMode {
                    case .none:
                        continue
                    case .fixed, .chunked:
                        guard let bodyState = HTTPBodyStreamState.make(for: head.bodyMode) else { return }
                        processingState = .rawBody(bodyState)
                    case .untilClose:
                        if !input.isEmpty {
                            forward(input, allocator: channel.allocator)
                            input.removeAll()
                        }
                        tunnelMode = true
                        return
                    case .invalid:
                        return
                    }
                    continue
                }

                guard case .untilClose = head.bodyMode else {
                    if head.headerContainsToken("expect", token: "100-continue"),
                       !Self.bodyModeIsEmpty(head.bodyMode) {
                        sendContinue(channel: channel)
                    }
                    if case .none = head.bodyMode {
                        rewrite(
                            BufferedRequest(
                                head: head,
                                context: request,
                                message: encodedHead,
                                bodyState: .fixed(0)
                            ),
                            channel: channel
                        )
                        return
                    }
                    if case .fixed(let length) = head.bodyMode,
                       length > Self.maximumMappedBodyBytes {
                        sendError(
                            "Mapped Docker API request exceeds 16 MiB.",
                            status: "413 Payload Too Large",
                            channel: channel
                        )
                        return
                    }
                    guard let bodyState = HTTPBodyStreamState.make(for: head.bodyMode) else { return }
                    processingState = .buffered(BufferedRequest(
                        head: head,
                        context: request,
                        message: encodedHead,
                        bodyState: bodyState
                    ))
                    continue
                }
                sendError(
                    "Mapped Docker API requests require Content-Length or chunked framing.",
                    status: "411 Length Required",
                    channel: channel
                )
                return

            case .rawBody(var bodyState):
                let consumption = bodyState.consume(from: &input)
                if !consumption.data.isEmpty {
                    forward(consumption.data, allocator: channel.allocator)
                }
                switch consumption.status {
                case .incomplete:
                    processingState = .rawBody(bodyState)
                    return
                case .complete:
                    processingState = .head
                case .malformed(let reason):
                    sendError(reason, status: "400 Bad Request", channel: channel)
                    return
                }

            case .buffered(var request):
                let consumption = request.bodyState.consume(from: &input)
                request.message.append(consumption.data)
                if request.message.count - request.head.encodedLength > Self.maximumMappedBodyBytes {
                    sendError(
                        "Mapped Docker API request exceeds 16 MiB.",
                        status: "413 Payload Too Large",
                        channel: channel
                    )
                    return
                }
                switch consumption.status {
                case .incomplete:
                    processingState = .buffered(request)
                    return
                case .complete:
                    processingState = .head
                    rewrite(request, channel: channel)
                    return
                case .malformed(let reason):
                    sendError(reason, status: "400 Bad Request", channel: channel)
                    return
                }
            }
        }
    }

    private static func bodyModeIsEmpty(_ bodyMode: HTTPMessageHead.BodyMode) -> Bool {
        if case .none = bodyMode { return true }
        return false
    }

    private func rewrite(_ request: BufferedRequest, channel: Channel) {
        guard let body = Self.decodedBody(from: request.message, head: request.head),
              body.count <= Self.maximumMappedBodyBytes else {
            sendError(
                "Mapped Docker API request is invalid or exceeds 16 MiB.",
                status: "413 Payload Too Large",
                channel: channel
            )
            return
        }
        rewriteInProgress = true
        channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        threadPool.runIfActive(eventLoop: channel.eventLoop) {
            try DockerAPIPathRewriter.rewriteRequestBody(
                body,
                method: request.context.method,
                uri: request.context.uri,
                transform: self.mapper.mapMacOSPath
            )
        }.whenComplete { result in
            switch result {
            case .success(let rewritten):
                guard self.responseQueue.append(request.context) else {
                    self.sendError("Too many pipelined Docker API requests.", status: "429 Too Many Requests", channel: channel)
                    self.rewriteInProgress = false
                    return
                }
                self.forward(
                    request.head.replacingBody(with: rewritten, removingExpect: true),
                    allocator: channel.allocator
                )
            case .failure(let error):
                self.sendError(error.localizedDescription, status: "400 Bad Request", channel: channel)
            }
            self.rewriteInProgress = false
            self.updateClientAutoRead(channel)
            self.processInput(channel: channel)
        }
    }

    private func sendContinue(channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: 25)
        buffer.writeString("HTTP/1.1 100 Continue\r\n\r\n")
        channel.writeAndFlush(buffer, promise: nil)
    }

    private func forward(_ source: inout ByteBuffer) {
        guard let backend else {
            let pendingBytes = pendingWrites.reduce(0) { $0 + $1.readableBytes }
            guard source.readableBytes <= DockerRawProxyPolicy.maximumPendingBackendBytes,
                  pendingBytes <= DockerRawProxyPolicy.maximumPendingBackendBytes - source.readableBytes else {
                pendingWrites.removeAll()
                connectQueueOverflowed = true
                return
            }
            pendingWrites.append(source)
            return
        }
        backend.writeAndFlush(source, promise: nil)
    }

    private func forward(_ data: Data, allocator: ByteBufferAllocator) {
        var buffer = allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        forward(&buffer)
    }

    private func updateClientAutoRead(_ channel: Channel?) {
        guard let channel else { return }
        channel.setOption(
            ChannelOptions.autoRead,
            value: backend?.isWritable == true && !rewriteInProgress && !inputClosed
        ).whenFailure { _ in channel.close(promise: nil) }
    }

    private func sendError(_ message: String, status: String, channel: Channel) {
        let body = DockerGuestFileUtilities.dockerErrorJSON(message)
        let response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        var buffer = channel.allocator.buffer(capacity: response.count)
        buffer.writeBytes(response)
        channel.writeAndFlush(buffer, promise: nil)
        channel.close(promise: nil)
    }

    fileprivate static func parseRequestHead(from data: Data) -> HTTPMessageHead? {
        parseHead(from: data, request: true, requestMethod: nil)
    }

    fileprivate static func parseResponseHead(from data: Data, requestMethod: String?) -> HTTPMessageHead? {
        parseHead(from: data, request: false, requestMethod: requestMethod)
    }

    private static func parseHead(
        from data: Data,
        request: Bool,
        requestMethod: String?
    ) -> HTTPMessageHead? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: data[..<range.lowerBound], encoding: .isoLatin1) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        var malformedHeader = false
        let headerLines = lines.dropFirst().compactMap { line -> DockerHTTPHeaderField? in
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                malformedHeader = true
                return nil
            }
            return DockerHTTPHeaderField(
                name: String(line[..<colon]),
                value: String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            )
        }
        let statusFields = firstLine.split(separator: " ")
        let status = !request && statusFields.count > 1 ? Int(statusFields[1]) : nil
        let bodyMode: HTTPMessageHead.BodyMode
        if malformedHeader {
            bodyMode = .invalid("Malformed HTTP header line.")
        } else {
            switch DockerRawProxyPolicy.framing(
                isRequest: request,
                requestMethod: requestMethod,
                responseStatus: status,
                headers: headerLines
            ) {
            case .accepted(.none): bodyMode = .none
            case .accepted(.fixed(let length)): bodyMode = .fixed(length)
            case .accepted(.chunked): bodyMode = .chunked
            case .accepted(.untilClose): bodyMode = .untilClose
            case .rejected(let reason): bodyMode = .invalid(reason)
            }
        }
        return HTTPMessageHead(
            firstLine: firstLine,
            headerLines: headerLines,
            encodedLength: data.distance(from: data.startIndex, to: range.upperBound),
            bodyMode: bodyMode
        )
    }

    fileprivate static func completeMessageLength(in data: Data, head: HTTPMessageHead) -> Int? {
        switch head.bodyMode {
        case .none:
            return head.encodedLength
        case .fixed(let length):
            let total = head.encodedLength + length
            return data.count >= total ? total : nil
        case .chunked:
            guard let length = chunkedBodyLength(Data(data.dropFirst(head.encodedLength))) else { return nil }
            return head.encodedLength + length
        case .untilClose, .invalid:
            return nil
        }
    }

    fileprivate static func decodedBody(from message: Data, head: HTTPMessageHead) -> Data? {
        let encoded = Data(message.dropFirst(head.encodedLength))
        switch head.bodyMode {
        case .none: return Data()
        case .fixed: return encoded
        case .chunked: return decodeChunked(encoded)
        case .untilClose: return encoded
        case .invalid: return nil
        }
    }

    private static func chunkedBodyLength(_ data: Data) -> Int? {
        var remainder = data
        var state = HTTPBodyStreamState.chunkSize
        let consumption = state.consume(from: &remainder)
        guard case .complete = consumption.status else { return nil }
        return data.count - remainder.count
    }

    private static func decodeChunked(_ data: Data) -> Data? {
        var result = Data()
        var input = data
        while true {
            guard case .complete(let size, let encodedLength) =
                DockerRawProxyPolicy.inspectChunkSizeLine(input) else { return nil }
            input.removeFirst(encodedLength)
            if size == 0 {
                var trailerState = HTTPBodyStreamState.chunkTrailers(0)
                let trailers = trailerState.consume(from: &input)
                guard case .complete = trailers.status else { return nil }
                return result
            }
            guard input.count >= size + 2,
                  input.dropFirst(size).prefix(2) == Data("\r\n".utf8) else { return nil }
            result.append(input.prefix(size))
            input.removeFirst(size + 2)
        }
    }
}

private final class RawDockerBackendHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let client: Channel
    private let mapper: GuestFilesystemMapper
    private let responseQueue: ResponseContextQueue
    private let threadPool: NIOThreadPool
    private let publishedPortsDidChange: @Sendable () throws -> Void
    private var input = Data()
    private var currentRequest: ProxyRequestContext?
    private var processingState = ResponseProcessingState.head
    private var tunnelMode = false
    private var inputFinished = false
    private var reconciliationInProgress = false

    init(
        client: Channel,
        mapper: GuestFilesystemMapper,
        responseQueue: ResponseContextQueue,
        threadPool: NIOThreadPool,
        publishedPortsDidChange: @escaping @Sendable () throws -> Void
    ) {
        self.client = client
        self.mapper = mapper
        self.responseQueue = responseQueue
        self.threadPool = threadPool
        self.publishedPortsDidChange = publishedPortsDidChange
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if tunnelMode {
            client.writeAndFlush(buffer, promise: nil)
            return
        }
        input.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        processInput(channel: context.channel)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let channelEvent = event as? ChannelEvent, case .inputClosed = channelEvent {
            finishBackendInput(halfCloseClient: true)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishBackendInput(halfCloseClient: false)
        context.fireChannelInactive()
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        client.setOption(ChannelOptions.autoRead, value: context.channel.isWritable).whenFailure { _ in
            context.close(promise: nil)
        }
        context.fireChannelWritabilityChanged()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client.close(promise: nil)
        context.close(promise: nil)
    }

    private func processInput(channel: Channel) {
        guard !reconciliationInProgress else { return }
        while !input.isEmpty {
            switch processingState {
            case .head:
                if currentRequest == nil { currentRequest = responseQueue.removeFirst() }
                guard let request = currentRequest else { return }
                switch DockerRawProxyPolicy.inspectHead(input) {
                case .incomplete:
                    return
                case .rejected:
                    client.close(promise: nil)
                    return
                case .complete:
                    break
                }
                guard let head = RawDockerProxyHandler.parseResponseHead(
                    from: input,
                    requestMethod: request.method
                ) else {
                    client.close(promise: nil)
                    return
                }
                if head.encodedLength > RawDockerProxyHandler.maximumHeadBytes {
                    client.close(promise: nil)
                    return
                }
                if case .invalid = head.bodyMode {
                    client.close(promise: nil)
                    return
                }
                let statusFields = head.firstLine.split(separator: " ")
                guard statusFields.count > 1, let status = Int(statusFields[1]) else {
                    client.close(promise: nil)
                    return
                }
                let encodedHead = takePrefix(head.encodedLength, from: &input)

                if (100...199).contains(status), status != 101 {
                    forward(encodedHead)
                    continue
                }

                let tunnelDecision = DockerRawProxyPolicy.tunnelDecision(
                    requestMethod: request.method,
                    requestURI: request.uri,
                    requestedUpgrade: request.requestedUpgrade,
                    responseStatus: status,
                    responseHeaders: head.headerLines
                )
                if tunnelDecision == .reject {
                    client.close(promise: nil)
                    return
                }
                if tunnelDecision == .tunnel {
                    forward(encodedHead)
                    if !input.isEmpty {
                        forward(input)
                        input.removeAll()
                    }
                    currentRequest = nil
                    tunnelMode = true
                    return
                }

                if DockerAPIPathRewriter.affectsPublishedPorts(
                    method: request.method,
                    uri: request.uri,
                    status: status
                ) {
                    reconcilePublishedPorts(beforeForwarding: encodedHead, head: head, channel: channel)
                    return
                }

                let shouldRewrite = DockerAPIPathRewriter.rewritesResponse(
                    method: request.method,
                    uri: request.uri,
                    status: status
                ) && !Self.bodyModeIsEmpty(head.bodyMode)

                if shouldRewrite {
                    switch head.bodyMode {
                    case .fixed(let length):
                        guard length <= RawDockerProxyHandler.maximumMappedBodyBytes,
                              let bodyState = HTTPBodyStreamState.make(for: head.bodyMode) else {
                            client.close(promise: nil)
                            return
                        }
                        processingState = .buffered(BufferedResponse(
                            head: head,
                            request: request,
                            status: status,
                            message: encodedHead,
                            bodyState: bodyState
                        ))
                    case .chunked:
                        guard let bodyState = HTTPBodyStreamState.make(for: head.bodyMode) else { return }
                        processingState = .buffered(BufferedResponse(
                            head: head,
                            request: request,
                            status: status,
                            message: encodedHead,
                            bodyState: bodyState
                        ))
                    case .untilClose:
                        processingState = .bufferedUntilClose(BufferedResponse(
                            head: head,
                            request: request,
                            status: status,
                            message: encodedHead,
                            bodyState: nil
                        ))
                    case .none, .invalid:
                        forward(encodedHead)
                        currentRequest = nil
                    }
                    continue
                }

                forward(encodedHead)
                switch head.bodyMode {
                case .none:
                    currentRequest = nil
                case .fixed, .chunked:
                    guard let bodyState = HTTPBodyStreamState.make(for: head.bodyMode) else { return }
                    processingState = .rawBody(bodyState)
                case .untilClose:
                    processingState = .rawUntilClose
                case .invalid:
                    return
                }

            case .rawBody(var bodyState):
                let consumption = bodyState.consume(from: &input)
                if !consumption.data.isEmpty { forward(consumption.data) }
                switch consumption.status {
                case .incomplete:
                    processingState = .rawBody(bodyState)
                    return
                case .complete:
                    processingState = .head
                    currentRequest = nil
                case .malformed:
                    client.close(promise: nil)
                    return
                }

            case .buffered(var response):
                guard var bodyState = response.bodyState else {
                    client.close(promise: nil)
                    return
                }
                let consumption = bodyState.consume(from: &input)
                response.message.append(consumption.data)
                response.bodyState = bodyState
                if response.message.count - response.head.encodedLength
                    > RawDockerProxyHandler.maximumMappedBodyBytes {
                    client.close(promise: nil)
                    return
                }
                switch consumption.status {
                case .incomplete:
                    processingState = .buffered(response)
                    return
                case .complete:
                    processingState = .head
                    currentRequest = nil
                    guard rewrite(response, closingClient: false) else { return }
                case .malformed:
                    client.close(promise: nil)
                    return
                }

            case .rawUntilClose:
                forward(input)
                input.removeAll()
                return

            case .bufferedUntilClose(var response):
                response.message.append(input)
                input.removeAll()
                guard response.message.count - response.head.encodedLength
                    <= RawDockerProxyHandler.maximumMappedBodyBytes else {
                    client.close(promise: nil)
                    return
                }
                processingState = .bufferedUntilClose(response)
                return
            }
        }
    }

    private func reconcilePublishedPorts(
        beforeForwarding encodedHead: Data,
        head: HTTPMessageHead,
        channel: Channel
    ) {
        reconciliationInProgress = true
        channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in
            channel.close(promise: nil)
        }
        threadPool.runIfActive(eventLoop: client.eventLoop) {
            try self.publishedPortsDidChange()
        }.whenComplete { result in
            DockerPublishedPortPolicy.forwardResponseAfterReconciliation(
                result,
                onFailure: { error in
                    DockerGuestLog.error(
                        "Published-port reconciliation failed after Docker accepted the request: \(error.localizedDescription)"
                    )
                },
                forwardResponse: {
                    self.reconciliationInProgress = false
                    self.forward(encodedHead)
                    switch head.bodyMode {
                    case .none:
                        self.currentRequest = nil
                        self.processingState = .head
                    case .fixed, .chunked:
                        guard let bodyState = HTTPBodyStreamState.make(for: head.bodyMode) else {
                            self.client.close(promise: nil)
                            return
                        }
                        self.processingState = .rawBody(bodyState)
                    case .untilClose:
                        self.processingState = .rawUntilClose
                    case .invalid:
                        self.client.close(promise: nil)
                        return
                    }
                    channel.setOption(ChannelOptions.autoRead, value: self.client.isWritable).whenComplete { _ in
                        self.processInput(channel: channel)
                    }
                }
            )
        }
    }

    private func finishBackendInput(halfCloseClient: Bool) {
        guard !inputFinished else {
            if !halfCloseClient { client.close(promise: nil) }
            return
        }
        inputFinished = true
        switch processingState {
        case .bufferedUntilClose(var response):
            response.message.append(input)
            input.removeAll()
            if response.message.count - response.head.encodedLength
                <= RawDockerProxyHandler.maximumMappedBodyBytes {
                _ = rewrite(
                    response,
                    closingClient: true,
                    halfCloseClient: halfCloseClient
                )
            } else if halfCloseClient {
                client.close(mode: .output, promise: nil)
            } else {
                client.close(promise: nil)
            }
        case .buffered:
            if halfCloseClient {
                client.close(mode: .output, promise: nil)
            } else {
                client.close(promise: nil)
            }
        case .head, .rawBody, .rawUntilClose:
            if !input.isEmpty {
                forward(input)
                input.removeAll()
            }
            if halfCloseClient {
                client.close(mode: .output, promise: nil)
            } else {
                client.close(promise: nil)
            }
        }
    }

    private static func bodyModeIsEmpty(_ bodyMode: HTTPMessageHead.BodyMode) -> Bool {
        if case .none = bodyMode { return true }
        return false
    }

    @discardableResult
    private func rewrite(
        _ response: BufferedResponse,
        closingClient: Bool,
        halfCloseClient: Bool = false
    ) -> Bool {
        guard let body = RawDockerProxyHandler.decodedBody(from: response.message, head: response.head),
              body.count <= RawDockerProxyHandler.maximumMappedBodyBytes else {
            client.close(promise: nil)
            return false
        }
        do {
            let rewritten = try DockerAPIPathRewriter.rewriteResponseBody(
                body,
                method: response.request.method,
                uri: response.request.uri,
                status: response.status,
                transform: mapper.mapLinuxPath
            )
            let message = response.head.replacingBody(with: rewritten)
            if closingClient {
                var buffer = client.allocator.buffer(capacity: message.count)
                buffer.writeBytes(message)
                client.writeAndFlush(buffer).whenComplete { _ in
                    if halfCloseClient {
                        self.client.close(mode: .output, promise: nil)
                    } else {
                        self.client.close(promise: nil)
                    }
                }
            } else {
                forward(message)
            }
            return true
        } catch {
            client.close(promise: nil)
            return false
        }
    }

    private func forward(_ data: Data) {
        var buffer = client.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        client.writeAndFlush(buffer, promise: nil)
    }
}
