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

    /// Recursively copy a directory hierarchy, cloning regular files on
    /// filesystems that support copy-on-write and falling back to ordinary
    /// copies everywhere else. The destination must not already exist.
    public static func copyDirectoryCloneFirst(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL

        guard source.path != destination.path else {
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MacVMError.bundleAlreadyExists(destination)
        }

        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            let message = String(cString: strerror(errno))
            throw MacVMError.message("Couldn't clone directory from \(source.path) to \(destination.path): \(message)")
        }
    }
}
