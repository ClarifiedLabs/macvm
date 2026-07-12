import Foundation

protocol GuestHardenerClient: Sendable {
    var framebufferSize: (width: Int, height: Int)? { get async }

    func nudgePointer() async throws
    func pressKey(_ keysym: UInt32, modifiers: [UInt32]) async throws
    func typeText(_ text: String, holdDelay: UInt64, gapDelay: UInt64) async throws
    func click(x: Int, y: Int, button: UInt8) async throws
    func captureFramebuffer() async throws -> Framebuffer
}

extension RFBClient: GuestHardenerClient {}

struct GuestHardenerTiming: Sendable {
    var spotlightDelay: UInt64 = 1_500_000_000
    var appLaunchDelay: UInt64 = 4_000_000_000
    var finderDelay: UInt64 = 1_500_000_000
    var shortDelay: UInt64 = 700_000_000
    var statusPollDelay: UInt64 = 250_000_000
    var startTimeout: TimeInterval = 12
    var completionTimeout: TimeInterval = 90
}

enum GuestProvisioningStatus: Equatable {
    case absent
    case running
    case done
    case failed(Int)
    case unknown(String)

    static func read(from url: URL) -> GuestProvisioningStatus {
        guard let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return .absent
        }
        if value == "running" { return .running }
        if value == "done" { return .done }
        if value.hasPrefix("failed:"), let code = Int(value.dropFirst("failed:".count)) {
            return .failed(code)
        }
        return .unknown(value)
    }
}

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

    let client: any GuestHardenerClient
    let bundle: VMBundle
    let options: SetupOptions
    let progress: VMOperationHandler?
    var runID = UUID()
    var timing = GuestHardenerTiming()

    func harden() async throws {
        progress?(.status("Guest configuration: staging setup script"))
        let publicKey = try SSHKeyManager.ensureKeyPair(in: bundle)
        try bundle.ensureTransfersDirectory()

        // The account password goes in a file the script reads then deletes, so it
        // never appears on the guest command line / in `ps`.
        let passwordFileName = ".macvm-pw"
        let passwordFileURL = bundle.transfersDirectoryURL.appendingPathComponent(passwordFileName)
        try options.password.write(to: passwordFileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwordFileURL.path)

        let statusFileName = Self.statusFileName(for: runID)
        let statusFileURL = bundle.transfersDirectoryURL.appendingPathComponent(statusFileName)
        try? FileManager.default.removeItem(at: statusFileURL)

        let extraKey = try options.authorizedKeyPath.map {
            try String(contentsOf: $0, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let script = GuestProvisioningScript.build(GuestProvisioningInputs(
            username: options.username,
            password: options.password,
            authorizedKey: publicKey,
            extraAuthorizedKey: extraKey,
            enableAutoLogin: options.autoLogin,
            passwordFilePath: "\(Self.guestTransfersPath)/\(passwordFileName)",
            statusFilePath: "\(Self.guestTransfersPath)/\(statusFileName)"
        ))
        let scriptURL = bundle.transfersDirectoryURL.appendingPathComponent("provision.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // Owner-only: the script embeds authorized keys and account details.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)

        progress?(.status("Guest configuration: opening Terminal with Spotlight"))
        try await activateFinder()
        try await openTerminalWithSpotlight()
        if try await runProvisioningScript(statusFileURL: statusFileURL) {
            return
        }

        progress?(.status("Guest configuration: opening Terminal from Finder Utilities"))
        try await activateFinder()
        try await openTerminalFromFinderUtilities()
        if try await runProvisioningScript(statusFileURL: statusFileURL) {
            return
        }

        DebugLog.log("Provisioning: keyboard launch paths did not start the script; falling back to Apps.")
        for _ in 0..<2 {
            progress?(.status("Guest configuration: opening Terminal from Apps"))
            try await activateFinder()
            try await openTerminalFromLaunchpad()
            if try await runProvisioningScript(statusFileURL: statusFileURL) {
                return
            }
        }
        throw MacVMError.message("Couldn't start the provisioning script in the guest.")
    }

    private func openTerminalWithSpotlight() async throws {
        try await client.nudgePointer()
        try await client.pressKey(Keysym.space, modifiers: [Keysym.command])
        await sleep(timing.spotlightDelay)
        try await client.typeText("Terminal", holdDelay: 35_000_000, gapDelay: 90_000_000)
        await sleep(timing.spotlightDelay)
        try await client.pressKey(Keysym.returnKey, modifiers: [])
        await sleep(timing.appLaunchDelay)
        await logTerminalDetection(for: "Spotlight")
    }

    private func openTerminalFromFinderUtilities() async throws {
        // Finder's Go > Utilities shortcut avoids both Spotlight indexing and Dock layout.
        try await client.pressKey(0x75, modifiers: [Keysym.command, Keysym.shift]) // Command-Shift-U
        await sleep(timing.finderDelay)
        try await client.typeText("Terminal", holdDelay: 35_000_000, gapDelay: 90_000_000)
        await sleep(timing.spotlightDelay)
        try await client.pressKey(0x6f, modifiers: [Keysym.command]) // Command-O
        await sleep(timing.appLaunchDelay)
        await logTerminalDetection(for: "Finder Utilities")
    }

    private func runProvisioningScript(statusFileURL: URL) async throws -> Bool {
        progress?(.status("Guest configuration: starting setup script in the guest"))
        try await client.typeText(
            "bash '\(Self.guestTransfersPath)/provision.sh'",
            holdDelay: 35_000_000,
            gapDelay: 90_000_000
        )
        try await client.pressKey(Keysym.returnKey, modifiers: [])

        let startDeadline = Date().addingTimeInterval(timing.startTimeout)
        while Date() <= startDeadline {
            switch GuestProvisioningStatus.read(from: statusFileURL) {
            case .absent, .unknown:
                await sleep(timing.statusPollDelay)
            case .running:
                progress?(.status("Guest configuration: setup script is running"))
                return try await waitForProvisioningCompletion(statusFileURL: statusFileURL)
            case .done:
                progress?(.status("Guest configuration: setup script completed"))
                return true
            case .failed(let code):
                throw MacVMError.message("Guest provisioning script failed with exit code \(code).")
            }
        }
        return false
    }

    private func waitForProvisioningCompletion(statusFileURL: URL) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timing.completionTimeout)
        while Date() <= deadline {
            switch GuestProvisioningStatus.read(from: statusFileURL) {
            case .done:
                progress?(.status("Guest configuration: setup script completed"))
                return true
            case .failed(let code):
                throw MacVMError.message("Guest provisioning script failed with exit code \(code).")
            case .absent, .running, .unknown:
                await sleep(timing.statusPollDelay)
            }
        }
        throw MacVMError.message("Guest provisioning script started but did not complete within \(Int(timing.completionTimeout)) seconds.")
    }

    private func logTerminalDetection(for method: String) async {
        if await terminalIsActive() {
            DebugLog.log("Provisioning: Terminal detected after \(method) launch.")
        } else {
            DebugLog.log("Provisioning: Terminal not visible after \(method) launch; relying on shared status.")
        }
    }

    private func activateFinder() async throws {
        if await menuBarShows("Finder") {
            return
        }

        // Hide first-launch prompts from Messages/FaceTime/etc. before opening
        // Spotlight. They are harmless to the VM but can steal typed commands.
        try await client.pressKey(Keysym.escape, modifiers: [])
        try await client.pressKey(0x68, modifiers: [Keysym.command]) // Command-H
        await sleep(timing.shortDelay)

        let size = try await currentFramebufferSize()
        let point = Self.finderDockPoint(width: size.width, height: size.height)
        try await client.click(x: point.x, y: point.y, button: 1)
        await sleep(timing.finderDelay)
    }

    private func openTerminalFromLaunchpad() async throws {
        let size = try await currentFramebufferSize()
        let launchpad = Self.launchpadDockPoint(width: size.width, height: size.height)

        try await client.click(x: launchpad.x, y: launchpad.y, button: 1)
        await sleep(timing.finderDelay)
        if await foregroundAppMayStealProvisioningTyping() {
            DebugLog.log("Provisioning: Launchpad dock click opened another app; closing it before retry.")
            try await closeForegroundPrompt()
            return
        }
        try await client.typeText("Terminal", holdDelay: 35_000_000, gapDelay: 90_000_000)
        await sleep(timing.spotlightDelay)
        try await client.pressKey(Keysym.returnKey, modifiers: [])
        await sleep(timing.appLaunchDelay)
        await logTerminalDetection(for: "Apps")
    }

    private func terminalIsActive() async -> Bool {
        await menuBarShows("Terminal")
    }

    private func menuBarShows(_ appName: String) async -> Bool {
        guard let framebuffer = try? await client.captureFramebuffer() else {
            return false
        }
        return Self.menuBarShows(appName, in: OCRService.observations(in: framebuffer))
    }

    private func foregroundAppMayStealProvisioningTyping() async -> Bool {
        guard let framebuffer = try? await client.captureFramebuffer() else {
            return false
        }
        return Self.foregroundAppMayStealProvisioningTyping(in: OCRService.observations(in: framebuffer))
    }

    private func closeForegroundPrompt() async throws {
        try await client.pressKey(Keysym.escape, modifiers: [])
        await sleep(200_000_000)
        try await client.pressKey(0x77, modifiers: [Keysym.command]) // Command-W
        await sleep(500_000_000)
        if await foregroundAppMayStealProvisioningTyping() {
            try await client.pressKey(0x71, modifiers: [Keysym.command]) // Command-Q
            await sleep(1_000_000_000)
        }
    }

    static func menuBarShows(_ appName: String, in observations: [TextObservation]) -> Bool {
        observations.contains { observation in
            observation.string.caseInsensitiveCompare(appName) == .orderedSame &&
                observation.rectInPixels.minY < 45
        }
    }

    static func firstLaunchPromptIsVisible(in observations: [TextObservation]) -> Bool {
        let promptQueries = [
            "Sign in to iMessage",
            "Apple Account",
            "Sign in with your Apple Account",
            "Sign in to FaceTime",
        ]
        return promptQueries.contains { query in
            observations.contains { OCRService.queryMatches(query, candidate: $0.string) }
        }
    }

    static func foregroundAppMayStealProvisioningTyping(in observations: [TextObservation]) -> Bool {
        if firstLaunchPromptIsVisible(in: observations) {
            return true
        }

        return ["Messages", "FaceTime", "Mail", "Safari"].contains { appName in
            menuBarShows(appName, in: observations)
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
            x: max(0, min(width - 1, Int(Double(width) * 0.102))),
            y: max(0, height - 48)
        )
    }

    static func statusFileName(for runID: UUID) -> String {
        ".macvm-provision-\(runID.uuidString).status"
    }

    private func sleep(_ nanoseconds: UInt64) async {
        guard nanoseconds > 0 else { return }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private func currentFramebufferSize() async throws -> (width: Int, height: Int) {
        if let size = await client.framebufferSize {
            return size
        }

        let framebuffer = try await client.captureFramebuffer()
        return (framebuffer.width, framebuffer.height)
    }
}
