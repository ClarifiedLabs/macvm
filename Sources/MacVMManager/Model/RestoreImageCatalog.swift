import Foundation
import MacVMHostKit

/// One cached IPSW in the restore-image cache.
struct RestoreImageEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let sizeBytes: UInt64
    let modifiedAt: Date
    /// True when this cached file matches Apple's current latest supported restore image.
    let isLatest: Bool

    var id: String { url.path }
}

enum RestoreImageCatalogError: LocalizedError {
    case invalidExtension(URL)
    case missingImage(URL)
    case importedImageMissing(String)
    case outsideCache(URL)

    var errorDescription: String? {
        switch self {
        case .invalidExtension(let url):
            return "Restore image must be an .ipsw file: \(url.path)"
        case .missingImage(let url):
            return "Restore image not found: \(url.path)"
        case .importedImageMissing(let name):
            return "Imported restore image was not found in the cache: \(name)"
        case .outsideCache(let url):
            return "Refusing to delete a restore image outside the cache: \(url.path)"
        }
    }
}

/// Lists the `.restore-images` cache that `macvm create --latest` populates.
enum RestoreImageCatalog {
    static func cacheDirectory(root: URL) -> URL {
        root.appendingPathComponent(".restore-images", isDirectory: true)
    }

    static func list(root: URL) -> [RestoreImageEntry] {
        let directory = cacheDirectory(root: root)
        return list(
            root: root,
            latestSupportedImageName: RestoreImageCacheMetadata.readLatestSupported(in: directory)?.imageName
        )
    }

    /// Cached IPSWs sorted newest first.
    static func list(root: URL, latestSupportedImageName: String?) -> [RestoreImageEntry] {
        let directory = cacheDirectory(root: root)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let files = contents
            .filter { $0.pathExtension.lowercased() == "ipsw" }
            .compactMap { url -> (URL, UInt64, Date)? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                    return nil
                }
                return (url, UInt64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.2 > $1.2 }

        return files.map { file in
            RestoreImageEntry(
                url: file.0,
                name: file.0.lastPathComponent,
                sizeBytes: file.1,
                modifiedAt: file.2,
                isLatest: file.0.lastPathComponent == latestSupportedImageName
            )
        }
    }

    static func totalSizeBytes(_ entries: [RestoreImageEntry]) -> UInt64 {
        entries.reduce(0) { $0 + $1.sizeBytes }
    }

    static func importImage(from sourceURL: URL, root: URL) throws -> RestoreImageEntry {
        let expandedPath = NSString(string: sourceURL.path).expandingTildeInPath
        let normalizedURL = URL(fileURLWithPath: expandedPath)
        guard normalizedURL.pathExtension.lowercased() == "ipsw" else {
            throw RestoreImageCatalogError.invalidExtension(normalizedURL)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw RestoreImageCatalogError.missingImage(normalizedURL)
        }

        let destinationURL = cacheDirectory(root: root).appendingPathComponent(normalizedURL.lastPathComponent, isDirectory: false)
        try MacVMFileStager.copyCloneFirst(from: normalizedURL, to: destinationURL)
        return try requireEntry(named: destinationURL.lastPathComponent, root: root)
    }

    static func delete(_ entry: RestoreImageEntry, root: URL) throws {
        let cacheURL = cacheDirectory(root: root).standardizedFileURL
        let parentURL = entry.url.deletingLastPathComponent().standardizedFileURL
        guard parentURL == cacheURL else {
            throw RestoreImageCatalogError.outsideCache(entry.url)
        }
        try FileManager.default.removeItem(at: entry.url)
    }

    private static func requireEntry(named name: String, root: URL) throws -> RestoreImageEntry {
        if let entry = list(root: root).first(where: { $0.name == name }) {
            return entry
        }
        throw RestoreImageCatalogError.importedImageMissing(name)
    }

    /// "14.8 GB"-style decimal size, matching Finder and the design copy.
    static func formattedSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
