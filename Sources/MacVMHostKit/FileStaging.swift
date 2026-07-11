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
    public static func copyDirectoryCloneFirst(
        from sourceURL: URL,
        to destinationURL: URL,
        excludingRelativePaths: Set<String> = []
    ) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL

        guard source.path != destination.path else {
            return
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw MacVMError.bundleAlreadyExists(destination)
        }

        do {
            try copyDirectory(
                from: source,
                to: destination,
                relativePath: "",
                excludingRelativePaths: excludingRelativePaths
            )
        } catch {
            throw MacVMError.message(
                "Couldn't clone directory from \(source.path) to \(destination.path): \(error.localizedDescription)"
            )
        }
    }

    private static func copyDirectory(
        from source: URL,
        to destination: URL,
        relativePath: String,
        excludingRelativePaths: Set<String>
    ) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        let contents = try FileManager.default.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil
        )
        for sourceItem in contents {
            let itemRelativePath = relativePath.isEmpty
                ? sourceItem.lastPathComponent
                : "\(relativePath)/\(sourceItem.lastPathComponent)"
            guard !excludingRelativePaths.contains(itemRelativePath) else {
                continue
            }

            let destinationItem = destination.appendingPathComponent(sourceItem.lastPathComponent)
            var itemStat = stat()
            guard lstat(sourceItem.path, &itemStat) == 0 else {
                throw posixError("Couldn't inspect", path: sourceItem.path)
            }

            if itemStat.st_mode & S_IFMT == S_IFDIR {
                try copyDirectory(
                    from: sourceItem,
                    to: destinationItem,
                    relativePath: itemRelativePath,
                    excludingRelativePaths: excludingRelativePaths
                )
            } else {
                try copyFileSystemItem(from: sourceItem, to: destinationItem, flags: COPYFILE_ALL | COPYFILE_CLONE)
            }
        }

        try copyFileSystemItem(from: source, to: destination, flags: COPYFILE_METADATA)
    }

    private static func copyFileSystemItem(
        from source: URL,
        to destination: URL,
        flags: Int32
    ) throws {
        let copyFlags = copyfile_flags_t(flags | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(source.path, destination.path, nil, copyFlags) == 0 else {
            throw posixError("Couldn't copy", path: source.path)
        }
    }

    private static func posixError(_ operation: String, path: String) -> MacVMError {
        MacVMError.message("\(operation) \(path): \(String(cString: strerror(errno)))")
    }
}
