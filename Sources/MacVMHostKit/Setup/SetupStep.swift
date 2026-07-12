import CoreGraphics
import Foundation

private final class SetupDiagnostics: @unchecked Sendable {
    private static let retainedFrameCount = 20

    let directory: URL
    private let lock = NSLock()
    private var frameNames: [String] = []
    private var sequence = 0

    init(bundle: VMBundle) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        directory = bundle.setupDirectoryURL
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("\(timestamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func record(_ event: String, screen: SetupPolicy.Screen? = nil) {
        let payload: [String: Any] = lock.withLock {
            sequence += 1
            var value: [String: Any] = [
                "sequence": sequence,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "event": event,
            ]
            if let screen {
                value["framebuffer"] = ["width": screen.size.width, "height": screen.size.height]
                value["visibleText"] = SetupStepRunner.visibleTextSummary(screen.observations, limit: 20)
                value["signature"] = String(SetupPolicy.signature(of: screen.observations).hash)
            }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        let url = directory.appendingPathComponent("trace.jsonl")
        guard let bytes = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: url, options: .atomic)
        }
    }

    func recordFrame(png: Data, observations: [TextObservation], width: Int, height: Int) {
        let frameName: String = lock.withLock {
            sequence += 1
            return String(format: "frame-%05d", sequence)
        }
        let pngURL = directory.appendingPathComponent("\(frameName).png")
        let textURL = directory.appendingPathComponent("\(frameName).txt")
        try? png.write(to: pngURL, options: .atomic)
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
        let header = "confidence  x,y wxh  text (framebuffer \(width)x\(height))"
        try? ([header] + lines).joined(separator: "\n").write(to: textURL, atomically: true, encoding: .utf8)

        let expired: [String] = lock.withLock {
            frameNames.append(frameName)
            guard frameNames.count > Self.retainedFrameCount else { return [] }
            let count = frameNames.count - Self.retainedFrameCount
            let removed = Array(frameNames.prefix(count))
            frameNames.removeFirst(count)
            return removed
        }
        for name in expired {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).png"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).txt"))
        }
    }

    func finishSuccessfully() {
        let names = lock.withLock { frameNames }
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).png"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).txt"))
        }
        record("setup assistant completed")
    }
}

/// One step in a Setup Assistant flow. A flat, Codable shape so flows can ship as
/// data and be overridden by a user-supplied JSON file.
public struct SetupStep: Codable, Equatable, Sendable {
    public enum ScreenGoal: String, Codable, Sendable {
        case loginWindowOrDesktop
        case desktop

        var query: String {
            switch self {
            case .loginWindowOrDesktop:
                return "Finder|Enter Password"
            case .desktop:
                return "Finder"
            }
        }

        func match(in screen: SetupPolicy.Screen) -> GuestTextMatch? {
            if self == .loginWindowOrDesktop,
               let password = OCRService.match("Enter Password", in: screen.observations) {
                return password
            }

            guard screen.size.height > 0 else { return nil }
            let menuBarLimit = screen.size.height * 0.12
            guard let finder = OCRService.findAll("Finder", in: screen.observations).first(where: {
                $0.center.y <= menuBarLimit
            }) else { return nil }
            return GuestTextMatch(
                text: finder.string,
                x: Int(finder.center.x.rounded()),
                y: Int(finder.center.y.rounded()),
                confidence: finder.confidence
            )
        }
    }

    public struct Account: Codable, Equatable, Sendable {
        public var username: String
        public var password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public enum Action: String, Codable, Sendable {
        case waitText   // wait until `text` appears via OCR
        case clickText  // wait for `text`, then click it
        case clickTextWhenText // wait for `whenText`, then click `text`
        case advanceUntilText // click known setup buttons until `text` appears
        case advanceUntilScreen // drive panes until a typed screen goal is reached
        case createAccount // fill, submit, and wait for creation of the setup account
        case type       // type `text` literally
        case repairAccountPasswordMismatch // recover from Setup Assistant's password mismatch alert
        case keys       // press each chord in `keys` (e.g. "return", "cmd+space")
        case delay      // sleep `seconds`
        case screenshot // dump a labelled screenshot (`text` = label)
        case wake       // nudge the pointer to keep the display awake
    }

    public var action: Action
    public var screenGoal: ScreenGoal?
    public var account: Account?
    public var text: String?
    public var whenText: String?
    public var keys: [String]?
    public var timeout: TimeInterval?
    public var occurrence: Int?
    public var seconds: TimeInterval?
    /// Optional per-character typing delays, in seconds. Password fields use a
    /// slower cadence than ordinary text because Setup Assistant can drop secure
    /// field keystrokes sent too quickly over VNC.
    public var typingHoldDelay: TimeInterval?
    public var typingGapDelay: TimeInterval?
    /// If true, a text-anchored step that times out is skipped instead of failing
    /// for panes that only appear on some macOS builds.
    public var optional: Bool?

    public init(
        action: Action,
        screenGoal: ScreenGoal? = nil,
        account: Account? = nil,
        text: String? = nil,
        whenText: String? = nil,
        keys: [String]? = nil,
        timeout: TimeInterval? = nil,
        occurrence: Int? = nil,
        seconds: TimeInterval? = nil,
        typingHoldDelay: TimeInterval? = nil,
        typingGapDelay: TimeInterval? = nil,
        optional: Bool? = nil
    ) {
        self.action = action
        self.screenGoal = screenGoal
        self.account = account
        self.text = text
        self.whenText = whenText
        self.keys = keys
        self.timeout = timeout
        self.occurrence = occurrence
        self.seconds = seconds
        self.typingHoldDelay = typingHoldDelay
        self.typingGapDelay = typingGapDelay
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

    public static func advanceUntilScreen(_ goal: ScreenGoal, timeout: TimeInterval = 90) -> SetupStep {
        SetupStep(action: .advanceUntilScreen, screenGoal: goal, timeout: timeout)
    }

    public static func createAccount(username: String, password: String, timeout: TimeInterval = 600) -> SetupStep {
        SetupStep(
            action: .createAccount,
            account: Account(username: username, password: password),
            timeout: timeout
        )
    }

    public static func type(
        _ text: String,
        holdDelay: TimeInterval? = nil,
        gapDelay: TimeInterval? = nil
    ) -> SetupStep {
        SetupStep(action: .type, text: text, typingHoldDelay: holdDelay, typingGapDelay: gapDelay)
    }

    public static func type(
        _ text: String,
        whenText: String,
        timeout: TimeInterval = 8,
        optional: Bool = false,
        holdDelay: TimeInterval? = nil,
        gapDelay: TimeInterval? = nil
    ) -> SetupStep {
        SetupStep(
            action: .type,
            text: text,
            whenText: whenText,
            timeout: timeout,
            typingHoldDelay: holdDelay,
            typingGapDelay: gapDelay,
            optional: optional
        )
    }

    public static func repairAccountPasswordMismatch(_ password: String, timeout: TimeInterval = 5) -> SetupStep {
        SetupStep(action: .repairAccountPasswordMismatch, text: password, timeout: timeout)
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
    private let diagnostics: SetupDiagnostics

    init(
        client: RFBClient,
        bundle: VMBundle,
        defaultTimeout: TimeInterval,
        progress: VMOperationHandler?,
        phases: [SetupPhase] = []
    ) {
        self.client = client
        self.bundle = bundle
        self.defaultTimeout = defaultTimeout
        self.progress = progress
        self.phases = phases
        diagnostics = SetupDiagnostics(bundle: bundle)
    }

    /// The pane/modal knowledge and every advancement decision live in
    /// `SetupPolicy`, which is pure and unit-testable. These shims keep the
    /// step-timeout rescue path on the same tables.
    static let rescueQueries = SetupPolicy.rescueQueries

    static func rescueMatch(in observations: [TextObservation]) -> GuestTextMatch? {
        SetupPolicy.rescueMatch(in: observations)
    }

    static func paneRule(in observations: [TextObservation]) -> SetupPolicy.PaneRule? {
        SetupPolicy.paneRule(in: observations)
    }

    static let accountPasswordMismatchQuery = "passwords don.t match"

    /// How many unexpected panes a single required step may click through
    /// before its timeout is treated as fatal. The login/desktop gates at the
    /// end of the flow may legitimately need to clear several panes in a row.
    static let maxRescueAttempts = 8
    private static let pollStatusInterval: TimeInterval = 10
    private static let setupPasswordHoldDelay: TimeInterval = 0.08
    private static let setupPasswordGapDelay: TimeInterval = 0.18

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
                diagnostics.record("step \(index) \(step.action.rawValue)")
                try await execute(step)
            } catch {
                await dumpScreenshot(label: "failure-\(index)-\(step.action.rawValue)")
                DebugLog.log("Setup step \(index) (\(step.action.rawValue)) failed: \(error.localizedDescription)")
                diagnostics.record("failed: \(error.localizedDescription)")
                throw MacVMError.message(
                    "\(error.localizedDescription) Diagnostics: \(diagnostics.directory.path)"
                )
            }
        }
        diagnostics.finishSuccessfully()
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
                    reportStatus("Setup: optional wait for “\(text)” timed out; skipping.")
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
                    reportStatus("Setup: optional click on “\(text)” not found; skipping.")
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
                    reportStatus("Setup: optional gated click on “\(text)” after “\(whenText)” not found; skipping.")
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
                    reportStatus("Setup: optional advance until “\(text)” timed out; skipping.")
                } else {
                    throw error
                }
            }

        case .advanceUntilScreen:
            guard let goal = step.screenGoal else {
                throw MacVMError.message("Setup screen-goal step is missing its goal.")
            }
            progress?(.status("Setup: advancing until \(goal.rawValue)"))
            _ = try await advanceUntilText(goal.query, timeout: step.timeout ?? defaultTimeout, screenGoal: goal)

        case .createAccount:
            guard let account = step.account else {
                throw MacVMError.message("Setup account-creation step is missing account inputs.")
            }
            try await createAccount(account, timeout: step.timeout ?? 600)

        case .type:
            guard try await shouldRunConditionalStep(step) else {
                return
            }
            let holdDelay = step.typingHoldDelay.map(Self.nanoseconds(from:)) ?? 35_000_000
            let gapDelay = step.typingGapDelay.map(Self.nanoseconds(from:)) ?? 90_000_000
            try await withInputClient { inputClient in
                try await inputClient.typeText(step.text ?? "", holdDelay: holdDelay, gapDelay: gapDelay)
            }

        case .repairAccountPasswordMismatch:
            try await repairAccountPasswordMismatch(password: step.text ?? "", timeout: step.timeout ?? 5)

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

    private func createAccount(_ account: SetupStep.Account, timeout: TimeInterval) async throws {
        progress?(.status("Setup: creating account “\(account.username)”"))
        _ = try await poll(text: "Create a.*Account|Create a Computer Account|Full Name", timeout: 30, occurrence: 0)

        if let fullName = try? await poll(text: "Full Name", timeout: 5, occurrence: 0) {
            try await click(fullName)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try await clearFocusedText(maxCharacters: max(34, account.username.count + 4))
        }
        try await withInputClient { inputClient in
            try await inputClient.typeText(account.username)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        try await enterAccountPassword(account.password, field: "^Password$")
        try await enterAccountPassword(account.password, field: "Verify Password")
        try await submitAccountForm()

        let deadline = Date().addingTimeInterval(timeout)
        let startedAt = Date()
        var nextStatusAt = startedAt
        var submitRetries = 0

        while Date() < deadline {
            if await visibleText(Self.accountPasswordMismatchQuery, timeout: 1) != nil {
                try await repairAccountPasswordMismatch(password: account.password, timeout: 5)
                continue
            }

            let screen = try await captureScreen()
            if screen.observations.isEmpty {
                try? await Task.sleep(nanoseconds: 700_000_000)
                continue
            }

            let isAccountForm = OCRService.match(
                "Create a.*Account|Create a Computer Account|Full Name|Hint \\(Optional\\)",
                in: screen.observations
            ) != nil
            let isCreating = OCRService.match("Creating account", in: screen.observations) != nil

            if !isAccountForm && !isCreating {
                return
            }

            let now = Date()
            if now >= nextStatusAt {
                let elapsed = Int(now.timeIntervalSince(startedAt))
                let state = isCreating ? "macOS is creating the account" : "waiting for account submission"
                reportStatus("Setup: \(state) (\(elapsed)s); no unrelated input will be sent")
                nextStatusAt = now.addingTimeInterval(Self.pollStatusInterval)
            }

            if !isCreating, submitRetries < 3,
               let continueButton = OCRService.match("^Continue$", in: screen.observations) {
                submitRetries += 1
                reportStatus("Setup: account form did not begin creating; retrying Continue (\(submitRetries)/3)")
                try await click(continueButton)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }

            try? await Task.sleep(nanoseconds: 700_000_000)
        }

        await dumpScreenshot(label: "account-creation-timeout")
        throw MacVMError.message(
            "Timed out after \(Int(timeout))s waiting for macOS to create account ‘\(account.username)’."
        )
    }

    private func enterAccountPassword(_ password: String, field: String) async throws {
        let match = try await poll(text: field, timeout: 15, occurrence: 0)
        try await click(match)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        try await clearFocusedText(maxCharacters: max(12, password.count + 2))
        try await withInputClient { inputClient in
            try await inputClient.typeText(
                password,
                holdDelay: Self.nanoseconds(from: Self.setupPasswordHoldDelay),
                gapDelay: Self.nanoseconds(from: Self.setupPasswordGapDelay)
            )
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func submitAccountForm() async throws {
        let continueButton = try await poll(text: "^Continue$", timeout: 20, occurrence: 0)
        try await click(continueButton)
        try? await Task.sleep(nanoseconds: 2_000_000_000)
    }

    private func repairAccountPasswordMismatch(password: String, timeout: TimeInterval) async throws {
        guard await visibleText(Self.accountPasswordMismatchQuery, timeout: timeout) != nil else {
            return
        }

        progress?(.status("Setup: password mismatch alert appeared; retrying account password entry"))
        let attempts = 2
        for attempt in 1...attempts {
            let goBack = try await poll(text: "Go Back", timeout: 10, occurrence: 0)
            try await click(goBack)
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            _ = try await poll(text: "Create a.*Account|Full Name|Hint \\(Optional\\)", timeout: 20, occurrence: 0)
            try await refillAccountPasswordFields(password: password, attempt: attempt)

            let continueButton = try await poll(text: "Continue", timeout: 15, occurrence: 0)
            try await click(continueButton)
            try? await Task.sleep(nanoseconds: 6_000_000_000)

            if await visibleText(Self.accountPasswordMismatchQuery, timeout: 2) == nil {
                return
            }

            if attempt < attempts {
                progress?(.status("Setup: password mismatch persisted; retrying account password entry again"))
            }
        }

        await dumpScreenshot(label: "account-password-mismatch")
        throw MacVMError.message("Setup Assistant reported mismatched account passwords after retrying account password entry.")
    }

    private func refillAccountPasswordFields(password: String, attempt: Int) async throws {
        let multiplier = attempt == 1 ? 1 : 1.5
        let holdDelay = Self.setupPasswordHoldDelay * multiplier
        let gapDelay = Self.setupPasswordGapDelay * multiplier

        try await refillAccountPasswordField("^Password$", password: password, holdDelay: holdDelay, gapDelay: gapDelay)
        try await refillAccountPasswordField("Verify Password", password: password, holdDelay: holdDelay, gapDelay: gapDelay)
    }

    private func refillAccountPasswordField(
        _ fieldText: String,
        password: String,
        holdDelay: TimeInterval,
        gapDelay: TimeInterval
    ) async throws {
        let field = try await poll(text: fieldText, timeout: 15, occurrence: 0)
        try await click(field)
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        try await clearFocusedText(maxCharacters: max(12, password.count + 2))
        try await withInputClient { inputClient in
            try await inputClient.typeText(
                password,
                holdDelay: Self.nanoseconds(from: holdDelay),
                gapDelay: Self.nanoseconds(from: gapDelay)
            )
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func clearFocusedText(maxCharacters: Int) async throws {
        try await withInputClient { inputClient in
            if let selectAll = Keysym.parseChord("cmd+a") {
                try await inputClient.pressKey(selectAll.key, modifiers: selectAll.modifiers)
            }
            for _ in 0..<maxCharacters {
                try await inputClient.pressKey(Keysym.backspace)
            }
        }
    }

    private func click(_ match: GuestTextMatch) async throws {
        try await withInputClient { inputClient in
            try await inputClient.click(x: match.x, y: match.y)
        }
    }

    func visibleText(_ text: String, timeout: TimeInterval) async -> GuestTextMatch? {
        try? await poll(text: text, timeout: timeout, occurrence: 0)
    }

    func visibleScreen(_ goal: SetupStep.ScreenGoal, timeout: TimeInterval) async -> GuestTextMatch? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard let screen = try? await captureScreen() else { return nil }
            if let match = goal.match(in: screen) {
                return match
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        } while Date() < deadline
        return nil
    }

    /// Last-resort recovery when a required wait/click times out: the guest is
    /// probably sitting on a pane the flow didn't anticipate (Setup Assistant
    /// reorders and inserts panes between releases). Click a known advance
    /// button, give the pane a moment to transition, and retry the step —
    /// up to `maxRescueAttempts` panes deep. Re-throws the original timeout if
    /// nothing clickable is on screen or the retries never find the target.
    private func rescueAndRetry(_ step: SetupStep, originalError: Error) async throws {
        let text = step.text ?? ""
        reportStatus("Setup: required step did not find “\(text)”; trying safe recovery clicks")

        for attempt in 1...Self.maxRescueAttempts {
            guard let rescued = await clickAnyRescueButton() else {
                let visible = await currentVisibleTextSummary()
                reportStatus("Setup rescue: no safe advance button visible while waiting for “\(text)”; visible: \(visible)")
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
        reportStatus("Setup rescue exhausted while waiting for “\(text)”")
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
                reportStatus("Setup: conditional step skipped because “\(whenText)” was not visible.")
                return false
            }
            throw error
        }
    }

    /// Perceive → decide → act → verify until `text` appears. Perception and
    /// action live here; every decision — which pane/modal owns the screen,
    /// which tactic to try next, when to give up — is `SetupPolicy.decide`,
    /// which is pure. After each action the loop measures whether the screen
    /// actually changed and feeds that back, so a click that did nothing
    /// escalates to the next rung instead of repeating forever.
    @discardableResult
    private func advanceUntilText(
        _ text: String,
        timeout: TimeInterval,
        screenGoal: SetupStep.ScreenGoal? = nil
    ) async throws -> GuestTextMatch {
        let deadline = Date().addingTimeInterval(timeout)
        let startedAt = Date()
        var nextStatusAt = startedAt.addingTimeInterval(Self.pollStatusInterval)
        var state = SetupPolicy.PolicyState()
        var screen = try await captureScreen()

        repeat {
            if let match = screenGoal?.match(in: screen) {
                diagnostics.record("reached typed goal \(screenGoal?.rawValue ?? "unknown")", screen: screen)
                return match
            }
            let policyTarget = screenGoal == nil ? text : "__macvm_typed_goal_never_matches__"
            let (decision, nextState) = SetupPolicy.decide(target: policyTarget, screen: screen, state: state)
            state = nextState
            diagnostics.record(Self.diagnosticSummary(decision), screen: screen)

            switch decision {
            case .reachedTarget(let match):
                return match

            case .stuck(let reason):
                await dumpScreenshot(label: "stuck-\(state.ladderKey.isEmpty ? "unknown" : state.ladderKey)")
                throw MacVMError.message(
                    "\(reason.summary) while advancing until “\(text)”. Last visible text: \(Self.visibleTextSummary(screen.observations))."
                )

            case .wait(let seconds):
                let now = Date()
                if now >= nextStatusAt {
                    let elapsed = Int(now.timeIntervalSince(startedAt))
                    progress?(.status("Setup: still advancing until “\(text)” (\(elapsed)s); visible: \(Self.visibleTextSummary(screen.observations))"))
                    nextStatusAt = now.addingTimeInterval(Self.pollStatusInterval)
                }
                try? await Task.sleep(nanoseconds: Self.nanoseconds(from: seconds))
                screen = try await captureScreen()

            case .act(let tactic, let ladderKey, let rationale):
                reportStatus("Setup: \(rationale)")
                let before = screen
                let outcome = try await performAndVerify(tactic, from: screen, ladderKey: ladderKey)
                state.lastActionAdvanced = outcome.advanced
                screen = outcome.screen
                if !outcome.advanced {
                    reportStatus("Setup: “\(ladderKey)” did not advance (similarity \(String(format: "%.2f", SetupPolicy.similarity(from: before, to: outcome.screen)))); escalating")
                }
            }
        } while Date() < deadline

        throw MacVMError.message("Timed out after \(Int(timeout))s advancing until “\(text)”. Last visible text: \(Self.visibleTextSummary(screen.observations)).")
    }

    /// Run an entire action transaction on one newest VNC connection. This is
    /// important for Virtualization.framework's private server, which may route
    /// input to the newest client: resolving on one connection and clicking on
    /// another races previews and attached viewers.
    private func performAndVerify(
        _ tactic: SetupPolicy.Tactic,
        from fallbackScreen: SetupPolicy.Screen,
        ladderKey: String
    ) async throws -> (advanced: Bool, screen: SetupPolicy.Screen) {
        let anchor = SetupPolicy.anchor(forLadderKey: ladderKey)
        if let session = bundle.liveVNCSession() {
            return try await RFBClient.withConnection(port: session.port, password: session.password) { actionClient in
                try? await actionClient.nudgePointer()
                try? await Task.sleep(nanoseconds: 400_000_000)
                let current = try await captureScreen(using: actionClient)
                if SetupPolicy.didAdvance(from: fallbackScreen, to: current, anchor: anchor) {
                    return (true, current)
                }
                try await perform(tactic, on: current, using: actionClient)
                return try await awaitScreenChange(from: current, anchor: anchor, using: actionClient)
            }
        }

        try await perform(tactic, on: fallbackScreen, using: client)
        return try await awaitScreenChange(from: fallbackScreen, anchor: anchor, using: client)
    }

    /// Nudge the display awake, let it settle, then capture and OCR one frame.
    /// An asleep guest serves a blank point-sized framebuffer that OCRs to
    /// nothing; retry a few times so a sleep blink doesn't reach the policy as
    /// a phantom "screen changed" or hide the pane we're on. A guest that is
    /// genuinely showing a blank screen (mid-transition) falls through after
    /// the retries and the policy waits.
    private func captureScreen() async throws -> SetupPolicy.Screen {
        var screen = try await captureScreenOnce()
        var retries = 0
        while screen.observations.isEmpty && retries < 3 {
            retries += 1
            try? await Task.sleep(nanoseconds: 700_000_000)
            screen = try await captureScreenOnce()
        }
        return screen
    }

    private func captureScreen(using captureClient: RFBClient) async throws -> SetupPolicy.Screen {
        var screen = try await captureScreenOnce(using: captureClient)
        var retries = 0
        while screen.observations.isEmpty && retries < 3 {
            retries += 1
            try? await Task.sleep(nanoseconds: 700_000_000)
            screen = try await captureScreenOnce(using: captureClient)
        }
        return screen
    }

    private func captureScreenOnce() async throws -> SetupPolicy.Screen {
        try? await nudgeDisplay()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let framebuffer = try await captureFramebufferForOCR()
        return SetupPolicy.Screen(
            observations: OCRService.observations(in: framebuffer),
            size: CGSize(width: framebuffer.width, height: framebuffer.height)
        )
    }

    private func captureScreenOnce(using captureClient: RFBClient) async throws -> SetupPolicy.Screen {
        try? await captureClient.nudgePointer()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let framebuffer = try await captureClient.captureFramebuffer()
        publishPreview(framebuffer)
        return SetupPolicy.Screen(
            observations: OCRService.observations(in: framebuffer),
            size: CGSize(width: framebuffer.width, height: framebuffer.height)
        )
    }

    /// Execute a tactic's atoms in order. Clicks after the first re-resolve
    /// against a fresh capture because earlier atoms may have moved the layout;
    /// a query that no longer matches abandons the tactic — the verify step
    /// then reports "did not advance" and the policy escalates.
    private func perform(
        _ tactic: SetupPolicy.Tactic,
        on screen: SetupPolicy.Screen,
        using actionClient: RFBClient
    ) async throws {
        // Input sent to an asleep display is consumed as a wake event and the
        // click never lands. Wake it just before acting, not only at capture
        // time — an aggressive guest can blank in the gap between the two.
        try? await actionClient.nudgePointer()
        try? await Task.sleep(nanoseconds: 250_000_000)

        var observations = screen.observations
        for (index, atom) in tactic.atoms.enumerated() {
            switch atom {
            case .click(let query):
                if index > 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if let framebuffer = try? await actionClient.captureFramebuffer() {
                        publishPreview(framebuffer)
                        observations = OCRService.observations(in: framebuffer)
                    }
                }
                guard let match = OCRService.match(query, in: observations) else {
                    reportStatus("Setup: “\(query)” is not on screen mid-tactic; abandoning this attempt")
                    return
                }
                try await actionClient.click(x: match.x, y: match.y)

            case .clickMatch(let match):
                let refreshed = SetupPolicy.detectModal(in: screen)?.button ?? match
                try await actionClient.click(x: refreshed.x, y: refreshed.y)

            case .keys(let keys):
                try await pressKeys(keys, using: actionClient)

            case .type(let text):
                try await actionClient.typeText(text)

            case .delay(let seconds):
                try await Task.sleep(nanoseconds: Self.nanoseconds(from: seconds))
            }
        }
    }

    /// Give the guest a moment to transition, then poll for a visible change.
    /// Patience matters more than speed: declaring "did not advance" on a pane
    /// that merely transitions slowly escalates to a redundant tactic, so poll
    /// several times and return as soon as the screen moves. Returns the last
    /// capture either way so the caller reuses it as the next perception.
    private func awaitScreenChange(
        from before: SetupPolicy.Screen,
        anchor: String?,
        using captureClient: RFBClient
    ) async throws -> (advanced: Bool, screen: SetupPolicy.Screen) {
        try? await Task.sleep(nanoseconds: 700_000_000)
        var latest = before
        for attempt in 0..<4 {
            latest = try await captureScreen(using: captureClient)
            if SetupPolicy.didAdvance(from: before, to: latest, anchor: anchor) {
                return (true, latest)
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        return (false, latest)
    }

    private func pressKeys(_ keys: [String], using inputClient: RFBClient) async throws {
        for token in keys {
            guard let chord = Keysym.parseChord(token) else {
                throw MacVMError.message("Unknown key in setup pane action: '\(token)'")
            }
            try await inputClient.pressKey(chord.key, modifiers: chord.modifiers)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
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

    private func poll(text: String, timeout: TimeInterval, occurrence: Int) async throws -> GuestTextMatch {
        let deadline = Date().addingTimeInterval(timeout)
        let startedAt = Date()
        var nextStatusAt = startedAt.addingTimeInterval(Self.pollStatusInterval)
        var lastVisibleSummary = "none"
        repeat {
            // Nudge, then let the display finish waking before capturing — a headless
            // guest dims its screen and an immediate capture can still be blank.
            try? await nudgeDisplay()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let framebuffer = try await captureFramebufferForOCR()
            let observations = OCRService.observations(in: framebuffer)
            lastVisibleSummary = Self.visibleTextSummary(observations)
            if let match = OCRService.match(text, in: observations, occurrence: occurrence) {
                return match
            }
            let now = Date()
            if now >= nextStatusAt {
                let elapsed = Int(now.timeIntervalSince(startedAt))
                progress?(.status("Setup: still waiting for “\(text)” (\(elapsed)s); visible: \(lastVisibleSummary)"))
                nextStatusAt = now.addingTimeInterval(Self.pollStatusInterval)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        } while Date() < deadline

        throw MacVMError.message("Timed out after \(Int(timeout))s waiting for “\(text)”. Last visible text: \(lastVisibleSummary).")
    }

    private func captureFramebufferForOCR() async throws -> Framebuffer {
        let framebuffer: Framebuffer
        if let session = bundle.liveVNCSession() {
            do {
                framebuffer = try await RFBClient.captureOnce(port: session.port, password: session.password)
                publishPreview(framebuffer)
                return framebuffer
            } catch {
                DebugLog.log("Setup: fresh VNC OCR capture failed (\(error.localizedDescription)); falling back to the control connection.")
            }
        }

        framebuffer = try await client.captureFramebuffer()
        publishPreview(framebuffer)
        return framebuffer
    }

    private func publishPreview(_ framebuffer: Framebuffer) {
        let url = bundle.setupPreviewURL
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) < 1.5 {
            return
        }
        guard let png = framebuffer.pngData() else { return }
        try? FileManager.default.createDirectory(at: bundle.runtimeDirectoryURL, withIntermediateDirectories: true)
        try? png.write(to: url, options: .atomic)
        diagnostics.recordFrame(
            png: png,
            observations: OCRService.observations(in: framebuffer),
            width: framebuffer.width,
            height: framebuffer.height
        )
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

    private func reportStatus(_ message: String) {
        DebugLog.log(message)
        progress?(.status(message))
    }

    private func currentVisibleTextSummary() async -> String {
        guard let framebuffer = try? await captureFramebufferForOCR() else {
            return "capture failed"
        }
        return Self.visibleTextSummary(OCRService.observations(in: framebuffer))
    }

    static func visibleTextSummary(_ observations: [TextObservation], limit: Int = 8) -> String {
        let sorted = observations.sorted { lhs, rhs in
            if abs(lhs.rectInPixels.minY - rhs.rectInPixels.minY) > 8 {
                return lhs.rectInPixels.minY < rhs.rectInPixels.minY
            }
            return lhs.rectInPixels.minX < rhs.rectInPixels.minX
        }

        var summary: [String] = []
        for observation in sorted {
            let compacted = observation.string
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !compacted.isEmpty else { continue }

            let clipped = compacted.count > 48 ? "\(compacted.prefix(45))..." : compacted
            guard !summary.contains(clipped) else { continue }

            summary.append(clipped)
            if summary.count == limit {
                break
            }
        }

        return summary.isEmpty ? "none" : summary.joined(separator: " | ")
    }

    private static func diagnosticSummary(_ decision: SetupPolicy.Decision) -> String {
        switch decision {
        case .reachedTarget(let match):
            return "reached target via \(match.text)"
        case .act(let tactic, let ladderKey, _):
            return "act \(ladderKey): \(tactic.summary)"
        case .wait(let seconds):
            return "wait \(seconds)s"
        case .stuck(let reason):
            return "stuck: \(reason.summary)"
        }
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        UInt64((max(0, seconds) * 1_000_000_000).rounded())
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
