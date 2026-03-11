import Foundation

/// One step in a Setup Assistant flow. A flat, Codable shape so flows can ship as
/// data and be overridden by a user-supplied JSON file.
public struct SetupStep: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case waitText   // wait until `text` appears via OCR
        case clickText  // wait for `text`, then click it
        case clickTextWhenText // wait for `whenText`, then click `text`
        case advanceUntilText // click known setup buttons until `text` appears
        case type       // type `text` literally
        case keys       // press each chord in `keys` (e.g. "return", "cmd+space")
        case delay      // sleep `seconds`
        case screenshot // dump a labelled screenshot (`text` = label)
        case wake       // nudge the pointer to keep the display awake
    }

    public var action: Action
    public var text: String?
    public var whenText: String?
    public var keys: [String]?
    public var timeout: TimeInterval?
    public var occurrence: Int?
    public var seconds: TimeInterval?
    /// If true, a text-anchored step that times out is skipped instead of failing
    /// for panes that only appear on some macOS builds.
    public var optional: Bool?

    public init(
        action: Action,
        text: String? = nil,
        whenText: String? = nil,
        keys: [String]? = nil,
        timeout: TimeInterval? = nil,
        occurrence: Int? = nil,
        seconds: TimeInterval? = nil,
        optional: Bool? = nil
    ) {
        self.action = action
        self.text = text
        self.whenText = whenText
        self.keys = keys
        self.timeout = timeout
        self.occurrence = occurrence
        self.seconds = seconds
        self.optional = optional
    }

    public static func waitText(_ text: String, timeout: TimeInterval = 90, optional: Bool = false) -> SetupStep {
        SetupStep(action: .waitText, text: text, timeout: timeout, optional: optional)
    }

    public static func clickText(_ text: String, timeout: TimeInterval = 90, occurrence: Int = 0, optional: Bool = false) -> SetupStep {
        SetupStep(action: .clickText, text: text, timeout: timeout, occurrence: occurrence, optional: optional)
    }

    public static func clickText(_ text: String, whenText: String, timeout: TimeInterval = 90, occurrence: Int = 0, optional: Bool = false) -> SetupStep {
        SetupStep(action: .clickTextWhenText, text: text, whenText: whenText, timeout: timeout, occurrence: occurrence, optional: optional)
    }

    public static func advanceUntilText(_ text: String, timeout: TimeInterval = 90, optional: Bool = false) -> SetupStep {
        SetupStep(action: .advanceUntilText, text: text, timeout: timeout, optional: optional)
    }

    public static func type(_ text: String) -> SetupStep {
        SetupStep(action: .type, text: text)
    }

    public static func type(_ text: String, whenText: String, timeout: TimeInterval = 8, optional: Bool = false) -> SetupStep {
        SetupStep(action: .type, text: text, whenText: whenText, timeout: timeout, optional: optional)
    }

    public static func keys(_ keys: [String]) -> SetupStep {
        SetupStep(action: .keys, keys: keys)
    }

    public static func keys(_ keys: [String], whenText: String, timeout: TimeInterval = 8, optional: Bool = false) -> SetupStep {
        SetupStep(action: .keys, whenText: whenText, keys: keys, timeout: timeout, optional: optional)
    }

    public static func delay(_ seconds: TimeInterval) -> SetupStep {
        SetupStep(action: .delay, seconds: seconds)
    }

    public static func screenshot(_ label: String) -> SetupStep {
        SetupStep(action: .screenshot, text: label)
    }

    public static let wake = SetupStep(action: .wake)
}

/// Executes a `[SetupStep]` against a connected RFB client, OCR-anchoring each
/// wait/click and dumping a screenshot on failure so a stuck pane is debuggable.
struct SetupStepRunner {
    let client: RFBClient
    let bundle: VMBundle
    let defaultTimeout: TimeInterval
    let progress: VMOperationHandler?
    /// Display phases over the flow; entering a phase's first step emits a
    /// structured `.setupStep` event for UIs.
    var phases: [SetupPhase] = []

    /// Buttons that advance an unexpected or lingering pane, in the order a
    /// rescue pass tries them after a required step times out. Dismissive
    /// choices come before generic advancement so a rescue never opts in to
    /// anything.
    static let rescueQueries = [
        "Not Now",
        "Other Sign-In Options",
        "Set Up Later",
        "Sign in Later in Settings",
        "Don.t Use",
        "^Skip$",
        "Adult|Acult",
        "Set up as new",
        "Get Started",
        "^Agree$",
        "Agree",
        "Continue",
        "^Done$",
    ]

    private struct ModalRescue {
        let anchor: String
        let button: String
    }

    /// Foreground modal confirmations whose body text must win over stale
    /// background buttons that are still visible to OCR but no longer clickable.
    private static let modalRescues = [
        ModalRescue(
            anchor: "Mac Data Will Not Be Securely Encrypted|Securely Encrypted",
            button: "^Continue$"
        ),
    ]

    /// How many unexpected panes a single required step may click through
    /// before its timeout is treated as fatal. The login/desktop gates at the
    /// end of the flow may legitimately need to clear several panes in a row.
    static let maxRescueAttempts = 8

    func run(_ steps: [SetupStep]) async throws {
        for (index, step) in steps.enumerated() {
            for phase in phases where phase.firstStepIndex == index {
                progress?(.setupStep(SetupStepProgress(
                    phaseIndex: phase.id,
                    phaseCount: phases.count,
                    title: phase.title,
                    anchor: phase.anchor
                )))
            }
            do {
                try await execute(step)
            } catch {
                await dumpScreenshot(label: "failure-\(index)-\(step.action.rawValue)")
                DebugLog.log("Setup step \(index) (\(step.action.rawValue)) failed: \(error.localizedDescription)")
                throw error
            }
        }
    }

    private func execute(_ step: SetupStep) async throws {
        switch step.action {
        case .waitText:
            let text = step.text ?? ""
            progress?(.status("Setup: waiting for “\(text)”"))
            do {
                _ = try await poll(text: text, timeout: step.timeout ?? defaultTimeout, occurrence: step.occurrence ?? 0)
            } catch {
                if step.optional == true {
                    DebugLog.log("Setup: optional wait for “\(text)” timed out; skipping.")
                } else {
                    try await rescueAndRetry(step, originalError: error)
                }
            }

        case .clickText:
            let text = step.text ?? ""
            progress?(.status("Setup: clicking “\(text)”"))
            do {
                let match = try await poll(text: text, timeout: step.timeout ?? defaultTimeout, occurrence: step.occurrence ?? 0)
                try await withInputClient { inputClient in
                    try await inputClient.click(x: match.x, y: match.y)
                }
            } catch {
                if step.optional == true {
                    DebugLog.log("Setup: optional click on “\(text)” not found; skipping.")
                } else {
                    try await rescueAndRetry(step, originalError: error)
                }
            }

        case .clickTextWhenText:
            let text = step.text ?? ""
            let whenText = step.whenText ?? ""
            progress?(.status("Setup: clicking “\(text)” after “\(whenText)” appears"))
            do {
                try await performGatedClick(step, timeout: step.timeout ?? defaultTimeout)
            } catch {
                if step.optional == true {
                    DebugLog.log("Setup: optional gated click on “\(text)” after “\(whenText)” not found; skipping.")
                } else {
                    try await rescueAndRetry(step, originalError: error)
                }
            }

        case .advanceUntilText:
            let text = step.text ?? ""
            progress?(.status("Setup: advancing until “\(text)” appears"))
            do {
                _ = try await advanceUntilText(text, timeout: step.timeout ?? defaultTimeout)
            } catch {
                if step.optional == true {
                    DebugLog.log("Setup: optional advance until “\(text)” timed out; skipping.")
                } else {
                    throw error
                }
            }

        case .type:
            guard try await shouldRunConditionalStep(step) else {
                return
            }
            try await withInputClient { inputClient in
                try await inputClient.typeText(step.text ?? "")
            }

        case .keys:
            guard try await shouldRunConditionalStep(step) else {
                return
            }
            try await withInputClient { inputClient in
                for token in step.keys ?? [] {
                    guard let chord = Keysym.parseChord(token) else {
                        throw MacVMError.message("Unknown key in setup step: '\(token)'")
                    }
                    try await inputClient.pressKey(chord.key, modifiers: chord.modifiers)
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
            }

        case .delay:
            // Wake the display each second so it doesn't dim during the wait and
            // blank the OCR of the following step.
            let seconds = Int((step.seconds ?? 1).rounded(.up))
            for _ in 0..<max(1, seconds) {
                try? await nudgeDisplay()
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }

        case .screenshot:
            await dumpScreenshot(label: step.text ?? "screenshot")

        case .wake:
            try? await nudgeDisplay()
        }
    }

    func visibleText(_ text: String, timeout: TimeInterval) async -> GuestTextMatch? {
        try? await poll(text: text, timeout: timeout, occurrence: 0)
    }

    /// Last-resort recovery when a required wait/click times out: the guest is
    /// probably sitting on a pane the flow didn't anticipate (Setup Assistant
    /// reorders and inserts panes between releases). Click a known advance
    /// button, give the pane a moment to transition, and retry the step —
    /// up to `maxRescueAttempts` panes deep. Re-throws the original timeout if
    /// nothing clickable is on screen or the retries never find the target.
    private func rescueAndRetry(_ step: SetupStep, originalError: Error) async throws {
        let text = step.text ?? ""

        for attempt in 1...Self.maxRescueAttempts {
            guard let rescued = await clickAnyRescueButton() else {
                DebugLog.log("Setup rescue: no advance button visible; giving up on “\(text)”.")
                break
            }
            progress?(.status("Setup: unexpected pane — clicked “\(rescued.text)” to advance (rescue \(attempt)/\(Self.maxRescueAttempts))"))
            try? await Task.sleep(nanoseconds: 3_000_000_000)

            // If the rescue button itself satisfies a clickText step's query,
            // that click WAS the step — don't click the next pane's button too.
            if step.action == .clickText, OCRService.queryMatches(text, candidate: rescued.text) {
                return
            }

            let retryTimeout = min(step.timeout ?? defaultTimeout, 45)
            if step.action == .clickTextWhenText {
                if (try? await performGatedClick(step, timeout: retryTimeout)) != nil {
                    return
                }
                continue
            }

            if let match = try? await poll(text: text, timeout: retryTimeout, occurrence: step.occurrence ?? 0) {
                if step.action == .clickText {
                    try await withInputClient { inputClient in
                        try await inputClient.click(x: match.x, y: match.y)
                    }
                }
                return
            }
        }

        await dumpScreenshot(label: "rescue-exhausted-\(step.action.rawValue)")
        throw originalError
    }

    private func performGatedClick(_ step: SetupStep, timeout: TimeInterval) async throws {
        guard let whenText = step.whenText, !whenText.isEmpty else {
            throw MacVMError.message("Setup gated click is missing whenText.")
        }
        guard let text = step.text, !text.isEmpty else {
            throw MacVMError.message("Setup gated click is missing text.")
        }

        _ = try await poll(text: whenText, timeout: timeout, occurrence: 0)
        let match = try await poll(text: text, timeout: min(timeout, 20), occurrence: step.occurrence ?? 0)
        try await withInputClient { inputClient in
            try await inputClient.click(x: match.x, y: match.y)
        }
    }

    private func shouldRunConditionalStep(_ step: SetupStep) async throws -> Bool {
        guard let whenText = step.whenText, !whenText.isEmpty else {
            return true
        }

        do {
            _ = try await poll(text: whenText, timeout: step.timeout ?? 8, occurrence: 0)
            return true
        } catch {
            if step.optional == true {
                DebugLog.log("Setup: conditional step skipped because “\(whenText)” was not visible.")
                return false
            }
            throw error
        }
    }

    @discardableResult
    private func advanceUntilText(_ text: String, timeout: TimeInterval) async throws -> GuestTextMatch {
        let deadline = Date().addingTimeInterval(timeout)
        var clickCount = 0

        repeat {
            // Treat each pass as a fresh screenshot-driven decision. This avoids
            // paying one timeout per possible pane when Setup Assistant reorders
            // or skips late onboarding screens.
            try? await nudgeDisplay()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let framebuffer = try await captureFramebufferForOCR()
            let observations = OCRService.observations(in: framebuffer)

            if let match = OCRService.match(text, in: observations) {
                return match
            }

            if let match = Self.rescueMatch(in: observations) {
                clickCount += 1
                progress?(.status("Setup: clicked “\(match.text)” while advancing Setup Assistant (\(clickCount))"))
                try await withInputClient { inputClient in
                    try await inputClient.click(x: match.x, y: match.y)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        } while Date() < deadline

        throw MacVMError.message("Timed out after \(Int(timeout))s advancing until “\(text)”.")
    }

    private func clickAnyRescueButton() async -> GuestTextMatch? {
        guard let framebuffer = try? await captureFramebufferForOCR() else {
            return nil
        }
        let observations = OCRService.observations(in: framebuffer)
        guard let match = Self.rescueMatch(in: observations) else {
            return nil
        }
        do {
            try await withInputClient { inputClient in
                try await inputClient.click(x: match.x, y: match.y)
            }
            return match
        } catch {
            DebugLog.log("Setup rescue: click on “\(match.text)” failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func rescueMatch(in observations: [TextObservation]) -> GuestTextMatch? {
        for modal in modalRescues {
            guard OCRService.match(modal.anchor, in: observations) != nil else {
                continue
            }
            if let match = OCRService.match(modal.button, in: observations) {
                return match
            }
        }

        for query in rescueQueries {
            if let match = OCRService.match(query, in: observations) {
                return match
            }
        }
        return nil
    }

    private func poll(text: String, timeout: TimeInterval, occurrence: Int) async throws -> GuestTextMatch {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // Nudge, then let the display finish waking before capturing — a headless
            // guest dims its screen and an immediate capture can still be blank.
            try? await nudgeDisplay()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let framebuffer = try await captureFramebufferForOCR()
            if let match = OCRService.match(text, in: framebuffer, occurrence: occurrence) {
                return match
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        } while Date() < deadline

        throw MacVMError.message("Timed out after \(Int(timeout))s waiting for “\(text)”.")
    }

    private func captureFramebufferForOCR() async throws -> Framebuffer {
        if let session = bundle.liveVNCSession() {
            do {
                return try await RFBClient.captureOnce(port: session.port, password: session.password)
            } catch {
                DebugLog.log("Setup: fresh VNC OCR capture failed (\(error.localizedDescription)); falling back to the control connection.")
            }
        }

        return try await client.captureFramebuffer()
    }

    private func nudgeDisplay() async throws {
        try await withInputClient { inputClient in
            try await inputClient.nudgePointer()
        }
    }

    private func withInputClient<T>(_ body: (RFBClient) async throws -> T) async throws -> T {
        if let session = bundle.liveVNCSession() {
            return try await RFBClient.withConnection(port: session.port, password: session.password, body)
        }

        return try await body(client)
    }

    private func dumpScreenshot(label: String) async {
        guard let framebuffer = try? await captureFramebufferForOCR(), let png = framebuffer.pngData() else {
            return
        }
        let directory = bundle.setupDirectoryURL.appendingPathComponent("screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeLabel = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
        try? png.write(to: directory.appendingPathComponent("\(safeLabel).png"))

        // Dump what Vision recognized alongside the pixels, so an OCR miss is
        // debuggable from the artifacts alone.
        let observations = OCRService.observations(in: framebuffer)
        let header = "confidence  x,y wxh  text (framebuffer \(framebuffer.width)x\(framebuffer.height))"
        let lines = observations.map { observation in
            String(
                format: "%.2f  %d,%d %dx%d  %@",
                observation.confidence,
                Int(observation.rectInPixels.minX),
                Int(observation.rectInPixels.minY),
                Int(observation.rectInPixels.width),
                Int(observation.rectInPixels.height),
                observation.string
            )
        }
        let text = ([header] + lines).joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("\(safeLabel).txt"), atomically: true, encoding: .utf8)
    }
}
