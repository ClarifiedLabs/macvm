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
