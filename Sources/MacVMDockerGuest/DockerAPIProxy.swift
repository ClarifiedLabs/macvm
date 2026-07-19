import Darwin
import Foundation
import NIOCore
import NIOPosix

final class DockerAPIProxy: @unchecked Sendable {
    private let group: MultiThreadedEventLoopGroup
    private let threadPool: NIOThreadPool
    private let mapper: GuestFilesystemMapper
    private let publicSocketPath: String
    private let privateSocketPath: String
    private let socketGroupName: String
    private var serverChannel: Channel?

    init(
        mapper: GuestFilesystemMapper,
        publicSocketPath: String = "/var/run/docker.sock",
        privateSocketPath: String = "/var/run/macvm-docker-forward.sock",
        socketGroupName: String = "docker"
    ) {
        self.mapper = mapper
        self.publicSocketPath = publicSocketPath
        self.privateSocketPath = privateSocketPath
        self.socketGroupName = socketGroupName
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.threadPool = NIOThreadPool(numberOfThreads: max(2, System.coreCount / 2))
    }

    func run() throws {
        threadPool.start()
        try? FileManager.default.removeItem(atPath: publicSocketPath)
        let mapper = self.mapper
        let privateSocketPath = self.privateSocketPath
        let threadPool = self.threadPool
        serverChannel = try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RawDockerProxyHandler(
                    mapper: mapper,
                    privateSocketPath: privateSocketPath,
                    threadPool: threadPool
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
    var headerLines: [(name: String, value: String)]
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
    var upgradeRequested: Bool
}

private final class ResponseContextQueue {
    private var values: [ProxyRequestContext] = []
    func append(_ value: ProxyRequestContext) { values.append(value) }
    func removeFirst() -> ProxyRequestContext? { values.isEmpty ? nil : values.removeFirst() }
}

private enum HTTPBodyStreamState {
    case fixed(Int)
    case chunkSize
    case chunkData(Int)
    case chunkDataTerminator
    case chunkTrailers

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
                guard let lineEnd = input.range(of: Data("\r\n".utf8)) else {
                    return HTTPBodyConsumption(data: consumed, status: .incomplete)
                }
                let lineData = Data(input[..<lineEnd.lowerBound])
                guard let line = String(data: lineData, encoding: .ascii) else {
                    return HTTPBodyConsumption(data: consumed, status: .malformed("Invalid chunk-size line."))
                }
                guard let rawSize = line.split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces),
                    !rawSize.isEmpty,
                    let size = Int(rawSize, radix: 16) else {
                    return HTTPBodyConsumption(data: consumed, status: .malformed("Invalid chunk size."))
                }
                let lineLength = input.distance(from: input.startIndex, to: lineEnd.upperBound)
                consumed.append(takePrefix(lineLength, from: &input))
                self = size == 0 ? .chunkTrailers : .chunkData(size)

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

            case .chunkTrailers:
                guard let lineEnd = input.range(of: Data("\r\n".utf8)) else {
                    return HTTPBodyConsumption(data: consumed, status: .incomplete)
                }
                let lineLength = input.distance(from: input.startIndex, to: lineEnd.upperBound)
                let isFinalLine = lineLength == 2
                consumed.append(takePrefix(lineLength, from: &input))
                if isFinalLine { return HTTPBodyConsumption(data: consumed, status: .complete) }
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
    fileprivate static let maximumHeadBytes = 64 * 1024

    private let mapper: GuestFilesystemMapper
    private let privateSocketPath: String
    private let threadPool: NIOThreadPool
    private let responseQueue = ResponseContextQueue()
    private var backend: Channel?
    private var pendingWrites: [ByteBuffer] = []
    private var input = Data()
    private var processingState = RequestProcessingState.head
    private var tunnelMode = false
    private var rewriteInProgress = false
    private var inputClosed = false

    init(mapper: GuestFilesystemMapper, privateSocketPath: String, threadPool: NIOThreadPool) {
        self.mapper = mapper
        self.privateSocketPath = privateSocketPath
        self.threadPool = threadPool
    }

    func channelActive(context: ChannelHandlerContext) {
        let client = context.channel
        ClientBootstrap(group: context.eventLoop)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.pipeline.addHandler(RawDockerBackendHandler(
                    client: client,
                    mapper: self.mapper,
                    responseQueue: self.responseQueue
                ))
            }
            .connect(unixDomainSocketPath: privateSocketPath)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    self.backend = channel
                    self.pendingWrites.forEach { channel.write($0, promise: nil) }
                    self.pendingWrites.removeAll()
                    channel.flush()
                    if self.inputClosed {
                        channel.close(mode: .output, promise: nil)
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

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        backend?.close(promise: nil)
        context.close(promise: nil)
    }

    private func processInput(channel: Channel) {
        guard !rewriteInProgress else { return }
        while !input.isEmpty {
            switch processingState {
            case .head:
                guard let head = Self.parseRequestHead(from: input) else {
                    if input.count > Self.maximumHeadBytes {
                        sendError("Docker API request headers exceed 64 KiB.", status: "431 Request Header Fields Too Large", channel: channel)
                    }
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
                let upgrade = head.headerContainsToken("connection", token: "upgrade")
                    || head.headers["upgrade"] != nil
                let request = ProxyRequestContext(method: method, uri: uri, upgradeRequested: upgrade)
                let encodedHead = takePrefix(head.encodedLength, from: &input)

                if upgrade {
                    responseQueue.append(request)
                    forward(encodedHead, allocator: channel.allocator)
                    if !input.isEmpty {
                        forward(input, allocator: channel.allocator)
                        input.removeAll()
                    }
                    tunnelMode = true
                    return
                }

                guard DockerAPIPathRewriter.rewritesRequest(method: method, uri: uri) else {
                    responseQueue.append(request)
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
                self.responseQueue.append(request.context)
                self.forward(
                    request.head.replacingBody(with: rewritten, removingExpect: true),
                    allocator: channel.allocator
                )
            case .failure(let error):
                self.sendError(error.localizedDescription, status: "400 Bad Request", channel: channel)
            }
            self.rewriteInProgress = false
            channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in
                self.processInput(channel: channel)
            }
        }
    }

    private func sendContinue(channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: 25)
        buffer.writeString("HTTP/1.1 100 Continue\r\n\r\n")
        channel.writeAndFlush(buffer, promise: nil)
    }

    private func forward(_ source: inout ByteBuffer) {
        guard let backend else {
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
        let headerLines = lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                malformedHeader = true
                return nil
            }
            return (
                String(line[..<colon]),
                String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            )
        }
        let statusFields = firstLine.split(separator: " ")
        let status = !request && statusFields.count > 1 ? Int(statusFields[1]) : nil
        let responseHasNoBody = !request && (
            requestMethod?.uppercased() == "HEAD"
                || status == 204
                || status == 304
                || status.map { 100...199 ~= $0 } == true
        )
        let transferCodings = headerLines
            .filter { $0.0.caseInsensitiveCompare("transfer-encoding") == .orderedSame }
            .flatMap { $0.1.split(separator: ",") }
            .map {
                $0.split(separator: ";", maxSplits: 1)[0]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
            }
        let rawContentLengths = headerLines
            .filter { $0.0.caseInsensitiveCompare("content-length") == .orderedSame }
            .flatMap { $0.1.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let contentLengths = rawContentLengths.compactMap(Int.init)
        let bodyMode: HTTPMessageHead.BodyMode
        if malformedHeader {
            bodyMode = .invalid("Malformed HTTP header line.")
        } else if responseHasNoBody {
            bodyMode = .none
        } else if !transferCodings.isEmpty {
            if transferCodings.last == "chunked" {
                bodyMode = .chunked
            } else if request {
                bodyMode = .invalid("Unsupported request Transfer-Encoding framing.")
            } else {
                bodyMode = .untilClose
            }
        } else if !rawContentLengths.isEmpty {
            if contentLengths.count != rawContentLengths.count
                || contentLengths.contains(where: { $0 < 0 })
                || Set(contentLengths).count != 1 {
                bodyMode = .invalid("Invalid or conflicting Content-Length headers.")
            } else if contentLengths[0] == 0 {
                bodyMode = .none
            } else {
                bodyMode = .fixed(contentLengths[0])
            }
        } else if request {
            bodyMode = .none
        } else {
            bodyMode = .untilClose
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
            guard let lineEnd = input.range(of: Data("\r\n".utf8)),
                  let line = String(data: input[..<lineEnd.lowerBound], encoding: .ascii),
                  let rawSize = line.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces),
                  !rawSize.isEmpty,
                  let size = Int(rawSize, radix: 16) else { return nil }
            let lineLength = input.distance(from: input.startIndex, to: lineEnd.upperBound)
            input.removeFirst(lineLength)
            if size == 0 {
                var trailerState = HTTPBodyStreamState.chunkTrailers
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
    private var input = Data()
    private var currentRequest: ProxyRequestContext?
    private var processingState = ResponseProcessingState.head
    private var tunnelMode = false
    private var inputFinished = false

    init(client: Channel, mapper: GuestFilesystemMapper, responseQueue: ResponseContextQueue) {
        self.client = client
        self.mapper = mapper
        self.responseQueue = responseQueue
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if tunnelMode {
            client.writeAndFlush(buffer, promise: nil)
            return
        }
        input.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        processInput()
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

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        client.close(promise: nil)
        context.close(promise: nil)
    }

    private func processInput() {
        while !input.isEmpty {
            switch processingState {
            case .head:
                if currentRequest == nil { currentRequest = responseQueue.removeFirst() }
                guard let request = currentRequest else { return }
                guard let head = RawDockerProxyHandler.parseResponseHead(
                    from: input,
                    requestMethod: request.method
                ) else {
                    if input.count > RawDockerProxyHandler.maximumHeadBytes {
                        client.close(promise: nil)
                    }
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

                let successfulConnect = request.method.uppercased() == "CONNECT"
                    && (200...299).contains(status)
                let successfulRequestedUpgrade = request.upgradeRequested
                    && (200...299).contains(status)
                if status == 101 || successfulConnect || successfulRequestedUpgrade {
                    forward(encodedHead)
                    if !input.isEmpty {
                        forward(input)
                        input.removeAll()
                    }
                    currentRequest = nil
                    tunnelMode = true
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
