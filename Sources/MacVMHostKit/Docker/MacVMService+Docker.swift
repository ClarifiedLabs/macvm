import Foundation
import Virtualization

enum DockerSidecarPairingKeyMaterialPlan: Equatable {
    case reuse
    case installAuthorizedKey
    case regenerate

    static func make(
        requiresPendingKeys: Bool,
        hasAuthorizedKey: Bool,
        hasPendingPrivateKey: Bool,
        hasPendingPublicKey: Bool
    ) -> Self {
        let hasCompletePendingPair = hasPendingPrivateKey && hasPendingPublicKey
        if hasAuthorizedKey, !requiresPendingKeys || hasCompletePendingPair {
            return .reuse
        }
        if !hasAuthorizedKey, hasCompletePendingPair {
            return .installAuthorizedKey
        }
        return .regenerate
    }
}

public struct DockerSidecarResourceConfiguration: Equatable, Sendable {
    public var cpuCount: Int
    public var memorySizeBytes: UInt64
    public var dataDiskSizeBytes: UInt64
    public var amd64Enabled: Bool

    public init(
        cpuCount: Int = DockerSidecarSettings.defaultCPUCount,
        memorySizeBytes: UInt64 = UInt64(DockerSidecarSettings.defaultMemoryGiB) * 1024 * 1024 * 1024,
        dataDiskSizeBytes: UInt64 = UInt64(DockerSidecarSettings.defaultDiskGiB) * 1024 * 1024 * 1024,
        amd64Enabled: Bool = true
    ) {
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.dataDiskSizeBytes = dataDiskSizeBytes
        self.amd64Enabled = amd64Enabled
    }
}

extension MacVMService {
    public func cachedDockerImage() throws -> FedoraCoreOSCachedImage? {
        try FedoraCoreOSImageProvider(
            cacheDirectory: storage.dockerImageCacheDirectory
        ).cachedImage()
    }

    public func refreshDockerImage(
        progress: VMOperationHandler? = nil
    ) async throws -> FedoraCoreOSCachedImage {
        try storage.ensureRootDirectories()
        return try await FedoraCoreOSImageProvider(
            cacheDirectory: storage.dockerImageCacheDirectory
        ).refresh(progress: progress)
    }

    public func dockerStatus(for vm: ManagedVM) -> DockerSidecarStatus {
        let bundle = VMBundle(url: vm.bundleURL)
        if bundle.hasDockerSidecarReplacementJournal {
            do {
                let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "recover Docker")
                defer { withExtendedLifetime(operationLock) {} }
                let recoveredMetadata = try bundle.recoverDockerSidecarReplacementIfNeeded()
                return dockerStatus(for: ManagedVM(bundleURL: vm.bundleURL, metadata: recoveredMetadata))
            } catch {
                return DockerSidecarStatus(state: .corrupt, lastError: error.localizedDescription)
            }
        }
        guard let settings = vm.metadata.dockerSidecar else {
            return DockerSidecarStatus(
                state: bundle.dockerSidecarBundle.isPresent ? .corrupt : .disabled,
                lastError: bundle.dockerSidecarBundle.isPresent
                    ? "A DockerSidecar directory exists without parent metadata. Run `macvm docker reset --force`."
                    : nil
            )
        }

        let base = { (state: DockerSidecarState, error: String?) in
            DockerSidecarStatus(
                state: state,
                fcosVersion: settings.imageVersion,
                mobyVersion: settings.mobyVersion,
                cpuCount: settings.cpuCount,
                memorySizeBytes: settings.memorySizeBytes,
                dataDiskSizeBytes: bundle.dockerSidecarBundle.logicalDataDiskSize() ?? settings.dataDiskSizeBytes,
                dataDiskAllocatedBytes: bundle.dockerSidecarAllocatedSizeBytes(),
                amd64Requested: settings.amd64Enabled,
                amd64Available: DockerSidecarRuntime.rosettaAvailable(settings: settings),
                lastError: error
            )
        }

        guard settings.schemaVersion == DockerSidecarSettings.currentSchemaVersion else {
            return base(.corrupt, "Docker settings version \(settings.schemaVersion) is unsupported.")
        }
        guard settings.enabled else { return base(.disabled, nil) }
        do {
            _ = try bundle.dockerSidecarBundle.validateIntegrity()
        } catch {
            return base(.corrupt, error.localizedDescription)
        }
        if let runtime = bundle.readDockerSidecarRuntimeDescriptor(), runtime.isLive {
            var value = base(runtime.state, runtime.lastError)
            value.updatedAt = runtime.updatedAt
            value.ownerPID = runtime.pid
            value.mobyVersion = runtime.mobyVersion ?? value.mobyVersion
            value.amd64Available = runtime.amd64Available
            return value
        }
        if let runtime = bundle.readDockerSidecarRuntimeDescriptor(), runtime.state == .degraded {
            return base(.degraded, runtime.lastError)
        }
        if settings.guestProvisioningState != .ready {
            return base(.pendingGuestProvisioning, nil)
        }
        return base(.stopped, nil)
    }

    public func enableDockerSidecar(
        for vm: ManagedVM,
        configuration: DockerSidecarResourceConfiguration = DockerSidecarResourceConfiguration(),
        progress: VMOperationHandler? = nil
    ) async throws -> ManagedVM {
        let ownerBundle = VMBundle(url: vm.bundleURL)
        let operationLock = try ownerBundle.acquireDockerSidecarOperationLock(operation: "enable Docker")
        defer { withExtendedLifetime(operationLock) {} }
        let currentVM = ManagedVM(
            bundleURL: vm.bundleURL,
            metadata: try ownerBundle.recoverDockerSidecarReplacementIfNeeded()
        )
        try requireStopped(currentVM, operation: "enable Docker")
        try requireDockerSetup(currentVM)
        try validateDockerResources(configuration, owner: currentVM.metadata)

        if var existing = currentVM.metadata.dockerSidecar {
            guard ownerBundle.dockerSidecarBundle.isPresent else {
                throw MacVMError.message("Docker settings exist but the sidecar appliance is missing. Run `macvm docker reset \(currentVM.metadata.name) --force`.")
            }
            _ = try ownerBundle.dockerSidecarBundle.validateIntegrity()
            if configuration.dataDiskSizeBytes < existing.dataDiskSizeBytes {
                throw MacVMError.message("Docker data disk shrinking requires `macvm docker reset --force`.")
            }
            try ownerBundle.dockerSidecarBundle.growDataDisk(to: configuration.dataDiskSizeBytes)
            existing.enabled = true
            existing.cpuCount = configuration.cpuCount
            existing.memorySizeBytes = configuration.memorySizeBytes
            existing.dataDiskSizeBytes = configuration.dataDiskSizeBytes
            existing.amd64Enabled = configuration.amd64Enabled
            let metadata = try ownerBundle.updateMetadata { metadata in
                metadata.dockerSidecar = existing
            }
            ownerBundle.clearDockerSidecarRuntimeDescriptor()
            return ManagedVM(bundleURL: currentVM.bundleURL, metadata: metadata)
        }
        guard !ownerBundle.dockerSidecarBundle.isPresent else {
            throw MacVMError.message("A partial Docker sidecar already exists. Run `macvm docker reset \(currentVM.metadata.name) --force`.")
        }

        var settings = DockerSidecarSettings(
            amd64Enabled: configuration.amd64Enabled,
            cpuCount: configuration.cpuCount,
            memorySizeBytes: configuration.memorySizeBytes,
            dataDiskSizeBytes: configuration.dataDiskSizeBytes,
            macOSMACAddress: VZMACAddress.randomLocallyAdministered().string,
            linuxPrivateMACAddress: VZMACAddress.randomLocallyAdministered().string,
            linuxNATMACAddress: VZMACAddress.randomLocallyAdministered().string
        )
        progress?(.status("Preparing Docker sidecar metadata and identities..."))
        return try await materializeDockerSidecar(
            for: currentVM,
            settings: &settings,
            preservingIdentityFrom: nil,
            progress: progress
        )
    }

    public func configureDockerSidecar(
        for vm: ManagedVM,
        cpuCount: Int? = nil,
        memorySizeBytes: UInt64? = nil,
        dataDiskSizeBytes: UInt64? = nil,
        amd64Enabled: Bool? = nil
    ) throws -> ManagedVM {
        let bundle = VMBundle(url: vm.bundleURL)
        let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "configure Docker")
        defer { withExtendedLifetime(operationLock) {} }
        let currentVM = ManagedVM(
            bundleURL: vm.bundleURL,
            metadata: try bundle.recoverDockerSidecarReplacementIfNeeded()
        )
        try requireStopped(currentVM, operation: "configure Docker")
        guard var settings = currentVM.metadata.dockerSidecar else {
            throw MacVMError.message("Docker is not enabled for '\(currentVM.metadata.name)'.")
        }
        let requested = DockerSidecarResourceConfiguration(
            cpuCount: cpuCount ?? settings.cpuCount,
            memorySizeBytes: memorySizeBytes ?? settings.memorySizeBytes,
            dataDiskSizeBytes: dataDiskSizeBytes ?? settings.dataDiskSizeBytes,
            amd64Enabled: amd64Enabled ?? settings.amd64Enabled
        )
        try validateDockerResources(requested, owner: currentVM.metadata)
        _ = try bundle.dockerSidecarBundle.validateIntegrity()
        if requested.dataDiskSizeBytes < settings.dataDiskSizeBytes {
            throw MacVMError.message("Docker data disk shrinking requires `macvm docker reset --force`.")
        }
        try bundle.dockerSidecarBundle.growDataDisk(to: requested.dataDiskSizeBytes)
        settings.cpuCount = requested.cpuCount
        settings.memorySizeBytes = requested.memorySizeBytes
        settings.dataDiskSizeBytes = requested.dataDiskSizeBytes
        settings.amd64Enabled = requested.amd64Enabled
        let metadata = try bundle.updateMetadata { metadata in
            metadata.dockerSidecar = settings
        }
        return ManagedVM(bundleURL: currentVM.bundleURL, metadata: metadata)
    }

    public func disableDockerSidecar(for vm: ManagedVM) throws -> ManagedVM {
        let bundle = VMBundle(url: vm.bundleURL)
        let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "disable Docker")
        defer { withExtendedLifetime(operationLock) {} }
        let currentVM = ManagedVM(
            bundleURL: vm.bundleURL,
            metadata: try bundle.recoverDockerSidecarReplacementIfNeeded()
        )
        try requireStopped(currentVM, operation: "disable Docker")
        guard var settings = currentVM.metadata.dockerSidecar else { return currentVM }
        settings.enabled = false
        let metadata = try bundle.updateMetadata { metadata in
            metadata.dockerSidecar = settings
        }
        bundle.clearDockerSidecarRuntimeDescriptor()
        return ManagedVM(bundleURL: currentVM.bundleURL, metadata: metadata)
    }

    public func resetDockerSidecar(
        for vm: ManagedVM,
        progress: VMOperationHandler? = nil
    ) async throws -> ManagedVM {
        let ownerBundle = VMBundle(url: vm.bundleURL)
        let operationLock = try ownerBundle.acquireDockerSidecarOperationLock(operation: "reset Docker")
        defer { withExtendedLifetime(operationLock) {} }
        let currentVM = ManagedVM(
            bundleURL: vm.bundleURL,
            metadata: try ownerBundle.recoverDockerSidecarReplacementIfNeeded()
        )
        try requireStopped(currentVM, operation: "reset Docker")
        try requireDockerSetup(currentVM)
        let existingSidecar = ownerBundle.dockerSidecarBundle
        var settings = currentVM.metadata.dockerSidecar ?? DockerSidecarSettings(
            macOSMACAddress: VZMACAddress.randomLocallyAdministered().string,
            linuxPrivateMACAddress: VZMACAddress.randomLocallyAdministered().string,
            linuxNATMACAddress: VZMACAddress.randomLocallyAdministered().string
        )
        settings.enabled = true
        settings.guestProvisioningState = currentVM.metadata.dockerSidecar?.guestProvisioningState ?? .pending
        settings.mobyVersion = nil
        return try await materializeDockerSidecar(
            for: currentVM,
            settings: &settings,
            preservingIdentityFrom: existingSidecar.isPresent ? existingSidecar.identityDirectoryURL : nil,
            progress: progress
        )
    }

    public func updateDockerSidecar(
        for vm: ManagedVM,
        progress: VMOperationHandler? = nil
    ) async throws -> ManagedVM {
        let ownerBundle = VMBundle(url: vm.bundleURL)
        let operationLock = try ownerBundle.acquireDockerSidecarOperationLock(operation: "update Docker")
        defer { withExtendedLifetime(operationLock) {} }
        let currentVM = ManagedVM(
            bundleURL: vm.bundleURL,
            metadata: try ownerBundle.recoverDockerSidecarReplacementIfNeeded()
        )
        try requireStopped(currentVM, operation: "update Docker")
        try requireDockerSetup(currentVM)
        guard var settings = currentVM.metadata.dockerSidecar else {
            throw MacVMError.message("Docker is not enabled for '\(currentVM.metadata.name)'.")
        }
        let existingSidecar = ownerBundle.dockerSidecarBundle
        let existingMetadata = try existingSidecar.validateIntegrity()
        let cachedImage = try await preferredDockerImage(progress: progress)
        guard existingMetadata.requiresUpdate(to: cachedImage.image) else {
            progress?(.status("Docker sidecar already uses Fedora CoreOS \(cachedImage.image.release)."))
            return currentVM
        }

        settings.imageVersion = cachedImage.image.release
        settings.mobyVersion = nil
        return try await materializeDockerSidecar(
            for: currentVM,
            settings: &settings,
            preservingIdentityFrom: existingSidecar.identityDirectoryURL,
            preservingDataDiskFrom: existingSidecar.dataDiskURL,
            preservingMachineIdentifierFrom: existingSidecar.genericMachineIdentifierURL,
            preparedImage: cachedImage,
            progress: progress
        )
    }

    public func installRosettaIfNeeded() async throws {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            return
        case .notSupported:
            throw MacVMError.message("Rosetta for Linux is not supported on this host.")
        case .notInstalled:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                VZLinuxRosettaDirectoryShare.installRosetta { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        @unknown default:
            throw MacVMError.message("The host returned an unknown Rosetta for Linux availability state.")
        }
    }

    private func materializeDockerSidecar(
        for vm: ManagedVM,
        settings: inout DockerSidecarSettings,
        preservingIdentityFrom identitySource: URL?,
        preservingDataDiskFrom dataDiskSource: URL? = nil,
        preservingMachineIdentifierFrom machineIdentifierSource: URL? = nil,
        preparedImage: FedoraCoreOSCachedImage? = nil,
        progress: VMOperationHandler?
    ) async throws -> ManagedVM {
        try storage.ensureRootDirectories()
        let ownerBundle = VMBundle(url: vm.bundleURL)
        let candidateID = UUID()
        let temporaryURL = vm.bundleURL.appendingPathComponent(
            "\(DockerSidecarReplacement.stagePrefix)\(candidateID.uuidString)",
            isDirectory: true
        )
        let temporarySidecar = DockerSidecarBundle(url: temporaryURL)
        let fileManager = FileManager.default
        defer {
            if !ownerBundle.hasDockerSidecarReplacementJournal {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        if let identitySource, fileManager.fileExists(atPath: identitySource.path) {
            try MacVMFileStager.copyDirectoryCloneFirst(from: identitySource, to: temporarySidecar.identityDirectoryURL)
        } else {
            try fileManager.createDirectory(at: temporarySidecar.identityDirectoryURL, withIntermediateDirectories: false)
        }
        try fileManager.createDirectory(at: temporarySidecar.ignitionDirectoryURL, withIntermediateDirectories: false)
        try ensurePairingKeys(
            in: temporarySidecar,
            requiresPendingKeys: settings.guestProvisioningVersion == 0
        )

        let cachedImage: FedoraCoreOSCachedImage
        if let preparedImage {
            cachedImage = preparedImage
        } else {
            cachedImage = try await preferredDockerImage(progress: progress)
        }
        let image = cachedImage.image
        settings.imageVersion = image.release
        try Task.checkCancellation()
        progress?(.status("Creating the per-VM Fedora CoreOS system disk..."))
        try MacVMFileStager.copyCloneFirst(from: cachedImage.rawImageURL, to: temporarySidecar.systemDiskURL)
        if let dataDiskSource {
            progress?(.status("Preserving Docker images, containers, and volumes..."))
            try MacVMFileStager.copyCloneFirst(from: dataDiskSource, to: temporarySidecar.dataDiskURL)
            try temporarySidecar.growDataDisk(to: settings.dataDiskSizeBytes)
        } else {
            try temporarySidecar.createSparseDataDisk(sizeBytes: settings.dataDiskSizeBytes)
        }
        let machineIdentifier: VZGenericMachineIdentifier
        if let machineIdentifierSource {
            try MacVMFileStager.copyCloneFirst(
                from: machineIdentifierSource,
                to: temporarySidecar.genericMachineIdentifierURL
            )
            machineIdentifier = try temporarySidecar.loadGenericMachineIdentifier()
        } else {
            machineIdentifier = try temporarySidecar.createGenericMachineIdentifier()
        }
        let machineDigest = DockerSidecarBundle.sha256Hex(machineIdentifier.dataRepresentation)
        try temporarySidecar.createEFIVariableStore()

        let dockerKey = try publicKey(at: temporarySidecar.dockerAuthorizedKeyURL)
        let mountKey = try publicKey(at: temporarySidecar.mountBrokerAuthorizedKeyURL)
        let ignition = try DockerIgnitionBuilder(
            settings: settings,
            dockerAuthorizedKey: dockerKey,
            mountBrokerAuthorizedKey: mountKey,
            linuxHostPrivateKey: try String(contentsOf: temporarySidecar.linuxHostPrivateKeyURL, encoding: .utf8),
            linuxHostPublicKey: try String(contentsOf: temporarySidecar.linuxHostPublicKeyURL, encoding: .utf8),
            genericMachineIdentifierDigest: machineDigest
        ).makeData()
        try ignition.write(to: temporarySidecar.initialIgnitionURL, options: .atomic)
        try temporarySidecar.writeMetadata(DockerSidecarMetadata(
            image: image,
            genericMachineIdentifierDigest: machineDigest,
            replacementCandidateID: candidateID
        ))
        _ = try temporarySidecar.validateIntegrity()

        let updatedMetadata = try DockerSidecarReplacement.commit(
            ownerBundle: ownerBundle,
            stageSidecar: temporarySidecar,
            candidateID: candidateID,
            previousSettings: vm.metadata.dockerSidecar,
            intendedSettings: settings
        )
        ownerBundle.clearDockerSidecarRuntimeDescriptor()
        progress?(.status("Docker sidecar \(image.release) is prepared; guest integration will complete on the next normal start."))
        return ManagedVM(bundleURL: vm.bundleURL, metadata: updatedMetadata)
    }

    private func preferredDockerImage(
        progress: VMOperationHandler?
    ) async throws -> FedoraCoreOSCachedImage {
        try storage.ensureRootDirectories()
        return try await FedoraCoreOSImageProvider(
            cacheDirectory: storage.dockerImageCacheDirectory
        ).preferredImage(
            automaticRefresh: dockerImageAutoRefreshOverride
                ?? MacVMSettings.shared.dockerImageAutoRefreshEnabled,
            progress: progress
        )
    }

    private func ensurePairingKeys(
        in sidecar: DockerSidecarBundle,
        requiresPendingKeys: Bool
    ) throws {
        try ensureKeyPair(
            privateKeyURL: sidecar.pendingDockerPrivateKeyURL,
            publicKeyURL: sidecar.pendingDockerPublicKeyURL,
            authorizedKeyURL: sidecar.dockerAuthorizedKeyURL,
            comment: "macvm-docker-forward",
            requiresPendingKeys: requiresPendingKeys
        )
        try ensureKeyPair(
            privateKeyURL: sidecar.pendingMountBrokerPrivateKeyURL,
            publicKeyURL: sidecar.pendingMountBrokerPublicKeyURL,
            authorizedKeyURL: sidecar.mountBrokerAuthorizedKeyURL,
            comment: "macvm-mount-broker",
            requiresPendingKeys: requiresPendingKeys
        )
        if !FileManager.default.fileExists(atPath: sidecar.linuxHostPrivateKeyURL.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = [
                "-q", "-t", "ed25519", "-N", "", "-C", "macvm-sidecar-host",
                "-f", sidecar.linuxHostPrivateKeyURL.path,
            ]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MacVMError.message("ssh-keygen failed while creating the Docker sidecar host identity.")
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: sidecar.linuxHostPrivateKeyURL.path
            )
        }
    }

    private func ensureKeyPair(
        privateKeyURL: URL,
        publicKeyURL: URL,
        authorizedKeyURL: URL,
        comment: String,
        requiresPendingKeys: Bool
    ) throws {
        let fileManager = FileManager.default
        let plan = DockerSidecarPairingKeyMaterialPlan.make(
            requiresPendingKeys: requiresPendingKeys,
            hasAuthorizedKey: fileManager.fileExists(atPath: authorizedKeyURL.path),
            hasPendingPrivateKey: fileManager.fileExists(atPath: privateKeyURL.path),
            hasPendingPublicKey: fileManager.fileExists(atPath: publicKeyURL.path)
        )
        switch plan {
        case .reuse:
            return
        case .installAuthorizedKey:
            try MacVMFileStager.copyCloneFirst(from: publicKeyURL, to: authorizedKeyURL)
        case .regenerate:
            for url in [privateKeyURL, publicKeyURL, authorizedKeyURL]
                where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", privateKeyURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MacVMError.message("ssh-keygen failed while creating the Docker sidecar pairing identity.")
            }
            try MacVMFileStager.copyCloneFirst(from: publicKeyURL, to: authorizedKeyURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
    }

    private func publicKey(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requireDockerSetup(_ vm: ManagedVM) throws {
        let setupKey = VMBundle(url: vm.bundleURL).setupPrivateKeyURL
        guard vm.metadata.setupCompletedAt != nil,
              vm.metadata.setupUsername != nil,
              FileManager.default.fileExists(atPath: setupKey.path) else {
            throw MacVMError.message("Docker requires a completed SSH-ready macOS setup. Run `macvm setup \(vm.metadata.name)` first.")
        }
    }

    private func requireStopped(_ vm: ManagedVM, operation: String) throws {
        guard !hasLiveRuntime(for: vm),
              VMBundle(url: vm.bundleURL).liveDockerSidecarRuntimeDescriptor() == nil else {
            throw MacVMError.message("Stop '\(vm.metadata.name)' before attempting to \(operation).")
        }
    }

    private func validateDockerResources(
        _ configuration: DockerSidecarResourceConfiguration,
        owner: VMMetadata
    ) throws {
        try validateDockerResources(
            configuration,
            ownerMemorySizeBytes: owner.memorySizeBytes
        )
    }

    func validateDockerResources(
        _ configuration: DockerSidecarResourceConfiguration,
        ownerMemorySizeBytes: UInt64
    ) throws {
        let minCPU = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maxCPU = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        guard (minCPU...maxCPU).contains(configuration.cpuCount) else {
            throw MacVMError.message("Docker CPU count must be between \(minCPU) and \(maxCPU).")
        }
        guard (VZVirtualMachineConfiguration.minimumAllowedMemorySize...VZVirtualMachineConfiguration.maximumAllowedMemorySize)
            .contains(configuration.memorySizeBytes) else {
            throw MacVMError.message("Docker memory must be between \(VMText.gibLabel(for: VZVirtualMachineConfiguration.minimumAllowedMemorySize)) and \(VMText.gibLabel(for: VZVirtualMachineConfiguration.maximumAllowedMemorySize)).")
        }
        guard configuration.dataDiskSizeBytes >= oneGiB,
              configuration.dataDiskSizeBytes <= UInt64(Int64.max) else {
            throw MacVMError.message("Docker data disk size must be at least 1 GiB.")
        }
        let combinedMemory = ownerMemorySizeBytes.addingReportingOverflow(configuration.memorySizeBytes)
        guard !combinedMemory.overflow, combinedMemory.partialValue <= ProcessInfo.processInfo.physicalMemory else {
            throw MacVMError.message("The macOS VM and Docker sidecar request more memory than this host has available.")
        }
    }
}
