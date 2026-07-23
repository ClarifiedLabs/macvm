import Darwin
import Foundation

public final class MacVMAppControlConsumerLease: @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }
}

public enum MacVMAppControlOperation: Codable, Equatable, Sendable {
    case run(headless: Bool, recovery: Bool, vncPort: UInt)
    case attach
    case stop
    case installClipboardHelper
}

public struct MacVMAppControlRequest: Codable, Equatable, Sendable {
    public static let currentProtocolVersion = 2
    /// Maximum time for MacVM.app to claim a newly submitted request.
    public static let validityInterval: TimeInterval = 90
    /// App-enforced upper bound after pickup. Individual subprocesses have tighter limits.
    public static let operationCompletionTimeout: TimeInterval = 15 * 60

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

    /// Acquire the exclusive live-app lease before inspecting claimed requests.
    /// Advisory locking releases automatically when an app crashes, allowing the
    /// next instance to recover `.processing` files without racing a live owner.
    public func acquireConsumerLease() throws -> MacVMAppControlConsumerLease? {
        try ensureDirectory()
        let url = directoryURL.appendingPathComponent("consumer.lock", isDirectory: false)
        let descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1 else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.EPERM)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            _ = Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return MacVMAppControlConsumerLease(descriptor: descriptor)
    }

    public func submit(_ request: MacVMAppControlRequest) throws {
        try ensureDirectory()
        try removeResponse(for: request.id)
        let data = try Self.encoder.encode(request)
        try data.write(to: requestURL(for: request.id), options: .atomic)
    }

    public func pendingRequests() throws -> [MacVMAppControlRequest] {
        try requests(withExtension: "request")
    }

    /// Requests claimed by an app instance that exited before publishing a response.
    public func interruptedRequests() throws -> [MacVMAppControlRequest] {
        try requests(withExtension: "processing")
    }

    /// Atomically claim a request before beginning a potentially long operation.
    /// The processing file is the CLI's pickup acknowledgement.
    @discardableResult
    public func claim(_ request: MacVMAppControlRequest) throws -> Bool {
        try ensureDirectory()
        let source = requestURL(for: request.id)
        let destination = processingURL(for: request.id)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return true
        } catch CocoaError.fileNoSuchFile {
            return false
        } catch CocoaError.fileWriteFileExists {
            // A processing file is itself proof that another app instance won
            // the claim, including the interrupted-request recovery case.
            return false
        }
    }

    public func isClaimed(_ requestID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: processingURL(for: requestID).path)
    }

    public func complete(_ request: MacVMAppControlRequest, with response: MacVMAppControlResponse) throws {
        try ensureDirectory()
        let data = try Self.encoder.encode(response)
        try data.write(to: responseURL(for: request.id), options: .atomic)
        try? FileManager.default.removeItem(at: requestURL(for: request.id))
        try? FileManager.default.removeItem(at: processingURL(for: request.id))
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

    private func processingURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("processing")
    }

    private func requests(withExtension pathExtension: String) throws -> [MacVMAppControlRequest] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension == pathExtension }
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
