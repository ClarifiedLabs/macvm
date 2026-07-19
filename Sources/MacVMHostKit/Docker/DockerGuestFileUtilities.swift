import Darwin
import Foundation

enum DockerGuestFileUtilities {
    static let filesystemKeyMarker = "macvm-filesystem"

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

    static func pathExists(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0
    }
}
