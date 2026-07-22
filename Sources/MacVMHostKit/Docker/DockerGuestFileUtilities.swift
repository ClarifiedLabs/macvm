import CryptoKit
import Darwin
import Foundation

struct DockerGuestFilesystemExportPlan: Equatable {
    var remoteExportRoot: String
    var linuxRelativePath: String
    var followsRemoteSymlinks: Bool
}

enum DockerGuestBindSourceKind: Equatable {
    case directory
    case regularFile
    case streamSocket
    case unsupported
}

enum DockerGuestFileUtilities {
    static let filesystemKeyMarker = "macvm-filesystem"
    static let fileExportName = "source"
    static let socketRelayDirectory = "/run/macvm-macos"

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

    static func bindSourceKind(at path: String) throws -> DockerGuestBindSourceKind {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw DockerGuestFileUtilityError(
                "Unable to inspect Docker bind source at \(path): \(String(cString: strerror(errno)))"
            )
        }
        switch metadata.st_mode & S_IFMT {
        case S_IFDIR:
            return .directory
        case S_IFREG:
            return .regularFile
        case S_IFSOCK:
            return .streamSocket
        default:
            return .unsupported
        }
    }

    static func socketRelayPath(filesystemID: String) -> String {
        "\(socketRelayDirectory)/\(filesystemID)/\(fileExportName)"
    }

    static func socketFilesystemID(forCanonicalPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "socket-\(digest)"
    }

    static func pathExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }
}

private struct DockerGuestFileUtilityError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
