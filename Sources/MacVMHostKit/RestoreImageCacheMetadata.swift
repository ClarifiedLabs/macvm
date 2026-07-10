import Foundation

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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: latestSupportedURL(in: cacheDirectory), options: .atomic)
    }
}
