import Darwin
import Foundation
import Testing
@testable import MacVMHostKit

@Test
func filesystemAuthorizedKeyReplacementPrunesOldKeysAndPreservesUnrelatedEntries() {
    let existing = """
    ssh-ed25519 AAAAUSER user@example
    restrict,command="internal-sftp" ssh-ed25519 AAAAOLD macvm-filesystem
    # keep this comment
    restrict,command="internal-sftp" ssh-ed25519 AAAACURRENT macvm-filesystem

    """
    let publicKey = "ssh-ed25519 AAAANEW macvm-filesystem"

    let updated = DockerGuestFileUtilities.replacingFilesystemAuthorizedKey(
        in: existing,
        with: publicKey
    )
    let lines = updated.split(separator: "\n").map(String.init)

    #expect(lines.contains("ssh-ed25519 AAAAUSER user@example"))
    #expect(lines.contains("# keep this comment"))
    #expect(lines.filter { $0.contains(DockerGuestFileUtilities.filesystemKeyMarker) } == [
        "restrict,command=\"internal-sftp\" \(publicKey)",
    ])
}

@Test
func dockerProxyErrorJSONEscapesMultilineProcessErrors() throws {
    let message = "Unable to write exports:\nOperation not permitted"
    let data = DockerGuestFileUtilities.dockerErrorJSON(message)
    let decoded = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: String]
    )
    #expect(decoded["message"] == message)
}

@Test
func dockerGuestFileExportsUseAnIsolatedDirectory() {
    let plan = DockerGuestFileUtilities.filesystemExportPlan(
        sourcePath: "/Users/admin/project/secret.txt",
        isDirectory: false,
        stateDirectoryPath: "/Library/Application Support/MacVM/Docker",
        filesystemID: "path-abc123"
    )

    #expect(plan.remoteExportRoot == "/Library/Application Support/MacVM/Docker/FileExports/path-abc123")
    #expect(plan.remoteExportRoot != "/Users/admin/project")
    #expect(plan.linuxRelativePath == "source")
    #expect(plan.followsRemoteSymlinks)
}

@Test
func dockerGuestDirectoryExportsUseTheRequestedDirectory() {
    let plan = DockerGuestFileUtilities.filesystemExportPlan(
        sourcePath: "/Users/admin/project",
        isDirectory: true,
        stateDirectoryPath: "/Library/Application Support/MacVM/Docker",
        filesystemID: "path-abc123"
    )

    #expect(plan.remoteExportRoot == "/Users/admin/project")
    #expect(plan.linuxRelativePath.isEmpty)
    #expect(!plan.followsRemoteSymlinks)
}

@Test
func dockerGuestPathExistenceTracksDeletedPaths() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    #expect(DockerGuestFileUtilities.pathExists(directory.path))

    try FileManager.default.removeItem(at: directory)
    #expect(!DockerGuestFileUtilities.pathExists(directory.path))
}

@Test
func dockerGuestBindSourceClassificationRecognizesUnixSockets() throws {
    // sockaddr_un paths are limited to 103 bytes on macOS, while XCTest's
    // temporary directory can already be longer than that.
    let root = URL(
        fileURLWithPath: "/tmp/macvm-bind-kind-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    let file = root.appendingPathComponent("file")
    try Data().write(to: file)
    let fifo = root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    let socketURL = root.appendingPathComponent("socket")
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    defer { Darwin.close(descriptor) }

    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketURL.path.utf8) + [0]
    #expect(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path))
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in
            destination.baseAddress?.copyMemory(
                from: source.baseAddress!,
                byteCount: source.count
            )
        }
    }
    let bindStatus = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            Darwin.bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bindStatus == 0)

    #expect(try DockerGuestFileUtilities.bindSourceKind(at: root.path) == .directory)
    #expect(try DockerGuestFileUtilities.bindSourceKind(at: file.path) == .regularFile)
    #expect(try DockerGuestFileUtilities.bindSourceKind(at: socketURL.path) == .streamSocket)
    #expect(try DockerGuestFileUtilities.bindSourceKind(at: fifo.path) == .unsupported)
    #expect(DockerGuestFileUtilities.socketRelayPath(filesystemID: "socket-abc") == "/run/macvm-macos/socket-abc/source")
}

@Test
func dockerSocketFilesystemIDIsStableForTheCanonicalPath() {
    let path = "/private/var/run/docker.sock"

    #expect(
        DockerGuestFileUtilities.socketFilesystemID(forCanonicalPath: path)
            == "socket-85f9b371d0af564b46b8924a"
    )
    #expect(
        DockerGuestFileUtilities.socketFilesystemID(forCanonicalPath: path)
            != DockerGuestFileUtilities.socketFilesystemID(forCanonicalPath: "/tmp/docker.sock")
    )
}
