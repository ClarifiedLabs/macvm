import Foundation
import MacVMHostKit

struct XcodeArchiveEntry: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let sizeBytes: UInt64
    let modifiedAt: Date

    var id: String { url.path }
}

enum XcodeArchiveCatalogError: LocalizedError {
    case invalidExtension(URL)
    case missingArchive(URL)
    case importedArchiveMissing(String)
    case outsideCache(URL)

    var errorDescription: String? {
        switch self {
        case .invalidExtension(let url):
            return "Xcode archive must be a .xip file: \(url.path)"
        case .missingArchive(let url):
            return "Xcode archive not found: \(url.path)"
        case .importedArchiveMissing(let name):
            return "Imported Xcode archive was not found in the library: \(name)"
        case .outsideCache(let url):
            return "Refusing to delete an Xcode archive outside the library: \(url.path)"
        }
    }
}

enum XcodeArchiveCatalog {
    static func cacheDirectory(root: URL) -> URL {
        root.appendingPathComponent(".xcode", isDirectory: true)
    }

    static func list(root: URL) -> [XcodeArchiveEntry] {
        let directory = cacheDirectory(root: root)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension.lowercased() == "xip" }
            .compactMap { url -> XcodeArchiveEntry? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                    return nil
                }
                return XcodeArchiveEntry(
                    url: url,
                    name: url.lastPathComponent,
                    sizeBytes: UInt64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func importArchive(from sourceURL: URL, root: URL) throws -> XcodeArchiveEntry {
        let expandedPath = NSString(string: sourceURL.path).expandingTildeInPath
        let normalizedURL = URL(fileURLWithPath: expandedPath)
        guard normalizedURL.pathExtension.lowercased() == "xip" else {
            throw XcodeArchiveCatalogError.invalidExtension(normalizedURL)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw XcodeArchiveCatalogError.missingArchive(normalizedURL)
        }

        let destinationURL = cacheDirectory(root: root).appendingPathComponent(normalizedURL.lastPathComponent, isDirectory: false)
        try MacVMFileStager.copyCloneFirst(from: normalizedURL, to: destinationURL)
        return try requireEntry(named: destinationURL.lastPathComponent, root: root)
    }

    static func totalSizeBytes(_ entries: [XcodeArchiveEntry]) -> UInt64 {
        entries.reduce(0) { $0 + $1.sizeBytes }
    }

    static func delete(_ entry: XcodeArchiveEntry, root: URL) throws {
        let cacheURL = cacheDirectory(root: root).standardizedFileURL
        let parentURL = entry.url.deletingLastPathComponent().standardizedFileURL
        guard parentURL == cacheURL else {
            throw XcodeArchiveCatalogError.outsideCache(entry.url)
        }
        try FileManager.default.removeItem(at: entry.url)
    }

    private static func requireEntry(named name: String, root: URL) throws -> XcodeArchiveEntry {
        if let entry = list(root: root).first(where: { $0.name == name }) {
            return entry
        }
        throw XcodeArchiveCatalogError.importedArchiveMissing(name)
    }
}
