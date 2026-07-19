import Darwin
import Foundation

struct DockerGuestFilesystemExportPlan: Equatable {
    var remoteExportRoot: String
    var linuxRelativePath: String
    var followsRemoteSymlinks: Bool
}

enum DockerGuestFileUtilities {
    static let filesystemKeyMarker = "macvm-filesystem"
    static let fileExportName = "source"

    static func dockerErrorJSON(_ message: String) -> Data {
        (try? JSONSerialization.data(
            withJSONObject: ["message": message],
            options: [.sortedKeys]
        )) ?? Data(#"{"message":"Unknown Docker proxy error."}"#.utf8)
    }

    static func replacingFilesystemAuthorizedKey(
        in contents: String,
        with publicKey: String
    ) -> String {
        var lines = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        lines.removeAll { $0.contains(filesystemKeyMarker) }
        lines.append("restrict,command=\"internal-sftp\" \(publicKey)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func filesystemExportPlan(
        sourcePath: String,
        isDirectory: Bool,
        stateDirectoryPath: String,
        filesystemID: String
    ) -> DockerGuestFilesystemExportPlan {
        if isDirectory {
            return DockerGuestFilesystemExportPlan(
                remoteExportRoot: sourcePath,
                linuxRelativePath: "",
                followsRemoteSymlinks: false
            )
        }
        return DockerGuestFilesystemExportPlan(
            remoteExportRoot: URL(fileURLWithPath: stateDirectoryPath, isDirectory: true)
                .appendingPathComponent("FileExports", isDirectory: true)
                .appendingPathComponent(filesystemID, isDirectory: true)
                .path,
            linuxRelativePath: fileExportName,
            followsRemoteSymlinks: true
        )
    }

    static func pathExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }
}
