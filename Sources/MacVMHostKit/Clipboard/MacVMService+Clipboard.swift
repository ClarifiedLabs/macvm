import Darwin
import Foundation
import MacVMClipboardProtocol

/// Shared enrolled-host-key SSH helpers for privileged provisioning paths.
/// Where a bundle already carries out-of-band enrolled host keys, these render
/// a validated per-host known-hosts file so every privileged `GuestSSH` call can
/// pin the guest identity instead of trusting the network on first use.
extension MacVMService {
    /// Write `Setup/provisioning-known-hosts` from the enrolled host keys and
    /// return it; nil when the bundle predates host-key enrollment. Pass a host
    /// to bind the file to one address, or nil to cover any resolved guest
    /// address (wildcard host patterns).
    func provisioningKnownHostsFile(bundle: VMBundle, host: String?) throws -> URL? {
        let source = bundle.setupSSHHostKeysURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let data = try Data(contentsOf: source)
        let rendered = try ClipboardKnownHosts.render(enrolledKeys: data, host: host ?? "*")
        try FileManager.default.createDirectory(
            at: bundle.setupDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let destination = bundle.setupDirectoryURL.appendingPathComponent("provisioning-known-hosts")
        try rendered.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    /// Strict-pinned when enrolled host keys exist; legacy bundles without an
    /// enrolled key keep the relaxed TOFU default rather than failing.
    func provisioningGuestSSH(host: String, user: String, identityFile: URL?, bundle: VMBundle) throws -> GuestSSH {
        if let knownHosts = try provisioningKnownHostsFile(bundle: bundle, host: host) {
            return GuestSSH(
                host: host,
                user: user,
                identityFile: identityFile,
                knownHostsFile: knownHosts,
                requirePinnedHostKey: true
            )
        }
        return GuestSSH(host: host, user: user, identityFile: identityFile)
    }
}

enum ClipboardKnownHosts {
    private static let allowedAlgorithms = [
        "ssh-ed25519",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "ssh-rsa",
    ]

    static func render(enrolledKeys data: Data, host: String) throws -> Data {
        guard !host.isEmpty,
              !host.contains(where: \.isWhitespace),
              let raw = String(data: data, encoding: .utf8) else {
            throw MacVMError.message("The enrolled guest SSH host keys are invalid.")
        }
        let keys = raw.split(whereSeparator: \.isNewline).map { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  allowedAlgorithms.contains(String(fields[0])),
                  let decoded = Data(base64Encoded: String(fields[1])),
                  !decoded.isEmpty else {
                return nil
            }
            return "\(fields[0]) \(fields[1])"
        }
        guard !keys.isEmpty, keys.allSatisfy({ $0 != nil }) else {
            throw MacVMError.message("The enrolled guest SSH host keys are invalid.")
        }
        let rendered = keys.compactMap { $0 }.map { "\(host) \($0)" }.joined(separator: "\n") + "\n"
        return Data(rendered.utf8)
    }
}

extension MacVMService {
    public func setAutomaticClipboardSync(
        _ enabled: Bool,
        for vm: ManagedVM
    ) throws -> ManagedVM {
        let bundle = VMBundle(url: vm.bundleURL)
        let metadata = try bundle.updateMetadata { metadata in
            metadata.automaticClipboardSyncEnabled = enabled
        }
        return ManagedVM(bundleURL: vm.bundleURL, metadata: metadata)
    }

    public func installClipboardHelper(
        for vm: ManagedVM,
        progress: VMOperationHandler? = nil
    ) async throws -> ClipboardGuestInstallDisposition {
        let bundle = VMBundle(url: vm.bundleURL)
        guard vm.metadata.setupCompletedAt != nil,
              let user = vm.metadata.setupUsername,
              FileManager.default.fileExists(atPath: bundle.setupPrivateKeyURL.path) else {
            throw MacVMError.message(
                "Clipboard helper installation requires completed setup, a setup username, and the per-VM SSH key. Run `macvm setup \(vm.metadata.name)` first."
            )
        }
        let host = try resolveGuestIP(vm)
        let disposition = try await installClipboardHelper(
            for: vm,
            host: host,
            user: user,
            identityFile: bundle.setupPrivateKeyURL,
            progress: progress
        )
        // A successful explicit install repairs any failure recorded during setup.
        _ = try bundle.updateMetadata { metadata in
            metadata.clipboardHelperInstallError = nil
        }
        return disposition
    }

    func installClipboardHelperDuringSetup(
        for vm: ManagedVM,
        host: String,
        user: String,
        progress: VMOperationHandler? = nil
    ) async throws -> ClipboardGuestInstallDisposition {
        try await installClipboardHelper(
            for: vm,
            host: host,
            user: user,
            identityFile: VMBundle(url: vm.bundleURL).setupPrivateKeyURL,
            progress: progress
        )
    }

    private func installClipboardHelper(
        for vm: ManagedVM,
        host: String,
        user: String,
        identityFile: URL,
        progress: VMOperationHandler?
    ) async throws -> ClipboardGuestInstallDisposition {
        let bundle = VMBundle(url: vm.bundleURL)
        // One operation lock covers pairing selection, host-key enrollment, upload,
        // and guest commit. Valid active keys are never rotated during an upgrade.
        let operationLock = try bundle.acquireClipboardOperationLock(
            operation: "install the clipboard helper"
        )
        defer { withExtendedLifetime(operationLock) {} }

        guard GuestProvisioningScript.isValidUsername(user) else {
            throw MacVMError.message("The recorded setup username is invalid.")
        }
        guard FileManager.default.fileExists(atPath: identityFile.path) else {
            throw MacVMError.message("The per-VM SSH private key is missing.")
        }
        guard let helper = Bundle.module.url(
            forResource: "macvm-clipboard-guest",
            withExtension: nil,
            subdirectory: "Clipboard"
        ) else {
            throw MacVMError.message("The bundled macvm-clipboard-guest executable is missing.")
        }
        try prepareClipboardKnownHosts(for: host, bundle: bundle)
        let secret = try ClipboardPairingStore(bundle: bundle)
            .ensureSecretWhileHoldingOperationLock(repairInvalid: true)

        let homeDirectory = "/Users/\(user)"
        let remoteSupportDirectory = "\(homeDirectory)/Library/Application Support/MacVM/Clipboard"
        let remoteStage = "\(remoteSupportDirectory)/.install-stage-\(UUID().uuidString)"
        let remoteResult = "\(remoteStage).result"
        let localStage = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macvm-clipboard-install-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: localStage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: localStage) }

        let configurationURL = localStage.appendingPathComponent("configuration.json")
        let pairingURL = localStage.appendingPathComponent("pairing.key")
        let markerURL = localStage.appendingPathComponent("installation.json")
        let plistURL = localStage.appendingPathComponent("dev.macvm.clipboard-guest.plist")
        let installScriptURL = localStage.appendingPathComponent("install.sh")
        try ClipboardGuestInstaller.configurationData(
            vmID: vm.metadata.id,
            homeDirectory: homeDirectory
        ).write(to: configurationURL, options: .atomic)
        try secret.write(to: pairingURL, options: .atomic)
        try ClipboardGuestInstaller.installationMarkerData().write(to: markerURL, options: .atomic)
        try ClipboardGuestInstaller.launchAgentData(homeDirectory: homeDirectory).write(to: plistURL, options: .atomic)
        try ClipboardGuestInstaller.installScript(
            user: user,
            homeDirectory: homeDirectory,
            remoteStage: remoteStage,
            remoteResult: remoteResult
        ).write(to: installScriptURL, atomically: true, encoding: .utf8)
        for url in [configurationURL, pairingURL, markerURL, installScriptURL] {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)

        try FileManager.default.createDirectory(at: bundle.setupDirectoryURL, withIntermediateDirectories: true)
        let ssh = GuestSSH(
            host: host,
            user: user,
            identityFile: identityFile,
            knownHostsFile: bundle.clipboardKnownHostsURL,
            requirePinnedHostKey: true
        )
        progress?(.status("Preparing clipboard helper installation..."))
        let connectionStatus = try await ssh.runQuietAsync(remoteCommand: ["true"], timeout: 15)
        guard connectionStatus == 0 else {
            throw MacVMError.message("Authenticated SSH is unavailable for clipboard helper installation.")
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: bundle.clipboardKnownHostsURL.path
        )

        let prepareStatus = try await ssh.runQuietAsync(remoteCommand: [
            "/bin/bash", "-c", GuestProvisioningScript.shellQuote(
                "set -e; install -d -m 0700 \(GuestProvisioningScript.shellQuote(remoteSupportDirectory)); rm -rf \(GuestProvisioningScript.shellQuote(remoteStage)); rm -f \(GuestProvisioningScript.shellQuote(remoteResult)); install -d -m 0700 \(GuestProvisioningScript.shellQuote(remoteStage))"
            ),
        ])
        guard prepareStatus == 0 else {
            throw MacVMError.message("Couldn't prepare clipboard helper staging inside the guest.")
        }

        var detachedInstallStarted = false
        do {
            let files: [(URL, String)] = [
                (helper, "macvm-clipboard-guest"),
                (configurationURL, "configuration.json"),
                (pairingURL, "pairing.key"),
                (markerURL, "installation.json"),
                (plistURL, "dev.macvm.clipboard-guest.plist"),
                (installScriptURL, "install.sh"),
            ]
            for (source, name) in files {
                try Task.checkCancellation()
                try await copyClipboardFileToGuest(
                    source,
                    remotePath: "\(remoteStage)/\(name)",
                    host: host,
                    user: user,
                    identityFile: identityFile,
                    knownHostsFile: bundle.clipboardKnownHostsURL
                )
            }

            progress?(.status("Installing the per-user clipboard LaunchAgent..."))
            let launchCommand = "nohup /bin/bash \(GuestProvisioningScript.shellQuote("\(remoteStage)/install.sh")) </dev/null >\(GuestProvisioningScript.shellQuote("\(remoteResult).log")) 2>&1 &"
            let launchStatus = try await ssh.runQuietAsync(
                remoteCommand: [
                    "/bin/bash", "-c", GuestProvisioningScript.shellQuote(launchCommand),
                ],
                timeout: 15
            )
            guard launchStatus == 0 else {
                throw MacVMError.message("Couldn't start the durable clipboard helper installation inside the guest.")
            }
            detachedInstallStarted = true
            let disposition = try await waitForClipboardInstallResult(
                ssh: ssh,
                resultPath: remoteResult,
                timeout: 240
            )
            _ = try? await ssh.runQuietAsync(
                remoteCommand: ["/bin/rm", "-f", remoteResult, "\(remoteResult).log"],
                timeout: 15
            )
            switch disposition {
            case .started:
                progress?(.status("Clipboard helper installed and started."))
            case .deferredUntilLogin:
                progress?(.status("Clipboard helper installed for the next GUI login."))
            case .inProgress:
                progress?(.status("Clipboard helper installation is already in progress in the guest."))
            }
            return disposition
        } catch {
            // Once detached, the journaled guest transaction owns completion and
            // recovery. Never delete its stage because the host disconnected.
            if !detachedInstallStarted {
                _ = try? await ssh.runQuietAsync(remoteCommand: [
                    "/bin/rm", "-rf", remoteStage,
                ], timeout: 15)
            }
            throw error
        }
    }

    private func waitForClipboardInstallResult(
        ssh: GuestSSH,
        resultPath: String,
        timeout: TimeInterval
    ) async throws -> ClipboardGuestInstallDisposition {
        let deadline = Date().addingTimeInterval(timeout)
        let probe = """
        if [[ ! -f \(GuestProvisioningScript.shellQuote(resultPath)) ]]; then exit 0; fi
        value=$(cat \(GuestProvisioningScript.shellQuote(resultPath)))
        case "$value" in
          started) exit 10 ;;
          deferred) exit 11 ;;
          failed:*) exit 12 ;;
          in-progress) exit 14 ;;
          *) exit 13 ;;
        esac
        """
        while Date() < deadline {
            try Task.checkCancellation()
            if let status = try? await ssh.runQuietAsync(
                remoteCommand: [
                    "/bin/bash", "-c", GuestProvisioningScript.shellQuote(probe),
                ],
                timeout: 15
            ) {
                switch status {
                case 10: return .started
                case 11: return .deferredUntilLogin
                case 12:
                    throw MacVMError.message("Clipboard helper installation rolled back inside the guest.")
                case 13:
                    throw MacVMError.message("Clipboard helper installation returned an invalid result.")
                case 14:
                    // A detached guest transaction is still running; keep waiting
                    // so its result (aliased into this result file) is reported.
                    break
                default: break
                }
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw MacVMError.message(
            "Timed out waiting for the durable clipboard helper installation; retry the command to recover its journal."
        )
    }

    private func prepareClipboardKnownHosts(for host: String, bundle: VMBundle) throws {
        let source = bundle.setupSSHHostKeysURL
        var status = stat()
        guard lstat(source.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o777 == 0o600,
              status.st_size > 0,
              status.st_size <= 64 * 1_024 else {
            throw MacVMError.message(
                "The guest SSH host key is not securely enrolled. Run setup again to enroll it over the VM shared directory before installing the clipboard helper."
            )
        }
        let descriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw MacVMError.message("Couldn't open the enrolled guest SSH host keys securely.")
        }
        defer { Darwin.close(descriptor) }
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == status.st_dev,
              openedStatus.st_ino == status.st_ino,
              openedStatus.st_mode & S_IFMT == S_IFREG,
              openedStatus.st_uid == getuid(),
              openedStatus.st_mode & 0o777 == 0o600,
              openedStatus.st_size > 0,
              openedStatus.st_size <= 64 * 1_024 else {
            throw MacVMError.message("The enrolled guest SSH host keys changed while being read.")
        }
        let data = try ClipboardDescriptorIO.readExactly(
            from: descriptor,
            count: Int(openedStatus.st_size)
        )
        let rendered = try ClipboardKnownHosts.render(enrolledKeys: data, host: host)

        try FileManager.default.createDirectory(
            at: bundle.setupDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try rendered.write(to: bundle.clipboardKnownHostsURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: bundle.clipboardKnownHostsURL.path
        )
    }

    private func copyClipboardFileToGuest(
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
        let status = try await waitForClipboardProcess(process, timeout: 120)
        guard status == 0 else {
            throw MacVMError.message("Couldn't copy \(source.lastPathComponent) into the macOS guest.")
        }
    }

    private func waitForClipboardProcess(_ process: Process, timeout: TimeInterval) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        return try await withTaskCancellationHandler {
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else {
                    process.terminate()
                    throw MacVMError.message("Guest file copy timed out after \(Int(timeout)) seconds.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return process.terminationStatus
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
