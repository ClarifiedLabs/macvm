import CoreGraphics
import Foundation

private final class SetupDiagnostics: @unchecked Sendable {
    private static let retainedFrameCount = 20

    let directory: URL
    private let expectedWidth: Int?
    private let expectedHeight: Int?
    private let lock = NSLock()
    private var frameNames: [String] = []
    private var pinnedFrameNames = Set<String>()
    private var observedSizes: [String: Int] = [:]
    private var accountAttempts: [[String: Any]] = []
    private var lastActionableFrame: String?
    private var sequence = 0

    init(bundle: VMBundle) {
        let metadata = try? bundle.readMetadata()
        expectedWidth = metadata?.displayPixelWidth
        expectedHeight = metadata?.displayPixelHeight
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        directory = bundle.setupDirectoryURL
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("\(timestamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func record(_ event: String, screen: SetupPolicy.Screen? = nil, fields: [String: Any] = [:]) {
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
            for (key, field) in fields {
                value[key] = field
            }
            return value
        }
        append(payload)
    }

    var rfbTraceSink: @Sendable (RFBTraceEvent) -> Void {
        { [weak self] event in
            self?.recordRFB(event)
        }
    }

    func recordAccountAttempt(_ attempt: Int, result: String, fields: [String: Any] = [:]) {
        var value: [String: Any] = ["attempt": attempt, "result": result]
        for (key, field) in fields {
            value[key] = field
        }
        lock.withLock {
            accountAttempts.append(value)
        }
        record("account_attempt", fields: value)
    }

    private func recordRFB(_ event: RFBTraceEvent) {
        var fields: [String: Any] = [
            "kind": event.kind,
            "connectionID": event.connectionID,
            "purpose": event.purpose,
        ]
        for (key, value) in event.fields {
            fields[key] = value
        }
        if ["server_init", "desktop_size", "framebuffer_result"].contains(event.kind),
           let width = event.fields["width"], let height = event.fields["height"] {
            lock.withLock {
                observedSizes["\(width)x\(height)", default: 0] += 1
            }
        }
        record("rfb", fields: fields)
    }

    func shouldRecordFrame(
        observations: [TextObservation],
        width: Int,
        height: Int,
        pinned: Bool,
        previewIsFresh: Bool
    ) -> Bool {
        pinned
            || !previewIsFresh
            || observations.isEmpty
            || (expectedWidth != nil && expectedHeight != nil
                && (width != expectedWidth || height != expectedHeight))
    }

    private func append(_ payload: [String: Any]) {
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

    @discardableResult
    func recordFrame(
        png: Data,
        observations: [TextObservation],
        width: Int,
        height: Int,
        connectionID: String? = nil,
        purpose: String? = nil,
        pinned: Bool = false
    ) -> String {
        let effectivePinned = pinned
            || observations.isEmpty
            || (expectedWidth != nil && expectedHeight != nil
                && (width != expectedWidth || height != expectedHeight))
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
            if !observations.isEmpty {
                lastActionableFrame = frameName
            }
            if effectivePinned {
                pinnedFrameNames.insert(frameName)
            }
            let rolling = frameNames.filter { !pinnedFrameNames.contains($0) }
            guard rolling.count > Self.retainedFrameCount else { return [] }
            let removed = Array(rolling.prefix(rolling.count - Self.retainedFrameCount))
            frameNames.removeAll { removed.contains($0) }
            return removed
        }
        for name in expired {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).png"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).txt"))
        }
        var fields: [String: Any] = [
            "frame": frameName,
            "width": width,
            "height": height,
            "ocrCount": observations.count,
            "actionable": !observations.isEmpty,
            "pinned": effectivePinned,
        ]
        if let connectionID { fields["connectionID"] = connectionID }
        if let purpose { fields["purpose"] = purpose }
        record("frame", fields: fields)
        return frameName
    }

    func finishSuccessfully() {
        let names = lock.withLock { frameNames }
        for name in names {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).png"))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).txt"))
        }
        record("setup assistant completed")
    }

    func finishFailure(_ error: Error) {
        let summary: [String: Any] = lock.withLock {
            var value: [String: Any] = [
                "failure": error.localizedDescription,
                "observedFramebufferSizes": observedSizes,
                "accountAttempts": accountAttempts,
            ]
            if let lastActionableFrame {
                value["lastActionableFrame"] = lastActionableFrame
            }
            if let expectedWidth, let expectedHeight {
                value["expectedFramebuffer"] = ["width": expectedWidth, "height": expectedHeight]
            }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: directory.appendingPathComponent("summary.json"), options: .atomic)
    }
}

private enum OCRActionAttemptResult<T> {
    case targetMissing(String)
    case value(T)
}

private struct OCRActionTargetNotFound: LocalizedError {
    let query: String
    let timeout: TimeInterval
    let visible: String

    var errorDescription: String? {
        "Timed out after \(Int(timeout))s waiting to act on “\(query)”. Last visible text: \(visible)."
    }
}

enum AccountFormInterruption: Error, Equatable {
    case missingInformation
    case passwordMismatch
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

private enum TacticExecutionResult {
    case completed(SetupPolicy.Screen)
    case abandoned(SetupPolicy.Screen)
}

/// Executes a `[SetupStep]` against a connected RFB client, OCR-anchoring each
/// wait/click and dumping a screenshot on failure so a stuck pane is debuggable.
struct SetupStepRunner {
    static let framebufferTimeout: TimeInterval = 10
    static let laterClickCaptureAttempts = 3

    let client: RFBClient
    let bundle: VMBundle
    let defaultTimeout: TimeInterval
    let progress: VMOperationHandler?
    let ruleSet: SetupPolicy.RuleSet
    let flowIdentifier: String
    let guestRelease: MacOSRelease?
    /// Display phases over the flow; entering a phase's first step emits a
    /// structured `.setupStep` event for UIs.
    var phases: [SetupPhase] = []
    private let diagnostics: SetupDiagnostics

    init(
        client: RFBClient,
        bundle: VMBundle,
        defaultTimeout: TimeInterval,
        progress: VMOperationHandler?,
        phases: [SetupPhase] = [],
        ruleSet: SetupPolicy.RuleSet = SetupPolicy.macOS26RuleSet,
        flowIdentifier: String = "custom",
        guestRelease: MacOSRelease? = nil
    ) {
        self.client = client
        self.bundle = bundle
        self.defaultTimeout = defaultTimeout
        self.progress = progress
        self.phases = phases
        self.ruleSet = ruleSet
        self.flowIdentifier = flowIdentifier
        self.guestRelease = guestRelease
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

    static func resolveLaterClick(
        query: String,
        initialScreen: SetupPolicy.Screen,
        maxAttempts: Int = laterClickCaptureAttempts,
        capture: () async throws -> SetupPolicy.Screen
    ) async throws -> (match: GuestTextMatch?, screen: SetupPolicy.Screen) {
        var latest = initialScreen
        for _ in 0..<max(1, maxAttempts) {
            latest = try await capture()
            if let match = OCRService.match(query, in: latest.observations) {
                return (match, latest)
            }
        }
        return (nil, latest)
    }

    static let accountPasswordMismatchQuery = "passwords don.t match"
    static let accountMissingInformationQuery = "haven.t provided all of the|requested information"

    static func accountInterruption(in observations: [TextObservation]) -> AccountFormInterruption? {
        if OCRService.match(accountMissingInformationQuery, in: observations) != nil {
            return .missingInformation
        }
        if OCRService.match(accountPasswordMismatchQuery, in: observations) != nil {
            return .passwordMismatch
        }
        return nil
    }

    static func shouldRetryAccountSubmission(
        isAccountForm: Bool,
        isCreating: Bool,
        elapsed: TimeInterval
    ) -> Bool {
        isAccountForm && !isCreating && elapsed >= 5
    }

    /// How many unexpected panes a single required step may click through
    /// before its timeout is treated as fatal. The login/desktop gates at the
    /// end of the flow may legitimately need to clear several panes in a row.
    static let maxRescueAttempts = 8
    private static let pollStatusInterval: TimeInterval = 10
    private static let setupPasswordHoldDelay: TimeInterval = 0.08
    private static let setupPasswordGapDelay: TimeInterval = 0.18

    func run(_ steps: [SetupStep]) async throws {
        diagnostics.record("selected setup flow", fields: [
            "flowIdentifier": flowIdentifier,
            "guestRelease": guestRelease?.displayDescription ?? "unidentified",
        ])
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
                diagnostics.finishFailure(error)
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
                try await performOCRAction(
                    query: text,
                    timeout: step.timeout ?? defaultTimeout,
                    occurrence: step.occurrence ?? 0,
                    purpose: "setup-click-text"
                ) { inputClient, match in
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
        let deadline = Date().addingTimeInterval(timeout)
        let startedAt = Date()
        var nextStatusAt = startedAt

        accountAttempts: for attempt in 1...3 {
            guard Date() < deadline else { break }
            let multiplier = [1.0, 1.5, 2.0][attempt - 1]
            diagnostics.recordAccountAttempt(attempt, result: "started", fields: ["typingMultiplier": multiplier])
            reportStatus("Setup: account form attempt \(attempt)/3")

            do {
                _ = try await fillAccountFieldIfVisible(
                    "Full Name",
                    value: account.username,
                    secure: false,
                    multiplier: multiplier,
                    purpose: "account-full-name"
                )
                try? await Task.sleep(nanoseconds: 800_000_000)
                _ = try await fillAccountFieldIfVisible(
                    "^Account Name$",
                    value: account.username,
                    secure: false,
                    multiplier: multiplier,
                    purpose: "account-name-fallback"
                )
                _ = try await fillAccountFieldIfVisible(
                    "^Password$",
                    value: account.password,
                    secure: true,
                    multiplier: multiplier,
                    purpose: "account-password"
                )
                _ = try await fillAccountFieldIfVisible(
                    "Verify Password",
                    value: account.password,
                    secure: true,
                    multiplier: multiplier,
                    purpose: "account-verify-password"
                )
                try await performOCRAction(
                    query: "^Continue$",
                    timeout: 20,
                    purpose: "account-submit",
                    detectAccountInterruptions: true
                ) { inputClient, match in
                    try await inputClient.click(x: match.x, y: match.y)
                }
            } catch let interruption as AccountFormInterruption {
                diagnostics.recordAccountAttempt(attempt, result: String(describing: interruption))
                try await dismissAccountAlert(interruption)
                continue
            }

            let submissionStartedAt = Date()
            while Date() < deadline {
                let screen: SetupPolicy.Screen
                do {
                    screen = try await captureScreen()
                } catch RFBError.framebufferTimeout {
                    reportStatus("Setup: framebuffer capture stalled during account creation; reconnecting")
                    continue
                }
                if screen.observations.isEmpty {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                if let interruption = Self.accountInterruption(in: screen.observations) {
                    diagnostics.recordAccountAttempt(attempt, result: String(describing: interruption))
                    try await dismissAccountAlert(interruption)
                    continue accountAttempts
                }

                let isAccountForm = OCRService.match(
                    "Create a.*Account|Create a Computer Account|Full Name|Hint \\(Optional\\)",
                    in: screen.observations
                ) != nil
                let isCreating = OCRService.match("Creating account", in: screen.observations) != nil

                if !isAccountForm && !isCreating {
                    diagnostics.recordAccountAttempt(attempt, result: "completed")
                    return
                }

                let now = Date()
                if now >= nextStatusAt {
                    let elapsed = Int(now.timeIntervalSince(startedAt))
                    let state = isCreating ? "macOS is creating the account" : "waiting for account submission"
                    reportStatus("Setup: \(state) (\(elapsed)s); no unrelated input will be sent")
                    nextStatusAt = now.addingTimeInterval(Self.pollStatusInterval)
                }

                if Self.shouldRetryAccountSubmission(
                    isAccountForm: isAccountForm,
                    isCreating: isCreating,
                    elapsed: now.timeIntervalSince(submissionStartedAt)
                ) {
                    diagnostics.recordAccountAttempt(attempt, result: "form-still-visible")
                    continue accountAttempts
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }

        await dumpScreenshot(label: "account-creation-timeout")
        if Date() >= deadline {
            throw MacVMError.message(
                "Timed out after \(Int(timeout))s waiting for macOS to create account ‘\(account.username)’."
            )
        }
        throw MacVMError.message("Account creation did not advance after 3 verified form attempts.")
    }

    private func repairAccountPasswordMismatch(password: String, timeout: TimeInterval) async throws {
        guard await visibleText(Self.accountPasswordMismatchQuery, timeout: timeout) != nil else {
            return
        }
        try await dismissAccountAlert(.passwordMismatch)
        _ = try await fillAccountFieldIfVisible(
            "^Password$", value: password, secure: true, multiplier: 1.5, purpose: "repair-password"
        )
        _ = try await fillAccountFieldIfVisible(
            "Verify Password", value: password, secure: true, multiplier: 1.5, purpose: "repair-verify-password"
        )
        try await performOCRAction(
            query: "^Continue$",
            timeout: 15,
            purpose: "repair-account-submit"
        ) { inputClient, match in
            try await inputClient.click(x: match.x, y: match.y)
        }
    }

    private func fillAccountFieldIfVisible(
        _ query: String,
        value: String,
        secure: Bool,
        multiplier: Double,
        purpose: String
    ) async throws -> Bool {
        do {
            try await performOCRAction(
                query: query,
                timeout: 3,
                purpose: purpose,
                detectAccountInterruptions: true
            ) { inputClient, match in
                try await inputClient.click(x: match.x, y: match.y)
                try? await Task.sleep(nanoseconds: 700_000_000)
                try await clearFocusedText(
                    using: inputClient,
                    maxCharacters: max(secure ? 12 : 34, value.count + 4)
                )
                diagnostics.record("account_type", fields: [
                    "purpose": purpose,
                    "characterCount": value.count,
                    "secure": secure,
                    "holdDelay": secure ? Self.setupPasswordHoldDelay * multiplier : 0.035,
                    "gapDelay": secure ? Self.setupPasswordGapDelay * multiplier : 0.09,
                ])
                try await inputClient.typeText(
                    value,
                    holdDelay: Self.nanoseconds(from: secure ? Self.setupPasswordHoldDelay * multiplier : 0.035),
                    gapDelay: Self.nanoseconds(from: secure ? Self.setupPasswordGapDelay * multiplier : 0.09)
                )
            }
            return true
        } catch is OCRActionTargetNotFound {
            diagnostics.record("account_field_not_empty_or_not_visible", fields: ["purpose": purpose, "query": query])
            return false
        }
    }

    private func dismissAccountAlert(_ interruption: AccountFormInterruption) async throws {
        let label = interruption == .passwordMismatch ? "password mismatch" : "missing required information"
        reportStatus("Setup: \(label) alert appeared; returning to the account form")
        try await performOCRAction(
            query: "Go Back",
            timeout: 10,
            purpose: "account-alert-go-back"
        ) { inputClient, match in
            try await inputClient.click(x: match.x, y: match.y)
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func clearFocusedText(using inputClient: RFBClient, maxCharacters: Int) async throws {
        if let selectAll = Keysym.parseChord("cmd+a") {
            try await inputClient.pressKey(selectAll.key, modifiers: selectAll.modifiers)
        }
        for _ in 0..<maxCharacters {
            try await inputClient.pressKey(Keysym.backspace)
        }
    }

    /// Resolve OCR and perform its input on one newest connection. A point-sized
    /// blank framebuffer cannot produce a match, so it is retained as diagnostics
    /// and retried without ever supplying pointer coordinates.
    private func performOCRAction<T>(
        query: String,
        timeout: TimeInterval,
        occurrence: Int = 0,
        purpose: String,
        detectAccountInterruptions: Bool = false,
        _ action: (RFBClient, GuestTextMatch) async throws -> T
    ) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var lastVisible = "none"

        repeat {
            let attempt: OCRActionAttemptResult<T>
            if let session = bundle.liveVNCSession() {
                do {
                    attempt = try await RFBClient.withActionFramebuffer(
                        port: session.port,
                        password: session.password,
                        framebufferTimeout: Self.framebufferTimeout,
                        purpose: purpose,
                        trace: diagnostics.rfbTraceSink
                    ) { actionClient, framebuffer in
                        let identity = await actionClient.traceIdentity
                        publishPreview(
                            framebuffer,
                            connectionID: identity.connectionID,
                            purpose: identity.purpose,
                            pinned: true
                        )
                        var screen = SetupPolicy.Screen(
                            observations: OCRService.observations(in: framebuffer),
                            size: CGSize(width: framebuffer.width, height: framebuffer.height)
                        )
                        if screen.observations.isEmpty {
                            screen = try await captureScreen(using: actionClient, pinned: true)
                        }
                        if detectAccountInterruptions,
                           let interruption = Self.accountInterruption(in: screen.observations) {
                            diagnostics.record("account_interruption", fields: [
                                "connectionID": identity.connectionID,
                                "purpose": purpose,
                                "interruption": String(describing: interruption),
                                "framebuffer": ["width": screen.size.width, "height": screen.size.height],
                            ])
                            throw interruption
                        }
                        guard let match = OCRService.match(query, in: screen.observations, occurrence: occurrence) else {
                            return .targetMissing(Self.visibleTextSummary(screen.observations))
                        }
                        let redactsVisibleText = purpose.hasPrefix("account-") || purpose.hasPrefix("repair-")
                        diagnostics.record("ocr_action_match", screen: redactsVisibleText ? nil : screen, fields: [
                            "connectionID": identity.connectionID,
                            "purpose": purpose,
                            "query": query,
                            "match": match.text,
                            "x": match.x,
                            "y": match.y,
                        ])
                        let result = try await action(actionClient, match)
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        let after = try? await captureScreen(using: actionClient, pinned: true)
                        var completionFields: [String: Any] = [
                            "connectionID": identity.connectionID,
                            "purpose": purpose,
                            "query": query,
                        ]
                        if let after {
                            completionFields["framebuffer"] = ["width": after.size.width, "height": after.size.height]
                        }
                        diagnostics.record(
                            "ocr_action_complete",
                            screen: redactsVisibleText ? nil : after,
                            fields: completionFields
                        )
                        return .value(result)
                    }
                } catch RFBError.framebufferTimeout {
                    reportStatus("Setup: framebuffer capture stalled during \(purpose); reconnecting")
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
            } else {
                let screen = try await captureScreen(using: client)
                if detectAccountInterruptions,
                   let interruption = Self.accountInterruption(in: screen.observations) {
                    throw interruption
                }
                guard let match = OCRService.match(query, in: screen.observations, occurrence: occurrence) else {
                    attempt = .targetMissing(Self.visibleTextSummary(screen.observations))
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                attempt = .value(try await action(client, match))
            }

            switch attempt {
            case .value(let result):
                return result
            case .targetMissing(let visible):
                lastVisible = visible
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
        } while Date() < deadline

        throw OCRActionTargetNotFound(query: query, timeout: timeout, visible: lastVisible)
    }

    func visibleText(_ text: String, timeout: TimeInterval) async -> GuestTextMatch? {
        try? await poll(text: text, timeout: timeout, occurrence: 0)
    }

    func visibleScreen(_ goal: SetupStep.ScreenGoal, timeout: TimeInterval) async -> GuestTextMatch? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let screen = try? await captureScreen(),
               let match = goal.match(in: screen) {
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

            do {
                try await performOCRAction(
                    query: text,
                    timeout: retryTimeout,
                    occurrence: step.occurrence ?? 0,
                    purpose: "setup-rescue-retry"
                ) { inputClient, match in
                    if step.action == .clickText {
                        try await inputClient.click(x: match.x, y: match.y)
                    }
                }
                return
            } catch {
                continue
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
        try await performOCRAction(
            query: text,
            timeout: min(timeout, 20),
            occurrence: step.occurrence ?? 0,
            purpose: "setup-gated-click"
        ) { inputClient, match in
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
        var screen = try await captureScreen(retryingUntil: deadline)

        repeat {
            if let match = screenGoal?.match(in: screen) {
                diagnostics.record("reached typed goal \(screenGoal?.rawValue ?? "unknown")", screen: screen)
                return match
            }
            let policyTarget = screenGoal == nil ? text : "__macvm_typed_goal_never_matches__"
            let (decision, nextState) = SetupPolicy.decide(
                target: policyTarget,
                screen: screen,
                state: state,
                ruleSet: ruleSet
            )
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
                screen = try await captureScreen(retryingUntil: deadline)

            case .act(let tactic, let ladderKey, let rationale):
                reportStatus("Setup: \(rationale)")
                let before = screen
                let outcome: (advanced: Bool, screen: SetupPolicy.Screen)
                do {
                    outcome = try await performAndVerify(tactic, from: screen, ladderKey: ladderKey)
                } catch RFBError.framebufferTimeout {
                    reportStatus("Setup: framebuffer capture stalled during pane action; reconnecting")
                    diagnostics.record("setup pane action framebuffer timeout", fields: [
                        "ladderKey": ladderKey,
                    ])
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    screen = try await captureScreen(retryingUntil: deadline)
                    continue
                }
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
        let anchor = SetupPolicy.anchor(forLadderKey: ladderKey, ruleSet: ruleSet)
        if let session = bundle.liveVNCSession() {
            return try await RFBClient.withConnection(
                port: session.port,
                password: session.password,
                purpose: "setup-pane-action",
                trace: diagnostics.rfbTraceSink
            ) { actionClient in
                try? await actionClient.nudgePointer()
                try? await Task.sleep(nanoseconds: 400_000_000)
                let current = try await captureScreen(using: actionClient)
                if SetupPolicy.didAdvance(from: fallbackScreen, to: current, anchor: anchor, ruleSet: ruleSet) {
                    return (true, current)
                }
                switch try await perform(tactic, on: current, using: actionClient) {
                case .completed(let latest):
                    return try await awaitScreenChange(from: latest, anchor: anchor, using: actionClient)
                case .abandoned(let latest):
                    return (false, latest)
                }
            }
        }

        switch try await perform(tactic, on: fallbackScreen, using: client) {
        case .completed(let latest):
            return try await awaitScreenChange(from: latest, anchor: anchor, using: client)
        case .abandoned(let latest):
            return (false, latest)
        }
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

    private func captureScreen(retryingUntil deadline: Date) async throws -> SetupPolicy.Screen {
        repeat {
            do {
                return try await captureScreen()
            } catch RFBError.framebufferTimeout {
                reportStatus("Setup: framebuffer capture stalled; reconnecting")
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        } while Date() < deadline
        throw RFBError.framebufferTimeout
    }

    private func captureScreen(using captureClient: RFBClient, pinned: Bool = false) async throws -> SetupPolicy.Screen {
        var screen = try await captureScreenOnce(using: captureClient, pinned: pinned)
        var retries = 0
        while screen.observations.isEmpty && retries < 3 {
            retries += 1
            try? await Task.sleep(nanoseconds: 700_000_000)
            screen = try await captureScreenOnce(using: captureClient, pinned: pinned)
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

    private func captureScreenOnce(using captureClient: RFBClient, pinned: Bool = false) async throws -> SetupPolicy.Screen {
        try? await captureClient.nudgePointer()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let framebuffer = try await captureClient.captureFramebuffer(timeout: Self.framebufferTimeout)
        let identity = await captureClient.traceIdentity
        publishPreview(
            framebuffer,
            connectionID: identity.connectionID,
            purpose: identity.purpose,
            pinned: pinned
        )
        return SetupPolicy.Screen(
            observations: OCRService.observations(in: framebuffer),
            size: CGSize(width: framebuffer.width, height: framebuffer.height)
        )
    }

    /// Execute a tactic's atoms in order. Clicks after the first re-resolve
    /// against fresh captures because earlier atoms may have moved the layout.
    /// A transient OCR miss gets a small retry budget; an exhausted later click
    /// returns its latest perception without paying a separate verification loop.
    private func perform(
        _ tactic: SetupPolicy.Tactic,
        on screen: SetupPolicy.Screen,
        using actionClient: RFBClient
    ) async throws -> TacticExecutionResult {
        // Input sent to an asleep display is consumed as a wake event and the
        // click never lands. Wake it just before acting, not only at capture
        // time — an aggressive guest can blank in the gap between the two.
        try? await actionClient.nudgePointer()
        try? await Task.sleep(nanoseconds: 250_000_000)

        var latest = screen
        for (index, atom) in tactic.atoms.enumerated() {
            switch atom {
            case .click(let query):
                let match: GuestTextMatch?
                if index > 0 {
                    let resolution = try await Self.resolveLaterClick(
                        query: query,
                        initialScreen: latest
                    ) {
                        try await captureScreen(using: actionClient)
                    }
                    latest = resolution.screen
                    match = resolution.match
                } else {
                    match = OCRService.match(query, in: latest.observations)
                }
                guard let match else {
                    reportStatus("Setup: “\(query)” is not on screen mid-tactic; abandoning this attempt")
                    return .abandoned(latest)
                }
                try await actionClient.click(x: match.x, y: match.y)

            case .clickMatch(let match):
                let refreshed = SetupPolicy.detectModal(in: latest, ruleSet: ruleSet)?.button ?? match
                try await actionClient.click(x: refreshed.x, y: refreshed.y)

            case .keys(let keys):
                try await pressKeys(keys, using: actionClient)

            case .type(let text):
                try await actionClient.typeText(text)

            case .delay(let seconds):
                try await Task.sleep(nanoseconds: Self.nanoseconds(from: seconds))
            }
        }
        return .completed(latest)
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
            if SetupPolicy.didAdvance(from: before, to: latest, anchor: anchor, ruleSet: ruleSet) {
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
        guard let session = bundle.liveVNCSession() else { return nil }
        return try? await RFBClient.withConnection(
            port: session.port,
            password: session.password,
            purpose: "setup-rescue",
            trace: diagnostics.rfbTraceSink
        ) { inputClient -> GuestTextMatch? in
            try? await inputClient.nudgePointer()
            try? await Task.sleep(nanoseconds: 400_000_000)
            let screen = try await captureScreen(using: inputClient)
            guard let match = SetupPolicy.rescueMatch(in: screen.observations, ruleSet: ruleSet) else {
                return nil
            }
            do {
                try await inputClient.click(x: match.x, y: match.y)
                return match
            } catch {
                DebugLog.log("Setup rescue: click on “\(match.text)” failed: \(error.localizedDescription)")
                return nil
            }
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
            let framebuffer: Framebuffer
            do {
                framebuffer = try await captureFramebufferForOCR()
            } catch RFBError.framebufferTimeout {
                reportStatus("Setup: framebuffer capture stalled while waiting for “\(text)”; reconnecting")
                continue
            }
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
                framebuffer = try await RFBClient.captureOnce(
                    port: session.port,
                    password: session.password,
                    timeout: Self.framebufferTimeout,
                    purpose: "setup-ocr-poll",
                    trace: diagnostics.rfbTraceSink
                )
                publishPreview(framebuffer)
                return framebuffer
            } catch {
                DebugLog.log("Setup: fresh VNC OCR capture failed (\(error.localizedDescription)); falling back to the control connection.")
            }
        }

        framebuffer = try await client.captureFramebuffer(timeout: Self.framebufferTimeout)
        publishPreview(framebuffer)
        return framebuffer
    }

    private func publishPreview(
        _ framebuffer: Framebuffer,
        connectionID: String? = nil,
        purpose: String? = nil,
        pinned: Bool = false
    ) {
        let url = bundle.setupPreviewURL
        let observations = OCRService.observations(in: framebuffer)
        let previewIsFresh: Bool
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date {
            previewIsFresh = Date().timeIntervalSince(modified) < 1.5
        } else {
            previewIsFresh = false
        }
        let shouldRecord = diagnostics.shouldRecordFrame(
            observations: observations,
            width: framebuffer.width,
            height: framebuffer.height,
            pinned: pinned,
            previewIsFresh: previewIsFresh
        )
        guard shouldRecord, let png = framebuffer.pngData() else { return }
        if !previewIsFresh {
            try? FileManager.default.createDirectory(at: bundle.runtimeDirectoryURL, withIntermediateDirectories: true)
            try? png.write(to: url, options: .atomic)
        }
        if shouldRecord {
            diagnostics.recordFrame(
                png: png,
                observations: observations,
                width: framebuffer.width,
                height: framebuffer.height,
                connectionID: connectionID,
                purpose: purpose,
                pinned: pinned
            )
        }
    }

    private func nudgeDisplay() async throws {
        try await withInputClient { inputClient in
            try await inputClient.nudgePointer()
        }
    }

    private func withInputClient<T>(_ body: (RFBClient) async throws -> T) async throws -> T {
        if let session = bundle.liveVNCSession() {
            return try await RFBClient.withConnection(
                port: session.port,
                password: session.password,
                purpose: "setup-input",
                trace: diagnostics.rfbTraceSink,
                body
            )
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
