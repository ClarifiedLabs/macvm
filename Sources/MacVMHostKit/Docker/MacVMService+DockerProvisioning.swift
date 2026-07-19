import Foundation

enum DockerGuestPairingKeyPlan: Equatable {
    case installPendingKeys
    case reuseInstalledKeys

    static func make(
        vmName: String,
        guestProvisioningVersion: Int,
        hasPendingDockerKey: Bool,
        hasPendingMountBrokerKey: Bool
    ) throws -> Self {
        switch (hasPendingDockerKey, hasPendingMountBrokerKey) {
        case (true, true):
            return .installPendingKeys
        case (false, false) where guestProvisioningVersion > 0:
            return .reuseInstalledKeys
        default:
            throw MacVMError.message(
                "Docker guest integration is pending but its temporary pairing keys are missing or incomplete. Run `macvm docker reset \(vmName) --force`."
            )
        }
    }
}

extension MacVMService {
    public func provisionDockerGuestIntegration(
        for vm: ManagedVM,
        progress: VMOperationHandler? = nil
    ) async throws -> ManagedVM {
        let bundle = VMBundle(url: vm.bundleURL)
        let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "provision Docker guest integration")
        defer { withExtendedLifetime(operationLock) {} }
        let currentVM = ManagedVM(bundleURL: vm.bundleURL, metadata: try bundle.readMetadata())
        guard var settings = currentVM.metadata.dockerSidecar, settings.enabled else { return currentVM }
        guard settings.guestProvisioningState != .ready
                || settings.guestProvisioningVersion < DockerSidecarSettings.currentGuestProvisioningVersion else {
            return currentVM
        }
        let sidecar = bundle.dockerSidecarBundle
        _ = try sidecar.validateIntegrity()
        let pairingKeyPlan = try DockerGuestPairingKeyPlan.make(
            vmName: vm.metadata.name,
            guestProvisioningVersion: settings.guestProvisioningVersion,
            hasPendingDockerKey: FileManager.default.fileExists(
                atPath: sidecar.pendingDockerPrivateKeyURL.path
            ),
            hasPendingMountBrokerKey: FileManager.default.fileExists(
                atPath: sidecar.pendingMountBrokerPrivateKeyURL.path
            )
        )
        settings.guestProvisioningState = .provisioning
        var provisioningMetadata = currentVM.metadata
        provisioningMetadata.dockerSidecar = settings
        try bundle.writeMetadata(provisioningMetadata)

        do {
            try Task.checkCancellation()
            progress?(.status("Waiting for authenticated SSH before installing Docker guest integration..."))
            let user = currentVM.metadata.setupUsername ?? "admin"
            let identity = bundle.setupPrivateKeyURL
            try FileManager.default.createDirectory(at: bundle.setupDirectoryURL, withIntermediateDirectories: true)
            let host = try await waitForDockerProvisioningHost(
                currentVM,
                user: user,
                identity: identity,
                knownHostsFile: bundle.dockerGuestKnownHostsURL
            )
            let ssh = GuestSSH(
                host: host,
                user: user,
                identityFile: identity,
                knownHostsFile: bundle.dockerGuestKnownHostsURL
            )
            let tools = try await DockerGuestToolsProvider(
                cacheDirectory: storage.dockerImageCacheDirectory.appendingPathComponent("guest-tools", isDirectory: true)
            ).prepare(progress: progress)
            try Task.checkCancellation()
            guard let helper = Bundle.module.url(
                forResource: "macvm-docker-guest",
                withExtension: nil,
                subdirectory: "Docker"
            ) else {
                throw MacVMError.message("The bundled macvm-docker-guest executable is missing.")
            }

            progress?(.status("Installing Docker CLI, Compose, and the path-aware guest API proxy..."))
            let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "macvm-docker-provision-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let configURL = temporaryDirectory.appendingPathComponent("docker-guest.json")
            let plistURL = temporaryDirectory.appendingPathComponent("dev.macvm.docker-guest.plist")
            try makeDockerGuestConfiguration(
                settings: settings,
                username: user,
                sidecarHostPublicKey: try String(
                    contentsOf: sidecar.linuxHostPublicKeyURL,
                    encoding: .utf8
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            ).write(to: configURL, options: .atomic)
            try makeDockerGuestLaunchDaemon().write(to: plistURL, options: .atomic)

            let remoteDirectory = "/tmp/macvm-docker-provision"
            let prepareStatus = try await ssh.runQuietAsync(remoteCommand: [
                "rm", "-rf", remoteDirectory, "&&", "mkdir", "-p", remoteDirectory,
            ])
            guard prepareStatus == 0 else {
                throw MacVMError.message("Couldn't prepare Docker integration staging inside the macOS guest.")
            }
            var stagedFiles: [(URL, String)] = [
                (helper, "macvm-docker-guest"),
                (tools.dockerCLITarball, "docker-cli.tgz"),
                (tools.composePlugin, "docker-compose"),
                (configURL, "docker-guest.json"),
                (plistURL, "dev.macvm.docker-guest.plist"),
            ]
            if pairingKeyPlan == .installPendingKeys {
                stagedFiles.append(contentsOf: [
                    (sidecar.pendingDockerPrivateKeyURL, "docker_ed25519"),
                    (sidecar.pendingMountBrokerPrivateKeyURL, "mount_broker_ed25519"),
                ])
            }
            for (source, name) in stagedFiles {
                try Task.checkCancellation()
                try await copyToGuest(
                    source,
                    remotePath: "\(remoteDirectory)/\(name)",
                    host: host,
                    user: user,
                    identityFile: identity,
                    knownHostsFile: bundle.dockerGuestKnownHostsURL
                )
            }

            let installPairingKeys = pairingKeyPlan == .installPendingKeys
                ? """
                  install -m 0600 "$stage/docker_ed25519" '/Library/Application Support/MacVM/Identity/docker_ed25519'
                  install -m 0600 "$stage/mount_broker_ed25519" '/Library/Application Support/MacVM/Identity/mount_broker_ed25519'
                  """
                : ""
            let installScript = """
            set -euo pipefail
            stage=\(GuestProvisioningScript.shellQuote(remoteDirectory))
            install -d -m 0755 /usr/local/libexec /usr/local/bin /usr/local/lib/docker/cli-plugins
            install -d -m 0700 '/Library/Application Support/MacVM/Identity'
            install -d -m 0755 '/Library/Application Support/MacVM'
            install -m 0755 "$stage/macvm-docker-guest" /usr/local/libexec/macvm-docker-guest
            \(installPairingKeys)
            rm -rf "$stage/docker"
            tar -xzf "$stage/docker-cli.tgz" -C "$stage"
            install -m 0755 "$stage/docker/docker" /usr/local/bin/docker
            install -m 0755 "$stage/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
            dseditgroup -o create docker >/dev/null 2>&1 || true
            dseditgroup -o edit -a \(GuestProvisioningScript.shellQuote(user)) -t user docker
            install -m 0644 "$stage/docker-guest.json" '/Library/Application Support/MacVM/docker-guest.json'
            install -m 0644 "$stage/dev.macvm.docker-guest.plist" /Library/LaunchDaemons/dev.macvm.docker-guest.plist
            launchctl bootout system/dev.macvm.docker-guest >/dev/null 2>&1 || true
            for attempt in $(seq 1 40); do
              if launchctl bootstrap system /Library/LaunchDaemons/dev.macvm.docker-guest.plist; then
                break
              fi
              [[ "$attempt" -lt 40 ]] || exit 1
              sleep 0.25
            done
            launchctl kickstart -k system/dev.macvm.docker-guest
            rm -rf "$stage"
            """
            try Task.checkCancellation()
            let installStatus = try await ssh.runLoggedAsync(
                remoteCommand: ["sudo", "/bin/bash", "-c", GuestProvisioningScript.shellQuote(installScript)],
                logFile: bundle.runtimeDirectoryURL.appendingPathComponent("docker-guest-provisioning.log")
            )
            guard installStatus == 0 else {
                throw MacVMError.message(
                    "Docker guest integration failed inside macOS (status \(installStatus)). See \(bundle.runtimeDirectoryURL.appendingPathComponent("docker-guest-provisioning.log").path)."
                )
            }

            progress?(.status("Verifying the Docker helper and authenticated API path..."))
            try await waitForDockerGuestHealth(over: ssh)
            try Task.checkCancellation()

            guard let descriptor = bundle.readDockerSidecarRuntimeDescriptor(),
                  descriptor.isLive,
                  [.pendingGuestProvisioning, .ready].contains(descriptor.state) else {
                throw MacVMError.message("The Docker sidecar became unavailable while guest integration was being installed.")
            }
            var metadata = try bundle.readMetadata()
            guard var currentSettings = metadata.dockerSidecar,
                  currentSettings.enabled,
                  sameDockerSidecarIdentity(currentSettings, settings) else {
                throw MacVMError.message("Docker settings changed while guest integration was being installed.")
            }
            currentSettings.guestProvisioningState = .ready
            currentSettings.guestProvisioningVersion = DockerSidecarSettings.currentGuestProvisioningVersion
            metadata.dockerSidecar = currentSettings
            try bundle.writeMetadata(metadata)
            try? FileManager.default.removeItem(at: sidecar.pendingDockerPrivateKeyURL)
            try? FileManager.default.removeItem(at: sidecar.pendingDockerPublicKeyURL)
            try? FileManager.default.removeItem(at: sidecar.pendingMountBrokerPrivateKeyURL)
            try? FileManager.default.removeItem(at: sidecar.pendingMountBrokerPublicKeyURL)
            progress?(.status("Docker is ready inside \(currentVM.metadata.name)."))
            return ManagedVM(bundleURL: currentVM.bundleURL, metadata: metadata)
        } catch {
            let cancelled = error is CancellationError
            if var metadata = try? bundle.readMetadata(),
               var currentSettings = metadata.dockerSidecar,
               sameDockerSidecarIdentity(currentSettings, settings) {
                currentSettings.guestProvisioningState = cancelled ? .pending : .failed
                metadata.dockerSidecar = currentSettings
                try? bundle.writeMetadata(metadata)
            }
            throw error
        }
    }

    private func waitForDockerProvisioningHost(
        _ vm: ManagedVM,
        user: String,
        identity: URL,
        knownHostsFile: URL
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            if let host = try? resolveGuestIP(vm) {
                let ssh = GuestSSH(
                    host: host,
                    user: user,
                    identityFile: identity,
                    knownHostsFile: knownHostsFile
                )
                if (try? await ssh.runQuietAsync(remoteCommand: ["true"], timeout: 15)) == 0 {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: knownHostsFile.path
                    )
                    return host
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw MacVMError.message("Timed out waiting for authenticated SSH to the macOS guest before Docker provisioning.")
    }

    private func waitForDockerGuestHealth(over ssh: GuestSSH) async throws {
        let deadline = Date().addingTimeInterval(90)
        let command = "test -S /var/run/docker.sock && sudo -n launchctl print system/dev.macvm.docker-guest >/dev/null && sudo -n /usr/local/bin/docker version >/dev/null"
        while Date() < deadline {
            try Task.checkCancellation()
            if (try? await ssh.runQuietAsync(remoteCommand: [
                "/bin/bash", "-c", GuestProvisioningScript.shellQuote(command),
            ], timeout: 15)) == 0 {
                return
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw MacVMError.message("Timed out verifying the macOS Docker helper and sidecar API connection.")
    }

    private func sameDockerSidecarIdentity(
        _ lhs: DockerSidecarSettings,
        _ rhs: DockerSidecarSettings
    ) -> Bool {
        lhs.macOSMACAddress == rhs.macOSMACAddress
            && lhs.linuxPrivateMACAddress == rhs.linuxPrivateMACAddress
            && lhs.linuxNATMACAddress == rhs.linuxNATMACAddress
            && lhs.imageVersion == rhs.imageVersion
    }

    private func copyToGuest(
        _ source: URL,
        remotePath: String,
        host: String,
        user: String,
        identityFile: URL,
        knownHostsFile: URL
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = [
            "-q",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\(knownHostsFile.path)",
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=10",
            "-i", identityFile.path,
            source.path,
            "\(user)@\(host):\(remotePath)",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let status = try await waitForProvisioningProcess(process, timeout: 2 * 60)
        guard status == 0 else {
            throw MacVMError.message("Couldn't copy \(source.lastPathComponent) into the macOS guest.")
        }
    }

    private func waitForProvisioningProcess(
        _ process: Process,
        timeout: TimeInterval
    ) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        return try await withTaskCancellationHandler {
            while process.isRunning {
                try Task.checkCancellation()
                if Date() >= deadline {
                    process.terminate()
                    throw MacVMError.message("Guest file copy timed out after \(Int(timeout)) seconds.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return process.terminationStatus
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private func makeDockerGuestConfiguration(
        settings: DockerSidecarSettings,
        username: String,
        sidecarHostPublicKey: String
    ) throws -> Data {
        let value: [String: String] = [
            "privateMacOSAddress": String(settings.macOSAddress.split(separator: "/").first ?? "192.168.127.1"),
            "privateLinuxAddress": String(settings.linuxAddress.split(separator: "/").first ?? "192.168.127.2"),
            "privateMacOSMACAddress": settings.macOSMACAddress,
            "sidecarHostPublicKey": sidecarHostPublicKey,
            "setupUsername": username,
            "dockerForwardKeyPath": "/Library/Application Support/MacVM/Identity/docker_ed25519",
            "mountBrokerKeyPath": "/Library/Application Support/MacVM/Identity/mount_broker_ed25519",
            "stateDirectoryPath": "/Library/Application Support/MacVM/Docker",
            "socketGroupName": "docker",
        ]
        return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    }

    private func makeDockerGuestLaunchDaemon() throws -> Data {
        let value: [String: Any] = [
            "Label": "dev.macvm.docker-guest",
            "ProgramArguments": [
                "/usr/local/libexec/macvm-docker-guest",
                "--config",
                "/Library/Application Support/MacVM/docker-guest.json",
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "EnvironmentVariables": [
                "LLVM_PROFILE_FILE": "/tmp/macvm-docker-guest-%p.profraw",
            ],
            "StandardOutPath": "/var/log/macvm-docker-guest.log",
            "StandardErrorPath": "/var/log/macvm-docker-guest.log",
        ]
        return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
}
