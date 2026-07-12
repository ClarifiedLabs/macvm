import Foundation

/// One display row in the setup progress UI: a human-readable pane grouping over
/// the fine-grained `SetupStep` flow, plus the OCR anchor that identifies it.
public struct SetupPhase: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    /// The mono anchor label shown next to the phase (e.g. `clickText "Continue"`).
    public let anchor: String
    /// Index into the step flow where this phase begins, or nil for phases owned
    /// by the pipeline rather than the step runner (boot, provisioning, SSH wait).
    public let firstStepIndex: Int?

    public init(id: Int, title: String, anchor: String, firstStepIndex: Int?) {
        self.id = id
        self.title = title
        self.anchor = anchor
        self.firstStepIndex = firstStepIndex
    }
}

/// A resolved setup flow together with its display phases.
public struct SetupPlan: Sendable {
    public let flowIdentifier: String
    public let guestRelease: MacOSRelease?
    public let steps: [SetupStep]
    public let phases: [SetupPhase]
    let automationStrategy: SetupAutomationStrategy
    let ruleSet: SetupPolicy.RuleSet

    public var usesNativeGuestProvisioning: Bool {
        automationStrategy == .nativeGuestProvisioning
    }

    public init(steps: [SetupStep], phases: [SetupPhase]) {
        self.flowIdentifier = "custom"
        self.guestRelease = nil
        self.steps = steps
        self.phases = phases
        self.automationStrategy = .vnc
        self.ruleSet = SetupPolicy.macOS26RuleSet
    }

    init(
        flowIdentifier: String,
        guestRelease: MacOSRelease?,
        steps: [SetupStep],
        phases: [SetupPhase],
        automationStrategy: SetupAutomationStrategy = .vnc,
        ruleSet: SetupPolicy.RuleSet
    ) {
        self.flowIdentifier = flowIdentifier
        self.guestRelease = guestRelease
        self.steps = steps
        self.phases = phases
        self.automationStrategy = automationStrategy
        self.ruleSet = ruleSet
    }
}

enum SetupAutomationStrategy: Sendable {
    case vnc
    case nativeGuestProvisioning
}

/// Built-in Setup Assistant step flows per macOS major version, plus loading of a
/// per-bundle override.
///
/// Setup Assistant panes drift between macOS releases (Apple renames buttons and
/// reorders screens), so these flows are OCR-anchored — each pane waits for a
/// distinctive label before acting — and are expected to need occasional upkeep.
/// A user can drop a `Setup/steps.json` into the bundle (or pass one via the CLI)
/// to override the built-in flow without a rebuild.
public enum SetupFlows {
    private enum RegisteredFlow {
        case macOS26
    }

    static let provisioningAnchor = "provisioning script"
    static let sshReadyAnchor = "dhcpd_leases"
    static let xcodeInstallAnchor = "bootstrap-tools --install-xcode"

    static func profileAnchor(_ profileID: String) -> String {
        "ansible-playbook \(profileID)"
    }

    public static let macOS26FlowIdentifier = "macos-26"

    /// Load steps from JSON at `url`.
    public static func load(from url: URL) throws -> [SetupStep] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SetupStep].self, from: data)
    }

    /// Resolve the registered built-in flow for an installed guest release.
    public static func builtIn(
        for release: MacOSRelease,
        options: SetupOptions,
        provisioningProfiles: [ProvisioningProfile] = []
    ) throws -> SetupPlan {
        guard let registeredFlow = registeredFlow(for: release) else {
            throw unsupportedReleaseError(release)
        }
        let steps: [SetupStep]
        let flowIdentifier: String
        let ruleSet: SetupPolicy.RuleSet
        let automationStrategy: SetupAutomationStrategy
        switch registeredFlow {
        case .macOS26:
            steps = macOS26(options: options)
            flowIdentifier = macOS26FlowIdentifier
            ruleSet = SetupPolicy.macOS26RuleSet
            automationStrategy = .vnc
        }
        return SetupPlan(
            flowIdentifier: flowIdentifier,
            guestRelease: release,
            steps: steps,
            phases: phases(
                for: steps,
                includeXcodeInstall: options.xcodeXIPURL != nil,
                provisioningProfiles: provisioningProfiles
            ),
            automationStrategy: automationStrategy,
            ruleSet: ruleSet
        )
    }

    /// Validate a requested setup before installation begins. A CLI override is
    /// an explicit opt-in for releases without a registered built-in flow.
    static func validateForCreation(options: SetupOptions, release: MacOSRelease) throws {
        if let override = options.scriptOverride {
            _ = try load(from: override)
            return
        }
        guard registeredFlow(for: release) != nil else {
            throw unsupportedReleaseError(release)
        }
    }

    /// Resolve the flow to run: a CLI override, else a bundled `Setup/steps.json`,
    /// else the built-in flow registered for the installed guest release.
    static func resolvePlan(
        bundle: VMBundle,
        options: SetupOptions,
        guestRelease: MacOSRelease?,
        provisioningProfiles: [ProvisioningProfile] = []
    ) throws -> SetupPlan {
        if let override = options.scriptOverride {
            let steps = try load(from: override)
            return SetupPlan(
                flowIdentifier: "custom-cli",
                guestRelease: guestRelease,
                steps: steps,
                phases: phases(
                    for: steps,
                    includeXcodeInstall: options.xcodeXIPURL != nil,
                    provisioningProfiles: provisioningProfiles
                ),
                ruleSet: SetupPolicy.macOS26RuleSet
            )
        }
        let bundleSteps = bundle.setupDirectoryURL.appendingPathComponent("steps.json")
        if FileManager.default.fileExists(atPath: bundleSteps.path) {
            let steps = try load(from: bundleSteps)
            return SetupPlan(
                flowIdentifier: "custom-bundle",
                guestRelease: guestRelease,
                steps: steps,
                phases: phases(
                    for: steps,
                    includeXcodeInstall: options.xcodeXIPURL != nil,
                    provisioningProfiles: provisioningProfiles
                ),
                ruleSet: SetupPolicy.macOS26RuleSet
            )
        }
        guard let guestRelease else {
            throw MacVMError.message(
                "Automated setup requires a recorded guest macOS release. Complete Setup Assistant manually, or supply an explicit flow with --script or Setup/steps.json."
            )
        }
        return try builtIn(
            for: guestRelease,
            options: options,
            provisioningProfiles: provisioningProfiles
        )
    }

    private static func unsupportedReleaseError(_ release: MacOSRelease) -> MacVMError {
        MacVMError.message(
            "Automated setup is not supported for \(release.displayDescription). Built-in setup currently supports macOS 26 only. Complete Setup Assistant manually, or supply an explicit flow with --script or Setup/steps.json."
        )
    }

    private static func registeredFlow(for release: MacOSRelease) -> RegisteredFlow? {
        switch release.majorVersion {
        case 26:
            .macOS26
        default:
            nil
        }
    }

    /// Group a step flow into the display phases shown by setup UIs. Boundaries
    /// are located by their OCR markers so the grouping survives flow edits; a
    /// marker missing from a custom flow leaves that phase without a step index.
    public static func phases(
        for steps: [SetupStep],
        includeXcodeInstall: Bool = false,
        provisioningProfiles: [ProvisioningProfile] = []
    ) -> [SetupPhase] {
        func firstIndex(_ action: SetupStep.Action, containing marker: String) -> Int? {
            steps.firstIndex { $0.action == action && ($0.text?.contains(marker) ?? false) }
        }
        func lastIndex(_ action: SetupStep.Action, containing marker: String) -> Int? {
            steps.lastIndex { $0.action == action && ($0.text?.contains(marker) ?? false) }
        }

        var phases = [
            SetupPhase(id: 0, title: "Boot headless, connect RFB client", anchor: "", firstStepIndex: nil),
            SetupPhase(id: 1, title: "Language and region", anchor: #"waitText "Language|Hello""#, firstStepIndex: steps.isEmpty ? nil : 0),
            SetupPhase(id: 2, title: "Setup Assistant panes before account", anchor: #"advanceUntilText "Create a.*Account""#, firstStepIndex: firstIndex(.advanceUntilText, containing: "Create a")),
            SetupPhase(id: 3, title: "Create admin account", anchor: "createAccount", firstStepIndex: steps.firstIndex { $0.action == .createAccount }),
            SetupPhase(id: 4, title: "Finish Setup Assistant panes", anchor: "advanceUntilScreen loginWindowOrDesktop", firstStepIndex: steps.firstIndex { $0.action == .advanceUntilScreen && $0.screenGoal == .loginWindowOrDesktop }),
            SetupPhase(
                id: 5,
                title: "Log in if required",
                anchor: #"whenText "Enter Password""#,
                firstStepIndex: steps.firstIndex { $0.action == .type && ($0.whenText?.contains("Enter Password") ?? false) }
            ),
            SetupPhase(id: 6, title: "Reach the desktop", anchor: "advanceUntilScreen desktop", firstStepIndex: steps.lastIndex { $0.action == .advanceUntilScreen && $0.screenGoal == .desktop }),
            SetupPhase(id: 7, title: "Enable SSH, install per-VM key", anchor: provisioningAnchor, firstStepIndex: nil),
            SetupPhase(id: 8, title: "Wait for IP and SSH", anchor: sshReadyAnchor, firstStepIndex: nil),
        ]

        if includeXcodeInstall {
            phases.append(SetupPhase(
                id: phases.count,
                title: "Install Xcode",
                anchor: xcodeInstallAnchor,
                firstStepIndex: nil
            ))
        }

        for profile in provisioningProfiles {
            phases.append(SetupPhase(
                id: phases.count,
                title: "Provisioning: \(profile.manifest.name)",
                anchor: profileAnchor(profile.id),
                firstStepIndex: nil
            ))
        }

        return phases
    }

    /// OCR-driven Setup Assistant flow validated against macOS 26 Tahoe.
    ///
    /// Two panes only advance via the default button (no OCR-able label): the
    /// animated "Hello" greeting and the Language list. Return activates their
    /// default (Continue / the arrow). The account is created by typing the username
    /// into the Full Name field so the Account Name auto-derives to it — the field's
    /// autocomplete makes clearing a separately-typed account name unreliable.
    public static func macOS26(options: SetupOptions) -> [SetupStep] {
        localeSteps()
            + preAccountSteps()
            + accountCreationSteps(options: options)
            + postAccountSteps(options: options)
    }

    /// Ordered front matter shared by any future flow that presents the same
    /// greeting, language, and region screens.
    static func localeSteps() -> [SetupStep] {
        [
            .waitText("Language|Country|Continue|Hello", timeout: 360),
            .wake,
            .keys(["return"]),
            .delay(2),
            .clickText("^English$", timeout: 30, optional: true),
            .keys(["return"]),
            .delay(3),
            .waitText("Select Your Country|Country or Region", timeout: 60),
            .clickText("Continue", timeout: 60),
            .delay(3),
        ]
    }

    /// Screenshot-driven panes before account creation. Future releases can
    /// reuse this fragment only after their pane family has been validated.
    static func preAccountSteps() -> [SetupStep] {
        [
            .advanceUntilText("Create a.*Account|Create a Computer Account|Full Name", timeout: 420),
        ]
    }

    static func accountCreationSteps(options: SetupOptions) -> [SetupStep] {
        [
            .createAccount(username: options.username, password: options.password, timeout: 600),
        ]
    }

    static func postAccountSteps(options: SetupOptions) -> [SetupStep] {
        let loginWindowText = "Enter Password"
        let passwordHoldDelay: TimeInterval = 0.08
        let passwordGapDelay: TimeInterval = 0.18

        return [
            .advanceUntilScreen(.loginWindowOrDesktop, timeout: 300),
            .clickText("Enter Password|Password", whenText: loginWindowText, timeout: 5, optional: true),
            .type(
                options.password,
                whenText: loginWindowText,
                timeout: 5,
                optional: true,
                holdDelay: passwordHoldDelay,
                gapDelay: passwordGapDelay
            ),
            .keys(["return"], whenText: loginWindowText, timeout: 5, optional: true),
            .delay(8),
            .advanceUntilScreen(.desktop, timeout: 240),
            .delay(5),
            .screenshot("post-setup-desktop"),
        ]
    }
}
