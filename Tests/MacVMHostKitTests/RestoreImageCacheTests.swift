import Foundation
import Testing

@testable import MacVMHostKit

private struct StubRestoreImageDownloader: RestoreImageDownloading {
    let temporaryURL: URL

    func download(from url: URL) async throws -> URL {
        try await Task.sleep(nanoseconds: 100_000_000)
        return temporaryURL
    }
}

private struct StubRestoreImageValidator: RestoreImageValidating {
    func validateRestoreImage(at url: URL) async throws {}
}

private struct RestoreImageValidationError: Error {}

private struct PayloadRestoreImageValidator: RestoreImageValidating {
    let expectedPayload: Data

    func validateRestoreImage(at url: URL) async throws {
        guard try Data(contentsOf: url) == expectedPayload else {
            throw RestoreImageValidationError()
        }
    }
}

@Test
func concurrentRestoreImageDownloadsPublishOneCompleteCacheFile() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
    let cache = root.appendingPathComponent("Cache", isDirectory: true)
    let imageName = "UniversalMac_27.0_26A123_Restore.ipsw"
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let firstTemporaryURL = downloads.appendingPathComponent("first.ipsw")
    let secondTemporaryURL = downloads.appendingPathComponent("second.ipsw")
    let firstPayload = Data("first complete download".utf8)
    let secondPayload = Data("second complete download".utf8)
    try firstPayload.write(to: firstTemporaryURL)
    try secondPayload.write(to: secondTemporaryURL)

    async let firstResult = RestoreImageCache.downloadImage(
        from: URL(string: "https://example.invalid/first.ipsw")!,
        named: imageName,
        in: cache,
        downloader: StubRestoreImageDownloader(temporaryURL: firstTemporaryURL),
        validator: StubRestoreImageValidator()
    )
    async let secondResult = RestoreImageCache.downloadImage(
        from: URL(string: "https://example.invalid/second.ipsw")!,
        named: imageName,
        in: cache,
        downloader: StubRestoreImageDownloader(temporaryURL: secondTemporaryURL),
        validator: StubRestoreImageValidator()
    )

    let results = try await [firstResult, secondResult]
    let cachedURL = cache.appendingPathComponent(imageName)
    let cachedPayload = try Data(contentsOf: cachedURL)

    #expect(results.allSatisfy { $0.url == cachedURL })
    #expect(results.filter(\.wasDownloaded).count == 1)
    #expect(cachedPayload == firstPayload || cachedPayload == secondPayload)
}

@Test
func restoreImageDownloadReplacesInvalidCachedFile() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
    let cache = root.appendingPathComponent("Cache", isDirectory: true)
    let imageName = "UniversalMac_27.0_26A123_Restore.ipsw"
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let cachedURL = cache.appendingPathComponent(imageName)
    let temporaryURL = downloads.appendingPathComponent(imageName)
    let validPayload = Data("valid restore image".utf8)
    try Data("invalid cached content".utf8).write(to: cachedURL)
    try validPayload.write(to: temporaryURL)
    let validator = PayloadRestoreImageValidator(expectedPayload: validPayload)

    let result = try await RestoreImageCache.downloadImage(
        from: URL(string: "https://example.invalid/\(imageName)")!,
        named: imageName,
        in: cache,
        downloader: StubRestoreImageDownloader(temporaryURL: temporaryURL),
        validator: validator
    )

    #expect(result.wasDownloaded)
    #expect(result.url == cachedURL)
    #expect(try Data(contentsOf: cachedURL) == validPayload)
    #expect(try await RestoreImageCache.cachedImageURL(
        named: imageName,
        in: cache,
        validator: validator
    ) == cachedURL)
}

@Test
func latestRestoreImageMetadataDoesNotRegressToAnOlderObservation() throws {
    let cache = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cache) }

    let newer = LatestSupportedRestoreImageMetadata(
        imageName: "UniversalMac_27.1_26B200_Restore.ipsw",
        sourceURLString: "https://example.invalid/newer.ipsw",
        buildVersion: "26B200",
        majorVersion: 27,
        minorVersion: 1,
        patchVersion: 0,
        checkedAt: Date(timeIntervalSince1970: 200)
    )
    let older = LatestSupportedRestoreImageMetadata(
        imageName: "UniversalMac_27.0_26A123_Restore.ipsw",
        sourceURLString: "https://example.invalid/older.ipsw",
        buildVersion: "26A123",
        majorVersion: 27,
        minorVersion: 0,
        patchVersion: 0,
        checkedAt: Date(timeIntervalSince1970: 100)
    )

    try RestoreImageCacheMetadata.writeLatestSupported(newer, in: cache)
    try RestoreImageCacheMetadata.writeLatestSupported(older, in: cache)

    #expect(RestoreImageCacheMetadata.readLatestSupported(in: cache) == newer)
}
