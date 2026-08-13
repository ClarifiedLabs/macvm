import Foundation

public struct DockerHTTPHeaderField: Equatable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public enum DockerHTTPHeadState: Equatable, Sendable {
    case incomplete
    case complete(Int)
    case rejected(String)
}

public enum DockerHTTPBodyFraming: Equatable, Sendable {
    case none
    case fixed(Int)
    case chunked
    case untilClose
}

public enum DockerHTTPChunkSizeState: Equatable, Sendable {
    case incomplete
    case complete(size: Int, encodedLength: Int)
    case rejected(String)
}

public enum DockerHTTPFramingDecision: Equatable, Sendable {
    case accepted(DockerHTTPBodyFraming)
    case rejected(String)
}

public enum DockerUpgradeRequestDecision: Equatable, Sendable {
    case none
    case requested(String)
    case rejected(String)
}

public enum DockerTunnelDecision: Equatable, Sendable {
    case http
    case tunnel
    case reject
}

/// Foundation-only HTTP policy shared by the Docker guest relay and host tests.
/// It deliberately handles framing and upgrade admission, not byte transport.
public struct DockerRawProxyPolicy {
    public static let maximumHeadBytes = 64 * 1024
    public static let maximumChunkLineBytes = 8 * 1024
    public static let maximumTrailerBytes = 64 * 1024
    public static let maximumPendingBackendBytes = 256 * 1024
    public static let maximumInFlightRequests = 128
    public static let writeBufferLowWaterMark = 64 * 1024
    public static let writeBufferHighWaterMark = 256 * 1024

    public static func inspectHead(_ data: Data) -> DockerHTTPHeadState {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count < maximumHeadBytes
                ? .incomplete
                : .rejected("HTTP headers exceed 64 KiB.")
        }
        let length = data.distance(from: data.startIndex, to: range.upperBound)
        return length <= maximumHeadBytes
            ? .complete(length)
            : .rejected("HTTP headers exceed 64 KiB.")
    }

    public static func inspectChunkSizeLine(_ data: Data) -> DockerHTTPChunkSizeState {
        guard let range = data.range(of: Data("\r\n".utf8)) else {
            return data.count <= maximumChunkLineBytes
                ? .incomplete
                : .rejected("Chunk-size line is too large.")
        }
        let lineLength = data.distance(from: data.startIndex, to: range.lowerBound)
        guard lineLength <= maximumChunkLineBytes else {
            return .rejected("Chunk-size line is too large.")
        }
        let lineData = Data(data[data.startIndex..<range.lowerBound])
        guard let line = String(data: lineData, encoding: .ascii) else {
            return .rejected("Invalid chunk-size line.")
        }
        guard let rawSize = line.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces),
            !rawSize.isEmpty,
            let size = Int(rawSize, radix: 16) else {
            return .rejected("Invalid chunk size.")
        }
        let encodedLength = data.distance(from: data.startIndex, to: range.upperBound)
        return .complete(size: size, encodedLength: encodedLength)
    }

    public static func framing(
        isRequest: Bool,
        requestMethod: String? = nil,
        responseStatus: Int? = nil,
        headers: [DockerHTTPHeaderField]
    ) -> DockerHTTPFramingDecision {
        guard headers.allSatisfy({ isToken($0.name) }) else {
            return .rejected("Malformed HTTP header name.")
        }

        let rawTransferCodings = values(named: "transfer-encoding", in: headers)
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let transferCodings = rawTransferCodings.map {
            $0.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0].lowercased()
        }
        let rawContentLengths = values(named: "content-length", in: headers)
            .flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if !transferCodings.isEmpty, !rawContentLengths.isEmpty {
            return .rejected("Transfer-Encoding and Content-Length cannot be combined.")
        }
        if !transferCodings.isEmpty {
            guard transferCodings.allSatisfy({ isToken($0) }),
                  transferCodings.filter({ $0 == "chunked" }).count <= 1,
                  !zip(rawTransferCodings, transferCodings).contains(where: {
                      $1 == "chunked" && $0.contains(";")
                  }) else {
                return .rejected("Invalid Transfer-Encoding header.")
            }
            if isRequest, transferCodings != ["chunked"] {
                return .rejected("Unsupported request Transfer-Encoding framing.")
            }
            if transferCodings.contains("chunked"), transferCodings.last != "chunked" {
                return .rejected("Chunked transfer coding must be final.")
            }
        }

        var contentLengths: [Int] = []
        for rawLength in rawContentLengths {
            guard !rawLength.isEmpty,
                  rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
                  let length = Int(rawLength) else {
                return .rejected("Invalid or conflicting Content-Length headers.")
            }
            contentLengths.append(length)
        }
        if Set(contentLengths).count > 1 {
            return .rejected("Invalid or conflicting Content-Length headers.")
        }

        if !isRequest && (
            requestMethod?.uppercased() == "HEAD"
                || responseStatus == 204
                || responseStatus == 304
                || responseStatus.map({ (100...199).contains($0) }) == true
        ) {
            return .accepted(.none)
        }
        if !transferCodings.isEmpty {
            return .accepted(transferCodings.last == "chunked" ? .chunked : .untilClose)
        }
        if let length = contentLengths.first {
            return .accepted(length == 0 ? .none : .fixed(length))
        }
        return .accepted(isRequest ? .none : .untilClose)
    }

    public static func requestUpgrade(
        method: String,
        uri: String,
        headers: [DockerHTTPHeaderField]
    ) -> DockerUpgradeRequestDecision {
        let connectionRequestsUpgrade = containsToken("upgrade", named: "connection", in: headers)
        let upgradeValues = values(named: "upgrade", in: headers)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard connectionRequestsUpgrade || !upgradeValues.isEmpty else { return .none }
        guard allowsHijack(method: method, uri: uri) else {
            return .rejected("Docker API endpoint is not permitted to hijack the connection.")
        }
        guard connectionRequestsUpgrade,
              upgradeValues.count == 1,
              !upgradeValues[0].contains(","),
              isProtocolToken(upgradeValues[0]) else {
            return .rejected("Docker hijack requests require matching Connection: Upgrade and one valid Upgrade protocol.")
        }
        return .requested(upgradeValues[0].lowercased())
    }

    public static func tunnelDecision(
        requestMethod: String,
        requestURI: String,
        requestedUpgrade: String?,
        responseStatus: Int,
        responseHeaders: [DockerHTTPHeaderField]
    ) -> DockerTunnelDecision {
        guard let requestedUpgrade,
              allowsHijack(method: requestMethod, uri: requestURI) else {
            return responseStatus == 101 ? .reject : .http
        }

        if responseStatus == 101 {
            let responseUpgrades = values(named: "upgrade", in: responseHeaders)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard containsToken("upgrade", named: "connection", in: responseHeaders),
                  responseUpgrades.count == 1,
                  responseUpgrades[0] == requestedUpgrade else {
                return .reject
            }
            return .tunnel
        }

        // Docker documents 200 as a compatibility response for older hijack
        // clients. Admit it only with the raw-stream media type and no finite
        // HTTP body framing, otherwise continue processing it as ordinary HTTP.
        if responseStatus == 200,
           values(named: "content-type", in: responseHeaders).contains(where: {
               $0.split(separator: ";", maxSplits: 1)[0]
                   .trimmingCharacters(in: .whitespaces)
                   .caseInsensitiveCompare("application/vnd.docker.raw-stream") == .orderedSame
           }),
           values(named: "content-length", in: responseHeaders).isEmpty,
           values(named: "transfer-encoding", in: responseHeaders).isEmpty {
            return .tunnel
        }
        return .http
    }

    public static func allowsHijack(method: String, uri: String) -> Bool {
        let components = normalizedAPIPath(uri).split(separator: "/").map(String.init)
        switch method.uppercased() {
        case "POST":
            return (components.count == 3 && components[0] == "containers" && components[2] == "attach")
                || (components.count == 3 && components[0] == "exec" && components[2] == "start")
                || components == ["session"]
        case "GET":
            return components.count == 4
                && components[0] == "containers"
                && components[2] == "attach"
                && components[3] == "ws"
        default:
            return false
        }
    }

    private static func normalizedAPIPath(_ uri: String) -> String {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        let pieces = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = pieces.first,
              first.first == "v",
              first.dropFirst().split(separator: ".").allSatisfy({ Int($0) != nil }) else {
            return "/" + pieces.joined(separator: "/")
        }
        return "/" + pieces.dropFirst().joined(separator: "/")
    }

    private static func containsToken(
        _ token: String,
        named name: String,
        in headers: [DockerHTTPHeaderField]
    ) -> Bool {
        values(named: name, in: headers)
            .flatMap { $0.split(separator: ",") }
            .contains {
                $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(token) == .orderedSame
            }
    }

    private static func values(
        named name: String,
        in headers: [DockerHTTPHeaderField]
    ) -> [String] {
        headers.compactMap {
            $0.name.caseInsensitiveCompare(name) == .orderedSame ? $0.value : nil
        }
    }

    private static func isProtocolToken(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(pieces.count) && pieces.allSatisfy { isToken(String($0)) }
    }

    private static func isToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
        return value.utf8.allSatisfy {
            (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || punctuation.contains($0)
        }
    }
}
