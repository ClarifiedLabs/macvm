import Foundation

public enum MacVMAppControlOperation: Codable, Equatable, Sendable {
    case run(headless: Bool, recovery: Bool, vncPort: UInt)
    case attach
    case stop
}

public struct MacVMAppControlRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 1
    public static let validityInterval: TimeInterval = 90

    public var protocolVersion: Int
    public var id: UUID
    public var createdAt: Date
    public var operation: MacVMAppControlOperation
    public var bundlePath: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        operation: MacVMAppControlOperation,
        bundleURL: URL
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.id = id
        self.createdAt = createdAt
        self.operation = operation
        self.bundlePath = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public struct MacVMAppControlResponse: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var requestID: UUID
    public var succeeded: Bool
    public var message: String
    public var vmName: String?
    public var vncURL: String?
    public var ownerPID: Int32?

    public init(
        requestID: UUID,
        succeeded: Bool,
        message: String,
        vmName: String? = nil,
        vncURL: String? = nil,
        ownerPID: Int32? = nil
    ) {
        self.protocolVersion = MacVMAppControlRequest.currentProtocolVersion
        self.requestID = requestID
        self.succeeded = succeeded
        self.message = message
        self.vmName = vmName
        self.vncURL = vncURL
        self.ownerPID = ownerPID
    }
}

/// A per-user, file-backed request queue used to hand CLI commands to MacVM.app.
/// Requests and responses are separate atomic JSON files, making app startup and
/// command acknowledgement reliable without an additional XPC service.
public struct MacVMAppControlQueue: Sendable {
    public static let controlOnlyArgument = "--macvm-control-only"

    public let directoryURL: URL

    public init(directoryURL: URL = Self.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    public static var defaultDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent(MacVMSettings.domain, isDirectory: true)
            .appendingPathComponent("Control", isDirectory: true)
    }

    public func submit(_ request: MacVMAppControlRequest) throws {
        try ensureDirectory()
        try removeResponse(for: request.id)
        let data = try Self.encoder.encode(request)
        try data.write(to: requestURL(for: request.id), options: .atomic)
    }

    public func pendingRequests() throws -> [MacVMAppControlRequest] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == "request" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let request = try? Self.decoder.decode(MacVMAppControlRequest.self, from: data) else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return request
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func complete(_ request: MacVMAppControlRequest, with response: MacVMAppControlResponse) throws {
        try ensureDirectory()
        let data = try Self.encoder.encode(response)
        try data.write(to: responseURL(for: request.id), options: .atomic)
        try? FileManager.default.removeItem(at: requestURL(for: request.id))
    }

    public func response(for requestID: UUID) throws -> MacVMAppControlResponse? {
        let url = responseURL(for: requestID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(MacVMAppControlResponse.self, from: data)
    }

    public func removeRequest(_ requestID: UUID) throws {
        let url = requestURL(for: requestID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func removeResponse(for requestID: UUID) throws {
        let url = responseURL(for: requestID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func requestURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("request")
    }

    private func responseURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("response")
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
