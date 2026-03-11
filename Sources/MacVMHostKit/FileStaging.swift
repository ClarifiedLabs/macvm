import Darwin
import Foundation

public enum MacVMFileStager {
    /// Put a file at `destinationURL`, using an APFS clone when possible so large
    /// artifacts can appear in per-VM staging directories without duplicating blocks.
    public static func copyCloneFirst(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL

        guard source.path != destination.path else {
            return
        }

        let fileManager = FileManager.default
        let destinationDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let temporaryURL = destinationDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp.\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        if clonefile(source.path, temporaryURL.path, 0) != 0 {
            try? fileManager.removeItem(at: temporaryURL)
            try fileManager.copyItem(at: source, to: temporaryURL)
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
    }
}
