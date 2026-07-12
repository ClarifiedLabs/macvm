import CoreGraphics
import Foundation
import Testing
@testable import MacVMHostKit

// MARK: - Builders

private func obs(_ string: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double, confidence: Float = 0.95) -> TextObservation {
    TextObservation(string: string, rectInPixels: CGRect(x: x, y: y, width: w, height: h), confidence: confidence)
}

private func screen(_ observations: [TextObservation], width: Double = 2560, height: Double = 1440) -> SetupPolicy.Screen {
    SetupPolicy.Screen(observations: observations, size: CGSize(width: width, height: height))
}

private let accountTarget = "Create a.*Account|Create a Computer Account|Full Name"

private let accountScreen = screen([
    obs("Create a Computer Account", 1000, 300, 560, 40),
    obs("Full Name", 880, 500, 120, 24),
    obs("Continue", 2280, 1330, 120, 30),
])

private func actTactic(_ decision: SetupPolicy.Decision) -> SetupPolicy.Tactic? {
    if case .act(let tactic, _, _) = decision { return tactic }
    return nil
}

private func actLadderKey(_ decision: SetupPolicy.Decision) -> String? {
    if case .act(_, let ladderKey, _) = decision { return ladderKey }
    return nil
}

private func containsKeysAtom(_ decisions: [SetupPolicy.Decision]) -> Bool {
    decisions.contains { decision in
        guard let tactic = actTactic(decision) else { return false }
        return tactic.atoms.contains { atom in
            if case .keys = atom { return true }
            return false
        }
    }
}

// MARK: - Account creation and typed login goals

@Test
func accountFormIdentityDoesNotSatisfyLoginWindowGoal() {
    let form = screen([
        obs("Create a Mac Account", 900, 260, 420, 40),
        obs("admin", 900, 470, 180, 24),
        obs("Administrator", 900, 510, 220, 24),
        obs("Password", 900, 590, 160, 24),
    ])

    #expect(SetupStep.ScreenGoal.loginWindowOrDesktop.match(in: form) == nil)

    let login = screen([
        obs("Administrator", 1120, 500, 240, 32),
        obs("Enter Password", 1100, 600, 280, 30),
    ])
    #expect(SetupStep.ScreenGoal.loginWindowOrDesktop.match(in: login) != nil)

    let setupTouchID = screen([
        obs("Touch ID", 1100, 300, 240, 36),
        obs("Set Up Later", 1050, 1200, 220, 30),
    ])
    #expect(SetupStep.ScreenGoal.loginWindowOrDesktop.match(in: setupTouchID) == nil)

    let bodyMention = screen([
        obs("Open Finder after setup", 900, 500, 420, 30),
    ])
    #expect(SetupStep.ScreenGoal.desktop.match(in: bodyMention) == nil)
}

@Test
func creatingAccountIsPassiveAndNeverRescueClicked() {
    let creating = screen([
        obs("Create a Mac Account", 900, 260, 420, 40),
        obs("admin", 900, 470, 180, 24),
        obs("Creating account...", 800, 1300, 260, 28),
        obs("Continue", 2200, 1300, 140, 30),
    ])
    let decisions = runPolicy(
        target: SetupStep.ScreenGoal.loginWindowOrDesktop.query,
        screens: [creating],
        maxSteps: 8
    )

    #expect(decisions.count == 8)
    #expect(decisions.allSatisfy { decision in
        if case .wait = decision { return true }
        return false
    })
}

@Test
func creatingAccountNeverTriggersFormResubmissionEvenWhenAccountAnchorsRemainVisible() {
    #expect(!SetupStepRunner.shouldRetryAccountSubmission(
        isAccountForm: true,
        isCreating: true,
        elapsed: 60
    ))
    #expect(SetupStepRunner.shouldRetryAccountSubmission(
        isAccountForm: true,
        isCreating: false,
        elapsed: 5
    ))
}

// MARK: - The reported failure (Transfer pane, macOS 26)

@Test
func transferPaneWithoutSetUpAsNewClicksNotNowInsteadOfBlindKeys() throws {
    let transfer = try OCRDumpFixture.load("transfer-macos26")
    let decisions = runPolicy(target: accountTarget, screens: [transfer, accountScreen])

    let firstDecision = try #require(decisions.first)
    let first = try #require(actTactic(firstDecision))
    #expect(first.atoms == [.click("^Not Now$")])
    #expect(!containsKeysAtom(decisions))

    guard case .reachedTarget = try #require(decisions.last) else {
        Issue.record("expected the flow to reach the account pane, got \(decisions)")
        return
    }
}

@Test
func migrationErrorAlertIsDismissedBeforePaneDispatch() throws {
    let error = try OCRDumpFixture.load("transfer-migration-error")
    let (decision, _) = SetupPolicy.decide(target: accountTarget, screen: error, state: SetupPolicy.PolicyState())

    #expect(actLadderKey(decision) == "modal:Migration source error")
    let tactic = try #require(actTactic(decision))
    guard case .clickMatch(let match) = try #require(tactic.atoms.first) else {
        Issue.record("expected a pre-resolved modal click, got \(tactic.atoms)")
        return
    }
    // The OK button's center, not the background Continue button.
    #expect(match.text == "OK")
    #expect(match.x == 1280)
    #expect(match.y == 794)
}

@Test
func migrationErrorRecoversToNotNowAfterDismissal() throws {
    let error = try OCRDumpFixture.load("transfer-migration-error")
    let transfer = try OCRDumpFixture.load("transfer-macos26")
    let decisions = runPolicy(target: accountTarget, screens: [error, transfer, accountScreen])

    #expect(decisions.count == 3)
    #expect(actLadderKey(decisions[0]) == "modal:Migration source error")
    #expect(actTactic(decisions[1])?.atoms == [.click("^Not Now$")])
    guard case .reachedTarget = decisions[2] else {
        Issue.record("expected the flow to reach the account pane, got \(decisions)")
        return
    }
}

@Test
func transferPaneLegacyLayoutSelectsSetUpAsNewThenContinue() throws {
    let legacy = try OCRDumpFixture.load("transfer-legacy")
    let (decision, _) = SetupPolicy.decide(target: accountTarget, screen: legacy, state: SetupPolicy.PolicyState())

    #expect(actLadderKey(decision) == "pane:Transfer or Migration Assistant")
    let tactic = try #require(actTactic(decision))
    #expect(tactic.atoms == [
        .click("^Set up as new$|^Set Up as New$|^Don.t Transfer.*$"),
        .delay(0.4),
        .click("^Continue$"),
    ])
    guard case .act(_, _, let rationale) = decision else { return }
    #expect(rationale.contains("rung 1"), "the Not Now rung must be skipped by applicability, not degraded to keys")
}

@Test
func unknownTransferLayoutFailsLoudlyInsteadOfClickingContinue() throws {
    let unknown = screen([
        obs("Transfer Your Data to This Mac", 1042, 268, 476, 40),
        obs(".AssetData", 1214, 608, 132, 24),
        obs("Continue", 1848, 1008, 122, 36),
    ])
    let decisions = runPolicy(target: accountTarget, screens: [unknown], maxSteps: 12)

    #expect(decisions.allSatisfy { actTactic($0) == nil }, "an unrecognized Transfer layout must never be clicked through")
    guard case .stuck(.ladderExhausted(let ladderKey)) = try #require(decisions.last) else {
        Issue.record("expected a loud ladder-exhausted failure, got \(decisions)")
        return
    }
    #expect(ladderKey == "pane:Transfer or Migration Assistant")
}

// MARK: - Anchor shadowing regressions

@Test
func locationServicesPaneIsNotShadowedByItsConfirmationDialog() throws {
    let pane = screen([
        obs("Enable Location Services", 900, 300, 400, 36),
        obs("Location Services allows Maps and other apps to gather and use data", 900, 380, 620, 24),
        obs("Don't Use", 1700, 1330, 110, 30),
        obs("Continue", 2280, 1330, 120, 30),
    ])
    let (paneDecision, _) = SetupPolicy.decide(target: accountTarget, screen: pane, state: SetupPolicy.PolicyState())
    #expect(actLadderKey(paneDecision) == "pane:Location Services")
    #expect(actTactic(paneDecision)?.atoms == [.click("Don.t Use")])

    let confirmation = screen([
        obs("Are you sure you don't want to use Location Services?", 1050, 600, 460, 26),
        obs("You can turn Location Services on later in Privacy & Security settings.", 1040, 640, 480, 22),
        obs("Don't Use", 1180, 720, 110, 30),
        obs("Cancel", 1330, 720, 90, 30),
    ])
    let (modalDecision, _) = SetupPolicy.decide(target: accountTarget, screen: confirmation, state: SetupPolicy.PolicyState())
    #expect(actLadderKey(modalDecision) == "modal:Location Services confirmation")

    let wrappedConfirmation = screen([
        obs("Enable Location Services", 900, 300, 400, 36),
        obs("Are you sure you don't want to", 1050, 600, 360, 26),
        obs("Don't Use", 1180, 720, 110, 30),
        obs("Use Location Services", 1330, 720, 180, 30),
    ])
    let (wrappedDecision, _) = SetupPolicy.decide(
        target: accountTarget,
        screen: wrappedConfirmation,
        state: SetupPolicy.PolicyState()
    )
    #expect(actLadderKey(wrappedDecision) == "modal:Location Services confirmation")
    guard case .clickMatch(let match) = try #require(actTactic(wrappedDecision)?.atoms.first) else {
        Issue.record("expected the wrapped modal button to be pre-resolved, got \(wrappedDecision)")
        return
    }
    #expect(match.text == "Don't Use")
}

@Test
func termsAndConditionsPaneIsNotShadowedByLicenseConfirmation() throws {
    let pane = screen([
        obs("Terms and Conditions", 1000, 280, 420, 40),
        obs("Read the following terms and conditions.", 960, 340, 500, 24),
        obs("macOS Software License Agreement", 900, 420, 460, 26),
        obs("Disagree", 2140, 1330, 110, 30),
        obs("Agree", 2300, 1330, 90, 30),
    ])
    let (paneDecision, _) = SetupPolicy.decide(target: accountTarget, screen: pane, state: SetupPolicy.PolicyState())
    #expect(actLadderKey(paneDecision) == "pane:Terms and Conditions")
    #expect(actTactic(paneDecision)?.atoms == [.click("^Agree$")])

    let sheet = screen([
        obs("Terms and Conditions", 1000, 280, 420, 40),
        obs("I have read and agree to the macOS Software License Agreement.", 1030, 660, 500, 24),
        obs("Disagree", 1210, 740, 110, 30),
        obs("Agree", 1360, 740, 90, 30),
        obs("Agree", 2300, 1330, 90, 30),
    ])
    let (sheetDecision, _) = SetupPolicy.decide(target: accountTarget, screen: sheet, state: SetupPolicy.PolicyState())
    #expect(actLadderKey(sheetDecision) == "modal:License agreement confirmation")
    let tactic = try #require(actTactic(sheetDecision))
    guard case .clickMatch(let match) = try #require(tactic.atoms.first) else {
        Issue.record("expected a pre-resolved modal click, got \(tactic.atoms)")
        return
    }
    // The sheet's Agree (below the sentence), not the dimmed pane button.
    #expect(match.x == 1405)
    #expect(match.y == 755)
}

// MARK: - Escalation, oscillation, and stuck accounting

@Test
func unchangedScreenEscalatesFromPreferredClickToKeyboardRung() throws {
    let accessibility = screen([
        obs("Accessibility", 1180, 300, 200, 40),
        obs("Not Now", 2320, 1330, 110, 30),
    ])
    // Generous maxSteps: after the pane's own rungs the ladder falls through to
    // generic rescue and then waits out `maxIdleRoundsInLadder` frozen frames
    // before failing. It must still fail.
    let decisions = runPolicy(target: accountTarget, screens: [accessibility], maxSteps: 32)

    #expect(actTactic(decisions[0])?.atoms == [.click("^Not Now$")])
    #expect(actTactic(decisions[1])?.atoms == [.keys(["shift+tab", "space"])])
    guard case .stuck = try #require(decisions.last) else {
        Issue.record("a pane that never advances must end stuck, got \(decisions)")
        return
    }
}

@Test
func oscillatingPanesAreReportedAsStuckNotLoopedForever() throws {
    let accessibility = screen([
        obs("Accessibility", 1180, 300, 200, 40),
        obs("Not Now", 2320, 1330, 110, 30),
    ])
    let analytics = screen([
        obs("Analytics", 1150, 300, 220, 40),
        obs("Share Mac Analytics to help improve products", 1000, 380, 460, 24),
        obs("Continue", 2280, 1330, 120, 30),
    ])
    var script: [SetupPolicy.Screen] = []
    for _ in 0..<6 {
        script.append(accessibility)
        script.append(analytics)
    }

    let decisions = runPolicy(target: accountTarget, screens: script)
    guard case .stuck(.oscillating) = try #require(decisions.last) else {
        Issue.record("an A→B→A pane loop must be reported as oscillation, got \(decisions)")
        return
    }
}

@Test
func screenSignatureIgnoresMenuBarClockAndLowConfidenceNoise() {
    let before = screen([
        obs("10:41 AM", 2372, 10, 116, 24),
        obs("Accessibility", 1180, 300, 200, 40, confidence: 0.98),
        obs("Not Now", 2320, 1330, 110, 30, confidence: 0.97),
    ])
    let after = screen([
        obs("10:42 AM", 2372, 10, 116, 24),
        obs("Accessibility", 1180, 300, 200, 40, confidence: 0.98),
        obs("Not Now", 2320, 1330, 110, 30, confidence: 0.97),
        obs("l|1i", 140, 700, 40, 14, confidence: 0.31),
    ])

    #expect(SetupPolicy.similarity(from: before, to: after) == 1)
    #expect(!SetupPolicy.didAdvance(from: before, to: after, anchor: nil))
    #expect(SetupPolicy.signature(of: before.observations).hash == SetupPolicy.signature(of: after.observations).hash)
}

@Test
func passwordMismatchAlertIsNeverAutoDismissed() throws {
    let mismatch = screen([
        obs("The passwords don't match.", 1100, 600, 320, 26),
        obs("Go Back", 1240, 700, 100, 28),
        obs("OK", 1250, 760, 60, 30),
    ])
    let (decision, _) = SetupPolicy.decide(target: "Finder", screen: mismatch, state: SetupPolicy.PolicyState())

    guard case .stuck(.dangerousModal) = decision else {
        Issue.record("the password-mismatch alert belongs to repairAccountPasswordMismatch, got \(decision)")
        return
    }
}

@Test
func accountRequiredInformationAlertIsDetectedWhileVerifyPasswordIsObscured() {
    let missingInformation = screen([
        obs("Create a Mac Account", 800, 250, 360, 34),
        obs("You haven't provided all of the", 1060, 670, 390, 30),
        obs("requested information.", 1060, 705, 300, 26),
        obs("Go Back", 1220, 900, 115, 22),
        obs("Password", 835, 830, 120, 24),
    ])

    #expect(SetupStepRunner.accountInterruption(in: missingInformation.observations) == .missingInformation)
    #expect(OCRService.match("Verify Password", in: missingInformation.observations) == nil)
}

@Test
func accountPasswordMismatchUsesTheSameAccountInterruptionClassifier() {
    let mismatch = screen([
        obs("The passwords don't match.", 1100, 600, 320, 26),
        obs("Go Back", 1240, 700, 100, 28),
    ])

    #expect(SetupStepRunner.accountInterruption(in: mismatch.observations) == .passwordMismatch)
}

@Test
func paneAndModalRuleTitlesAreUnique() {
    // Attempt counters are keyed by ladder key; duplicate titles would merge
    // two screens' accounting.
    let paneTitles = SetupPolicy.paneRules.map(\.title)
    #expect(Set(paneTitles).count == paneTitles.count)
    let modalTitles = SetupPolicy.modalRules.map(\.title)
    #expect(Set(modalTitles).count == modalTitles.count)
}

// MARK: - Slow pane transitions (observed live: the last pre-account pane
// hands off to a multi-second OS transition, so "no change yet" is not "stuck")

@Test
func slowPaneThatEventuallyAdvancesIsNotDeclaredStuck() throws {
    // Only "Don't Use" is on screen, so once it is clicked the ladder has
    // nothing else applicable — the old policy threw ladderExhausted here even
    // though the pane was mid-transition.
    let locationServices = screen([
        obs("Enable Location Services", 900, 300, 400, 36),
        obs("Don't Use", 1700, 1330, 110, 30),
    ])
    let decisions = runPolicy(
        target: accountTarget,
        screens: [locationServices, locationServices, locationServices, accountScreen]
    )

    #expect(actTactic(decisions[0])?.atoms == [.click("Don.t Use")])
    #expect(!decisions.contains { decision in
        if case .stuck = decision { return true }
        return false
    }, "a pane that is still transitioning must be waited out, not declared stuck")
    guard case .reachedTarget = try #require(decisions.last) else {
        Issue.record("expected the slow pane to resolve to the target, got \(decisions)")
        return
    }
}

@Test
func frozenPaneWithNothingLeftToTryStillFailsLoudly() throws {
    // Same shape, but the screen never changes: the frozen-signature counter
    // must still fail the run instead of waiting for the outer timeout.
    let frozen = screen([
        obs("Enable Location Services", 900, 300, 400, 36),
        obs("Don't Use", 1700, 1330, 110, 30),
    ])
    let decisions = runPolicy(target: accountTarget, screens: [frozen], maxSteps: 32)

    guard case .stuck(.ladderExhausted(let ladderKey)) = try #require(decisions.last) else {
        Issue.record("a frozen pane must fail loudly, got \(decisions)")
        return
    }
    #expect(ladderKey == "pane:Location Services")
    #expect(decisions.count <= SetupPolicy.maxIdleRoundsInLadder + 4, "stuck must arrive promptly once frozen")
}

@Test
func automaticUpdatesHandoffToWelcomeIsWaitedOutRatherThanEscalatedToFailure() throws {
    // The reported failure: Continue was clicked, the pane sat visually
    // identical past the verify window, the ladder escalated to exhaustion and
    // threw — while Welcome was already fading in.
    let automaticUpdates = screen([
        obs("Update Mac Automatically", 900, 300, 420, 36),
        obs("Future software updates will be automatically downloaded", 880, 380, 700, 24),
        obs("Continue", 2280, 1330, 120, 30),
    ])
    let welcome = screen([
        obs("Welcome to Mac", 1100, 600, 320, 60),
        obs("Get Started", 1180, 1200, 180, 34),
    ])
    // Four identical frames: the click, the keyboard rung, and the generic
    // rescue click all "fail", exhausting the ladder — exactly the reported
    // sequence — before Welcome finally renders.
    let decisions = runPolicy(
        target: accountTarget,
        screens: [automaticUpdates, automaticUpdates, automaticUpdates, automaticUpdates, welcome, accountScreen]
    )

    #expect(actTactic(decisions[0])?.atoms == [.click("^Continue$")])
    #expect(!decisions.contains { decision in
        if case .stuck = decision { return true }
        return false
    }, "the Automatic Updates → Welcome handoff must not be declared stuck")
    #expect(decisions.contains { decision in
        if case .wait = decision { return true }
        return false
    }, "the exhausted ladder must wait out the transition")
    #expect(decisions.contains { actLadderKey($0) == "pane:Welcome to Mac" })
    guard case .reachedTarget = try #require(decisions.last) else {
        Issue.record("expected the handoff to resolve to the account pane, got \(decisions)")
        return
    }
}

// MARK: - Asleep-display blank frames (observed on a live guest: the VNC
// server serves an empty point-sized framebuffer while the display sleeps)

@Test
func blankCaptureIsNeverJudgedAsProgress() {
    let accessibility = screen([
        obs("Accessibility", 1180, 300, 200, 40),
        obs("Not Now", 2320, 1330, 110, 30),
    ])
    let blank = screen([], width: 1280, height: 720)

    // Without the guard, the anchor "disappearing" into a blank frame reads
    // as an advance and resets the escalation ladder on every sleep blink.
    #expect(!SetupPolicy.didAdvance(from: accessibility, to: blank, anchor: "Accessibility"))
}

@Test
func stablePaneAnchorOutranksSparseOCRSpellingJitter() {
    let before = screen([
        obs("welcome", 848, 599, 859, 186),
        obs("Get Started", 1209, 1194, 141, 23),
    ])
    let after = screen([
        obs("wacome", 840, 602, 900, 182),
        obs("Get Started", 1209, 1194, 141, 23),
    ])

    #expect(SetupPolicy.similarity(from: before, to: after) < SetupPolicy.screenChangeSimilarityThreshold)
    #expect(!SetupPolicy.didAdvance(from: before, to: after, anchor: "Welcome to Mac|Get Started"))
}

@Test
func blankScreenWaitsWithoutDisturbingEscalationState() throws {
    let accessibility = screen([
        obs("Accessibility", 1180, 300, 200, 40),
        obs("Not Now", 2320, 1330, 110, 30),
    ])
    let blank = screen([], width: 1280, height: 720)
    let decisions = runPolicy(target: accountTarget, screens: [accessibility, blank, accessibility], maxSteps: 3)

    #expect(actTactic(decisions[0])?.atoms == [.click("^Not Now$")])
    guard case .wait = decisions[1] else {
        Issue.record("a blank frame must be waited out, got \(decisions[1])")
        return
    }
    // The sleep blink must not reset the ladder: the un-advanced click
    // escalates straight to the keyboard rung when the pane reappears.
    #expect(actTactic(decisions[2])?.atoms == [.keys(["shift+tab", "space"])])
}

// MARK: - Apple Account sign-in pane (fixture is a real dump from a stuck run)

@Test
func postAccountAppleSignInPaneOpensMenuAndPicksItemInOneTactic() throws {
    let pane = try OCRDumpFixture.load("apple-account-post-account")
    let (decision, _) = SetupPolicy.decide(target: "Finder|admin|Administrator|Enter Password|Touch ID", screen: pane, state: SetupPolicy.PolicyState())

    #expect(actLadderKey(decision) == "pane:Apple Account")
    let tactic = try #require(actTactic(decision))
    // Menu open + item click must be ONE tactic: opening the menu barely
    // changes the OCR token set, and a later rung's click would land outside
    // the menu and dismiss it — escalation would close its own menu forever.
    #expect(tactic.atoms == [
        .click("Other Sign-In Options"),
        .delay(1.0),
        .click("Sign in Later in Settings"),
    ])
}

@Test
func laterTacticClickRetriesTransientOCRMiss() async throws {
    let initial = screen([obs("Other Sign-In Options", 610, 710, 150, 28)])
    let missed = screen([obs("Other Sign-In Options", 610, 710, 150, 28)])
    let revealed = screen([
        obs("Other Sign-In Options", 610, 710, 150, 28),
        obs("@ Sign in Later in Settings", 625, 765, 190, 24),
    ])
    var captures = [missed, revealed]
    var captureCount = 0

    let resolution = try await SetupStepRunner.resolveLaterClick(
        query: "Sign in Later in Settings",
        initialScreen: initial
    ) {
        captureCount += 1
        return captures.removeFirst()
    }

    #expect(captureCount == 2)
    #expect(resolution.match?.text == "@ Sign in Later in Settings")
    #expect(resolution.screen == revealed)
}

@Test
func laterTacticClickReturnsLatestScreenWhenRetriesAreExhausted() async throws {
    let initial = screen([obs("Other Sign-In Options", 610, 710, 150, 28)])
    let latest = screen([obs("Sign In to Your Apple Account", 650, 320, 350, 35)])
    var captureCount = 0

    let resolution = try await SetupStepRunner.resolveLaterClick(
        query: "Sign in Later in Settings",
        initialScreen: initial,
        maxAttempts: 3
    ) {
        captureCount += 1
        return latest
    }

    #expect(captureCount == 3)
    #expect(resolution.match == nil)
    #expect(resolution.screen == latest)
}

@Test
func appleAccountSkipConfirmationMatchesMergedOCRRuns() throws {
    // Vision merged the dialog body with background text and dropped the
    // leading "Are" (observed live): the anchor must still match.
    let merged = screen([
        obs("Sign In to Your Apple Account", 826, 494, 491, 37),
        obs("Email or Phone Number you sure you want to skip", 1000, 671, 500, 26),
        obs("signing in with an Apple Account?", 1060, 700, 380, 26),
        obs("Don't Skip", 1100, 912, 130, 30),
        obs("Skip", 1360, 912, 70, 30),
    ])
    let modal = try #require(SetupPolicy.detectModal(in: merged))
    #expect(modal.title == "Apple Account skip confirmation")
    let button = try #require(modal.button)
    #expect(button.text == "Skip")
}

// MARK: - Generic alert detection

@Test
func genericAlertDetectionIsResolutionIndependent() throws {
    let retina = screen([
        obs("This operation cannot be completed.", 1080, 700, 400, 26),
        obs("OK", 1250, 760, 60, 30),
    ])
    let retinaModal = try #require(SetupPolicy.detectModal(in: retina))
    #expect(retinaModal.title == "unexpected alert")
    #expect(retinaModal.button != nil)

    // The same layout at 1920x1080 (every rect scaled by 0.75) must detect
    // identically — the geometry is fractional, never absolute pixels.
    let scaled = screen([
        obs("This operation cannot be completed.", 810, 525, 300, 20),
        obs("OK", 938, 570, 45, 22),
    ], width: 1920, height: 1080)
    let scaledModal = try #require(SetupPolicy.detectModal(in: scaled))
    #expect(scaledModal.title == "unexpected alert")
    #expect(scaledModal.button != nil)

    // A corner "OK" with no alert prose nearby is not a modal.
    let corner = screen([
        obs("OK", 80, 1380, 60, 30),
    ])
    #expect(SetupPolicy.detectModal(in: corner) == nil)

    // Alert prose without a lone OK is not a modal either (two OKs = ambiguous).
    let ambiguous = screen([
        obs("This operation cannot be completed.", 1080, 700, 400, 26),
        obs("OK", 1150, 760, 60, 30),
        obs("OK", 1350, 760, 60, 30),
    ])
    #expect(SetupPolicy.detectModal(in: ambiguous) == nil)
}

// MARK: - findAll and fixture parsing

@Test
func ocrFindAllFirstElementMatchesFindAndReturnsAllCandidates() throws {
    let observations = [
        obs("Click Continue to proceed", 100, 100, 300, 20),
        obs("Continue", 200, 500, 100, 20),
    ]

    let first = try #require(OCRService.findAll("Continue", in: observations).first)
    let found = try #require(OCRService.find("Continue", in: observations))
    #expect(first == found)
    #expect(first.string == "Continue", "the exact tier must win over an earlier substring match")
    #expect(OCRService.findAll("Continue", in: observations).count == 2)

    let both = OCRService.findAll("^OK$", in: [
        obs("OK", 1150, 760, 60, 30),
        obs("OK", 1350, 760, 60, 30),
    ])
    #expect(both.count == 2)
    #expect(both[0].rectInPixels.minX == 1150, "candidates keep positional order")
}

@Test
func ocrDumpFixtureParsesFramebufferSizeAndObservations() throws {
    let parsed = try OCRDumpFixture.parse("""
    confidence  x,y wxh  text (framebuffer 2560x1440)
    0.98  1042,268 476x40  Transfer Your Data to This Mac
    0.91  1214,608 132x24  .AssetData
    """)

    #expect(parsed.size == CGSize(width: 2560, height: 1440))
    #expect(parsed.observations.count == 2)
    let title = try #require(parsed.observations.first)
    #expect(title.string == "Transfer Your Data to This Mac")
    #expect(title.rectInPixels == CGRect(x: 1042, y: 268, width: 476, height: 40))
    #expect(title.confidence == 0.98)

    #expect(throws: OCRDumpFixture.FixtureError.self) {
        try OCRDumpFixture.parse("no header here")
    }
}
