import Foundation

protocol GuestHardenerClient: Sendable {
    var framebufferSize: (width: Int, height: Int)? { get async }

    func nudgePointer() async throws
    func pressKey(_ keysym: UInt32, modifiers: [UInt32]) async throws
    func typeText(_ text: String, holdDelay: UInt64, gapDelay: UInt64) async throws
    func setClipboardText(_ text: String) async throws
    func click(x: Int, y: Int, button: UInt8) async throws
    func captureFramebuffer() async throws -> Framebuffer
    func captureTextObservations() async -> [TextObservation]?
}

extension RFBClient: GuestHardenerClient {
    func captureTextObservations() async -> [TextObservation]? {
        guard let framebuffer = try? await captureFramebuffer() else {
            return nil
        }
        return OCRService.observations(in: framebuffer)
    }
}

struct GuestHardenerTiming: Sendable {
    var finderDelay: UInt64 = 1_500_000_000
    var searchDelay: UInt64 = 1_000_000_000
    var shortDelay: UInt64 = 700_000_000
    var clipboardPropagationDelay: UInt64 = 300_000_000
    var statusPollDelay: UInt64 = 250_000_000
    var terminalActivationTimeout: TimeInterval = 6
    var clipboardStartTimeout: TimeInterval = 3
    var typedStartTimeout: TimeInterval = 5
    var completionTimeout: TimeInterval = 90
}

enum GuestForegroundState: Equatable {
    case terminal
    case other
    case unreadable
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
/// The staged command is pasted atomically when possible, with conservative typing
/// as a fallback. Shared status also preserves the macOS 26 compositor workaround:
/// commands can still reach Terminal when its window does not visibly draw over VNC.
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

        progress?(.status("Guest configuration: opening Terminal from Finder Utilities"))
        try await resetToFinder()
        try await openTerminalFromFinderUtilities()
        if await terminalMayBeActive(after: "Finder Utilities") {
            if try await runProvisioningScript(statusFileURL: statusFileURL) {
                return
            }
        } else {
            progress?(.status("Guest configuration: Finder Utilities did not activate Terminal; trying Apps"))
        }

        for attempt in 1...2 {
            progress?(.status("Guest configuration: opening Terminal from Apps"))
            try await resetToFinder()
            guard try await openTerminalFromApps() else {
                continue
            }
            if await terminalMayBeActive(after: "Apps attempt \(attempt)"),
               try await runProvisioningScript(statusFileURL: statusFileURL) {
                return
            }
        }
        throw MacVMError.message("Couldn't start the provisioning script in the guest.")
    }

    private func openTerminalFromFinderUtilities() async throws {
        // Finder's Go > Utilities shortcut avoids both Spotlight indexing and Dock layout.
        try await client.pressKey(0x75, modifiers: [Keysym.command, Keysym.shift]) // Command-Shift-U
        await sleep(timing.finderDelay)
        try await client.typeText("Terminal", holdDelay: 35_000_000, gapDelay: 90_000_000)
        await sleep(timing.searchDelay)
        try await client.pressKey(0x6f, modifiers: [Keysym.command]) // Command-O
    }

    private func runProvisioningScript(statusFileURL: URL) async throws -> Bool {
        if let result = try await provisioningResult(statusFileURL: statusFileURL) {
            return result
        }

        let command = "bash '\(Self.guestTransfersPath)/provision.sh'"
        progress?(.status("Guest configuration: starting setup script in the guest"))
        let clipboardSubmitted: Bool
        do {
            try await client.setClipboardText(command)
            await sleep(timing.clipboardPropagationDelay)
            try await client.pressKey(0x76, modifiers: [Keysym.command]) // Command-V
            try await client.pressKey(Keysym.returnKey, modifiers: [])
            clipboardSubmitted = true
        } catch {
            clipboardSubmitted = false
            DebugLog.log("Provisioning: VNC clipboard injection failed: \(error.localizedDescription)")
        }

        if clipboardSubmitted,
           try await waitForProvisioningStart(
               statusFileURL: statusFileURL,
               timeout: timing.clipboardStartTimeout
           ) {
            return true
        }

        progress?(.status("Guest configuration: clipboard command did not start; retrying with keyboard"))
        DebugLog.log("Provisioning: clipboard command did not start; retrying with keyboard input.")
        try await client.pressKey(0x63, modifiers: [Keysym.control]) // Control-C
        await sleep(timing.shortDelay)
        try await client.typeText(
            command,
            holdDelay: 35_000_000,
            gapDelay: 90_000_000
        )
        try await client.pressKey(Keysym.returnKey, modifiers: [])
        return try await waitForProvisioningStart(
            statusFileURL: statusFileURL,
            timeout: timing.typedStartTimeout
        )
    }

    private func waitForProvisioningStart(statusFileURL: URL, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let result = try await provisioningResult(statusFileURL: statusFileURL) {
                return result
            }
            guard Date() < deadline else {
                return false
            }
            await sleep(timing.statusPollDelay)
        }
    }

    private func provisioningResult(statusFileURL: URL) async throws -> Bool? {
        switch GuestProvisioningStatus.read(from: statusFileURL) {
        case .absent, .unknown:
            return nil
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

    private func terminalMayBeActive(after method: String) async -> Bool {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(timing.terminalActivationTimeout)
        var latestState = GuestForegroundState.unreadable

        while true {
            latestState = await foregroundState()
            if latestState == .terminal {
                DebugLog.log(
                    "Provisioning: Terminal detected after \(method) launch in " +
                    String(format: "%.2fs.", Date().timeIntervalSince(startedAt))
                )
                return true
            }
            guard Date() < deadline else {
                break
            }
            await sleep(timing.statusPollDelay)
        }

        switch latestState {
        case .other:
            DebugLog.log("Provisioning: \(method) left another readable app in front; skipping command injection.")
            return false
        case .unreadable:
            DebugLog.log("Provisioning: framebuffer unreadable after \(method); relying on shared status.")
            return true
        case .terminal:
            return true
        }
    }

    private func resetToFinder() async throws {
        // A Spotlight or first-launch overlay can retain keyboard focus while the
        // menu bar still says Finder, so reset focus unconditionally.
        try await client.nudgePointer()
        try await client.pressKey(Keysym.escape, modifiers: [])
        try await client.pressKey(0x68, modifiers: [Keysym.command]) // Command-H
        await sleep(timing.shortDelay)

        let size = try await currentFramebufferSize()
        let point = Self.finderDockPoint(width: size.width, height: size.height)
        try await client.click(x: point.x, y: point.y, button: 1)
        await sleep(timing.finderDelay)
    }

    private func openTerminalFromApps() async throws -> Bool {
        let size = try await currentFramebufferSize()
        let apps = Self.appsDockPoint(width: size.width, height: size.height)

        try await client.click(x: apps.x, y: apps.y, button: 1)
        await sleep(timing.finderDelay)
        if await foregroundAppMayStealProvisioningTyping() {
            DebugLog.log("Provisioning: Apps dock click opened another app; closing it before retry.")
            try await closeForegroundPrompt()
            return false
        }
        try await client.typeText("Terminal", holdDelay: 35_000_000, gapDelay: 90_000_000)
        await sleep(timing.searchDelay)
        try await client.pressKey(Keysym.returnKey, modifiers: [])
        return true
    }

    private func foregroundState() async -> GuestForegroundState {
        guard let observations = await client.captureTextObservations() else {
            return .unreadable
        }
        return Self.foregroundState(in: observations)
    }

    private func foregroundAppMayStealProvisioningTyping() async -> Bool {
        guard let observations = await client.captureTextObservations() else {
            return false
        }
        return Self.foregroundAppMayStealProvisioningTyping(in: observations)
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

    static func foregroundState(in observations: [TextObservation]) -> GuestForegroundState {
        if menuBarShows("Terminal", in: observations) {
            return .terminal
        }

        let knownApps = ["Finder", "Messages", "FaceTime", "Mail", "Safari", "System Settings"]
        if knownApps.contains(where: { menuBarShows($0, in: observations) }) {
            return .other
        }
        return .unreadable
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

    static func appsDockPoint(width: Int, height: Int) -> (x: Int, y: Int) {
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
