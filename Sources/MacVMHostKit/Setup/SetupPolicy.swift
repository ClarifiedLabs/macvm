import CoreGraphics
import Foundation

/// The pure decision core of the Setup Assistant driver.
///
/// `SetupStepRunner.advanceUntilText` runs a perceive → decide → act → verify
/// loop: it captures a `Screen`, asks `SetupPolicy.decide` what to do, performs
/// the returned `Tactic`, and feeds whether the screen visibly changed back into
/// the next decision. Everything in this file is pure — no captures, no sleeps,
/// no clicks — so the whole policy is unit-testable against recorded OCR dumps.
///
/// Maintainer trap: `OCRService.find` resolves exact → substring → regex and
/// picks by *screen position* within each tier, NOT by regex alternation order.
/// `"^Not Now$|^Continue$"` means "whichever is topmost", never "prefer Not
/// Now". Express preference as ordered tactics, one query per rung.
enum SetupPolicy {

    // MARK: - Perception

    /// A perceived screen: OCR observations plus the framebuffer size they were
    /// measured in. All geometry below is expressed as fractions of this size —
    /// the default guest framebuffer is 2560x1440 (2x Retina) but the size is
    /// user-configurable, so absolute pixel constants are forbidden here.
    struct Screen: Equatable {
        let observations: [TextObservation]
        let size: CGSize
    }

    /// A foreground alert/sheet that must be handled before the pane behind it.
    struct DetectedModal: Equatable {
        let title: String
        /// The dismissing button, geometrically disambiguated from identical
        /// background labels. `nil` when the body text matched but the button
        /// didn't OCR; the ladder then falls back to the default-button key.
        let button: GuestTextMatch?
    }

    // MARK: - Actions

    /// One indivisible input. A tactic's atoms run in order with no
    /// verification between them; verification happens after the tactic.
    enum Atom: Equatable {
        /// Click the match for an OCR query, resolved at execution time.
        case click(String)
        /// Click a pre-resolved point (used for modal buttons, whose query can
        /// also match a stale background label).
        case clickMatch(GuestTextMatch)
        case keys([String])
        case type(String)
        case delay(TimeInterval)
    }

    /// One rung of an escalation ladder.
    struct Tactic: Equatable {
        let atoms: [Atom]
        /// Optional extra OCR gate; the rung is skipped unless this matches.
        let requires: String?

        init(atoms: [Atom], requires: String? = nil) {
            self.atoms = atoms
            self.requires = requires
        }

        /// Applicable iff `requires` matches and, when the first atom is a
        /// click, its query has a match. Later clicks resolve against fresh
        /// observations at execution time; a miss abandons the tactic and is
        /// reported as "did not advance", which escalates to the next rung.
        func isApplicable(in screen: Screen) -> Bool {
            if let requires, OCRService.match(requires, in: screen.observations) == nil {
                return false
            }
            if case .click(let query) = atoms.first {
                return OCRService.match(query, in: screen.observations) != nil
            }
            return true
        }

        var summary: String {
            let parts = atoms.compactMap { atom -> String? in
                switch atom {
                case .click(let query): return "click “\(query)”"
                case .clickMatch(let match): return "click “\(match.text)”"
                case .keys(let keys): return "press \(keys.joined(separator: " "))"
                case .type(let text): return "type “\(text)”"
                case .delay: return nil
                }
            }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Rules

    /// A recognized Setup Assistant pane and its escalation ladder,
    /// most-preferred tactic first.
    struct PaneRule: Equatable {
        let title: String
        let anchor: String
        let tactics: [Tactic]
        /// Whether the generic rescue buttons may run after the ladder is
        /// exhausted. FALSE for panes with selectable rows (Transfer, Age
        /// Range, Location Services): a generic "Continue" there can opt in to
        /// something — on the Transfer pane it starts a migration. Those panes
        /// fail loudly instead, dumping the artifacts needed to add the
        /// missing layout as a fixture.
        let allowGenericRescue: Bool

        init(title: String, anchor: String, tactics: [Tactic], allowGenericRescue: Bool = true) {
            self.title = title
            self.anchor = anchor
            self.tactics = tactics
            self.allowGenericRescue = allowGenericRescue
        }
    }

    /// A known foreground modal. `anchors` are conjunctive — every element must
    /// match (each element may itself be an alternation of OCR fragmentations
    /// of the same sentence). Conjunction is what stops a modal rule from
    /// shadowing the pane it confirms.
    struct ModalRule: Equatable {
        let title: String
        let anchors: [String]
        let button: String
    }

    // MARK: - Decisions

    enum Decision: Equatable {
        case reachedTarget(GuestTextMatch)
        case act(Tactic, ladderKey: String, rationale: String)
        case wait(TimeInterval)
        case stuck(StuckReason)
    }

    enum StuckReason: Equatable {
        case ladderExhausted(ladderKey: String)
        case oscillating(signatureHash: UInt64, actions: Int)
        case tooManyActions(ladderKey: String, actions: Int)
        case dangerousModal(anchor: String)

        var summary: String {
            switch self {
            case .ladderExhausted(let key):
                return "Setup Assistant stayed on “\(key)” after every tactic was tried"
            case .oscillating(_, let actions):
                return "Setup Assistant kept returning to the same screen after \(actions) actions"
            case .tooManyActions(let key, let actions):
                return "Setup Assistant needed more than \(actions) actions on “\(key)”"
            case .dangerousModal(let anchor):
                return "Setup Assistant showed an alert matching “\(anchor)” that must not be auto-dismissed"
            }
        }
    }

    /// Bookkeeping carried between `decide` calls. Counters are cumulative for
    /// the lifetime of one `advanceUntilText` call and are never reset, so an
    /// A→B→A pane oscillation cannot evade the caps by alternating.
    struct PolicyState: Equatable {
        var ladderKey = ""
        var rung = 0
        /// Set by the runner after performing a tactic: did the screen change?
        var lastActionAdvanced: Bool?
        var actionsInLadder: [String: Int] = [:]
        var idleRoundsInLadder: [String: Int] = [:]
        var actionsPerSignature: [UInt64: Int] = [:]
        var totalActions = 0
        var modalDismissals = 0

        init() {}
    }

    // MARK: - Caps

    /// Actions allowed on one pane/rescue ladder before failing loudly.
    static let maxActionsPerLadder = 8
    /// Modal dismissal is a single click; a modal that survives 3 of them means
    /// the pane handler underneath is wrong — fail with artifacts instead of
    /// ping-ponging.
    static let maxActionsPerModalLadder = 3
    /// Actions allowed while the screen signature stays the same. Waiting never
    /// increments this — it only counts acting with zero visible effect.
    static let maxSignatureActions = 5
    /// Total actions per `advanceUntilText` call.
    static let maxTotalActions = 60
    /// Waits a recognized pane/modal may sit frozen — same screen, nothing left
    /// to try — before it is declared stuck. Generous: Setup Assistant's last
    /// pane hands off to an OS transition that can take many seconds, and a
    /// screen that is actually transitioning resets this counter (it is keyed
    /// by screen signature), so only a truly frozen pane spends the budget.
    static let maxIdleRoundsInLadder = 10
    /// After this many modal dismissals, a still-visible target wins over a
    /// still-visible modal so a persistent dialog cannot livelock the target.
    static let maxModalDismissals = 3
    /// Below this Jaccard similarity two screens count as different.
    static let screenChangeSimilarityThreshold = 0.80
    /// Idle poll pause when nothing is actionable.
    static let idleWait: TimeInterval = 0.7
    /// Observations below this confidence are ignored by screen signatures.
    static let signatureMinimumConfidence: Float = 0.5

    // MARK: - Modal rules (checked before panes)

    /// Anchors whose modals must never be auto-dismissed. "passwords don't
    /// match" belongs to `repairAccountPasswordMismatch`; blind-dismissing it
    /// would hide the failure that step exists to repair.
    static let dangerousModalAnchors = [
        "passwords don.t match",
        "^Erase",
        "^Delete",
    ]

    static let modalRules: [ModalRule] = [
        // Alert prose wraps mid-sentence and anchors match one OCR observation
        // at a time, so each anchor alternates the fragments a line break can
        // produce (observed: "The selected source cannot be" / "used for
        // migration." and "…using a Case" / "Sensitive filesystem…").
        ModalRule(
            title: "Migration source error",
            anchors: ["cannot be used for migration|source cannot be|used for migration"],
            button: "^OK$"
        ),
        ModalRule(
            title: "Case-sensitive source error",
            anchors: ["Case Sensitive|Sensitive filesystem"],
            button: "^OK$"
        ),
        // "you sure you want to skip" rather than "Are you sure…": Vision can
        // merge the dialog body with background text and drop the leading word
        // (observed: "Email or Phone Number you sure you want to skip").
        ModalRule(
            title: "Apple Account skip confirmation",
            anchors: ["you sure you want to skip|signing in with an Apple"],
            button: "^Skip$"
        ),
        ModalRule(
            title: "License agreement confirmation",
            anchors: ["I have read and agree"],
            button: "^Agree$"
        ),
        ModalRule(
            title: "Location Services confirmation",
            anchors: ["don.t want to use Location"],
            button: "Don.t Use"
        ),
        ModalRule(
            title: "FileVault confirmation",
            anchors: ["Mac Data Will Not Be Securely Encrypted|Securely Encrypted"],
            button: "^Continue$"
        ),
    ]

    /// Body words that mark a text run as alert prose for the generic detector.
    static let alertBodyLexicon =
        "cannot|can.t|failed|unable|error|not be used|isn.t|is not supported|try again"

    // MARK: - Pane rules (first match wins)

    static let paneRules: [PaneRule] = [
        // The sign-in menu revealed by "Other Sign-In Options" must precede the
        // Apple Account pane that opens it.
        PaneRule(
            title: "Apple Account sign-in menu",
            anchor: "Sign in Later in Settings",
            tactics: [
                Tactic(atoms: [.click("Sign in Later in Settings")]),
            ]
        ),
        // macOS 26 shows a migration-source list with Not Now/Continue; older
        // releases show a "Set up as new" choice that must be selected before
        // Continue. Never press blind keys here — space toggles a source row,
        // and Continue with a source selected starts a migration.
        PaneRule(
            title: "Transfer or Migration Assistant",
            anchor: "Transfer Your Data|Migration Assistant|How do you want to transfer",
            tactics: [
                Tactic(atoms: [.click("^Not Now$")]),
                Tactic(atoms: [
                    .click("^Set up as new$|^Set Up as New$|^Don.t Transfer.*$"),
                    .delay(0.4),
                    .click("^Continue$"),
                ]),
            ],
            allowGenericRescue: false
        ),
        PaneRule(
            title: "Written and Spoken Languages",
            anchor: "Written and Spoken Languages|Preferred Languages",
            tactics: [
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["shift+tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Accessibility",
            anchor: "Accessibility",
            tactics: [
                Tactic(atoms: [.click("^Not Now$")]),
                Tactic(atoms: [.keys(["shift+tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Data & Privacy",
            anchor: "Data & Privacy",
            tactics: [
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["shift+tab", "space"])]),
            ]
        ),
        // The sign-in menu must be opened AND its item clicked within one
        // tactic: opening the menu barely changes the OCR token set (reads as
        // "did not advance"), and any later rung's click lands outside the
        // menu and dismisses it — escalation would close the menu it just
        // opened, forever. The second click re-resolves on a fresh capture
        // (the item OCRs with a leading icon glyph, e.g. "@ Sign in Later in
        // Settings", which the substring tier tolerates).
        PaneRule(
            title: "Apple Account",
            anchor: "Sign In with Your Apple|Sign in with your Apple|Apple Account|Apple ID",
            tactics: [
                Tactic(atoms: [.click("Set Up Later|Set up later")]),
                Tactic(atoms: [
                    .click("Other Sign-In Options"),
                    .delay(1.0),
                    .click("Sign in Later in Settings"),
                ]),
                Tactic(atoms: [.click("^Skip$")]),
            ]
        ),
        PaneRule(
            title: "Terms and Conditions",
            anchor: "Terms and Conditions|Software License Agreement",
            tactics: [
                Tactic(atoms: [.click("^Agree$")]),
                Tactic(atoms: [.keys(["shift+tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Age Range",
            anchor: "Age Range|^Adult$|^Acult$",
            tactics: [
                Tactic(atoms: [.click("^Adult$|^Acult$"), .delay(0.4), .click("^Continue$")]),
                Tactic(atoms: [.click("^Continue$")]),
            ],
            allowGenericRescue: false
        ),
        PaneRule(
            title: "Location Services",
            anchor: "Enable Location Services|Location Services",
            tactics: [
                Tactic(atoms: [.click("Don.t Use")]),
                Tactic(atoms: [.click("^Not Now$")]),
                Tactic(atoms: [.click("^Skip$")]),
                Tactic(atoms: [.click("^Continue$")]),
            ],
            allowGenericRescue: false
        ),
        PaneRule(
            title: "Time Zone",
            anchor: "Select Your Time Zone|Time Zone|Closest City",
            tactics: [
                Tactic(atoms: [
                    .keys(["tab", "tab"]),
                    .type("UTC"),
                    .keys(["return"]),
                    .delay(0.8),
                    .click("^Continue$"),
                ]),
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["shift+tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Analytics",
            anchor: "Analytics",
            tactics: [
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["shift+tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Screen Time",
            anchor: "Screen Time",
            tactics: [
                Tactic(atoms: [.click("Set Up Later|Set up later")]),
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Siri",
            anchor: "Siri",
            tactics: [
                Tactic(atoms: [.click("Set Up Later|Set up later")]),
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "FileVault",
            anchor: "Your Mac is Ready for FileVault|FileVault",
            tactics: [
                Tactic(atoms: [.click("^Not Now$")]),
                Tactic(atoms: [.keys(["shift+tab", "tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Touch ID",
            anchor: "Touch ID",
            tactics: [
                Tactic(atoms: [.click("Set Up Later|Set up later")]),
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["shift+tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Appearance",
            anchor: "Choose Your Look|Choose Your Appearance|Appearance",
            tactics: [
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["shift+tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Automatic Updates",
            anchor: "Update Mac Automatically|Keep Your Mac Up to Date|Software Update",
            tactics: [
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.keys(["tab", "space"])]),
            ]
        ),
        PaneRule(
            title: "Welcome to Mac",
            anchor: "Welcome to Mac|Get Started",
            tactics: [
                Tactic(atoms: [.click("Get Started")]),
                Tactic(atoms: [.click("^Continue$")]),
                Tactic(atoms: [.click("^Done$")]),
                Tactic(atoms: [.keys(["space"])]),
            ]
        ),
    ]

    /// Buttons that advance an unexpected pane, dismissive choices first so a
    /// rescue never opts in to anything. Also the tail of every pane ladder
    /// that allows generic rescue.
    static let rescueQueries = [
        "^Not Now$",
        "Set Up Later",
        "Sign in Later in Settings",
        "Other Sign-In Options",
        "Don.t Use",
        "^Skip$",
        "Adult|Acult",
        "^Set up as new$|^Set Up as New$|^Don.t Transfer.*$",
        "Get Started",
        "^Agree$",
        "Agree",
        "^Continue$",
        "^Done$",
    ]

    static let genericRescueTactics: [Tactic] = rescueQueries.map {
        Tactic(atoms: [.click($0)])
    }

    // MARK: - The decision

    static func decide(target: String, screen: Screen, state: PolicyState) -> (decision: Decision, state: PolicyState) {
        var state = state

        // A blank capture means the guest display is asleep or mid-transition
        // (an asleep guest serves an empty point-sized framebuffer). Wait for a
        // real frame without disturbing ladder or escalation state — treating a
        // sleep blink as a new screen would reset rungs and forget progress.
        if screen.observations.isEmpty {
            return (.wait(idleWait), state)
        }

        if let dangerous = dangerousModalAnchors.first(where: { OCRService.match($0, in: screen.observations) != nil }) {
            return (.stuck(.dangerousModal(anchor: dangerous)), state)
        }

        let modal = detectModal(in: screen)

        // A modal can sit over a screen whose background still shows the target
        // (e.g. an error dialog over the desktop), so the modal normally wins —
        // but only up to `maxModalDismissals` times, so a persistent dialog
        // cannot livelock a genuinely reached target.
        if let match = OCRService.match(target, in: screen.observations),
           modal == nil || state.modalDismissals >= maxModalDismissals {
            return (.reachedTarget(match), state)
        }

        let ladderKey: String
        let ladder: [Tactic]
        let ladderCap: Int
        if let modal {
            ladderKey = "modal:\(modal.title)"
            var tactics: [Tactic] = []
            if let button = modal.button {
                tactics.append(Tactic(atoms: [.clickMatch(button)]))
            }
            // An alert's highlighted default button responds to Return even
            // when its label didn't OCR or the click missed.
            tactics.append(Tactic(atoms: [.keys(["return"])]))
            ladder = tactics
            ladderCap = maxActionsPerModalLadder
        } else if let pane = paneRule(in: screen.observations) {
            ladderKey = "pane:\(pane.title)"
            ladder = pane.tactics + (pane.allowGenericRescue ? genericRescueTactics : [])
            ladderCap = maxActionsPerLadder
        } else {
            ladderKey = "rescue"
            ladder = genericRescueTactics
            ladderCap = maxActionsPerLadder
        }

        // Rung bookkeeping: a new ladder starts at its preferred rung; a
        // verified non-advance escalates; an advance restarts from the top
        // (the same pane may present a new layout after a partial action).
        if ladderKey != state.ladderKey {
            state.ladderKey = ladderKey
            state.rung = 0
        } else if state.lastActionAdvanced == false {
            state.rung += 1
        } else if state.lastActionAdvanced == true {
            state.rung = 0
        }
        state.lastActionAdvanced = nil

        let signatureHash = signature(of: screen.observations).hash
        if state.actionsPerSignature[signatureHash, default: 0] >= maxSignatureActions {
            return (.stuck(.oscillating(signatureHash: signatureHash, actions: state.actionsPerSignature[signatureHash, default: 0])), state)
        }
        if state.actionsInLadder[ladderKey, default: 0] >= ladderCap {
            return (.stuck(.tooManyActions(ladderKey: ladderKey, actions: state.actionsInLadder[ladderKey, default: 0])), state)
        }
        if state.totalActions >= maxTotalActions {
            return (.stuck(.tooManyActions(ladderKey: ladderKey, actions: state.totalActions)), state)
        }

        guard let (index, tactic) = ladder.enumerated().first(where: { offset, tactic in
            offset >= state.rung && tactic.isApplicable(in: screen)
        }) else {
            // Nothing left to try on this screen. Waiting beats acting here:
            //  - an unrecognized screen may be booting, logging in, or showing
            //    a spinner, so wait for the outer timeout as before;
            //  - a recognized pane may still be rendering its buttons, or may
            //    have accepted the click and be transitioning slowly (the last
            //    pre-account pane hands off to a multi-second OS transition).
            // Re-clicking a slow pane risks double-advancing past the next one,
            // so wait and re-perceive. Only a screen that stays byte-identical
            // for `maxIdleRoundsInLadder` waits is stuck: a live transition
            // changes the signature, which keys — and so resets — the counter.
            if ladderKey != "rescue" {
                let frozenKey = "\(ladderKey)#\(signatureHash)"
                state.idleRoundsInLadder[frozenKey, default: 0] += 1
                if state.idleRoundsInLadder[frozenKey, default: 0] > maxIdleRoundsInLadder {
                    return (.stuck(.ladderExhausted(ladderKey: ladderKey)), state)
                }
            }
            return (.wait(idleWait), state)
        }

        state.rung = index
        state.actionsInLadder[ladderKey, default: 0] += 1
        state.actionsPerSignature[signatureHash, default: 0] += 1
        state.totalActions += 1
        if modal != nil {
            state.modalDismissals += 1
        }
        let rationale = "\(ladderKey) rung \(index) → \(tactic.summary)"
        return (.act(tactic, ladderKey: ladderKey, rationale: rationale), state)
    }

    /// The anchor to watch for disappearance after acting on a ladder, when the
    /// ladder has one.
    static func anchor(forLadderKey key: String) -> String? {
        if key.hasPrefix("pane:") {
            let title = String(key.dropFirst("pane:".count))
            return paneRules.first { $0.title == title }?.anchor
        }
        if key.hasPrefix("modal:") {
            let title = String(key.dropFirst("modal:".count))
            return modalRules.first { $0.title == title }?.anchors.first
        }
        return nil
    }

    // MARK: - Modal detection

    static func detectModal(in screen: Screen) -> DetectedModal? {
        for rule in modalRules {
            let anchorsMatch = rule.anchors.allSatisfy {
                OCRService.match($0, in: screen.observations) != nil
            }
            guard anchorsMatch else { continue }
            let body = OCRService.find(rule.anchors[0], in: screen.observations)
            let button = body.flatMap { modalButton(rule.button, body: $0, in: screen) }
                ?? OCRService.match(rule.button, in: screen.observations)
            return DetectedModal(title: rule.title, button: button)
        }
        return genericAlert(in: screen)
    }

    /// Generic safety net for alert dialogs no rule knows: a single, centered,
    /// button-sized "OK" with alert prose right above it. All geometry is
    /// fractional so it holds at any framebuffer size.
    static func genericAlert(in screen: Screen) -> DetectedModal? {
        let width = screen.size.width
        let height = screen.size.height
        guard width > 0, height > 0 else { return nil }

        let okMatches = OCRService.findAll("^OK$", in: screen.observations)
        guard okMatches.count == 1, let ok = okMatches.first else { return nil }

        let center = ok.center
        guard center.x >= 0.25 * width, center.x <= 0.75 * width,
              center.y >= 0.20 * height, center.y <= 0.85 * height else { return nil }
        let labelHeight = ok.rectInPixels.height
        guard labelHeight >= 0.006 * height, labelHeight <= 0.06 * height else { return nil }

        let hasAlertBody = screen.observations.contains { observation in
            observation.string.count >= 12
                && observation.rectInPixels.maxY <= ok.rectInPixels.minY
                && ok.rectInPixels.minY - observation.rectInPixels.maxY <= 0.35 * height
                && abs(observation.center.x - center.x) <= 0.30 * width
                && OCRService.queryMatches(alertBodyLexicon, candidate: observation.string)
        }
        guard hasAlertBody else { return nil }

        return DetectedModal(title: "unexpected alert", button: guestMatch(for: ok))
    }

    /// Among all matches for `query`, prefer the one that belongs to the modal:
    /// below the body text, within 0.30H of it, nearest its horizontal center.
    /// Falls back to the positional first match (the modal is frontmost, but a
    /// dimmed background button with the same label can still OCR).
    static func modalButton(_ query: String, body: TextObservation, in screen: Screen) -> GuestTextMatch? {
        let all = OCRService.findAll(query, in: screen.observations)
        guard !all.isEmpty else { return nil }
        let height = screen.size.height
        let candidates = all.filter { observation in
            observation.center.y > body.rectInPixels.maxY
                && (height <= 0 || observation.center.y - body.rectInPixels.maxY <= 0.30 * height)
        }
        let chosen = candidates.min { lhs, rhs in
            abs(lhs.center.x - body.center.x) < abs(rhs.center.x - body.center.x)
        } ?? all[0]
        return guestMatch(for: chosen)
    }

    // MARK: - Screen signatures

    struct ScreenSignature: Equatable {
        let tokens: Set<String>
        let hash: UInt64
    }

    /// Tokens that change without the pane changing: the menu-bar clock,
    /// battery percentage, dates.
    private static let volatileTokenPatterns = [
        "^\\d{1,2}:\\d{2}(:\\d{2})? ?([ap]m)?$",
        "^\\d{1,3}%$",
        "^(mon|tue|wed|thu|fri|sat|sun)[a-z]*,?( .*)?$",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func signature(of observations: [TextObservation]) -> ScreenSignature {
        var tokens: Set<String> = []
        for observation in observations where observation.confidence >= signatureMinimumConfidence {
            let normalized = observation.string
                .lowercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard normalized.count >= 2 else { continue }
            let range = NSRange(normalized.startIndex..., in: normalized)
            let volatile = volatileTokenPatterns.contains {
                $0.firstMatch(in: normalized, options: [], range: range) != nil
            }
            guard !volatile else { continue }
            tokens.insert(normalized)
        }

        // FNV-1a over the sorted tokens: stable across processes (unlike
        // `Hasher`), so signatures are loggable and reproducible in fixtures.
        var hash: UInt64 = 0xcbf29ce484222325
        for token in tokens.sorted() {
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            hash ^= 0x1f
            hash = hash &* 0x100000001b3
        }
        return ScreenSignature(tokens: tokens, hash: hash)
    }

    static func similarity(from: Screen, to: Screen) -> Double {
        let a = signature(of: from.observations).tokens
        let b = signature(of: to.observations).tokens
        let unionCount = a.union(b).count
        guard unionCount > 0 else { return 1 }
        return Double(a.intersection(b).count) / Double(unionCount)
    }

    /// Whether the screen visibly moved on: the acted-on ladder's anchor is
    /// gone (decisive), or the OCR text changed materially. A blank capture is
    /// never progress — it is the asleep-display framebuffer, and counting it
    /// as an advance would reset the escalation ladder on every sleep blink.
    static func didAdvance(from: Screen, to: Screen, anchor: String?) -> Bool {
        guard !to.observations.isEmpty else { return false }
        if let anchor, OCRService.match(anchor, in: to.observations) == nil {
            return true
        }
        return similarity(from: from, to: to) < screenChangeSimilarityThreshold
    }

    // MARK: - Lookups shared with the rescue path

    static func paneRule(in observations: [TextObservation]) -> PaneRule? {
        paneRules.first { OCRService.match($0.anchor, in: observations) != nil }
    }

    /// A single safe button for the step-timeout rescue path: known modals
    /// first (their body text gates the button so a live dialog wins over
    /// stale background buttons), then the generic dismissive-first list.
    static func rescueMatch(in observations: [TextObservation]) -> GuestTextMatch? {
        for rule in modalRules {
            let anchorsMatch = rule.anchors.allSatisfy {
                OCRService.match($0, in: observations) != nil
            }
            guard anchorsMatch else { continue }
            if let match = OCRService.match(rule.button, in: observations) {
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

    private static func guestMatch(for observation: TextObservation) -> GuestTextMatch {
        GuestTextMatch(
            text: observation.string,
            x: Int(observation.center.x.rounded()),
            y: Int(observation.center.y.rounded()),
            confidence: observation.confidence
        )
    }
}
