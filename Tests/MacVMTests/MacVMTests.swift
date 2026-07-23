import AppKit
import Darwin
import Foundation
import Testing

@testable import MacVMHostKit
@testable import MacVM

private let macOS26Release = MacOSRelease(
    majorVersion: 26,
    minorVersion: 0,
    patchVersion: 0,
    buildVersion: "25A000"
)

@Test
func appRuntimePolicyIsolatesUnitTestHosts() {
    let environmentDetected = AppRuntimePolicy.resolve(
        environment: ["XCTestConfigurationFilePath": "/tmp/macvm-tests.xctestconfiguration"],
        xctestLoaded: false
    )
    let classDetected = AppRuntimePolicy.resolve(environment: [:], xctestLoaded: true)
    let production = AppRuntimePolicy.resolve(environment: [:], xctestLoaded: false)

    #expect(environmentDetected.isUnitTestHost)
    #expect(!environmentDetected.usesSharedControlQueue)
    #expect(!environmentDetected.requestsLocalNetworkAccess)
    #expect(classDetected.isUnitTestHost)
    #expect(!production.isUnitTestHost)
    #expect(production.usesSharedControlQueue)
    #expect(production.requestsLocalNetworkAccess)
}

@Test
@MainActor
func managerWindowAppearanceRequestsLocalNetworkAccessOnce() {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var requestCount = 0
    let store = AppStore(
        service: MacVMService(rootDirectory: rootURL),
        triggerLocalNetworkPrivacyAlert: { requestCount += 1 }
    )

    store.managerWindowDidAppear()
    store.managerWindowDidAppear()

    #expect(requestCount == 1)
}

@Test
func localNetworkPrivacyTargetsBroadcastCapableLinkLocalIPv6Addresses() {
    func ipv6Address(prefix: [UInt8], scopeID: UInt32) -> sockaddr_in6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_scope_id = scopeID
        withUnsafeMutableBytes(of: &address.sin6_addr) { buffer in
            buffer.copyBytes(from: prefix)
        }
        return address
    }

    let linkLocal = ipv6Address(
        prefix: [0xfe, 0x80, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8],
        scopeID: 7
    )
    let global = ipv6Address(
        prefix: [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8],
        scopeID: 8
    )
    let firstHostPart: [UInt8] = [10, 11, 12, 13, 14, 15, 16, 17]
    let secondHostPart: [UInt8] = [20, 21, 22, 23, 24, 25, 26, 27]

    let targets = LocalNetworkPrivacy.selectedLinkLocalIPv6Addresses(
        from: [
            .init(flags: UInt32(bitPattern: IFF_BROADCAST), address: linkLocal),
            .init(flags: 0, address: linkLocal),
            .init(flags: UInt32(bitPattern: IFF_BROADCAST), address: global),
        ],
        hostParts: [firstHostPart, secondHostPart]
    )

    #expect(targets.count == 2)
    #expect(targets.allSatisfy { $0.sin6_port == UInt16(9).bigEndian })
    #expect(targets.allSatisfy { $0.sin6_scope_id == 7 })
    #expect(withUnsafeBytes(of: targets[0].sin6_addr) { Array($0[0..<8]) }
        == [0xfe, 0x80, 0, 0, 0, 0, 0, 0])
    #expect(withUnsafeBytes(of: targets[0].sin6_addr) { Array($0[8..<16]) } == firstHostPart)
    #expect(withUnsafeBytes(of: targets[1].sin6_addr) { Array($0[8..<16]) } == secondHostPart)
}

@Test
@MainActor
func failedCreationOffersRemovalForNewIncompleteBundle() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("failed", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let store = AppStore(service: MacVMService(rootDirectory: rootURL))
    let error = NSError(
        domain: "VZErrorDomain",
        code: 10007,
        userInfo: [NSLocalizedDescriptionKey: "Detailed installation failure"]
    )

    store.presentCreationFailure(
        name: "failed",
        error: error,
        bundleExistedBeforeCreation: false
    )

    #expect(store.alertMessage?.contains("Failed to create failed") == true)
    #expect(store.alertMessage?.contains("Detailed installation failure") == true)
    #expect(store.alertRemovalCandidate == "failed")

    store.requestAlertRemoval()
    #expect(store.alertMessage == nil)
    #expect(store.alertRemovalCandidate == nil)
    #expect(store.pendingRemoval == "failed")

    store.confirmRemove()
    #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
}

@Test
@MainActor
func failedCreationNeverOffersRemovalForPreexistingBundle() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("existing", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let store = AppStore(service: MacVMService(rootDirectory: rootURL))
    store.presentCreationFailure(
        name: "existing",
        error: NSError(domain: "VZErrorDomain", code: 10007),
        bundleExistedBeforeCreation: true
    )

    #expect(store.alertRemovalCandidate == nil)
    #expect(FileManager.default.fileExists(atPath: bundleURL.path))
}

// MARK: - CLIEquivalent

@Test
func cliEquivalentRendersFixedActionCommands() {
    #expect(CLIEquivalent.show("dev-01") == "macvm show dev-01")
    #expect(CLIEquivalent.run("dev") == "macvm run dev")
    #expect(CLIEquivalent.run("dev", recovery: true) == "macvm run dev --recovery")
    #expect(CLIEquivalent.stop("dev") == "macvm stop dev")
    #expect(CLIEquivalent.attach("dev") == "macvm attach dev")
    #expect(CLIEquivalent.shutDown("dev") == "macvm shutdown dev")
    #expect(CLIEquivalent.ip("dev") == "macvm ip dev")
    #expect(CLIEquivalent.ssh("dev") == "macvm ssh dev")
    #expect(CLIEquivalent.inventory("dev") == "macvm inventory dev")
    #expect(CLIEquivalent.vnc("dev") == "macvm vnc dev")
    #expect(CLIEquivalent.vnc("dev", open: true) == "macvm vnc dev --open")
    #expect(CLIEquivalent.rm("dev") == "macvm rm dev")
    #expect(CLIEquivalent.clone("dev", name: "dev-copy") == "macvm clone dev --name dev-copy")
    #expect(CLIEquivalent.autostartStatus("dev") == "macvm autostart status dev")
    #expect(CLIEquivalent.autostartEnable("dev") == "macvm autostart enable dev")
    #expect(CLIEquivalent.autostartDisable("dev") == "macvm autostart disable dev")
}

@Test
func cliEquivalentRendersCloneSizingOverridesInCLIOrder() {
    #expect(
        CLIEquivalent.clone("dev", name: "dev-copy", cpuCount: 8)
            == "macvm clone dev --name dev-copy --cpu 8"
    )
    #expect(
        CLIEquivalent.clone("dev", name: "dev-copy", memoryGiB: 16)
            == "macvm clone dev --name dev-copy --memory-gi-b 16"
    )
    #expect(
        CLIEquivalent.clone("dev", name: "dev-copy", cpuCount: 8, memoryGiB: 16)
            == "macvm clone dev --name dev-copy --cpu 8 --memory-gi-b 16"
    )
}

@Test
func setupProgressPhaseStateShowsFailureInsteadOfSpinner() {
    #expect(SetupProgressCard.phaseState(phaseID: 2, currentPhaseID: 3, failureMessage: "failed") == .done)
    #expect(SetupProgressCard.phaseState(phaseID: 3, currentPhaseID: 3, failureMessage: nil) == .active)
    #expect(SetupProgressCard.phaseState(phaseID: 3, currentPhaseID: 3, failureMessage: "failed") == .failed)
    #expect(SetupProgressCard.phaseState(phaseID: 4, currentPhaseID: 3, failureMessage: "failed") == .pending)
}

@Test
func setupProgressHeadingTracksTheCurrentPhase() {
    let phase = SetupPhase(
        id: 10,
        title: "Provisioning: Codex",
        anchor: "ansible-playbook codex",
        firstStepIndex: nil
    )
    let setup = SetupProgress(
        operationActive: true,
        phases: [phase],
        currentPhaseID: phase.id,
        vncURL: "vnc://127.0.0.1:5900",
        username: "admin",
        ipAddress: "192.168.64.10",
        sshReady: true,
        statusMessage: "Running ansible-playbook for Codex",
        logMessages: [],
        activeLog: nil,
        activeLogSnapshot: nil,
        thumbnail: nil,
        failureMessage: nil
    )

    #expect(SetupProgressCard.heading(for: setup) == "Provisioning: Codex")
}

@Test
func setupPreviewDefaultsToAnalyzedFrameWithoutAnInProcessDisplay() {
    #expect(SetupPreviewMode.resolved(.live, hasLiveDisplay: true) == .live)
    #expect(SetupPreviewMode.resolved(.analyzed, hasLiveDisplay: true) == .analyzed)
    #expect(SetupPreviewMode.resolved(.live, hasLiveDisplay: false) == .analyzed)
}

@Test
func setupGuestInputRequiresAcknowledgementBeforeEnabling() {
    #expect(SetupInputPolicy.decision(requested: false, warningAcknowledged: false) == .disable)
    #expect(SetupInputPolicy.decision(requested: true, warningAcknowledged: false) == .confirm)
    #expect(SetupInputPolicy.decision(requested: true, warningAcknowledged: true) == .enable)
}

@Test
@MainActor
func setupLiveDisplayIsReadOnlyAndDoesNotResizeTheGuestByDefault() {
    let view = SetupVirtualMachineDisplayView(frame: NSRect(x: 0, y: 0, width: 520, height: 292.5))

    #expect(!view.allowsGuestInput)
    #expect(!view.displayView.capturesSystemKeys)
    #expect(!view.displayView.automaticallyReconfiguresDisplay)
    #expect(view.hitTest(NSPoint(x: 100, y: 100)) == nil)

    view.setAllowsGuestInput(true)

    #expect(view.allowsGuestInput)
    #expect(view.displayView.capturesSystemKeys)
    #expect(view.hitTest(NSPoint(x: 100, y: 100)) != nil)

    view.setAllowsGuestInput(false)
    #expect(view.hitTest(NSPoint(x: 100, y: 100)) == nil)
}

@Test
func setupAccessRowsAppearAsCapabilitiesBecomeUsable() {
    #expect(AccessSectionView.capabilities(
        status: .settingUp,
        hasIP: false,
        sshReady: false,
        hasVNC: true
    ) == AccessSectionView.Capabilities(
        showsIP: false,
        showsSSH: false,
        showsInventory: false,
        showsVNC: true
    ))
    #expect(AccessSectionView.capabilities(
        status: .settingUp,
        hasIP: true,
        sshReady: false,
        hasVNC: true
    ) == AccessSectionView.Capabilities(
        showsIP: true,
        showsSSH: false,
        showsInventory: false,
        showsVNC: true
    ))
    #expect(AccessSectionView.capabilities(
        status: .settingUp,
        hasIP: true,
        sshReady: true,
        hasVNC: true
    ) == AccessSectionView.Capabilities(
        showsIP: true,
        showsSSH: true,
        showsInventory: true,
        showsVNC: true
    ))
}

@Test
func cliEquivalentRendersProvisioningProfilesAndInputs() {
    let defaults = VMCreationDraft(
        name: "dev", cpuCount: 4, memoryGiB: 8, diskGiB: 80,
        displayWidth: 1280, displayHeight: 720, restoreMode: .latestSupported
    )
    #expect(
        CLIEquivalent.create(
            defaults,
            defaults: defaults,
            setupAfter: true,
            profileIDs: ["python", "go"],
            profileInputs: ["python": ["version": "3.14"]]
        ) == "macvm create --name dev --setup --profile go --profile python --profile-input python.version=3.14"
    )
    #expect(CLIEquivalent.provision("dev", profileIDs: ["python", "go"]) == "macvm provision dev --profile go --profile python")
}

@Test
func longCLICommandsWrapBetweenOptionGroups() {
    let command = "macvm create --name test1 --setup --xcode ~/VirtualMachines/MacVMHost/.xcode/Xcode_26.6_Apple_silicon.xip --profile apple-development --profile github-runner"
    let expected = [
        "macvm create --name test1 --setup \\",
        "  --xcode ~/VirtualMachines/MacVMHost/.xcode/Xcode_26.6_Apple_silicon.xip \\",
        "  --profile apple-development --profile github-runner",
    ].joined(separator: "\n")

    #expect(CLICommandFormatter.multiline(command, maximumLineLength: 80) == expected)
    #expect(CLICommandFormatter.multiline("macvm clone dev --name copy", maximumLineLength: 80) == "macvm clone dev --name copy")
}

@Test
func attachmentRoutingPrefersNativeViewerThenVNC() {
    let session = VNCSession(port: 5901, password: "secret42", pid: getpid(), startedAt: Date())

    #expect(
        AppStore.attachmentRoute(hasNativeViewer: true, session: session, vmName: "dev")
            == .nativeViewer
    )
    #expect(
        AppStore.attachmentRoute(hasNativeViewer: false, session: session, vmName: "dev")
            == .vnc(session.vncURLString)
    )
    let unavailable = AppStore.attachmentRoute(hasNativeViewer: false, session: nil, vmName: "dev")
    guard case .unavailable(let message) = unavailable else {
        Issue.record("Expected unavailable attachment route")
        return
    }
    #expect(message.contains("marked as running"))
    #expect(message.contains("restart the VM"))
}

@Test
func shutdownRoutingAlwaysUsesSSH() {
    #expect(AppStore.shutdownRoute(hasNativeViewer: true, hasInProcessRunner: true) == .ssh)
    #expect(AppStore.shutdownRoute(hasNativeViewer: true, hasInProcessRunner: false) == .ssh)
    #expect(AppStore.shutdownRoute(hasNativeViewer: false, hasInProcessRunner: true) == .ssh)
    #expect(AppStore.shutdownRoute(hasNativeViewer: false, hasInProcessRunner: false) == .ssh)
}

@Test
@MainActor
func viewerCloseHidesWindowAndShowRestoresIt() throws {
    _ = NSApplication.shared
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL.appendingPathComponent("dev.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let metadata = VMMetadata(
        name: "dev",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    let controller = VMViewerController(managedVM: ManagedVM(bundleURL: bundleURL, metadata: metadata))
    let window = try controller.makeWindow()
    window.makeKeyAndOrderFront(nil)
    #expect(window.isVisible)

    #expect(controller.windowShouldClose(window) == false)
    #expect(!window.isVisible)
    #expect(!controller.isFinished)

    controller.showWindow()
    #expect(window.isVisible)
    #expect(controller.window === window)
    window.orderOut(nil)
    controller.tearDown()
}

@Test
@MainActor
func viewerWindowProvidesPasteboardTransferToolbarButtons() throws {
    _ = NSApplication.shared
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL.appendingPathComponent("dev.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let metadata = VMMetadata(
        name: "dev",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    let controller = VMViewerController(managedVM: ManagedVM(bundleURL: bundleURL, metadata: metadata))
    let window = try controller.makeWindow()
    let items = try #require(window.toolbar?.items)
    let automaticSync = try #require(items.first { $0.label == "Automatic Clipboard Sync" })
    let pasteToVM = try #require(items.first { $0.label == "Paste to VM →" })
    let copyFromVM = try #require(items.first { $0.label == "← Copy from VM" })

    #expect(window.toolbarStyle == .expanded)
    #expect(window.toolbar?.displayMode == .iconAndLabel)
    #expect(items.first?.itemIdentifier == .flexibleSpace)
    #expect(items.suffix(3).map(\.label) == [
        "Automatic Clipboard Sync",
        "Paste to VM →",
        "← Copy from VM",
    ])
    #expect(automaticSync.view != nil)
    #expect(pasteToVM.action == #selector(VMViewerController.copyHostPasteboardToGuest(_:)))
    #expect(copyFromVM.action == #selector(VMViewerController.copyGuestPasteboardToHost(_:)))
    #expect(pasteToVM.target === controller)
    #expect(copyFromVM.target === controller)
    #expect(pasteToVM.toolTip?.contains("host pasteboard") == true)
    #expect(copyFromVM.toolTip?.contains("current plain text") == true)
    #expect(!controller.validateToolbarItem(pasteToVM))
    #expect(!controller.validateToolbarItem(copyFromVM))

    controller.tearDown()
}

@Test
@MainActor
func viewerTeardownClearsPublishedVNCAndManagerRuntime() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL.appendingPathComponent("dev.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let metadata = VMMetadata(
        name: "dev",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    let bundle = VMBundle(url: bundleURL)
    try bundle.writeVNCSession(VNCSession(port: 5901, password: "secret42", pid: getpid(), startedAt: Date()))
    try bundle.writeVMProcessRuntimeState(VMProcessRuntimeState(role: .manager, pid: getpid(), startedAt: Date()))

    let controller = VMViewerController(
        managedVM: ManagedVM(bundleURL: bundleURL, metadata: metadata),
        processRuntimeRole: .manager
    )
    controller.tearDown()

    #expect(bundle.readVNCSession() == nil)
    #expect(bundle.readVMProcessRuntimeState() == nil)
}

@Test
func cliEquivalentAbbreviatesHomeDirectory() {
    let home = NSHomeDirectory()
    #expect(CLIEquivalent.abbreviatePath("\(home)/VirtualMachines") == "~/VirtualMachines")
    #expect(CLIEquivalent.abbreviatePath("/opt/thing") == "/opt/thing")
    #expect(
        CLIEquivalent.listRestoreImages(rootPath: "\(home)/VirtualMachines/MacVMHost")
            == "ls ~/VirtualMachines/MacVMHost/.restore-images"
    )
    #expect(
        CLIEquivalent.listXcodeArchives(rootPath: "\(home)/VirtualMachines/MacVMHost")
            == "ls ~/VirtualMachines/MacVMHost/.xcode"
    )
}

private func makeDraft(name: String = "dev-01") -> VMCreationDraft {
    VMCreationDraft(
        name: name,
        cpuCount: 6,
        memoryGiB: 8,
        diskGiB: 80,
        displayWidth: 1920,
        displayHeight: 1080,
        restoreMode: .latestSupported,
        createBootstrapShare: true
    )
}

@Test
func createCommandOmitsFlagsAtDefaultValues() {
    let defaults = makeDraft(name: "")
    let draft = makeDraft()
    #expect(
        CLIEquivalent.create(draft, defaults: defaults, setupAfter: false)
            == "macvm create --name dev-01"
    )
}

@Test
func createCommandIncludesOverridesInCLIOrder() {
    let defaults = makeDraft(name: "")
    var draft = makeDraft(name: "ci")
    draft.cpuCount = 8
    draft.memoryGiB = 16
    draft.diskGiB = 100
    draft.displayWidth = 1440
    draft.displayHeight = 900
    draft.createBootstrapShare = false

    #expect(
        CLIEquivalent.create(draft, defaults: defaults, setupAfter: true)
            == "macvm create --name ci --cpu 8 --memory-gi-b 16 --disk-gi-b 100 --display 1440x900 --no-bootstrap --setup"
    )
}

@Test
func createCommandRendersHomebrewSetupOptOut() {
    let defaults = makeDraft(name: "")
    let draft = makeDraft(name: "minimal")

    #expect(
        CLIEquivalent.create(
            draft,
            defaults: defaults,
            setupAfter: true,
            installHomebrew: false
        ) == "macvm create --name minimal --setup --no-homebrew"
    )
}

@Test
func createCommandRendersClipboardHelperSetupOptOut() {
    let defaults = makeDraft(name: "")
    let draft = makeDraft(name: "minimal")

    #expect(
        CLIEquivalent.create(
            draft,
            defaults: defaults,
            setupAfter: true,
            installClipboardHelper: false
        ) == "macvm create --name minimal --setup --no-clipboard-helper"
    )
}

@Test
func createCommandRendersLocalIPSWPath() {
    let defaults = makeDraft(name: "")
    var draft = makeDraft(name: "local")
    draft.restoreMode = .localFile
    draft.localRestoreImageURL = URL(fileURLWithPath: "/tmp/UniversalMac.ipsw")

    #expect(
        CLIEquivalent.create(draft, defaults: defaults, setupAfter: false)
            == "macvm create --name local --ipsw /tmp/UniversalMac.ipsw"
    )
}

@Test
func createCommandRendersLaunchOnBootFlag() {
    let defaults = makeDraft(name: "")
    var draft = makeDraft(name: "autostart")
    draft.launchOnBoot = true

    #expect(
        CLIEquivalent.create(draft, defaults: defaults, setupAfter: false)
            == "macvm create --name autostart --launch-on-boot"
    )
}

@Test
func createCommandRendersXcodeOnlyWithSetup() {
    let defaults = makeDraft(name: "")
    let draft = makeDraft(name: "xcode")
    let xcodeURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Downloads/Xcode_26.3.xip")

    #expect(
        CLIEquivalent.create(draft, defaults: defaults, setupAfter: true, xcodeXIPURL: xcodeURL)
            == "macvm create --name xcode --setup --xcode ~/Downloads/Xcode_26.3.xip"
    )
    #expect(
        CLIEquivalent.create(draft, defaults: defaults, setupAfter: false, xcodeXIPURL: xcodeURL)
            == "macvm create --name xcode"
    )
}

@Test
func createSheetMemoryHintReportsHostMemory() {
    let memoryBytes = UInt64(24) * 1024 * 1024 * 1024
    #expect(CreateVMSheet.hostMemoryHint(physicalMemoryBytes: memoryBytes) == "host has 24 GB")
}

@Test
func createSheetUsesBoundedProvisioningProfileSummary() {
    #expect(CreateVMSheet.provisioningProfileSummary(selectedNames: []) == "None selected")
    #expect(CreateVMSheet.provisioningProfileSummary(selectedNames: ["Codex"]) == "Codex")
    #expect(
        CreateVMSheet.provisioningProfileSummary(
            selectedNames: ["Codex", "Go", "Python", "Rust"]
        ) == "4 selected"
    )
}

// MARK: - SidebarInitialFocusPolicy

@Test
func sidebarInitialFocusRequestsFocusForInitialVMSelectionOnly() {
    var policy = SidebarInitialFocusPolicy()
    let initialVMSelection = policy.consumeFocusRequest(for: .vm("dev-01"))
    let secondVMSelection = policy.consumeFocusRequest(for: .vm("dev-02"))
    let laterLibrarySelection = policy.consumeFocusRequest(for: .images)

    #expect(initialVMSelection)
    #expect(!secondVMSelection)
    #expect(!laterLibrarySelection)
}

@Test
func sidebarInitialFocusDoesNotRequestFocusAfterInitialLibrarySelection() {
    var policy = SidebarInitialFocusPolicy()
    let initialLibrarySelection = policy.consumeFocusRequest(for: .images)
    let laterVMSelection = policy.consumeFocusRequest(for: .vm("dev-01"))

    #expect(!initialLibrarySelection)
    #expect(!laterVMSelection)
}

// MARK: - VMStatus

@Test
func vmStatusDerivationFollowsPrecedence() {
    let session = VNCSession(port: 5901, password: "pw", pid: 1, startedAt: Date())
    let process = VMProcessRuntimeState(role: .viewer, pid: 1, startedAt: Date())
    let display = VMDisplayRuntimeState(width: 1920, height: 1080, source: .viewer, pid: 1, updatedAt: Date())

    // In-app operations win over everything.
    #expect(VMStatus.derive(cloning: true, installing: true, settingUp: true, viewerActive: true, liveProcess: process, liveDisplay: display, liveSession: session) == .cloning)
    #expect(VMStatus.derive(cloning: false, installing: true, settingUp: true, viewerActive: true, liveProcess: process, liveDisplay: display, liveSession: session) == .installing)
    // Active setup owns the detail view even though its VM is live.
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: true, setupOperationActive: true, viewerActive: true, liveProcess: process, liveDisplay: display, liveSession: session) == .settingUp)

    // A live runtime wins over an inactive setup marker (e.g. a stale
    // setup-state.json after provisioning a running VM).
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: true, viewerActive: true, liveProcess: process, liveDisplay: display, liveSession: session) == .running)
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: true, viewerActive: false, liveProcess: process, liveDisplay: nil, liveSession: nil) == .running)
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: true, viewerActive: false, liveProcess: nil, liveDisplay: nil, liveSession: session) == .running)

    // Setup marker with nothing live still reads as setting up.
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: true, viewerActive: false, liveProcess: nil, liveDisplay: nil, liveSession: nil) == .settingUp)

    // Any liveness signal means running.
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: false, viewerActive: true, liveProcess: nil, liveDisplay: nil, liveSession: nil) == .running)
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: false, viewerActive: false, liveProcess: process, liveDisplay: nil, liveSession: nil) == .running)
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: false, viewerActive: false, liveProcess: nil, liveDisplay: display, liveSession: nil) == .running)
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: false, viewerActive: false, liveProcess: nil, liveDisplay: nil, liveSession: session) == .running)

    // Nothing live → stopped.
    #expect(VMStatus.derive(cloning: false, installing: false, settingUp: false, viewerActive: false, liveProcess: nil, liveDisplay: nil, liveSession: nil) == .stopped)
}

@Test
func cloneNameSuggestionAvoidsExistingNames() {
    #expect(AppStore.suggestedCloneName(source: "dev", occupiedNames: []) == "dev-copy")
    #expect(
        AppStore.suggestedCloneName(
            source: "dev",
            occupiedNames: ["dev-copy", "dev-copy-2", "unrelated"]
        ) == "dev-copy-3"
    )
}

@Test
@MainActor
func managerCloneWorkflowSelectsCompletedClone() async throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("template", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let metadata = VMMetadata(
        name: "template",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        macAddress: "02:00:00:00:00:01"
    )
    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(metadata)
    try Data("installed guest".utf8).write(to: bundle.diskImageURL)

    let store = AppStore(service: MacVMService(rootDirectory: rootURL))
    let source = try #require(store.vm(named: "template"))
    store.cloneCPUCountOverride = 12
    store.cloneMemoryGiBOverride = 32
    store.requestClone(source)
    #expect(store.cloneName == "template-copy")
    #expect(store.cloneCPUCountOverride == nil)
    #expect(store.cloneMemoryGiBOverride == nil)
    #expect(store.cloneCommandPreview == "macvm clone template --name template-copy")

    store.cloneCPUCountOverride = 4
    store.cloneMemoryGiBOverride = 2
    #expect(
        store.cloneCommandPreview
            == "macvm clone template --name template-copy --cpu 4 --memory-gi-b 2"
    )
    store.submitClone()

    for _ in 0..<40 where store.vm(named: "template-copy") == nil && store.alertMessage == nil {
        try await Task.sleep(nanoseconds: 25_000_000)
    }

    #expect(store.alertMessage == nil)
    #expect(store.vm(named: "template-copy") != nil)
    #expect(store.vm(named: "template-copy")?.metadata.cpuCount == 4)
    #expect(store.vm(named: "template-copy")?.metadata.memorySizeBytes == 2 * oneGiB)
    #expect(store.selection == .vm("template-copy"))
    #expect(store.clones["template"] == nil)
    #expect(store.lastCommand == "macvm clone template --name template-copy --cpu 4 --memory-gi-b 2")
}

@Test
func displaySpecShowsOnlyResolvedCurrentResolution() {
    let metadata = VMMetadata(
        name: "dev-01",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    let headlessDisplay = VMDisplayRuntimeState(
        width: 1280,
        height: 720,
        pixelWidth: 2560,
        pixelHeight: 1440,
        source: .headless,
        pid: getpid(),
        updatedAt: Date()
    )
    let viewerDisplay = VMDisplayRuntimeState(
        width: 900,
        height: 550,
        pixelWidth: 1800,
        pixelHeight: 1100,
        source: .viewer,
        pid: getpid(),
        updatedAt: Date()
    )

    #expect(SpecCardsView.displayResolutionText(metadata: metadata, status: .stopped, liveDisplay: viewerDisplay) == "1280 × 720")
    #expect(SpecCardsView.displayResolutionText(metadata: metadata, status: .running, liveDisplay: headlessDisplay) == "1280 × 720")
    #expect(SpecCardsView.displayResolutionText(metadata: metadata, status: .running, liveDisplay: viewerDisplay) == "900 × 550")
}

@Test
@MainActor
func managerStopForExternalSetupUsesRuntimeOwnerInsteadOfClearingProgress() async throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("dev-01", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let metadata = VMMetadata(
        name: "dev-01",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(metadata)
    try bundle.writeSetupRuntimeState(VMSetupRuntimeState(
        username: "admin",
        fullName: "Administrator",
        phaseCount: 14,
        pid: getpid(),
        startedAt: Date(),
        updatedAt: Date()
    ))

    let store = AppStore(service: MacVMService(rootDirectory: rootURL))
    let vm = try #require(store.vm(named: "dev-01"))
    #expect(store.status(forName: "dev-01") == .settingUp)
    #expect(store.setups["dev-01"] != nil)

    store.requestStop(vm)
    store.confirmPowerAction()

    for _ in 0..<20 where store.alertMessage == nil {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    #expect(store.alertMessage?.contains("Refusing to stop the current process") == true)
    #expect(store.setups["dev-01"] != nil)
}

@Test
@MainActor
func managerStopClearsFailedInProcessSetupWithNoRuntime() async throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("dev-01", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let metadata = VMMetadata(
        name: "dev-01",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(metadata)
    try bundle.writeSetupRuntimeState(VMSetupRuntimeState(
        username: "admin",
        fullName: "Administrator",
        phaseIndex: 1,
        phaseCount: 14,
        failureMessage: "The operation couldn’t be completed. (Network.NWError error 57 - Socket is not connected)",
        pid: getpid(),
        startedAt: Date(),
        updatedAt: Date()
    ))

    let store = AppStore(service: MacVMService(rootDirectory: rootURL))
    let vm = try #require(store.vm(named: "dev-01"))
    #expect(store.status(forName: "dev-01") == .settingUp)
    #expect(store.setups["dev-01"]?.failureMessage != nil)

    store.requestStop(vm)
    store.confirmPowerAction()

    #expect(store.alertMessage == nil)
    #expect(store.status(forName: "dev-01") == .stopped)
    #expect(store.setups["dev-01"] == nil)
    #expect(bundle.readSetupRuntimeState() == nil)
}

@Test
@MainActor
func managerReconstructsXcodeSetupProgressFromRuntimeState() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("dev-01", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let metadata = VMMetadata(
        name: "dev-01",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(metadata)
    let plan = try SetupFlows.builtIn(
        for: macOS26Release,
        options: SetupOptions(
            username: "admin",
            fullName: "Administrator",
            xcodeXIPURL: URL(fileURLWithPath: "Xcode.xip")
        )
    )
    let xcodePhase = try #require(plan.phases.first { $0.title == "Install Xcode" })
    try bundle.writeSetupRuntimeState(VMSetupRuntimeState(
        username: "admin",
        fullName: "Administrator",
        phaseIndex: xcodePhase.id,
        phaseCount: plan.phases.count,
        phases: plan.phases,
        statusMessage: "Xcode: installing Xcode.xip in the guest",
        logMessages: ["Waiting for SSH", "Xcode: installing Xcode.xip in the guest"],
        installsXcode: true,
        pid: getpid(),
        startedAt: Date(),
        updatedAt: Date()
    ))
    try bundle.writeVMProcessRuntimeState(VMProcessRuntimeState(
        role: .headless,
        pid: getpid(),
        startedAt: Date()
    ))

    let store = AppStore(service: MacVMService(rootDirectory: rootURL))
    let setup = try #require(store.setups["dev-01"])

    #expect(store.status(forName: "dev-01") == .settingUp)
    #expect(setup.operationActive)
    #expect(setup.currentPhaseID == xcodePhase.id)
    #expect(setup.statusMessage == "Xcode: installing Xcode.xip in the guest")
    #expect(setup.logMessages == ["Waiting for SSH", "Xcode: installing Xcode.xip in the guest"])
    #expect(setup.phases.suffix(2).map(\.title) == ["Install Xcode", "Install Homebrew"])
    #expect(setup.phases.count == plan.phases.count)
}

@Test
@MainActor
func managerKeepsLiveRuntimeAheadOfInactiveManagerSetupMarker() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("dev-01", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(VMMetadata(
        name: "dev-01",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    ))
    try bundle.writeSetupRuntimeState(VMSetupRuntimeState(
        username: "admin",
        fullName: "Administrator",
        phaseCount: 14,
        pid: getpid(),
        startedAt: Date(),
        updatedAt: Date()
    ))
    try bundle.writeVMProcessRuntimeState(VMProcessRuntimeState(
        role: .manager,
        pid: getpid(),
        startedAt: Date()
    ))

    let store = AppStore(service: MacVMService(rootDirectory: rootURL))
    let setup = try #require(store.setups["dev-01"])

    #expect(!setup.operationActive)
    #expect(store.status(forName: "dev-01") == .running)
}

// MARK: - RestoreImageCatalog

@Test
func restoreImageCatalogListsIPSWsNewestFirstWithoutGuessingLatest() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = RestoreImageCatalog.cacheDirectory(root: root)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let older = cache.appendingPathComponent("UniversalMac_26.4_25E100_Restore.ipsw")
    let newer = cache.appendingPathComponent("UniversalMac_26.5.2_25G120_Restore.ipsw")
    let ignored = cache.appendingPathComponent("notes.txt")
    try Data(repeating: 0, count: 1024).write(to: older)
    try Data(repeating: 0, count: 2048).write(to: newer)
    try Data().write(to: ignored)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)],
        ofItemAtPath: older.path
    )

    let entries = RestoreImageCatalog.list(root: root)
    #expect(entries.count == 2)
    #expect(entries[0].name == "UniversalMac_26.5.2_25G120_Restore.ipsw")
    #expect(!entries[0].isLatest)
    #expect(entries[0].sizeBytes == 2048)
    #expect(entries[1].name == "UniversalMac_26.4_25E100_Restore.ipsw")
    #expect(!entries[1].isLatest)
    #expect(RestoreImageCatalog.totalSizeBytes(entries) == 3072)
}

@Test
func restoreImageCatalogMarksOnlyAppleReportedLatestName() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = RestoreImageCatalog.cacheDirectory(root: root)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let publicRelease = cache.appendingPathComponent("UniversalMac_26.5.2_25F84_Restore.ipsw")
    let importedBeta = cache.appendingPathComponent("UniversalMac_27.0_26A5378j_Restore.ipsw")
    try Data(repeating: 0, count: 1024).write(to: publicRelease)
    try Data(repeating: 0, count: 2048).write(to: importedBeta)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)],
        ofItemAtPath: publicRelease.path
    )

    try RestoreImageCacheMetadata.writeLatestSupported(
        LatestSupportedRestoreImageMetadata(
            imageName: publicRelease.lastPathComponent,
            sourceURLString: "https://example.invalid/\(publicRelease.lastPathComponent)",
            buildVersion: "25F84",
            majorVersion: 26,
            minorVersion: 5,
            patchVersion: 2
        ),
        in: cache
    )
    let entries = RestoreImageCatalog.list(root: root)

    #expect(entries.map(\.name) == [
        "UniversalMac_27.0_26A5378j_Restore.ipsw",
        "UniversalMac_26.5.2_25F84_Restore.ipsw",
    ])
    #expect(!entries[0].isLatest)
    #expect(entries[1].isLatest)
}

@Test
func clipboardHelperFailureRecordsAnActionableRepairState() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let bundleURL = rootURL
        .appendingPathComponent("repair", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    let bundle = VMBundle(url: bundleURL)

    var metadata = VMMetadata(
        name: "repair",
        cpuCount: 2,
        memorySizeBytes: 4 * 1024 * 1024 * 1024,
        diskSizeBytes: 40 * 1024 * 1024 * 1024,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false,
        setupCompletedAt: Date(),
        clipboardHelperInstallError: "Guest file copy timed out"
    )
    try bundle.writeMetadata(metadata)

    let vm = ManagedVM(bundleURL: bundleURL, metadata: try bundle.readMetadata())
    let text = ClipboardSectionView.helperRepairText(
        try #require(vm.metadata.clipboardHelperInstallError),
        vmName: vm.metadata.name
    )
    #expect(text.contains("Clipboard helper unavailable"))
    #expect(text.contains("macvm clipboard install repair"))

    // The repair clears the recorded failure, hiding the banner again.
    metadata.clipboardHelperInstallError = nil
    try bundle.writeMetadata(metadata)
    #expect(try bundle.readMetadata().clipboardHelperInstallError == nil)
}

@Test
func restoreImageCatalogHandlesMissingCacheDirectory() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    #expect(RestoreImageCatalog.list(root: root).isEmpty)
}

@Test
func restoreImageCatalogImportsIPSWIntoCache() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("UniversalMac_26.5.2_25G120_Restore.ipsw")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = Data("ipsw".utf8)
    try payload.write(to: source)

    let entry = try RestoreImageCatalog.importImage(from: source, root: root)
    #expect(entry.name == "UniversalMac_26.5.2_25G120_Restore.ipsw")
    #expect(entry.url.deletingLastPathComponent().standardizedFileURL == RestoreImageCatalog.cacheDirectory(root: root).standardizedFileURL)
    #expect(!entry.isLatest)
    #expect(try Data(contentsOf: entry.url) == payload)
}

@Test
func restoreImageCatalogRejectsNonIPSWImport() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("restore.zip")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data("not ipsw".utf8).write(to: source)

    #expect(throws: RestoreImageCatalogError.self) {
        try RestoreImageCatalog.importImage(from: source, root: root)
    }
}

@Test
func restoreImageCatalogDeletesOnlyCachedIPSWs() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = RestoreImageCatalog.cacheDirectory(root: root)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let url = cache.appendingPathComponent("UniversalMac_26.5.2_25G120_Restore.ipsw")
    try Data("ipsw".utf8).write(to: url)
    let entry = try #require(RestoreImageCatalog.list(root: root).first)

    try RestoreImageCatalog.delete(entry, root: root)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    let outside = RestoreImageEntry(
        url: root.appendingPathComponent("outside.ipsw"),
        name: "outside.ipsw",
        sizeBytes: 0,
        modifiedAt: Date(),
        isLatest: false
    )
    #expect(throws: RestoreImageCatalogError.self) {
        try RestoreImageCatalog.delete(outside, root: root)
    }
}

// MARK: - XcodeArchiveCatalog

@Test
func xcodeArchiveCatalogListsXIPsNewestFirst() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = XcodeArchiveCatalog.cacheDirectory(root: root)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let older = cache.appendingPathComponent("Xcode_26.2.xip")
    let newer = cache.appendingPathComponent("Xcode_26.3.xip")
    let ignored = cache.appendingPathComponent("Xcode.app")
    try Data(repeating: 0, count: 1024).write(to: older)
    try Data(repeating: 0, count: 2048).write(to: newer)
    try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -3600)],
        ofItemAtPath: older.path
    )

    let entries = XcodeArchiveCatalog.list(root: root)
    #expect(entries.map(\.name) == ["Xcode_26.3.xip", "Xcode_26.2.xip"])
    #expect(entries[0].sizeBytes == 2048)
    #expect(XcodeArchiveCatalog.totalSizeBytes(entries) == 3072)
}

@Test
func xcodeArchiveCatalogImportsXIPIntoLibrary() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = root.appendingPathComponent("Downloads", isDirectory: true)
    let source = sourceDirectory.appendingPathComponent("Xcode_26.3.xip")
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = Data("xcode".utf8)
    try payload.write(to: source)

    let entry = try XcodeArchiveCatalog.importArchive(from: source, root: root)
    #expect(entry.name == "Xcode_26.3.xip")
    #expect(entry.url.deletingLastPathComponent().standardizedFileURL == XcodeArchiveCatalog.cacheDirectory(root: root).standardizedFileURL)
    #expect(try Data(contentsOf: entry.url) == payload)
}

@Test
func xcodeArchiveCatalogDeletesOnlyLibraryArchives() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cache = XcodeArchiveCatalog.cacheDirectory(root: root)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let url = cache.appendingPathComponent("Xcode_26.3.xip")
    try Data("xcode".utf8).write(to: url)
    let entry = try #require(XcodeArchiveCatalog.list(root: root).first)

    try XcodeArchiveCatalog.delete(entry, root: root)
    #expect(!FileManager.default.fileExists(atPath: url.path))

    let outside = XcodeArchiveEntry(
        url: root.appendingPathComponent("outside.xip"),
        name: "outside.xip",
        sizeBytes: 0,
        modifiedAt: Date()
    )
    #expect(throws: XcodeArchiveCatalogError.self) {
        try XcodeArchiveCatalog.delete(outside, root: root)
    }
}
