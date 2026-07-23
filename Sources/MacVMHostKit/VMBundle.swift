import Darwin
import Foundation
import Virtualization

enum MacVMError: LocalizedError {
    case invalidName
    case invalidDisplaySize(String)
    case invalidCPUCount(Int)
    case invalidMemoryGiB(Int)
    case invalidDiskGiB(Int)
    case restoreImageRequired
    case invalidRestoreImage(URL)
    case bundleAlreadyExists(URL)
    case bundleNotFound(String)
    case ambiguousVMIdentifier(String)
    case invalidBundle(URL)
    case invalidHardwareModel(URL)
    case invalidMachineIdentifier(URL)
    case unsupportedHardwareModel
    case sharedDirectoryMissing(URL)
    case installCancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "VM name must not be empty."
        case .invalidDisplaySize(let rawValue):
            return "Display size must be in WIDTHxHEIGHT form. Received: \(rawValue)"
        case .invalidCPUCount(let value):
            return "CPU count must be greater than zero. Received: \(value)"
        case .invalidMemoryGiB(let value):
            return "Memory size must be greater than zero GiB. Received: \(value)"
        case .invalidDiskGiB(let value):
            return "Disk size must be greater than zero GiB. Received: \(value)"
        case .restoreImageRequired:
            return "Use --ipsw PATH or let the tool fetch the latest supported restore image."
        case .invalidRestoreImage(let url):
            return "Restore image not found at \(url.path)"
        case .bundleAlreadyExists(let url):
            return "A VM bundle already exists at \(url.path)"
        case .bundleNotFound(let identifier):
            return "No VM matched '\(identifier)'."
        case .ambiguousVMIdentifier(let identifier):
            return "More than one VM matched '\(identifier)'. Use the full bundle path instead."
        case .invalidBundle(let url):
            return "The bundle at \(url.path) is missing required metadata."
        case .invalidHardwareModel(let url):
            return "Couldn't load the hardware model stored at \(url.path)."
        case .invalidMachineIdentifier(let url):
            return "Couldn't load the machine identifier stored at \(url.path)."
        case .unsupportedHardwareModel:
            return "The current host doesn't support the hardware model exposed by this restore image."
        case .sharedDirectoryMissing(let url):
            return "The shared directory expected at \(url.path) doesn't exist."
        case .installCancelled:
            return "Installation cancelled."
        case .message(let value):
            return value
        }
    }
}

struct VMStorage {
    static let bundleExtension = "macvm"

    let rootDirectory: URL

    init(rootDirectory: URL?) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory
    }

    static var defaultRootDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("VirtualMachines", isDirectory: true)
            .appendingPathComponent("MacVMHost", isDirectory: true)
    }

    var restoreCacheDirectory: URL {
        rootDirectory.appendingPathComponent(".restore-images", isDirectory: true)
    }

    var dockerImageCacheDirectory: URL {
        rootDirectory.appendingPathComponent(".docker-images", isDirectory: true)
    }

    func ensureRootDirectories() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: restoreCacheDirectory, withIntermediateDirectories: true)
        // Docker image/tool caches are created lazily by their providers. Eagerly
        // touching a disconnected or slow external VM root here would block every
        // ordinary list/launch operation, including app-hosted unit tests.
    }

    func bundleURL(for name: String) -> URL {
        rootDirectory
            .appendingPathComponent(sanitizedBundleName(name), isDirectory: true)
            .appendingPathExtension(Self.bundleExtension)
    }

    func loadManagedVMs() throws -> [ManagedVM] {
        try ensureRootDirectories()

        let fileManager = FileManager.default
        // Names are sufficient here; asking NSURL for resource keys can block on
        // unrelated hidden cache entries on removable/network VM roots.
        let contents = try fileManager.contentsOfDirectory(atPath: rootDirectory.path)
            .filter { !$0.hasPrefix(".") }
            .map { rootDirectory.appendingPathComponent($0, isDirectory: true) }

        return try contents
            .filter { $0.pathExtension == Self.bundleExtension }
            .map { bundleURL in
                let bundle = VMBundle(url: bundleURL)
                return ManagedVM(bundleURL: bundleURL, metadata: try bundle.readMetadata())
            }
            .sorted { $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending }
    }

    func resolveVM(identifier: String) throws -> ManagedVM {
        let expandedIdentifier = NSString(string: identifier).expandingTildeInPath
        let directURL = URL(fileURLWithPath: expandedIdentifier)

        if FileManager.default.fileExists(atPath: directURL.path) {
            let resolvedURL = directURL.resolvingSymlinksInPath().standardizedFileURL
            let bundle = VMBundle(url: resolvedURL)
            return ManagedVM(bundleURL: resolvedURL, metadata: try bundle.readMetadata())
        }

        let candidates = try loadManagedVMs().filter { managedVM in
            managedVM.metadata.name == identifier || managedVM.bundleURL.deletingPathExtension().lastPathComponent == identifier
        }

        if candidates.isEmpty {
            throw MacVMError.bundleNotFound(identifier)
        }

        if candidates.count > 1 {
            throw MacVMError.ambiguousVMIdentifier(identifier)
        }

        return candidates[0]
    }

    func resolveRemovalTarget(identifier: String) throws -> VMRemovalTarget {
        let expandedIdentifier = NSString(string: identifier).expandingTildeInPath
        let directURL = URL(fileURLWithPath: expandedIdentifier)

        if FileManager.default.fileExists(atPath: directURL.path) {
            let resolvedURL = directURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedURL.pathExtension == Self.bundleExtension else {
                throw MacVMError.invalidBundle(resolvedURL)
            }

            return removalTarget(for: resolvedURL)
        }

        let candidates = try removalTargets(matching: identifier)

        if candidates.isEmpty {
            throw MacVMError.bundleNotFound(identifier)
        }

        if candidates.count > 1 {
            throw MacVMError.ambiguousVMIdentifier(identifier)
        }

        return candidates[0]
    }

    private func removalTargets(matching identifier: String) throws -> [VMRemovalTarget] {
        try ensureRootDirectories()

        let contents = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return contents
            .filter { $0.pathExtension == Self.bundleExtension }
            .map { removalTarget(for: $0) }
            .filter { target in
                target.name == identifier || target.bundleURL.deletingPathExtension().lastPathComponent == identifier
            }
    }

    private func removalTarget(for bundleURL: URL) -> VMRemovalTarget {
        VMRemovalTarget(bundleURL: bundleURL, metadata: try? VMBundle(url: bundleURL).readMetadata())
    }
}

struct VMBundle {
    let url: URL

    var metadataURL: URL {
        url.appendingPathComponent("Metadata.json")
    }

    var metadataLockURL: URL {
        let resolvedBundleURL = url.resolvingSymlinksInPath().standardizedFileURL
        return resolvedBundleURL.deletingLastPathComponent().appendingPathComponent(
            ".\(resolvedBundleURL.lastPathComponent).metadata.lock",
            isDirectory: false
        )
    }

    var hardwareModelURL: URL {
        url.appendingPathComponent("HardwareModel")
    }

    var machineIdentifierURL: URL {
        url.appendingPathComponent("MachineIdentifier")
    }

    var auxiliaryStorageURL: URL {
        url.appendingPathComponent("AuxiliaryStorage")
    }

    var diskImageURL: URL {
        url.appendingPathComponent("Disk.img")
    }

    var sharedDirectoryRootURL: URL {
        url.appendingPathComponent("Shared", isDirectory: true)
    }

    /// Where the host stages files for the guest (auto-mounts at
    /// `/Volumes/My Shared Files/Transfers` inside the guest).
    var transfersDirectoryURL: URL {
        sharedDirectoryRootURL.appendingPathComponent(BootstrapAssets.transfersDirectoryName, isDirectory: true)
    }

    func ensureTransfersDirectory() throws {
        try FileManager.default.createDirectory(at: transfersDirectoryURL, withIntermediateDirectories: true)
    }

    /// Ephemeral runtime state (e.g. the live VNC session/display descriptors).
    var runtimeDirectoryURL: URL {
        url.appendingPathComponent("Runtime", isDirectory: true)
    }

    /// Persistent automation artifacts (per-VM SSH key, setup step overrides).
    var setupDirectoryURL: URL {
        url.appendingPathComponent("Setup", isDirectory: true)
    }

    var setupPrivateKeyURL: URL {
        setupDirectoryURL.appendingPathComponent("id_ed25519")
    }

    var setupPublicKeyURL: URL {
        setupDirectoryURL.appendingPathComponent("id_ed25519.pub")
    }

    /// Guest SSH host public keys exported over the trusted setup shared directory.
    /// Clipboard installation renders these for the currently resolved guest address.
    var setupSSHHostKeysURL: URL {
        setupDirectoryURL.appendingPathComponent("ssh-host-keys")
    }

    var vncSessionURL: URL {
        runtimeDirectoryURL.appendingPathComponent("vnc-session.json")
    }

    var displayRuntimeStateURL: URL {
        runtimeDirectoryURL.appendingPathComponent("display-state.json")
    }

    var vmProcessRuntimeStateURL: URL {
        runtimeDirectoryURL.appendingPathComponent("vm-process.json")
    }

    var setupRuntimeStateURL: URL {
        runtimeDirectoryURL.appendingPathComponent("setup-state.json")
    }

    var setupPreviewURL: URL {
        runtimeDirectoryURL.appendingPathComponent("setup-preview.png")
    }

    var provisioningStateURL: URL {
        setupDirectoryURL.appendingPathComponent("provisioning-state.json")
    }

    var provisioningLogsDirectoryURL: URL {
        setupDirectoryURL.appendingPathComponent("Provisioning", isDirectory: true)
    }

    func readProvisioningState() -> ProvisioningState? {
        guard let data = try? Data(contentsOf: provisioningStateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProvisioningState.self, from: data)
    }

    func writeProvisioningState(_ state: ProvisioningState) throws {
        try FileManager.default.createDirectory(at: setupDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: provisioningStateURL, options: .atomic)
    }

    var viewerWindowStateURL: URL {
        url.appendingPathComponent("ViewerWindow.json")
    }

    func createDirectory() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func removeFromDisk() throws {
        try makeDirectoriesRemovable(at: url)
        try FileManager.default.removeItem(at: url)
    }

    func writeMetadata(_ metadata: VMMetadata) throws {
        try encodedMetadata(metadata).write(to: metadataURL, options: .atomic)
    }

    /// Serialize metadata read-modify-write operations across app and CLI processes.
    /// The sibling lock inode remains stable while the atomic metadata write replaces
    /// `Metadata.json`, and it is not copied as part of a VM clone.
    @discardableResult
    func updateMetadata(
        defaultingTo initialMetadata: VMMetadata? = nil,
        _ mutation: (inout VMMetadata) throws -> Void
    ) throws -> VMMetadata {
        try FileManager.default.createDirectory(
            at: metadataLockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(metadataLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MacVMError.message(
                "Couldn't lock metadata for '\(url.lastPathComponent)': \(String(cString: strerror(errno)))"
            )
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw MacVMError.message(
                "Couldn't lock metadata for '\(url.lastPathComponent)': \(String(cString: strerror(errno)))"
            )
        }

        var metadata: VMMetadata
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            metadata = try readMetadata()
        } else if let initialMetadata {
            metadata = initialMetadata
        } else {
            throw MacVMError.invalidBundle(url)
        }
        try mutation(&metadata)
        try encodedMetadata(metadata).write(to: metadataURL, options: .atomic)
        return metadata
    }

    private func encodedMetadata(_ metadata: VMMetadata) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeMetadataDateFormatter().string(from: date))
        }
        return try encoder.encode(metadata)
    }

    func readMetadata() throws -> VMMetadata {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw MacVMError.invalidBundle(url)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = makeMetadataDateFormatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid metadata date: \(value)"
                )
            }

            return date
        }
        let data = try Data(contentsOf: metadataURL)
        return try decoder.decode(VMMetadata.self, from: data)
    }

    /// Guarantee the bundle has a persisted MAC address, generating and saving
    /// one if absent. Idempotent — returns the (possibly updated) metadata so a
    /// stable identity is available before the VM boots and requests a lease.
    func ensureNetworkIdentity(_ metadata: VMMetadata) throws -> VMMetadata {
        if let macAddress = metadata.macAddress, VZMACAddress(string: macAddress) != nil {
            return metadata
        }

        return try updateMetadata(defaultingTo: metadata) { current in
            if current.macAddress.flatMap(VZMACAddress.init(string:)) == nil {
                current.macAddress = VZMACAddress.randomLocallyAdministered().string
            }
        }
    }

    func writeVNCSession(_ session: VNCSession) throws {
        try FileManager.default.createDirectory(at: runtimeDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: vncSessionURL, options: .atomic)
        // The descriptor holds the VNC password, so keep it owner-only. This also
        // limits who can poison the session another process would trust.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vncSessionURL.path)
    }

    func readVNCSession() -> VNCSession? {
        guard let data = try? Data(contentsOf: vncSessionURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VNCSession.self, from: data)
    }

    func clearVNCSession() {
        try? FileManager.default.removeItem(at: vncSessionURL)
    }

    /// The live VNC session for this bundle, or nil if none is currently running.
    /// A stale descriptor (owning process gone) is treated as absent.
    func liveVNCSession() -> VNCSession? {
        guard let session = readVNCSession(), session.isLive else {
            return nil
        }
        return session
    }

    func writeDisplayRuntimeState(_ state: VMDisplayRuntimeState) throws {
        try FileManager.default.createDirectory(at: runtimeDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: displayRuntimeStateURL, options: .atomic)
    }

    func readDisplayRuntimeState() -> VMDisplayRuntimeState? {
        guard let data = try? Data(contentsOf: displayRuntimeStateURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMDisplayRuntimeState.self, from: data)
    }

    func clearDisplayRuntimeState() {
        try? FileManager.default.removeItem(at: displayRuntimeStateURL)
    }

    /// The live display state for this bundle, or nil if none is currently
    /// publishing it. A stale descriptor (owning process gone) is treated as absent.
    func liveDisplayRuntimeState() -> VMDisplayRuntimeState? {
        guard let state = readDisplayRuntimeState(), state.isLive else {
            return nil
        }
        return state
    }

    func writeVMProcessRuntimeState(_ state: VMProcessRuntimeState) throws {
        try FileManager.default.createDirectory(at: runtimeDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: vmProcessRuntimeStateURL, options: .atomic)
    }

    func readVMProcessRuntimeState() -> VMProcessRuntimeState? {
        guard let data = try? Data(contentsOf: vmProcessRuntimeStateURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMProcessRuntimeState.self, from: data)
    }

    func clearVMProcessRuntimeState() {
        try? FileManager.default.removeItem(at: vmProcessRuntimeStateURL)
    }

    /// The live process that owns this VM, or nil if none is currently running.
    /// A stale descriptor (owning process gone) is treated as absent.
    func liveVMProcessRuntimeState() -> VMProcessRuntimeState? {
        guard let state = readVMProcessRuntimeState(), state.isLive else {
            return nil
        }
        return state
    }

    func writeSetupRuntimeState(_ state: VMSetupRuntimeState) throws {
        try FileManager.default.createDirectory(at: runtimeDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: setupRuntimeStateURL, options: .atomic)
    }

    func readSetupRuntimeState() -> VMSetupRuntimeState? {
        guard let data = try? Data(contentsOf: setupRuntimeStateURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMSetupRuntimeState.self, from: data)
    }

    func clearSetupRuntimeState() {
        try? FileManager.default.removeItem(at: setupRuntimeStateURL)
        try? FileManager.default.removeItem(at: setupPreviewURL)
    }

    /// The live setup operation for this bundle, or nil if setup is not running.
    /// A stale descriptor (owning process gone) is treated as absent and pruned
    /// from disk so a crashed or killed setup cannot leave a lingering marker
    /// that later misidentifies the VM as still setting up.
    func liveSetupRuntimeState() -> VMSetupRuntimeState? {
        guard let state = readSetupRuntimeState() else {
            return nil
        }
        guard state.isLive else {
            clearSetupRuntimeState()
            return nil
        }
        return state
    }

    func writeViewerWindowState(_ state: VMViewerWindowState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: viewerWindowStateURL, options: .atomic)
    }

    func readViewerWindowState() -> VMViewerWindowState? {
        guard let data = try? Data(contentsOf: viewerWindowStateURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VMViewerWindowState.self, from: data)
    }

    func savePlatformArtifacts(hardwareModel: VZMacHardwareModel, machineIdentifier: VZMacMachineIdentifier) throws {
        try hardwareModel.dataRepresentation.write(to: hardwareModelURL, options: .atomic)
        try machineIdentifier.dataRepresentation.write(to: machineIdentifierURL, options: .atomic)
    }

    func createAuxiliaryStorage(for hardwareModel: VZMacHardwareModel) throws {
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: auxiliaryStorageURL,
            hardwareModel: hardwareModel,
            options: []
        )
    }

    func createDiskImage(sizeBytes: UInt64) throws {
        guard !FileManager.default.fileExists(atPath: diskImageURL.path) else {
            return
        }

        let descriptor = open(diskImageURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor != -1 else {
            throw MacVMError.message("Couldn't create disk image at \(diskImageURL.path)")
        }

        defer {
            close(descriptor)
        }

        try truncateDiskImage(descriptor: descriptor, sizeBytes: sizeBytes)
    }

    private func truncateDiskImage(descriptor: Int32, sizeBytes: UInt64) throws {
        guard sizeBytes <= UInt64(Int64.max) else {
            throw MacVMError.message("Disk size \(VMText.gibLabel(for: sizeBytes)) exceeds the supported file size.")
        }

        guard ftruncate(descriptor, off_t(sizeBytes)) == 0 else {
            let message = String(cString: strerror(errno))
            throw MacVMError.message("Couldn't set disk image size at \(diskImageURL.path): \(message)")
        }
    }

    private func makeDirectoriesRemovable(at itemURL: URL) throws {
        var itemStat = stat()
        guard lstat(itemURL.path, &itemStat) == 0 else {
            throw posixError("Couldn't inspect", path: itemURL.path)
        }

        guard itemStat.isDirectory else {
            return
        }

        try addOwnerDirectoryPermissions(at: itemURL.path, currentStat: itemStat)

        let contents = try FileManager.default.contentsOfDirectory(
            at: itemURL,
            includingPropertiesForKeys: nil
        )
        for childURL in contents {
            try makeDirectoriesRemovable(at: childURL)
        }
    }

    private func addOwnerDirectoryPermissions(at path: String, currentStat: stat) throws {
        if currentStat.st_flags != 0 && chflags(path, 0) != 0 {
            throw posixError("Couldn't clear file flags for", path: path)
        }

        let requiredPermissions = mode_t(S_IRUSR | S_IWUSR | S_IXUSR)
        let currentPermissions = currentStat.st_mode & 0o7777
        let updatedPermissions = currentPermissions | requiredPermissions
        guard updatedPermissions != currentPermissions else {
            return
        }

        guard chmod(path, updatedPermissions) == 0 else {
            throw posixError("Couldn't update permissions for", path: path)
        }
    }

    private func posixError(_ operation: String, path: String) -> MacVMError {
        MacVMError.message("\(operation) \(path): \(String(cString: strerror(errno)))")
    }

    func prepareSharedDirectory(includeBootstrapShare: Bool) throws {
        guard includeBootstrapShare else {
            return
        }

        let bootstrapDirectory = sharedDirectoryRootURL.appendingPathComponent(BootstrapAssets.bootstrapDirectoryName, isDirectory: true)
        let transfersDirectory = sharedDirectoryRootURL.appendingPathComponent(BootstrapAssets.transfersDirectoryName, isDirectory: true)

        try FileManager.default.createDirectory(at: bootstrapDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transfersDirectory, withIntermediateDirectories: true)

        let readmeURL = bootstrapDirectory.appendingPathComponent(BootstrapAssets.readmeFileName)
        let scriptURL = bootstrapDirectory.appendingPathComponent(BootstrapAssets.scriptFileName)

        try BootstrapAssets.readme.write(to: readmeURL, atomically: true, encoding: .utf8)
        try BootstrapAssets.loadBootstrapScript().write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func loadHardwareModel() throws -> VZMacHardwareModel {
        let hardwareModelData = try Data(contentsOf: hardwareModelURL)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            throw MacVMError.invalidHardwareModel(hardwareModelURL)
        }

        return hardwareModel
    }

    func loadMachineIdentifier() throws -> VZMacMachineIdentifier {
        let machineIdentifierData = try Data(contentsOf: machineIdentifierURL)
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            throw MacVMError.invalidMachineIdentifier(machineIdentifierURL)
        }

        return machineIdentifier
    }

    func makePlatformConfiguration() throws -> VZMacPlatformConfiguration {
        let hardwareModel = try loadHardwareModel()
        guard hardwareModel.isSupported else {
            throw MacVMError.unsupportedHardwareModel
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = try loadMachineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxiliaryStorageURL)
        return platform
    }

    func makeConfiguration(
        metadata: VMMetadata,
        forceSharedDirectory: Bool = false,
        additionalNetworkDevices: [VZNetworkDeviceConfiguration] = [],
        memoryBalloonEnabled: Bool = true
    ) throws -> VZVirtualMachineConfiguration {
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = try makePlatformConfiguration()
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = metadata.cpuCount
        configuration.memorySize = metadata.memorySizeBytes
        configuration.storageDevices = [try makeStorageDevice()]
        configuration.graphicsDevices = [makeGraphicsDevice(metadata: metadata)]
        configuration.networkDevices = [makeNetworkDevice(metadata: metadata)] + additionalNetworkDevices
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        if memoryBalloonEnabled {
            MemoryBalloonConfiguration.install(on: configuration)
        }

        // `setup` stages a provisioning script through the shared folder, so it
        // forces the share on even for VMs created with --no-bootstrap.
        if metadata.bootstrapShareEnabled || forceSharedDirectory {
            configuration.directorySharingDevices = [try makeSharedDirectoryDevice()]
        }

        try configuration.validate()
        return configuration
    }

    private func makeStorageDevice() throws -> VZVirtioBlockDeviceConfiguration {
        let attachment = try VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false)
        return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }

    private func makeGraphicsDevice(metadata: VMMetadata) -> VZMacGraphicsDeviceConfiguration {
        let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
        graphicsConfiguration.displays = [
            // Retina density: displayWidth x displayHeight is the effective
            // guest workspace in points; Virtualization gets the derived 2x
            // backing framebuffer. Doubled glyph pixels also make Setup
            // Assistant labels easy for the OCR-driven setup flow to read.
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: metadata.displayPixelWidth,
                heightInPixels: metadata.displayPixelHeight,
                pixelsPerInch: VMDisplayMetrics.retinaPixelsPerInch
            )
        ]
        return graphicsConfiguration
    }

    private func makeNetworkDevice(metadata: VMMetadata) -> VZVirtioNetworkDeviceConfiguration {
        let networkConfiguration = VZVirtioNetworkDeviceConfiguration()
        networkConfiguration.attachment = VZNATNetworkDeviceAttachment()
        // Prefer the persisted MAC so host-side DHCP/ARP lookups stay valid across
        // boots. Fall back to a random address only for bundles that predate
        // `ensureNetworkIdentity` (their IP simply won't be discoverable until the
        // MAC is backfilled and the guest reboots).
        if let macAddress = metadata.macAddress, let parsed = VZMACAddress(string: macAddress) {
            networkConfiguration.macAddress = parsed
        } else {
            networkConfiguration.macAddress = VZMACAddress.randomLocallyAdministered()
        }
        return networkConfiguration
    }

    private func makeSharedDirectoryDevice() throws -> VZVirtioFileSystemDeviceConfiguration {
        if !FileManager.default.fileExists(atPath: sharedDirectoryRootURL.path) {
            try FileManager.default.createDirectory(at: sharedDirectoryRootURL, withIntermediateDirectories: true)
        }

        let sharedDirectory = VZSharedDirectory(url: sharedDirectoryRootURL, readOnly: false)
        let share = VZSingleDirectoryShare(directory: sharedDirectory)
        let configuration = VZVirtioFileSystemDeviceConfiguration(
            tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
        )
        configuration.share = share
        return configuration
    }
}

private extension stat {
    var isDirectory: Bool {
        (st_mode & S_IFMT) == S_IFDIR
    }
}

private func makeMetadataDateFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}
