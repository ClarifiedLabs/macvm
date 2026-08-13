import Darwin
import Foundation
import Testing
@testable import MacVMDockerGuestCore

@Test
func dockerExportCapabilityProducesOneStrictForcedCommand() throws {
    let capability = try DockerExportCapability(
        filesystemID: "path-abc123",
        sourcePath: "/Users/admin/project",
        kind: .directory
    )
    let line = try capability.authorizedKeyLine(
        publicKey: "ssh-ed25519 AAAA macvm-export",
        executablePath: "/usr/local/libexec/macvm-docker-guest",
        configurationPath: "/Library/Application Support/MacVM/docker-guest.json"
    )

    #expect(line.contains("restrict,command="))
    #expect(line.contains("--serve-export path-abc123"))
    #expect(line.contains("macvm-export:path-abc123"))
    #expect(!line.contains("internal-sftp"))
}

@Test
func dockerExportAuthorizedKeysRemoveLegacyGlobalAndStaleCapabilities() throws {
    let existing = """
    ssh-ed25519 AAAAUSER user
    restrict,command="internal-sftp" ssh-ed25519 AAAAOLD macvm-filesystem
    restrict,command="old" ssh-ed25519 AAAAOLD macvm-export:path-stale
    restrict,command="keep" ssh-ed25519 AAAAKEEP macvm-export:path-current
    """
    let cleaned = DockerExportCapability.removingLegacyAndUnknownExportKeys(
        from: existing,
        retaining: ["path-current"]
    )

    #expect(cleaned.contains("AAAAUSER"))
    #expect(cleaned.contains("path-current"))
    #expect(!cleaned.contains("macvm-filesystem"))
    #expect(!cleaned.contains("path-stale"))
}

@Test
func dockerExportAuthorizedKeyReplacementUsesExactCapabilityIdentity() throws {
    let existing = """
    restrict,command="keep" ssh-ed25519 AAAAKEEP macvm-export:path-abc2
    restrict,command="replace" ssh-ed25519 AAAAOLD macvm-export:path-abc
    """
    let replaced = try DockerExportCapability.replacingAuthorizedKey(
        in: existing,
        filesystemID: "path-abc",
        with: "restrict,command=\"new\" ssh-ed25519 AAAANEW macvm-export:path-abc"
    )

    #expect(replaced.contains("AAAAKEEP"))
    #expect(replaced.contains("AAAANEW"))
    #expect(!replaced.contains("AAAAOLD"))
    #expect(DockerExportCapability.containsAuthorizedKey(in: replaced, filesystemID: "path-abc"))
    #expect(DockerExportCapability.containsAuthorizedKey(in: replaced, filesystemID: "path-abc2"))
}

@Test(arguments: [
    "mount-export path-abc admin /Users/admin",
    "mount-export ../../escape admin",
    "export-key path-abc trailing",
    "prepare-socket path-not-a-socket",
    "publish-port tcp 0",
    "publish-port tcp 65536",
    "publish-port icmp 80",
    "reset-ports trailing",
    "export-key path-abc\nremove-export path-abc",
])
func dockerMountBrokerGrammarRejectsUnboundedOrExtraArguments(_ value: String) {
    #expect(throws: (any Error).self) {
        _ = try DockerMountBrokerCommand(parsing: value)
    }
}

@Test
func dockerMountBrokerGrammarRoundTripsPerExportCommands() throws {
    let commands: [DockerMountBrokerCommand] = [
        .exportKey(filesystemID: "path-abc"),
        .mountExport(filesystemID: "path-abc", remoteUser: "admin"),
        .unmount(filesystemID: "path-abc"),
        .removeExport(filesystemID: "path-abc"),
        .prepareSocket(filesystemID: "socket-abc"),
        .publishPort(protocolName: "tcp", port: 443),
    ]
    for command in commands {
        #expect(try DockerMountBrokerCommand(parsing: command.rendered) == command)
    }
}

@Test
func descriptorRootRejectsTraversalAndSymlinkEscape() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("secret".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("escape"),
        withDestinationURL: outside
    )
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: outside)
    }

    let capability = try DockerExportCapability(
        filesystemID: "path-test",
        sourcePath: root.path,
        kind: .directory
    )
    let descriptorRoot = try DockerDescriptorRoot(capability: capability)
    #expect(throws: (any Error).self) {
        _ = try descriptorRoot.normalizedComponents(for: "../outside")
    }
    #expect(throws: (any Error).self) {
        _ = try descriptorRoot.openFile(path: "escape", flags: O_RDONLY)
    }
}

@Test
func descriptorRootRejectsAReplacementExportRoot() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = parent.appendingPathComponent("export", isDirectory: true)
    let moved = parent.appendingPathComponent("moved", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let capability = try DockerExportCapability(
        filesystemID: "path-test",
        sourcePath: root.path,
        kind: .directory
    )
    let descriptorRoot = try DockerDescriptorRoot(capability: capability)
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

    #expect(throws: (any Error).self) {
        _ = try descriptorRoot.directoryEntries(path: "/", limit: 10)
    }
}

@Test
func descriptorRootRegularFileExposesOnlyStableSourceName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("value")
    try Data("value".utf8).write(to: file)
    let capability = try DockerExportCapability(
        filesystemID: "path-file",
        sourcePath: file.path,
        kind: .regularFile
    )
    let descriptorRoot = try DockerDescriptorRoot(capability: capability)

    let rootEntries = try descriptorRoot.directoryEntries(path: "/", limit: 10)
    #expect(rootEntries.map(\.0) == ["source"])
    let descriptor = try descriptorRoot.openFile(path: "/source", flags: O_RDONLY)
    defer { close(descriptor) }
    #expect(throws: (any Error).self) {
        _ = try descriptorRoot.openFile(path: "/value", flags: O_RDONLY)
    }
}

@Test
func transientIdentityUsesPrivateSetupUserMaterialAndPrunesStaleFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let identity = try DockerTransientIdentityFile(
        privateKey: Data("private-key".utf8),
        rootDirectory: root,
        ownerUID: getuid(),
        ownerGID: getgid()
    )
    var directoryMetadata = stat()
    var keyMetadata = stat()
    #expect(lstat(identity.url.deletingLastPathComponent().path, &directoryMetadata) == 0)
    #expect(lstat(identity.url.path, &keyMetadata) == 0)
    #expect(directoryMetadata.st_mode & 0o777 == 0o700)
    #expect(keyMetadata.st_mode & 0o777 == 0o600)
    #expect(keyMetadata.st_uid == getuid())
    #expect(try Data(contentsOf: identity.url) == Data("private-key".utf8))

    try identity.remove()
    #expect(!FileManager.default.fileExists(atPath: identity.url.path))
    let stale = root.appendingPathComponent("stale", isDirectory: true)
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
    try Data("old-key".utf8).write(to: stale.appendingPathComponent("identity"))
    try DockerTransientIdentityFile.pruneRootDirectory(root)
    #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
}

@Test
func sftpServerRejectsInvalidResourceLimits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let capability = try DockerExportCapability(
        filesystemID: "path-test",
        sourcePath: root.path,
        kind: .directory
    )

    #expect(throws: (any Error).self) {
        _ = try DockerSFTPServer(
            capability: capability,
            limits: DockerSFTPServerLimits(maximumPacketBytes: 32)
        )
    }
}

@Test
func guestTerminationCoordinatorCleansUpOnceAcrossRegistrationRaces() {
    let coordinator = DockerGuestTerminationCoordinator()
    let cleanups = CleanupRecorder()

    coordinator.registerCleanup {
        cleanups.append("early")
    }
    coordinator.requestTermination()
    coordinator.requestTermination()
    coordinator.registerCleanup {
        cleanups.append("late")
    }

    #expect(coordinator.isTerminationRequested)
    #expect(cleanups.values == ["early", "late"])
}

private final class CleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }
}

@Test
func publishedPortReconciliationFailureStillForwardsDockerResponse() {
    struct ReconciliationError: Error {}
    var reportedFailure = false
    var forwardedResponse = false

    DockerPublishedPortPolicy.forwardResponseAfterReconciliation(
        .failure(ReconciliationError()),
        onFailure: { _ in reportedFailure = true },
        forwardResponse: { forwardedResponse = true }
    )

    #expect(reportedFailure)
    #expect(forwardedResponse)
}
