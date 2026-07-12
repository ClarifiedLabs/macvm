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
    public let steps: [SetupStep]
    public let phases: [SetupPhase]

    public init(steps: [SetupStep], phases: [SetupPhase]) {
        self.steps = steps
        self.phases = phases
    }
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
    static let provisioningAnchor = "provisioning script"
    static let sshReadyAnchor = "dhcpd_leases"
    static let xcodeInstallAnchor = "bootstrap-tools --install-xcode"

    static func profileAnchor(_ profileID: String) -> String {
        "ansible-playbook \(profileID)"
    }

    /// Choose the built-in flow for a macOS major version.
    public static func builtIn(forMacOSMajor major: Int, options: SetupOptions) -> [SetupStep] {
        // The OCR dispatcher handles the Setup Assistant pane families covered by
        // macOS 12 Monterey through 15 Sequoia and 26 Tahoe. Keep one built-in
        // flow so pane ordering differences are handled at runtime from the
        // current screenshot instead of by branching on imperfect version data.
        tahoe(options: options)
    }

    /// Load steps from JSON at `url`.
    public static func load(from url: URL) throws -> [SetupStep] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([SetupStep].self, from: data)
    }

    /// The built-in flow plus its display phases for a macOS major version.
    public static func plan(
        forMacOSMajor major: Int,
        options: SetupOptions,
        provisioningProfiles: [ProvisioningProfile] = []
    ) -> SetupPlan {
        let steps = builtIn(forMacOSMajor: major, options: options)
        return SetupPlan(
            steps: steps,
            phases: phases(
                for: steps,
                includeXcodeInstall: options.xcodeXIPURL != nil,
                provisioningProfiles: provisioningProfiles
            )
        )
    }

    /// Resolve the flow to run: a CLI override, else a bundled `Setup/steps.json`,
    /// else the built-in flow for the host major version.
    static func resolvePlan(
        bundle: VMBundle,
        options: SetupOptions,
        hostMajor: Int,
        provisioningProfiles: [ProvisioningProfile] = []
    ) throws -> SetupPlan {
        if let override = options.scriptOverride {
            let steps = try load(from: override)
            return SetupPlan(
                steps: steps,
                phases: phases(
                    for: steps,
                    includeXcodeInstall: options.xcodeXIPURL != nil,
                    provisioningProfiles: provisioningProfiles
                )
            )
        }
        let bundleSteps = bundle.setupDirectoryURL.appendingPathComponent("steps.json")
        if FileManager.default.fileExists(atPath: bundleSteps.path) {
            let steps = try load(from: bundleSteps)
            return SetupPlan(
                steps: steps,
                phases: phases(
                    for: steps,
                    includeXcodeInstall: options.xcodeXIPURL != nil,
                    provisioningProfiles: provisioningProfiles
                )
            )
        }
        return plan(
            forMacOSMajor: hostMajor,
            options: options,
            provisioningProfiles: provisioningProfiles
        )
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

    /// OCR-driven Setup Assistant flow for macOS 12 Monterey through 15 Sequoia
    /// and 26 Tahoe. The boot/language/region front matter is still ordered, then
    /// the runner repeatedly OCRs the current pane and applies a pane-specific
    /// handler until it reaches account creation.
    ///
    /// Two panes only advance via the default button (no OCR-able label): the
    /// animated "Hello" greeting and the Language list. Return activates their
    /// default (Continue / the arrow). The account is created by typing the username
    /// into the Full Name field so the Account Name auto-derives to it — the field's
    /// autocomplete makes clearing a separately-typed account name unreliable.
    public static func tahoe(options: SetupOptions) -> [SetupStep] {
        let loginWindowText = "Enter Password"
        let passwordHoldDelay: TimeInterval = 0.08
        let passwordGapDelay: TimeInterval = 0.18

        return [
            // 1. Setup Assistant can take a while to appear after install; the first
            //    real screen is the Hello greeting or the Language list.
            .waitText("Language|Country|Continue|Hello", timeout: 360),
            .wake,

            // 2. Hello greeting (localized, cycles languages) → default button.
            .keys(["return"]),
            .delay(2),

            // 3. Language (English default) → default button (the arrow).
            .clickText("^English$", timeout: 30, optional: true),
            .keys(["return"]),
            .delay(3),

            // 4. Select Your Country or Region (United States is at the top by default).
            .waitText("Select Your Country|Country or Region", timeout: 60),
            .clickText("Continue", timeout: 60),
            .delay(3),

            // 5. Early Setup Assistant panes are version- and build-dependent:
            //    Monterey/Ventura/Sonoma put Migration/Apple ID/Terms before the
            //    account pane, while Sequoia/Tahoe put Transfer before
            //    Written/Spoken and create the account earlier. Drive whatever is
            //    visible until account creation appears.
            .advanceUntilText("Create a.*Account|Create a Computer Account|Full Name", timeout: 420),

            // 6. Fill, submit, and wait for the account as one verified action.
            //    The "Creating account…" state is passive and can legitimately
            //    take several minutes; never mistake the typed username for a
            //    login-window anchor or send unrelated input while it is busy.
            .createAccount(username: options.username, password: options.password, timeout: 600),

            // 7. Late Setup Assistant panes drift and reorder the most across
            //    releases. FileVault may appear before or after Apple Account,
            //    so it belongs in this screenshot-driven dispatcher instead of
            //    an ordered conditional step that waits for it prematurely.
            //    Instead of paying one timeout per possible pane, repeatedly OCR
            //    the current screenshot and click the safest visible advancement
            //    button until either the login window or Finder appears.
            .advanceUntilScreen(.loginWindowOrDesktop, timeout: 300),

            // 8. Some builds land at the login window, while others auto-login
            //     straight to Finder. Only type the password if a login window is
            //     actually visible.
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

            // 9. Per-user first-login setup can still insert panes after login.
            //     Keep driving from screenshots until Finder is visible.
            // Plain substring (no ^$ anchors): Vision sometimes merges adjacent
            // menu-bar titles into one observation ("Finder File Edit …").
            .advanceUntilScreen(.desktop, timeout: 240),
            .delay(5),
            .screenshot("post-setup-desktop"),
        ]
    }
}
