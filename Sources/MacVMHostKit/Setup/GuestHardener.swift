import Foundation

/// Runs the post-Setup-Assistant provisioning: stage a script + credentials into
/// the shared folder, then open Terminal in the guest and run it.
///
/// Only one fragile line is typed blindly (`bash …/provision.sh`); everything else
/// lives in the staged script. This also survives the macOS 26 compositor bug that
/// can leave guest windows unrendered over VNC — the keystrokes reach the guest
/// even when Terminal doesn't visibly draw.
struct GuestHardener {
    /// The guest-side mount point of the bundle's `Shared/Transfers` folder.
    static let guestTransfersPath = "/Volumes/My Shared Files/Transfers"

    let client: RFBClient
    let bundle: VMBundle
    let options: SetupOptions
    let progress: VMOperationHandler?

    func harden() async throws {
        progress?(.status("Provisioning: staging setup script"))
        let publicKey = try SSHKeyManager.ensureKeyPair(in: bundle)
        try bundle.ensureTransfersDirectory()

        // The account password goes in a file the script reads then deletes, so it
        // never appears on the guest command line / in `ps`.
        let passwordFileName = ".macvm-pw"
        let passwordFileURL = bundle.transfersDirectoryURL.appendingPathComponent(passwordFileName)
        try options.password.write(to: passwordFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFileURL.path)

        let extraKey = try options.authorizedKeyPath.map {
            try String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let script = GuestProvisioningScript.build(GuestProvisioningInputs(
            username: options.username,
            password: options.password,
            authorizedKey: publicKey,
            extraAuthorizedKey: extraKey,
            enableAutoLogin: options.autoLogin,
            passwordFilePath: "\(Self.guestTransfersPath)/\(passwordFileName)"
        ))
        let scriptURL = bundle.transfersDirectoryURL.appendingPathComponent("provision.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // Owner-only: the script embeds authorized keys and account details.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)

        progress?(.status("Provisioning: opening Terminal in the guest"))
        try await activateFinder()
        try await openTerminal()

        progress?(.status("Provisioning: running setup script in the guest"))
        try await client.typeText("bash '\(Self.guestTransfersPath)/provision.sh'")
        try await client.pressKey(Keysym.returnKey)
    }

    private func openTerminal() async throws {
        try await client.nudgePointer()
        try await client.pressKey(Keysym.space, modifiers: [Keysym.command]) // Spotlight
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await client.typeText("Terminal")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await client.pressKey(Keysym.returnKey)
        try await Task.sleep(nanoseconds: 4_000_000_000) // let Terminal launch

        if await terminalIsActive() {
            return
        }

        DebugLog.log("Provisioning: Spotlight did not activate Terminal; falling back to Launchpad.")
        try await openTerminalFromLaunchpad()
        if !(await terminalIsActive()) {
            throw MacVMError.message("Couldn't open Terminal in the guest.")
        }
    }

    private func activateFinder() async throws {
        if await menuBarShows("Finder") {
            return
        }

        // Hide first-launch prompts from Messages/FaceTime/etc. before opening
        // Spotlight. They are harmless to the VM but can steal typed commands.
        try await client.pressKey(Keysym.escape)
        try await client.pressKey(0x68, modifiers: [Keysym.command]) // Command-H
        try await Task.sleep(nanoseconds: 700_000_000)

        let size = try await currentFramebufferSize()
        let point = Self.finderDockPoint(width: size.width, height: size.height)
        try await client.click(x: point.x, y: point.y)
        try await Task.sleep(nanoseconds: 1_500_000_000)
    }

    private func openTerminalFromLaunchpad() async throws {
        let size = try await currentFramebufferSize()
        let launchpad = Self.launchpadDockPoint(width: size.width, height: size.height)

        try await client.click(x: launchpad.x, y: launchpad.y)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try await client.typeText("Terminal")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await client.pressKey(Keysym.returnKey)
        try await Task.sleep(nanoseconds: 4_000_000_000)
    }

    private func terminalIsActive() async -> Bool {
        await menuBarShows("Terminal")
    }

    private func menuBarShows(_ appName: String) async -> Bool {
        guard let framebuffer = try? await client.captureFramebuffer() else {
            return false
        }
        return OCRService.observations(in: framebuffer).contains { observation in
            observation.string.caseInsensitiveCompare(appName) == .orderedSame &&
                observation.rectInPixels.minY < 45
        }
    }

    static func finderDockPoint(width: Int, height: Int) -> (x: Int, y: Int) {
        (
            x: max(0, min(width - 1, Int(Double(width) * 0.059))),
            y: max(0, height - 48)
        )
    }

    static func launchpadDockPoint(width: Int, height: Int) -> (x: Int, y: Int) {
        (
            x: max(0, min(width - 1, Int(Double(width) * 0.174))),
            y: max(0, height - 48)
        )
    }

    private func currentFramebufferSize() async throws -> (width: Int, height: Int) {
        if let size = await client.framebufferSize {
            return size
        }

        let framebuffer = try await client.captureFramebuffer()
        return (framebuffer.width, framebuffer.height)
    }
}
