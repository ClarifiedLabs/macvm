import Darwin
import Foundation
import Virtualization

private final class RestoreImagePublicationLease: @unchecked Sendable {
    private let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

public struct LatestSupportedRestoreImageMetadata: Codable, Equatable, Sendable {
    public var imageName: String
    public var sourceURLString: String
    public var buildVersion: String
    public var majorVersion: Int
    public var minorVersion: Int
    public var patchVersion: Int
    public var checkedAt: Date

    public init(
        imageName: String,
        sourceURLString: String,
        buildVersion: String,
        majorVersion: Int,
        minorVersion: Int,
        patchVersion: Int,
        checkedAt: Date = Date()
    ) {
        self.imageName = imageName
        self.sourceURLString = sourceURLString
        self.buildVersion = buildVersion
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.patchVersion = patchVersion
        self.checkedAt = checkedAt
    }
}

public protocol RestoreImageDownloading: Sendable {
    func download(from url: URL) async throws -> URL
}

public protocol RestoreImageValidating: Sendable {
    func validateRestoreImage(at url: URL) async throws
}

public struct VirtualizationRestoreImageValidator: RestoreImageValidating {
    public init() {}

    public func validateRestoreImage(at url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public struct URLSessionRestoreImageDownloader: RestoreImageDownloading {
    public init() {}

    public func download(from url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw RestoreImageCacheError.downloadFailed(url, statusCode: response.statusCode)
        }
        return temporaryURL
    }
}

public struct RestoreImageCacheResult: Equatable, Sendable {
    public let url: URL
    public let wasDownloaded: Bool

    public init(url: URL, wasDownloaded: Bool) {
        self.url = url
        self.wasDownloaded = wasDownloaded
    }
}

public enum RestoreImageCacheError: LocalizedError {
    case invalidImageName(String)
    case invalidDownloadedImage(URL, reason: String)
    case downloadFailed(URL, statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidImageName(let name):
            return "Invalid restore image name: \(name)"
        case .invalidDownloadedImage(let url, let reason):
            return "The download from \(url.absoluteString) is not a valid restore image: \(reason)"
        case .downloadFailed(let url, let statusCode):
            return "Download from \(url.absoluteString) failed with HTTP \(statusCode)."
        }
    }
}

public enum RestoreImageCache {
    public static func cachedImageURL(
        named imageName: String,
        in cacheDirectory: URL,
        validator: any RestoreImageValidating = VirtualizationRestoreImageValidator()
    ) async throws -> URL? {
        let url = cacheDirectory.appendingPathComponent(imageName, isDirectory: false)
        guard isUsableFile(at: url) else { return nil }
        do {
            try await validator.validateRestoreImage(at: url)
            return url
        } catch let error as CancellationError {
            throw error
        } catch {
            return nil
        }
    }

    public static func downloadImage(
        from sourceURL: URL,
        named imageName: String,
        in cacheDirectory: URL,
        downloader: any RestoreImageDownloading = URLSessionRestoreImageDownloader(),
        validator: any RestoreImageValidating = VirtualizationRestoreImageValidator()
    ) async throws -> RestoreImageCacheResult {
        let imageNameURL = URL(fileURLWithPath: imageName)
        guard imageNameURL.lastPathComponent == imageName,
              imageNameURL.pathExtension.lowercased() == "ipsw" else {
            throw RestoreImageCacheError.invalidImageName(imageName)
        }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let publicationLease = try await acquirePublicationLease(for: imageName, in: cacheDirectory)
        defer { withExtendedLifetime(publicationLease) {} }

        let destinationURL = cacheDirectory.appendingPathComponent(imageName, isDirectory: false)
        if let cachedURL = try await cachedImageURL(
            named: imageName,
            in: cacheDirectory,
            validator: validator
        ) {
            return RestoreImageCacheResult(url: cachedURL, wasDownloaded: false)
        }

        let downloadedURL = try await downloader.download(from: sourceURL)
        defer { try? FileManager.default.removeItem(at: downloadedURL) }
        try Task.checkCancellation()

        let stagingURL = cacheDirectory.appendingPathComponent(".\(imageName).\(UUID().uuidString).download.ipsw")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        try FileManager.default.moveItem(at: downloadedURL, to: stagingURL)
        try Task.checkCancellation()
        guard isUsableFile(at: stagingURL) else {
            throw RestoreImageCacheError.invalidDownloadedImage(
                sourceURL,
                reason: "the downloaded content is empty or is not a regular file"
            )
        }
        do {
            try await validator.validateRestoreImage(at: stagingURL)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw RestoreImageCacheError.invalidDownloadedImage(
                sourceURL,
                reason: error.localizedDescription
            )
        }
        try Task.checkCancellation()

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        do {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
            return RestoreImageCacheResult(url: destinationURL, wasDownloaded: true)
        } catch {
            guard let cachedURL = try await cachedImageURL(
                named: imageName,
                in: cacheDirectory,
                validator: validator
            ) else {
                throw error
            }
            return RestoreImageCacheResult(url: cachedURL, wasDownloaded: false)
        }
    }

    private static func acquirePublicationLease(
        for imageName: String,
        in cacheDirectory: URL
    ) async throws -> RestoreImagePublicationLease {
        let lockURL = cacheDirectory.appendingPathComponent(".\(imageName).lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                guard code == EWOULDBLOCK || code == EAGAIN else {
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return RestoreImagePublicationLease(descriptor: descriptor)
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func isUsableFile(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else {
            return false
        }
        return values.isRegularFile == true
            && values.isSymbolicLink != true
            && (values.fileSize ?? 0) > 0
    }
}

public enum RestoreImageCacheMetadata {
    public static let latestSupportedFilename = ".latest-supported.json"

    public static func latestSupportedURL(in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent(latestSupportedFilename, isDirectory: false)
    }

    public static func readLatestSupported(in cacheDirectory: URL) -> LatestSupportedRestoreImageMetadata? {
        let url = latestSupportedURL(in: cacheDirectory)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LatestSupportedRestoreImageMetadata.self, from: data)
    }

    public static func writeLatestSupported(
        _ metadata: LatestSupportedRestoreImageMetadata,
        in cacheDirectory: URL
    ) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let lockURL = cacheDirectory.appendingPathComponent(".latest-supported.lock", isDirectory: false)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if let existing = readLatestSupported(in: cacheDirectory),
           existing.checkedAt > metadata.checkedAt {
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: latestSupportedURL(in: cacheDirectory), options: .atomic)
    }
}
