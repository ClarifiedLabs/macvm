import CryptoKit
import Darwin
import Foundation
import Testing
import Virtualization
@testable import MacVMHostKit

private struct DockerImageUnavailable: Error {}

private func runDockerConfigurationScript(home: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", DockerGuestToolInstaller.configurationScript]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    process.environment = environment
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    _ = standardOutput.fileHandleForReading.readDataToEndOfFile()
    _ = standardError.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus
}

private func dockerConfigObject(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private struct DockerImageTestDownloader: DockerImageDownloading {
    let streamData: Data?
    let compressedImageData: Data?

    func data(from url: URL) async throws -> Data {
        guard let streamData else { throw DockerImageUnavailable() }
        return streamData
    }

    func download(from url: URL) async throws -> URL {
        guard let compressedImageData else { throw DockerImageUnavailable() }
        let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try compressedImageData.write(to: temporaryURL)
        return temporaryURL
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func gzipData(_ data: Data) throws -> Data {
    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-c"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: data)
    try input.fileHandleForWriting.close()
    let compressed = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DockerImageUnavailable()
    }
    return compressed
}

private func stableStreamData(
    release: String,
    compressedImage: Data,
    rawImage: Data
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "stream": "stable",
        "architectures": [
            "aarch64": [
                "artifacts": [
                    "applehv": [
                        "release": release,
                        "formats": [
                            "raw.gz": [
                                "disk": [
                                    "location": "https://example.test/fcos.raw.gz",
                                    "sha256": sha256Hex(compressedImage),
                                    "uncompressed-sha256": sha256Hex(rawImage),
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ],
    ])
}

private let dockerTestImage = FedoraCoreOSImage(
    stream: "stable",
    architecture: "aarch64",
    platform: "applehv",
    format: "raw.gz",
    release: "44.20260621.3.1",
    downloadURL: URL(string: "https://example.invalid/fcos.raw.gz")!,
    compressedSHA256: String(repeating: "a", count: 64),
    uncompressedSHA256: String(repeating: "b", count: 64)
)

private func dockerTestSettings(enabled: Bool = true) -> DockerSidecarSettings {
    DockerSidecarSettings(
        enabled: enabled,
        macOSMACAddress: "02:00:00:00:00:10",
        linuxPrivateMACAddress: "02:00:00:00:00:11",
        linuxNATMACAddress: "02:00:00:00:00:12",
        guestProvisioningState: .ready,
        guestProvisioningVersion: DockerSidecarSettings.currentGuestProvisioningVersion,
        imageVersion: dockerTestImage.release,
        mobyVersion: "28.3.2"
    )
}

@Test
func dockerGuestToolsUseHomebrewFormulae() {
    #expect(DockerGuestToolInstaller.packageInstallScript.contains(
        "/opt/homebrew/bin/brew install docker docker-buildx docker-compose"
    ))
    #expect(DockerGuestToolInstaller.dockerExecutablePath == "/opt/homebrew/bin/docker")
    #expect(!DockerGuestToolInstaller.installScript.contains("download.docker.com"))
}

@Test
func dockerPluginConfigIsCreatedForHomebrew() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: home) }

    #expect(try runDockerConfigurationScript(home: home) == 0)
    let configURL = home.appendingPathComponent(".docker/config.json")
    let config = try dockerConfigObject(at: configURL)
    #expect(config["cliPluginsExtraDirs"] as? [String] == [DockerGuestToolInstaller.pluginDirectory])
    let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber
    )
    #expect(permissions.intValue & 0o777 == 0o600)
}

@Test
func dockerPluginConfigMergePreservesSettingsAndIsIdempotent() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let dockerDirectory = home.appendingPathComponent(".docker", isDirectory: true)
    try FileManager.default.createDirectory(at: dockerDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let configURL = dockerDirectory.appendingPathComponent("config.json")
    try Data(#"{"auths":{"example.test":{}},"cliPluginsExtraDirs":["/custom/plugins"]}"#.utf8)
        .write(to: configURL)

    #expect(try runDockerConfigurationScript(home: home) == 0)
    #expect(try runDockerConfigurationScript(home: home) == 0)
    let config = try dockerConfigObject(at: configURL)
    #expect(config["auths"] != nil)
    #expect(config["cliPluginsExtraDirs"] as? [String] == [
        "/custom/plugins",
        DockerGuestToolInstaller.pluginDirectory,
    ])
}

@Test(arguments: [
    "not json",
    #"{"cliPluginsExtraDirs":"/custom/plugins"}"#,
])
func invalidDockerPluginConfigIsNotOverwritten(contents: String) throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let dockerDirectory = home.appendingPathComponent(".docker", isDirectory: true)
    try FileManager.default.createDirectory(at: dockerDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let configURL = dockerDirectory.appendingPathComponent("config.json")
    try Data(contents.utf8).write(to: configURL)

    #expect(try runDockerConfigurationScript(home: home) != 0)
    #expect(try String(contentsOf: configURL, encoding: .utf8) == contents)
}

@Test
func dockerSettingsRoundTripInParentMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = VMBundle(url: root)
    let metadata = VMMetadata(
        name: "docker-dev",
        cpuCount: 4,
        memorySizeBytes: 8 * oneGiB,
        diskSizeBytes: 80 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        dockerSidecar: dockerTestSettings()
    )
    try bundle.writeMetadata(metadata)
    let decoded = try bundle.readMetadata()
    #expect(decoded.dockerSidecar == metadata.dockerSidecar)
    #expect(decoded.dockerSidecar?.schemaVersion == DockerSidecarSettings.currentSchemaVersion)
    #expect(decoded.dockerSidecar?.dataDiskSizeBytes == 64 * oneGiB)
}

@Test
func dockerGuestUpgradeReusesKeysInstalledByInitialProvisioning() throws {
    #expect(try DockerGuestPairingKeyPlan.make(
        vmName: "dev",
        guestProvisioningVersion: 1,
        hasPendingDockerKey: false,
        hasPendingMountBrokerKey: false
    ) == .reuseInstalledKeys)
}

@Test
func initialDockerGuestProvisioningRequiresBothPendingKeys() {
    #expect(throws: (any Error).self) {
        try DockerGuestPairingKeyPlan.make(
            vmName: "dev",
            guestProvisioningVersion: 0,
            hasPendingDockerKey: true,
            hasPendingMountBrokerKey: false
        )
    }
}

@Test
func successfulDockerResetReusesAuthorizedPairingIdentity() {
    #expect(DockerSidecarPairingKeyMaterialPlan.make(
        requiresPendingKeys: false,
        hasAuthorizedKey: true,
        hasPendingPrivateKey: false,
        hasPendingPublicKey: false
    ) == .reuse)
}

@Test
func failedInitialDockerResetRegeneratesIncompletePairingIdentity() {
    #expect(DockerSidecarPairingKeyMaterialPlan.make(
        requiresPendingKeys: true,
        hasAuthorizedKey: true,
        hasPendingPrivateKey: true,
        hasPendingPublicKey: false
    ) == .regenerate)
}

@Test
func initialDockerPairingInstallsExistingPendingPublicKey() {
    #expect(DockerSidecarPairingKeyMaterialPlan.make(
        requiresPendingKeys: true,
        hasAuthorizedKey: false,
        hasPendingPrivateKey: true,
        hasPendingPublicKey: true
    ) == .installAuthorizedKey)
}

@Test
func dockerSidecarBundleValidatesRequiredFilesAndSparseAccounting() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sidecar = DockerSidecarBundle(url: root.appendingPathComponent("DockerSidecar", isDirectory: true))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }

    try sidecar.createDirectories()
    try Data("fcos".utf8).write(to: sidecar.systemDiskURL)
    try sidecar.createSparseDataDisk(sizeBytes: 2 * oneGiB)
    let identifier = try sidecar.createGenericMachineIdentifier()
    try sidecar.createEFIVariableStore()
    try "ssh-ed25519 AAAA docker".write(to: sidecar.dockerAuthorizedKeyURL, atomically: true, encoding: .utf8)
    try "ssh-ed25519 AAAA mount".write(to: sidecar.mountBrokerAuthorizedKeyURL, atomically: true, encoding: .utf8)
    try "PRIVATE HOST KEY".write(to: sidecar.linuxHostPrivateKeyURL, atomically: true, encoding: .utf8)
    try "ssh-ed25519 AAAA host".write(to: sidecar.linuxHostPublicKeyURL, atomically: true, encoding: .utf8)
    try Data("{}".utf8).write(to: sidecar.initialIgnitionURL)
    try sidecar.writeMetadata(DockerSidecarMetadata(
        image: dockerTestImage,
        genericMachineIdentifierDigest: DockerSidecarBundle.sha256Hex(identifier.dataRepresentation)
    ))

    let metadata = try sidecar.validateIntegrity()
    #expect(metadata.image == dockerTestImage)
    #expect(sidecar.logicalDataDiskSize() == 2 * oneGiB)
    #expect(sidecar.allocatedSizeBytes() < 2 * oneGiB)

    try FileManager.default.removeItem(at: sidecar.initialIgnitionURL)
    #expect(throws: (any Error).self) { try sidecar.validateIntegrity() }
}

@Test
func stableStreamParserSelectsOnlyAarch64AppleHVRawGzip() throws {
    let data = Data("""
    {
      "stream":"stable",
      "architectures":{
        "aarch64":{"artifacts":{"applehv":{"release":"44.test","formats":{"raw.gz":{"disk":{
          "location":"https://example.test/fcos.raw.gz",
          "sha256":"ABCDEF",
          "uncompressed-sha256":"123456"
        }}}}}},
        "x86_64":{"artifacts":{"applehv":{"release":"wrong","formats":{"raw.gz":{"disk":{
          "location":"https://example.test/wrong.raw.gz",
          "sha256":"bad",
          "uncompressed-sha256":"bad"
        }}}}}},
        "ppc64le":{"artifacts":{"metal":{"release":"unrelated","formats":{"pxe":{
          "kernel":{"location":"https://example.test/vmlinuz","sha256":"ignored"}
        }}}}}
      }
    }
    """.utf8)
    let image = try FedoraCoreOSImageProvider.parseStableAppleHVImage(from: data)
    #expect(image.architecture == "aarch64")
    #expect(image.platform == "applehv")
    #expect(image.format == "raw.gz")
    #expect(image.release == "44.test")
    #expect(image.compressedSHA256 == "abcdef")
    #expect(image.uncompressedSHA256 == "123456")
}

@Test
func dockerSidecarReplacementUsesAtomicDirectoryExchange() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data("first payload".utf8).write(to: first.appendingPathComponent("value"))
    try Data("second payload".utf8).write(to: second.appendingPathComponent("value"))
    defer { try? FileManager.default.removeItem(at: root) }

    try DockerSidecarReplacement.exchangeDirectoriesAtomically(first, second)

    #expect(try Data(contentsOf: first.appendingPathComponent("value")) == Data("second payload".utf8))
    #expect(try Data(contentsOf: second.appendingPathComponent("value")) == Data("first payload".utf8))
}

@Test
func dockerSidecarReplacementRecoveryUsesCandidateIdentity() {
    let candidateID = UUID()
    let previousID = UUID()

    #expect(DockerSidecarReplacement.recoveryDecision(
        canonicalCandidateID: candidateID,
        stageCandidateID: previousID,
        expectedCandidateID: candidateID
    ) == .rollForward)
    #expect(DockerSidecarReplacement.recoveryDecision(
        canonicalCandidateID: previousID,
        stageCandidateID: candidateID,
        expectedCandidateID: candidateID
    ) == .rollBack)
    #expect(DockerSidecarReplacement.recoveryDecision(
        canonicalCandidateID: previousID,
        stageCandidateID: nil,
        expectedCandidateID: candidateID
    ) == .ambiguous)
}

@Test
func dockerSidecarReplacementRecoveryRollsBackBeforeExchange() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = root.appendingPathComponent("owner.macvm", isDirectory: true)
    let bundle = VMBundle(url: bundleURL)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var previousSettings = dockerTestSettings()
    previousSettings.imageVersion = "previous"
    var intendedSettings = previousSettings
    intendedSettings.imageVersion = "candidate"
    var metadata = VMMetadata(
        name: "owner-renamed-during-replacement",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        dockerSidecar: previousSettings
    )
    try bundle.writeMetadata(metadata)
    try writeReplacementTestSidecar(bundle.dockerSidecarBundle, candidateID: nil)

    let candidateID = UUID()
    let stageName = "\(DockerSidecarReplacement.stagePrefix)\(UUID().uuidString)"
    let stageSidecar = DockerSidecarBundle(
        url: bundleURL.appendingPathComponent(stageName, isDirectory: true)
    )
    try writeReplacementTestSidecar(stageSidecar, candidateID: candidateID)
    try DockerSidecarReplacement.writeJournal(
        DockerSidecarReplacementJournal(
            transactionID: UUID(),
            stageDirectoryName: stageName,
            candidateID: candidateID,
            previousSettings: previousSettings,
            intendedSettings: intendedSettings
        ),
        ownerBundle: bundle
    )

    metadata.setupFullName = "Unrelated concurrent edit"
    try bundle.writeMetadata(metadata)
    let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "recover Docker")
    defer { withExtendedLifetime(operationLock) {} }
    let recovered = try bundle.recoverDockerSidecarReplacementIfNeeded()

    #expect(recovered.dockerSidecar == previousSettings)
    #expect(recovered.setupFullName == "Unrelated concurrent edit")
    #expect(!bundle.hasDockerSidecarReplacementJournal)
    #expect(!stageSidecar.isPresent)
    #expect(try bundle.dockerSidecarBundle.readMetadata().replacementCandidateID == nil)
}

@Test
func dockerSidecarReplacementRecoveryPreservesAmbiguousState() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = root.appendingPathComponent("owner.macvm", isDirectory: true)
    let bundle = VMBundle(url: bundleURL)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let settings = dockerTestSettings()
    try bundle.writeMetadata(VMMetadata(
        name: "owner",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        dockerSidecar: settings
    ))
    try writeReplacementTestSidecar(bundle.dockerSidecarBundle, candidateID: UUID())
    let stageName = "\(DockerSidecarReplacement.stagePrefix)\(UUID().uuidString)"
    let stageSidecar = DockerSidecarBundle(
        url: bundleURL.appendingPathComponent(stageName, isDirectory: true)
    )
    try writeReplacementTestSidecar(stageSidecar, candidateID: UUID())
    try DockerSidecarReplacement.writeJournal(
        DockerSidecarReplacementJournal(
            transactionID: UUID(),
            stageDirectoryName: stageName,
            candidateID: UUID(),
            previousSettings: settings,
            intendedSettings: settings
        ),
        ownerBundle: bundle
    )

    let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "recover Docker")
    defer { withExtendedLifetime(operationLock) {} }
    #expect(throws: (any Error).self) {
        _ = try bundle.recoverDockerSidecarReplacementIfNeeded()
    }
    #expect(bundle.hasDockerSidecarReplacementJournal)
    #expect(bundle.dockerSidecarBundle.isPresent)
    #expect(stageSidecar.isPresent)
}

private func writeReplacementTestSidecar(
    _ sidecar: DockerSidecarBundle,
    candidateID: UUID?
) throws {
    try sidecar.createDirectories()
    try sidecar.writeMetadata(DockerSidecarMetadata(
        image: dockerTestImage,
        genericMachineIdentifierDigest: "test",
        replacementCandidateID: candidateID
    ))
}

@Test
func dockerImageRefreshCreatesVerifiedOfflineFallback() async throws {
    let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let rawImage = Data("offline Fedora CoreOS image".utf8)
    let compressedImage = try gzipData(rawImage)
    let streamData = try stableStreamData(
        release: "44.20260718.3.0",
        compressedImage: compressedImage,
        rawImage: rawImage
    )
    let onlineProvider = FedoraCoreOSImageProvider(
        cacheDirectory: cacheDirectory,
        streamURL: URL(string: "https://example.test/stable.json")!,
        downloader: DockerImageTestDownloader(
            streamData: streamData,
            compressedImageData: compressedImage
        )
    )

    let refreshed = try await onlineProvider.refresh()
    #expect(refreshed.image.release == "44.20260718.3.0")
    #expect(try Data(contentsOf: refreshed.rawImageURL) == rawImage)

    let offlineProvider = FedoraCoreOSImageProvider(
        cacheDirectory: cacheDirectory,
        streamURL: URL(string: "https://offline.invalid/stable.json")!,
        downloader: DockerImageTestDownloader(streamData: nil, compressedImageData: nil)
    )
    let automaticFallback = try await offlineProvider.preferredImage(automaticRefresh: true)
    let refreshDisabled = try await offlineProvider.preferredImage(automaticRefresh: false)
    #expect(automaticFallback.image == refreshed.image)
    #expect(refreshDisabled.image == refreshed.image)
    #expect(automaticFallback.rawImageURL == refreshed.rawImageURL)
}

@Test
func dockerSidecarUpdatePreservesDataAndIdentity() async throws {
    let storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let bundleURL = storageRoot.appendingPathComponent("update.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: storageRoot) }

    let bundle = VMBundle(url: bundleURL)
    let sidecar = bundle.dockerSidecarBundle
    try sidecar.createDirectories()
    let oldSystemDisk = Data("old system disk".utf8)
    let dockerData = Data("persistent docker state".utf8)
    try oldSystemDisk.write(to: sidecar.systemDiskURL)
    try dockerData.write(to: sidecar.dataDiskURL)
    let machineIdentifier = try sidecar.createGenericMachineIdentifier()
    let originalMachineIdentifier = machineIdentifier.dataRepresentation
    try sidecar.createEFIVariableStore()
    try "ssh-ed25519 AAAA docker".write(
        to: sidecar.dockerAuthorizedKeyURL,
        atomically: true,
        encoding: .utf8
    )
    try "ssh-ed25519 AAAA mount".write(
        to: sidecar.mountBrokerAuthorizedKeyURL,
        atomically: true,
        encoding: .utf8
    )
    try "PRIVATE HOST KEY".write(
        to: sidecar.linuxHostPrivateKeyURL,
        atomically: true,
        encoding: .utf8
    )
    try "ssh-ed25519 AAAA host".write(
        to: sidecar.linuxHostPublicKeyURL,
        atomically: true,
        encoding: .utf8
    )
    try Data("{}".utf8).write(to: sidecar.initialIgnitionURL)
    try sidecar.writeMetadata(DockerSidecarMetadata(
        image: dockerTestImage,
        genericMachineIdentifierDigest: DockerSidecarBundle.sha256Hex(originalMachineIdentifier)
    ))

    var settings = dockerTestSettings()
    settings.dataDiskSizeBytes = UInt64(dockerData.count)
    let metadata = VMMetadata(
        name: "update",
        cpuCount: 4,
        memorySizeBytes: 8 * oneGiB,
        diskSizeBytes: 80 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        setupUsername: "admin",
        setupCompletedAt: Date(),
        dockerSidecar: settings
    )
    try bundle.writeMetadata(metadata)
    try FileManager.default.createDirectory(at: bundle.setupDirectoryURL, withIntermediateDirectories: true)
    try Data("setup key".utf8).write(to: bundle.setupPrivateKeyURL)

    let newSystemDisk = Data("new system disk".utf8)
    let compressedImage = try gzipData(newSystemDisk)
    let streamData = try stableStreamData(
        release: "45.20260718.3.0",
        compressedImage: compressedImage,
        rawImage: newSystemDisk
    )
    _ = try await FedoraCoreOSImageProvider(
        cacheDirectory: storageRoot.appendingPathComponent(".docker-images", isDirectory: true),
        streamURL: URL(string: "https://example.test/stable.json")!,
        downloader: DockerImageTestDownloader(
            streamData: streamData,
            compressedImageData: compressedImage
        )
    ).refresh()

    let service = MacVMService(
        rootDirectory: storageRoot,
        dockerImageAutoRefreshEnabled: false
    )
    let updated = try await service.updateDockerSidecar(
        for: ManagedVM(bundleURL: bundleURL, metadata: metadata)
    )

    #expect(updated.metadata.dockerSidecar?.imageVersion == "45.20260718.3.0")
    #expect(try Data(contentsOf: sidecar.systemDiskURL) == newSystemDisk)
    #expect(try Data(contentsOf: sidecar.dataDiskURL) == dockerData)
    #expect(try sidecar.loadGenericMachineIdentifier().dataRepresentation == originalMachineIdentifier)
    #expect(try String(contentsOf: sidecar.linuxHostPrivateKeyURL, encoding: .utf8) == "PRIVATE HOST KEY")
    #expect(try sidecar.readMetadata().replacementCandidateID != nil)
    #expect(!bundle.hasDockerSidecarReplacementJournal)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bundleURL.path)
        .filter { $0.hasPrefix(DockerSidecarReplacement.stagePrefix) }
        .isEmpty)
}

@Test
func dockerSidecarRequiresUpdateForIgnitionOnlyChanges() {
    let stale = DockerSidecarMetadata(
        image: dockerTestImage,
        ignitionVersion: DockerSidecarMetadata.currentIgnitionVersion - 1,
        genericMachineIdentifierDigest: "digest"
    )
    let current = DockerSidecarMetadata(
        image: dockerTestImage,
        genericMachineIdentifierDigest: "digest"
    )

    #expect(stale.requiresUpdate(to: dockerTestImage))
    #expect(!current.requiresUpdate(to: dockerTestImage))
}

@Test
func ignitionPinsPrivateNetworkingRestrictedSSHDataDiskAndRosetta() throws {
    var settings = dockerTestSettings()
    settings.guestProvisioningState = .pending
    let data = try DockerIgnitionBuilder(
        settings: settings,
        dockerAuthorizedKey: "ssh-ed25519 AAAA docker",
        mountBrokerAuthorizedKey: "ssh-ed25519 AAAA mount",
        linuxHostPrivateKey: "PRIVATE HOST KEY",
        linuxHostPublicKey: "ssh-ed25519 AAAA host",
        genericMachineIdentifierDigest: "digest"
    ).makeData()
    let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var rendered = String(decoding: data, as: UTF8.self)
    let storage = document["storage"] as? [String: Any]
    let directories = try #require(storage?["directories"] as? [[String: Any]])
    #expect(!directories.contains(where: { ($0["path"] as? String)?.hasPrefix("/run/") == true }))
    for file in storage?["files"] as? [[String: Any]] ?? [] {
        guard let contents = file["contents"] as? [String: String],
              let source = contents["source"],
              let encoded = source.split(separator: ",", maxSplits: 1).last,
              let decoded = Data(base64Encoded: String(encoded)) else { continue }
        rendered += "\n" + String(decoding: decoded, as: UTF8.self)
    }
    let systemd = document["systemd"] as? [String: Any]
    for unit in systemd?["units"] as? [[String: Any]] ?? [] {
        rendered += "\n" + (unit["contents"] as? String ?? "")
    }

    #expect((document["ignition"] as? [String: String])?["version"] == DockerIgnitionBuilder.ignitionVersion)
    let passwd = try #require(document["passwd"] as? [String: Any])
    let users = try #require(passwd["users"] as? [[String: Any]])
    let dockerUser = try #require(users.first(where: { $0["name"] as? String == "macvm-docker" }))
    #expect(dockerUser["homeDir"] as? String == "/var/lib/macvm-docker")
    #expect(dockerUser["noCreateHome"] as? Bool == false)
    let mountUser = try #require(users.first(where: { $0["name"] as? String == "macvm-mount" }))
    let mountKeys = try #require(mountUser["sshAuthorizedKeys"] as? [String])
    #expect(mountKeys.contains(where: { $0.contains("restrict,port-forwarding,command=") }))
    #expect(rendered.contains("192.168.127.2/30"))
    #expect(rendered.contains("127.0.0.1:2375"))
    #expect(!rendered.contains("0.0.0.0:2375"))
    #expect(rendered.contains("root = \"/var/lib/docker/containerd\""))
    #expect(rendered.contains("path = \"/var/lib/docker/containerd/opt\""))
    #expect(rendered.contains("Requires=var-lib-docker.mount\nAfter=var-lib-docker.mount"))
    #expect(rendered.contains("permitopen"))
    #expect(rendered.contains("permitlisten=\\\"127.0.0.1:2222\\\""))
    let filesystems = try #require(storage?["filesystems"] as? [[String: Any]])
    let dockerFilesystem = try #require(filesystems.first)
    #expect(dockerFilesystem["label"] as? String == "macvm-docker")
    #expect(dockerFilesystem["withMountUnit"] == nil)
    #expect(rendered.contains("/run/macvm-macos"))
    #expect(rendered.contains("macvm-rosetta.service"))
    #expect(rendered.contains(#":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/run/macvm-rosetta/rosetta:OCF"#))
    #expect(!rendered.contains(#"\x02\x00\x3e:\xff"#))
    #expect(rendered.contains(#"printf '%s\n' ':rosetta:M::\x7fELF"#))
    #expect(!rendered.contains(#"printf ':rosetta:M::"#))
    #expect(rendered.contains(#"printf "\nMACVM_DOCKER_READY\n" >/dev/hvc0"#))
    #expect(!rendered.contains("MACVM_DOCKER_READY >/dev/ttyS0"))
    #expect(rendered.contains("MACVM_MANAGEMENT_INPUT"))
    #expect(!rendered.contains("${jump[@]}"))
    #expect(rendered.contains("nmcli -g GENERAL.DEVICES connection show macvm-private"))
    #expect(!rendered.contains("nmcli -g GENERAL.DEVICE connection show macvm-private"))
    #expect(rendered.contains("public-key)\n    ensure_filesystem_key"))
    #expect(rendered.contains("/usr/bin/mktemp -d /tmp/macvm-filesystem-key.XXXXXX"))
    #expect(rendered.contains("/usr/bin/ssh-keygen -q -t ed25519"))
    #expect(rendered.contains("/usr/bin/install -m 0600 \"$temporary/macos_fs_ed25519\""))
    #expect(rendered.contains("Requires=docker.service sshd.service macvm-filesystem-key.service"))
    #expect(!rendered.contains("firewall-cmd"))
    #expect(rendered.contains("/var/lib/docker/engine-id"))
    #expect(rendered.contains("mount-sshfs|mount-sshfs-file"))
    #expect(rendered.contains("follow=(-o follow_symlinks)"))
    #expect(rendered.contains("AllowTcpForwarding remote"))
    #expect(rendered.contains("AllowStreamLocalForwarding remote"))
    #expect(rendered.contains("StreamLocalBindUnlink yes"))
    #expect(rendered.contains("prepare-socket|wait-socket|remove-socket"))
    #expect(rendered.contains("install -d -o macvm-mount -g macvm-mount -m 0700"))
    #expect(rendered.contains(#"[[ -S "$socket" ]]"#))
    #expect(!rendered.contains("mount-nfs"))
    #expect(!rendered.contains("nfs-utils"))
    #expect(rendered.contains("sshfs \"$remote_user@127.0.0.1:$remote_path\" \"$target\" -p 2222"))
    #expect(rendered.contains("/usr/bin/umount --lazy \"$target\""))
    #expect(rendered.contains("reset-ports|publish-port|unpublish-port"))
    #expect(rendered.contains("MACVM_DOCKER_NAT"))
    #expect(rendered.contains("route_localnet"))
    #expect(rendered.contains("ssh_host_ed25519_key"))
    #expect(rendered.contains("802-3-ethernet.mac-address"))
    let units = try #require(systemd?["units"] as? [[String: Any]])
    let dockerMount = try #require(units.first(where: { $0["name"] as? String == "var-lib-docker.mount" }))
    #expect((dockerMount["contents"] as? String)?.contains("What=/dev/disk/by-id/virtio-macvm-docker-data") == true)
    #expect((dockerMount["contents"] as? String)?.contains("Where=/var/lib/docker") == true)
    let zincati = try #require(units.first(where: { $0["name"] as? String == "zincati.service" }))
    #expect(zincati["mask"] as? Bool == true)
}

@Test
func dockerReadinessRequiresStandaloneSerialMarker() {
    #expect(!DockerSidecarRuntime.containsReadinessMarker(
        "ExecStart=/bin/sh -c 'echo MACVM_DOCKER_READY >/dev/ttyS0'\r\n"
    ))
    #expect(DockerSidecarRuntime.containsReadinessMarker(
        "boot output\r\nMACVM_DOCKER_READY\r\n"
    ))
}

@Test
func dockerCreationWaitsForCurrentGuestProvisioningBeforeCompleting() {
    var settings = dockerTestSettings()
    settings.guestProvisioningState = .pending
    settings.guestProvisioningVersion = 0

    #expect(DockerGuestProvisioningWaitDecision.make(
        settings: settings,
        runtime: DockerSidecarRuntimeDescriptor(
            state: .pendingGuestProvisioning,
            pid: getpid(),
            startedAt: Date(),
            updatedAt: Date(),
            fcosVersion: dockerTestImage.release,
            amd64Available: true
        ),
        ownerFinished: false
    ) == .waiting)

    settings.guestProvisioningState = .ready
    settings.guestProvisioningVersion = DockerSidecarSettings.currentGuestProvisioningVersion
    #expect(DockerGuestProvisioningWaitDecision.make(
        settings: settings,
        runtime: nil,
        ownerFinished: false
    ) == .ready)
}

@Test @MainActor
func createRejectsDockerResourceOverflowBeforeCreatingBundle() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = MacVMService(rootDirectory: root)
    var draft = service.defaultDraft(named: "overflow")
    draft.dockerEnabled = true
    draft.dockerMemoryGiB = Int.max

    do {
        _ = try await service.createVM(from: draft)
        Issue.record("Expected Docker memory overflow to fail before restore-image resolution.")
    } catch {
        #expect(error.localizedDescription.contains("exceeds the supported size"))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("overflow.macvm").path))
}

@Test
func dockerStatusDistinguishesDisabledCorruptAndStopped() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = root.appendingPathComponent("dev.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = MacVMService(rootDirectory: root)
    var metadata = VMMetadata(
        name: "dev",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    var vm = ManagedVM(bundleURL: bundleURL, metadata: metadata)
    #expect(service.dockerStatus(for: vm).state == .disabled)

    try FileManager.default.createDirectory(at: VMBundle(url: bundleURL).dockerSidecarDirectoryURL, withIntermediateDirectories: false)
    #expect(service.dockerStatus(for: vm).state == .corrupt)

    metadata.dockerSidecar = dockerTestSettings(enabled: false)
    vm = ManagedVM(bundleURL: bundleURL, metadata: metadata)
    #expect(service.dockerStatus(for: vm).state == .disabled)
}

@Test
func cloneCopiesDockerPayloadButRefreshesConcurrentIdentities() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceURL = root.appendingPathComponent("source.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var settings = dockerTestSettings()
    settings.linuxNATMACAddress = "02:00:00:00:00:99"
    let metadata = VMMetadata(
        name: "source",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        dockerSidecar: settings
    )
    let sourceBundle = VMBundle(url: sourceURL)
    try sourceBundle.writeMetadata(metadata)
    for (url, value) in [
        (sourceBundle.hardwareModelURL, "hardware"),
        (sourceBundle.machineIdentifierURL, "machine"),
        (sourceBundle.auxiliaryStorageURL, "efi"),
        (sourceBundle.diskImageURL, "macos"),
    ] {
        try value.write(to: url, atomically: true, encoding: .utf8)
    }
    let sidecar = sourceBundle.dockerSidecarBundle
    try sidecar.createDirectories()
    try Data("fcos-state".utf8).write(to: sidecar.systemDiskURL)
    try Data("docker-images-volumes".utf8).write(to: sidecar.dataDiskURL)
    try Data("efi-state".utf8).write(to: sidecar.efiVariableStoreURL)
    let identifier = try sidecar.createGenericMachineIdentifier()
    try "ssh-ed25519 AAAA docker".write(to: sidecar.dockerAuthorizedKeyURL, atomically: true, encoding: .utf8)
    try "ssh-ed25519 AAAA mount".write(to: sidecar.mountBrokerAuthorizedKeyURL, atomically: true, encoding: .utf8)
    try "PRIVATE HOST KEY".write(to: sidecar.linuxHostPrivateKeyURL, atomically: true, encoding: .utf8)
    try "ssh-ed25519 AAAA host".write(to: sidecar.linuxHostPublicKeyURL, atomically: true, encoding: .utf8)
    try DockerIgnitionBuilder(
        settings: settings,
        dockerAuthorizedKey: "ssh-ed25519 AAAA docker",
        mountBrokerAuthorizedKey: "ssh-ed25519 AAAA mount",
        linuxHostPrivateKey: "PRIVATE HOST KEY",
        linuxHostPublicKey: "ssh-ed25519 AAAA host",
        genericMachineIdentifierDigest: DockerSidecarBundle.sha256Hex(identifier.dataRepresentation)
    ).makeData().write(to: sidecar.initialIgnitionURL)
    try sidecar.writeMetadata(DockerSidecarMetadata(
        image: dockerTestImage,
        genericMachineIdentifierDigest: DockerSidecarBundle.sha256Hex(identifier.dataRepresentation)
    ))
    try FileManager.default.createDirectory(at: sourceBundle.runtimeDirectoryURL, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: sourceBundle.dockerSidecarRuntimeURL)

    let clone = try await MacVMService(rootDirectory: root).cloneVM(
        from: ManagedVM(bundleURL: sourceURL, metadata: metadata),
        named: "clone"
    )
    let cloneBundle = VMBundle(url: clone.bundleURL)
    let clonedSidecar = cloneBundle.dockerSidecarBundle

    #expect(try Data(contentsOf: clonedSidecar.systemDiskURL) == Data("fcos-state".utf8))
    #expect(try Data(contentsOf: clonedSidecar.dataDiskURL) == Data("docker-images-volumes".utf8))
    #expect(try Data(contentsOf: clonedSidecar.efiVariableStoreURL) == Data("efi-state".utf8))
    #expect(try Data(contentsOf: clonedSidecar.dockerAuthorizedKeyURL) == Data(contentsOf: sidecar.dockerAuthorizedKeyURL))
    #expect(try Data(contentsOf: clonedSidecar.linuxHostPrivateKeyURL) == Data(contentsOf: sidecar.linuxHostPrivateKeyURL))
    #expect(try Data(contentsOf: clonedSidecar.genericMachineIdentifierURL) != Data(contentsOf: sidecar.genericMachineIdentifierURL))
    #expect(clone.metadata.dockerSidecar?.linuxNATMACAddress != settings.linuxNATMACAddress)
    #expect(clone.metadata.dockerSidecar?.linuxPrivateMACAddress == settings.linuxPrivateMACAddress)
    #expect(!FileManager.default.fileExists(atPath: cloneBundle.runtimeDirectoryURL.path))
}

@Test
func dockerOperationLockRejectsConcurrentMutationsAndReleases() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = VMBundle(url: root)
    defer { try? FileManager.default.removeItem(at: bundle.dockerSidecarOperationLockURL) }

    var first: DockerSidecarOperationLock? = try bundle.acquireDockerSidecarOperationLock(operation: "first")
    _ = withExtendedLifetime(first) {
        #expect(throws: (any Error).self) {
            _ = try bundle.acquireDockerSidecarOperationLock(operation: "second")
        }
    }
    try FileManager.default.removeItem(at: root)
    #expect(throws: (any Error).self) {
        _ = try bundle.acquireDockerSidecarOperationLock(operation: "after removal")
    }

    first = nil
    let next = try bundle.acquireDockerSidecarOperationLock(operation: "next")
    withExtendedLifetime(next) {}
    #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test
func dockerOperationLockUsesResolvedBundleIdentity() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = root.appendingPathComponent("VMs/owner.macvm", isDirectory: true)
    let aliasURL = root.appendingPathComponent("Aliases/renamed.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: aliasURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: bundleURL)
    defer { try? FileManager.default.removeItem(at: root) }

    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(VMMetadata(
        name: "owner",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    ))
    let resolved = try VMStorage(rootDirectory: bundleURL.deletingLastPathComponent())
        .resolveVM(identifier: aliasURL.path)
    let removalTarget = try VMStorage(rootDirectory: bundleURL.deletingLastPathComponent())
        .resolveRemovalTarget(identifier: aliasURL.path)
    let resolvedBundleURL = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    #expect(resolved.bundleURL.path == resolvedBundleURL.path)
    #expect(removalTarget.bundleURL.path == resolvedBundleURL.path)

    let alias = VMBundle(url: aliasURL)
    #expect(bundle.dockerSidecarOperationLockURL == alias.dockerSidecarOperationLockURL)

    let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "original path")
    defer { withExtendedLifetime(operationLock) {} }
    #expect(throws: (any Error).self) {
        _ = try alias.acquireDockerSidecarOperationLock(operation: "alias path")
    }
}

@Test
func dockerReplacementRecoveryRemovesUnjournaledStage() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = root.appendingPathComponent("owner.macvm", isDirectory: true)
    let bundle = VMBundle(url: bundleURL)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try bundle.createDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = VMMetadata(
        name: "owner",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    try bundle.writeMetadata(metadata)
    let orphan = bundleURL.appendingPathComponent(
        "\(DockerSidecarReplacement.stagePrefix)orphan",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    try Data("partial appliance".utf8).write(to: orphan.appendingPathComponent("disk.img"))

    let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "recover Docker")
    defer { withExtendedLifetime(operationLock) {} }
    let recovered = try bundle.recoverDockerSidecarReplacementIfNeeded()

    #expect(recovered.name == metadata.name)
    #expect(recovered.dockerSidecar == nil)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
}

@Test
func dockerRuntimeLivenessRequiresActiveStateFreshHeartbeatAndProcess() {
    let base = DockerSidecarRuntimeDescriptor(
        state: .ready,
        pid: getpid(),
        startedAt: Date(),
        updatedAt: Date(),
        fcosVersion: "test",
        mobyVersion: nil,
        amd64Available: true,
        lastError: nil
    )
    #expect(base.isLive)

    var stale = base
    stale.updatedAt = Date().addingTimeInterval(-31)
    #expect(!stale.isLive)

    var stopped = base
    stopped.state = .stopped
    #expect(!stopped.isLive)

    var degraded = base
    degraded.state = .degraded
    #expect(degraded.isLive)
}

@Test
func removalRefusesLiveDegradedDockerSidecar() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = root.appendingPathComponent("running.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = VMMetadata(
        name: "running",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        dockerSidecar: dockerTestSettings()
    )
    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(metadata)
    try bundle.writeDockerSidecarRuntimeDescriptor(DockerSidecarRuntimeDescriptor(
        state: .degraded,
        pid: getpid(),
        startedAt: Date(),
        updatedAt: Date(),
        fcosVersion: "test",
        mobyVersion: nil,
        amd64Available: true,
        lastError: "test"
    ))

    let vm = ManagedVM(bundleURL: bundleURL, metadata: metadata)
    #expect(throws: (any Error).self) {
        try MacVMService(rootDirectory: root).removeVM(vm)
    }
    #expect(FileManager.default.fileExists(atPath: bundleURL.path))
}
