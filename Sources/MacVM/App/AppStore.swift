import AppKit
import Darwin
import Foundation
import MacVMHostKit
import Observation
import Virtualization

/// Sidebar selection: a VM (by its unique name, stable across install → setup →
/// run) or the restore-image library.
enum SidebarItem: Hashable {
    case vm(String)
    case images
    case xcode
}

/// Live install progress for a VM this app is creating.
struct InstallProgress {
    var status: String
    var fraction: Double?
    var command: String
}

struct CloneProgress {
    var destinationName: String
    var status: String
    var command: String
}

/// Live setup progress for a VM this app is driving through Setup Assistant.
struct SetupProgress {
    var phases: [SetupPhase]
    var currentPhaseID: Int?
    var vncURL: String
    var username: String
    var ipAddress: String?
    var sshReady: Bool
    var statusMessage: String?
    var logMessages: [String]
    var activeLog: SetupLogArtifact?
    var activeLogSnapshot: SetupLogSnapshot?
    var thumbnail: NSImage?
    var failureMessage: String?

    var currentPhase: SetupPhase? {
        guard let currentPhaseID else { return nil }
        return phases.first { $0.id == currentPhaseID }
    }
}

enum VMPowerActionKind: Equatable {
    case stop
    case shutDown
}

struct PendingPowerAction: Equatable {
    var kind: VMPowerActionKind
    var name: String
}

enum VMAttachmentRoute: Equatable {
    case nativeViewer
    case vnc(String)
    case unavailable(String)
}

enum VMShutdownRoute: Equatable {
    case nativeViewer
    case inProcessRunner
    case ssh
}

/// Single source of truth for the manager window: the VM list, per-VM liveness,
/// in-app operations (install / setup / viewer windows), the create-sheet draft,
/// and the CLI-equivalent bar.
@MainActor
@Observable
final class AppStore {
    private static let maxSetupLogMessages = 10

    let service: MacVMService
    private let triggerLocalNetworkPrivacyAlert: () -> Void

    private(set) var vms: [ManagedVM] = []
    var selection: SidebarItem?
    var sheetPresented = false
    var draft: VMCreationDraft
    var setupAfterInstall = false
    var selectedXcodeXIPURL: URL?
    var selectedProfileIDs: Set<String> = []
    var profileInputValues: [String: [String: String]] = [:]
    var provisionSheetVMName: String?
    var provisionProfileIDs: Set<String> = []
    var provisionInputValues: [String: [String: String]] = [:]
    var cloneSheetSourceName: String?
    var cloneName = ""
    var cloneCPUCountOverride: Int?
    var cloneMemoryGiBOverride: Int?
    private(set) var lastCommand = CLIEquivalent.list()
    private(set) var copiedKey: String?
    var alertMessage: String?
    private(set) var alertRemovalCandidate: String?
    var pendingPowerAction: PendingPowerAction?

    private(set) var installs: [String: InstallProgress] = [:]
    private(set) var clones: [String: CloneProgress] = [:]
    private(set) var setups: [String: SetupProgress] = [:]
    private(set) var liveProcesses: [String: VMProcessRuntimeState] = [:]
    private(set) var liveSessions: [String: VNCSession] = [:]
    private(set) var liveDisplays: [String: VMDisplayRuntimeState] = [:]
    private(set) var liveSetupStates: [String: VMSetupRuntimeState] = [:]
    private(set) var launchOnBootStatuses: [String: VMLaunchOnBootStatus] = [:]
    private(set) var guestIPs: [String: String] = [:]

    private(set) var restoreImages: [RestoreImageEntry] = []
    private(set) var restoreImageLabels: [String: String] = [:]
    private(set) var latestCheckStatus: String?
    private(set) var restoreImageImportInProgress = false
    private(set) var xcodeArchives: [XcodeArchiveEntry] = []
    private(set) var profileCatalog: ProvisioningCatalog
    private(set) var provisioningStates: [String: ProvisioningState] = [:]
    private(set) var provisioningStatus: [String: String] = [:]
    private(set) var xcodeImportStatus: String?
    private(set) var xcodeImportInProgress = false

    private var viewers: [String: VMViewerController] = [:]
    private var headlessRunners: [String: HeadlessRunner] = [:]
    private var refreshTimer: Timer?
    private var copyResetTask: Task<Void, Never>?
    private var didTriggerLocalNetworkPrivacyAlert = false

    init(
        service: MacVMService = MacVMService(),
        triggerLocalNetworkPrivacyAlert: @escaping () -> Void = LocalNetworkPrivacy.triggerAlert
    ) {
        self.service = service
        self.triggerLocalNetworkPrivacyAlert = triggerLocalNetworkPrivacyAlert
        self.draft = service.defaultDraft()
        self.profileCatalog = service.provisioningCatalog()
        setenv("MACVM_MANAGER_PROCESS", "1", 1)
        refresh()
        selection = vms.first.map { .vm($0.metadata.name) } ?? .images
        updateCommandForSelection()
        startRefreshTimer()
    }

    func managerWindowDidAppear() {
        guard !didTriggerLocalNetworkPrivacyAlert else { return }
        didTriggerLocalNetworkPrivacyAlert = true
        triggerLocalNetworkPrivacyAlert()
    }

    func dismissAlert() {
        alertMessage = nil
        alertRemovalCandidate = nil
    }

    func requestAlertRemoval() {
        guard let name = alertRemovalCandidate else { return }
        dismissAlert()
        requestRemove(name)
    }

    // MARK: - Derived state

    func vm(named name: String) -> ManagedVM? {
        vms.first { $0.metadata.name == name }
    }

    func status(forName name: String) -> VMStatus {
        VMStatus.derive(
            cloning: clones[name] != nil,
            installing: installs[name] != nil,
            settingUp: setups[name] != nil,
            viewerActive: viewers[name] != nil,
            liveProcess: liveProcesses[name],
            liveDisplay: liveDisplays[name],
            liveSession: liveSessions[name]
        )
    }

    /// Names shown in the sidebar: every bundle on disk plus in-flight installs
    /// whose bundle metadata hasn't been written yet.
    var sidebarVMNames: [String] {
        var names = vms.map(\.metadata.name)
        for name in installs.keys.sorted() where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    func sidebarSubtitle(forName name: String) -> String {
        let status = status(forName: name)
        guard let vm = vm(named: name) else {
            return status.sidebarLabel
        }
        let metadata = vm.metadata
        let memory = metadata.memorySizeBytes / (1024 * 1024 * 1024)
        let disk = metadata.diskSizeBytes / (1024 * 1024 * 1024)
        return "\(metadata.cpuCount) CPU · \(memory) GiB · \(disk) GiB · \(status.sidebarLabel)"
    }

    /// The viewer controller whose window is key, for the VM menu commands.
    var activeViewer: VMViewerController? {
        viewers.values.first { $0.window?.isKeyWindow == true }
            ?? (viewers.count == 1 ? viewers.values.first : nil)
    }

    func hasViewer(forName name: String) -> Bool {
        viewers[name] != nil
    }

    /// The VM instance owned by an in-process setup runner. Setup UI can attach
    /// a native display view to this instance without opening another VNC client.
    func setupVirtualMachine(forName name: String) -> VZVirtualMachine? {
        headlessRunners[name]?.runningVirtualMachine
    }

    // MARK: - Refresh loop

    private func startRefreshTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func refresh() {
        // Terminal callbacks normally remove local owners immediately. This is
        // a defensive reconciliation in case a callback was missed.
        let finishedViewerNames = viewers.compactMap { $0.value.isFinished ? $0.key : nil }
        for name in finishedViewerNames {
            viewers[name] = nil
        }
        let finishedRunnerNames = headlessRunners.compactMap { $0.value.isFinished ? $0.key : nil }
        for name in finishedRunnerNames {
            headlessRunners[name] = nil
            setups[name] = nil
        }

        vms = (try? service.listVMs()) ?? []

        var processes: [String: VMProcessRuntimeState] = [:]
        var sessions: [String: VNCSession] = [:]
        var displays: [String: VMDisplayRuntimeState] = [:]
        var setupStates: [String: VMSetupRuntimeState] = [:]
        var launchOnBoot: [String: VMLaunchOnBootStatus] = [:]
        for vm in vms {
            let name = vm.metadata.name
            if let process = service.liveVMProcessRuntimeState(for: vm) {
                processes[name] = process
            }
            if let session = service.liveVNCSession(for: vm) {
                sessions[name] = session
            }
            if let display = service.liveDisplayRuntimeState(for: vm) {
                displays[name] = display
            }
            if let setupState = service.liveSetupRuntimeState(for: vm) {
                setupStates[name] = setupState
            }
            launchOnBoot[name] = service.launchOnBootStatus(for: vm)
        }
        liveProcesses = processes
        liveSessions = sessions
        liveDisplays = displays
        liveSetupStates = setupStates
        launchOnBootStatuses = launchOnBoot
        reconcileSetupProgress(from: setupStates, sessions: sessions)

        for vm in vms {
            let name = vm.metadata.name
            if status(forName: name) == .running {
                if guestIPs[name] == nil, let ip = try? service.resolveGuestIP(vm) {
                    guestIPs[name] = ip
                }
            } else if status(forName: name) == .stopped {
                guestIPs[name] = nil
            }
        }

        restoreImages = RestoreImageCatalog.list(root: service.rootDirectory)
        xcodeArchives = XcodeArchiveCatalog.list(root: service.rootDirectory)
        profileCatalog = service.provisioningCatalog()
        provisioningStates = Dictionary(uniqueKeysWithValues: vms.compactMap { vm in
            service.provisioningState(for: vm).map { (vm.metadata.name, $0) }
        })
    }

    private func reconcileSetupProgress(from setupStates: [String: VMSetupRuntimeState], sessions: [String: VNCSession]) {
        for (name, state) in setupStates {
            guard let vm = vm(named: name) else { continue }
            let existing = setups[name]
            let fallbackOptions = SetupOptions(
                username: state.username,
                fullName: state.fullName,
                xcodeXIPURL: state.installsXcode ? URL(fileURLWithPath: "Xcode.xip") : nil
            )
            let fallbackSteps = SetupFlows.macOS26(options: fallbackOptions)
            let fallbackPhases = SetupFlows.phases(
                for: fallbackSteps,
                includeXcodeInstall: state.installsXcode
            )
            let phases = state.phases.isEmpty ? fallbackPhases : state.phases
            let vncURL: String
            if let session = sessions[name] {
                vncURL = session.vncURLString
            } else {
                vncURL = existing?.vncURL ?? ""
            }

            setups[name] = SetupProgress(
                phases: phases,
                currentPhaseID: state.phaseIndex,
                vncURL: vncURL,
                username: state.username,
                ipAddress: state.ipAddress,
                sshReady: state.sshReady,
                statusMessage: state.statusMessage,
                logMessages: state.logMessages.isEmpty ? (existing?.logMessages ?? []) : state.logMessages,
                activeLog: state.activeLog,
                activeLogSnapshot: state.activeLog.flatMap {
                    service.setupLogSnapshot(for: vm, artifact: $0)
                },
                thumbnail: existing?.thumbnail,
                failureMessage: state.failureMessage
            )

            if let ipAddress = state.ipAddress {
                guestIPs[name] = ipAddress
            }

            if existing == nil {
                startThumbnailLoop(vm: vm)
            }
        }

        for name in Array(setups.keys) where setupStates[name] == nil && headlessRunners[name] == nil {
            setups[name] = nil
        }
    }

    // MARK: - Selection & CLI bar

    func updateCommandForSelection() {
        switch selection {
        case .vm(let name):
            lastCommand = CLIEquivalent.show(name)
        case .images:
            lastCommand = CLIEquivalent.listRestoreImages(rootPath: service.rootDirectory.path)
        case .xcode:
            lastCommand = CLIEquivalent.listXcodeArchives(rootPath: service.rootDirectory.path)
        case nil:
            lastCommand = CLIEquivalent.list()
        }
    }

    // MARK: - Clipboard

    func copy(_ text: String, key: String, command: String? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copiedKey = key
        if let command {
            lastCommand = command
        }
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            self?.copiedKey = nil
        }
    }

    func openVNCURL(_ vncURL: String, name: String) {
        guard let url = URL(string: vncURL) else {
            alertMessage = "Invalid VNC URL for \(name): \(vncURL)"
            return
        }

        guard NSWorkspace.shared.open(url) else {
            alertMessage = "Unable to open \(vncURL) with the system default handler."
            return
        }

        lastCommand = CLIEquivalent.vnc(name, open: true)
    }

    func openSetupLog(_ url: URL) {
        guard NSWorkspace.shared.open(url) else {
            alertMessage = "Unable to open setup log at \(url.path)."
            return
        }
    }

    func revealSetupArtifacts(for vm: ManagedVM) {
        let directory = service.setupArtifactsDirectory(for: vm)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    nonisolated static func attachmentRoute(
        hasNativeViewer: Bool,
        session: VNCSession?,
        vmName: String
    ) -> VMAttachmentRoute {
        if hasNativeViewer {
            return .nativeViewer
        }
        if let session {
            return .vnc(session.vncURLString)
        }
        return .unavailable(
            "\(vmName) is marked as running, but its owner has not published an attachable VNC session. Confirm the owner is still running, then restart the VM if needed."
        )
    }

    nonisolated static func shutdownRoute(hasNativeViewer _: Bool, hasInProcessRunner _: Bool) -> VMShutdownRoute {
        // `VZVirtualMachine.requestStop()` behaves like pressing the guest's
        // power button and displays a confirmation dialog. Always use the same
        // immediate SSH shutdown as the CLI, even when Manager owns the VM.
        return .ssh
    }

    func attach(_ vm: ManagedVM) {
        let name = vm.metadata.name
        let route = Self.attachmentRoute(
            hasNativeViewer: viewers[name] != nil,
            session: liveSessions[name] ?? service.liveVNCSession(for: vm),
            vmName: name
        )
        lastCommand = CLIEquivalent.attach(name)
        switch route {
        case .nativeViewer:
            viewers[name]?.showWindow()
        case .vnc(let vncURL):
            guard let url = URL(string: vncURL), NSWorkspace.shared.open(url) else {
                alertMessage = "Unable to open \(vncURL) with the system default handler."
                return
            }
        case .unavailable(let message):
            alertMessage = message
        }
    }

    // MARK: - Run / viewer / power

    func runViewer(_ vm: ManagedVM, recovery: Bool = false) {
        let name = vm.metadata.name
        guard viewers[name] == nil else {
            openViewer(vm)
            return
        }
        do {
            let controller = VMViewerController(managedVM: vm, processRuntimeRole: .manager)
            controller.onStop = { [weak self] in
                guard let self else { return }
                self.viewers[name]?.window?.orderOut(nil)
                self.viewers[name] = nil
                self.refresh()
            }
            let window = try controller.makeWindowAndStart(startInRecovery: recovery)
            viewers[name] = controller
            window.makeKeyAndOrderFront(nil)
            lastCommand = CLIEquivalent.run(name, recovery: recovery)
        } catch {
            alertMessage = "Failed to start \(name): \(error.localizedDescription)"
        }
    }

    func openViewer(_ vm: ManagedVM) {
        let name = vm.metadata.name
        viewers[name]?.showWindow()
        lastCommand = CLIEquivalent.run(name)
    }

    func setLaunchOnBoot(_ enabled: Bool, for vm: ManagedVM) {
        let name = vm.metadata.name
        do {
            try service.setLaunchOnBoot(enabled, for: vm)
            launchOnBootStatuses[name] = service.launchOnBootStatus(for: vm)
            lastCommand = enabled ? CLIEquivalent.autostartEnable(name) : CLIEquivalent.autostartDisable(name)
        } catch {
            launchOnBootStatuses[name] = service.launchOnBootStatus(for: vm)
            alertMessage = "Failed to \(enabled ? "enable" : "disable") launch on boot for \(name): \(error.localizedDescription)"
        }
    }

    func requestStop(_ vm: ManagedVM) {
        pendingPowerAction = PendingPowerAction(kind: .stop, name: vm.metadata.name)
    }

    func requestShutDown(_ vm: ManagedVM) {
        pendingPowerAction = PendingPowerAction(kind: .shutDown, name: vm.metadata.name)
    }

    func confirmPowerAction() {
        guard let pendingPowerAction else { return }
        self.pendingPowerAction = nil
        guard let vm = vm(named: pendingPowerAction.name) else { return }

        switch pendingPowerAction.kind {
        case .stop:
            stop(vm)
        case .shutDown:
            shutDown(vm)
        }
    }

    private func stop(_ vm: ManagedVM) {
        let name = vm.metadata.name
        lastCommand = CLIEquivalent.stop(name)

        if let controller = viewers[name] {
            Task { @MainActor in
                await controller.stop()
                viewers[name] = nil
                setups[name] = nil
                refresh()
            }
            return
        }

        if let runner = headlessRunners[name] {
            Task { @MainActor in
                await runner.stop()
                headlessRunners[name] = nil
                // Stopping mid-setup abandons the setup; drop its progress card
                // so the VM returns to the stopped state with Run/Recovery.
                setups[name] = nil
                refresh()
            }
            return
        }

        if setups[name] != nil,
           liveProcesses[name] == nil,
           liveSessions[name] == nil,
           liveDisplays[name] == nil,
           liveSetupStates[name] == nil {
            setups[name] = nil
            refresh()
            return
        }

        if hasFailedInProcessSetupWithNoRuntime(name) {
            service.clearSetupRuntimeState(for: vm)
            setups[name] = nil
            refresh()
            return
        }

        let service = self.service
        Task { @MainActor in
            let errorMessage = await Task.detached {
                do {
                    try service.stopVM(vm)
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let errorMessage {
                alertMessage = "Failed to stop \(name): \(errorMessage)"
            } else {
                refresh()
            }
        }
    }

    private func hasFailedInProcessSetupWithNoRuntime(_ name: String) -> Bool {
        guard let setupState = liveSetupStates[name],
              setupState.pid == getpid(),
              setupState.failureMessage != nil else {
            return false
        }

        return liveProcesses[name] == nil
            && liveSessions[name] == nil
            && liveDisplays[name] == nil
    }

    private func shutDown(_ vm: ManagedVM) {
        let name = vm.metadata.name
        lastCommand = CLIEquivalent.shutDown(name)

        switch Self.shutdownRoute(
            hasNativeViewer: viewers[name] != nil,
            hasInProcessRunner: headlessRunners[name] != nil
        ) {
        case .nativeViewer:
            guard let controller = viewers[name] else { return }
            do {
                try controller.requestGuestStop()
            } catch {
                alertMessage = "Failed to shut down \(name): \(error.localizedDescription)"
            }
            return
        case .inProcessRunner:
            guard let runner = headlessRunners[name] else { return }
            do {
                try runner.requestGuestStop()
            } catch {
                alertMessage = "Failed to shut down \(name): \(error.localizedDescription)"
            }
            return
        case .ssh:
            break
        }

        let service = self.service
        Task { @MainActor in
            let result = await Task.detached {
                do {
                    return (status: try service.shutdownGuest(vm) as Int32?, errorMessage: nil as String?)
                } catch {
                    return (status: nil as Int32?, errorMessage: error.localizedDescription)
                }
            }.value

            if let errorMessage = result.errorMessage {
                alertMessage = "Failed to shut down \(name): \(errorMessage)"
            } else if let status = result.status {
                if status != 0 {
                    alertMessage = "Shutdown command failed for \(name) with exit code \(status)."
                }
                refresh()
            }
        }
    }

    // MARK: - Remove

    /// VM name awaiting removal confirmation (drives the confirmation dialog).
    var pendingRemoval: String?

    func requestRemove(_ name: String) {
        guard status(forName: name) == .stopped else {
            alertMessage = "Shut down \(name) before removing it."
            return
        }
        pendingRemoval = name
    }

    func confirmRemove() {
        guard let name = pendingRemoval else { return }
        pendingRemoval = nil
        do {
            try service.removeVM(identifier: name)
            guestIPs[name] = nil
            setups[name] = nil
            installs[name] = nil
            lastCommand = CLIEquivalent.rm(name)
            refresh()
            if selection == .vm(name) {
                selection = vms.first.map { .vm($0.metadata.name) } ?? .images
            }
        } catch {
            alertMessage = "Failed to remove \(name): \(error.localizedDescription)"
        }
    }

    // MARK: - Clone

    nonisolated static func suggestedCloneName(source: String, occupiedNames: Set<String>) -> String {
        let base = "\(source)-copy"
        guard occupiedNames.contains(base) else { return base }
        var suffix = 2
        while occupiedNames.contains("\(base)-\(suffix)") {
            suffix += 1
        }
        return "\(base)-\(suffix)"
    }

    func requestClone(_ vm: ManagedVM) {
        guard status(forName: vm.metadata.name) == .stopped else {
            alertMessage = "Stop \(vm.metadata.name) before cloning it."
            return
        }
        let occupied = Set(vms.map(\.metadata.name)).union(installs.keys)
        cloneName = Self.suggestedCloneName(source: vm.metadata.name, occupiedNames: occupied)
        cloneCPUCountOverride = nil
        cloneMemoryGiBOverride = nil
        cloneSheetSourceName = vm.metadata.name
    }

    var cloneCommandPreview: String {
        CLIEquivalent.clone(
            cloneSheetSourceName ?? "<source>",
            name: cloneName,
            cpuCount: cloneCPUCountOverride,
            memoryGiB: cloneMemoryGiBOverride
        )
    }

    func submitClone() {
        guard let sourceName = cloneSheetSourceName,
              let source = vm(named: sourceName),
              status(forName: sourceName) == .stopped else {
            cloneSheetSourceName = nil
            alertMessage = "The source VM must be stopped before cloning."
            return
        }
        let destinationName = cloneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destinationName.isEmpty else { return }

        let cpuCount = cloneCPUCountOverride
        let memoryGiB = cloneMemoryGiBOverride
        let command = CLIEquivalent.clone(
            sourceName,
            name: destinationName,
            cpuCount: cpuCount,
            memoryGiB: memoryGiB
        )
        cloneSheetSourceName = nil
        clones[sourceName] = CloneProgress(
            destinationName: destinationName,
            status: "Preparing copy…",
            command: command
        )
        lastCommand = command

        Task { @MainActor in
            do {
                let clonedVM = try await service.cloneVM(
                    from: source,
                    named: destinationName,
                    cpuCount: cpuCount,
                    memoryGiB: memoryGiB
                ) { [weak self] event in
                    guard case .status(let message) = event else { return }
                    DispatchQueue.main.async {
                        self?.clones[sourceName]?.status = message
                    }
                }
                clones[sourceName] = nil
                refresh()
                selection = .vm(clonedVM.metadata.name)
                updateCommandForSelection()
                lastCommand = command
            } catch {
                clones[sourceName] = nil
                refresh()
                alertMessage = "Failed to clone \(sourceName): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Create

    func openCreateSheet(prefillIPSW url: URL? = nil, prefillXcode xcodeURL: URL? = nil) {
        draft = service.defaultDraft()
        setupAfterInstall = false
        selectedXcodeXIPURL = nil
        selectedProfileIDs = []
        profileInputValues = [:]
        profileCatalog = service.provisioningCatalog()
        if let url {
            draft.restoreMode = .localFile
            draft.localRestoreImageURL = url
        }
        if let xcodeURL {
            setupAfterInstall = true
            selectedXcodeXIPURL = xcodeURL
            selectedProfileIDs.insert("apple-development")
        }
        sheetPresented = true
    }

    var createCommandPreview: String {
        CLIEquivalent.create(
            draft,
            defaults: service.defaultDraft(),
            setupAfter: setupAfterInstall,
            xcodeXIPURL: setupAfterInstall ? selectedXcodeXIPURL : nil,
            profileIDs: Array(selectedProfileIDs),
            profileInputs: profileInputValues
        )
    }

    func submitCreate() {
        let draft = self.draft
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let shouldSetup = setupAfterInstall || !selectedProfileIDs.isEmpty
        if shouldSetup, let selectedXcodeXIPURL {
            var isDirectory: ObjCBool = false
            guard selectedXcodeXIPURL.pathExtension.lowercased() == "xip",
                  FileManager.default.fileExists(atPath: selectedXcodeXIPURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue
            else {
                alertMessage = "Selected Xcode archive is no longer available."
                return
            }
        }
        var effectiveProfileIDs = selectedProfileIDs
        if selectedXcodeXIPURL != nil {
            effectiveProfileIDs.insert("apple-development")
        }
        let provisioningSelection = ProvisioningSelection(
            profileIDs: Array(effectiveProfileIDs),
            inputs: profileInputValues
        )
        do {
            try service.preflightProvisioning(
                selection: provisioningSelection,
                xcodeXIPURL: selectedXcodeXIPURL,
                freshVM: true
            )
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        let installCommand = CLIEquivalent.create(
            draft,
            defaults: service.defaultDraft(),
            setupAfter: shouldSetup,
            xcodeXIPURL: shouldSetup ? selectedXcodeXIPURL : nil,
            profileIDs: Array(effectiveProfileIDs),
            profileInputs: profileInputValues
        )

        sheetPresented = false
        installs[name] = InstallProgress(status: "Preparing…", fraction: nil, command: installCommand)
        selection = .vm(name)
        lastCommand = installCommand

        let runSetupAfter = shouldSetup
        let setupXcodeXIPURL = shouldSetup ? selectedXcodeXIPURL : nil
        let setupSelection = provisioningSelection
        let bundleExistedBeforeCreation = (try? service.resolveRemovalTarget(identifier: name)) != nil
        Task { @MainActor in
            do {
                let creationSetupOptions = runSetupAfter ? SetupOptions(
                    xcodeXIPURL: setupXcodeXIPURL,
                    provisioningSelection: setupSelection
                ) : nil
                let vm = try await service.createVM(
                    from: draft,
                    setupOptions: creationSetupOptions
                ) { [weak self] event in
                    DispatchQueue.main.async {
                        self?.applyInstallEvent(event, name: name)
                    }
                }
                if draft.launchOnBoot {
                    do {
                        try service.setLaunchOnBoot(true, for: vm)
                        launchOnBootStatuses[name] = service.launchOnBootStatus(for: vm)
                    } catch {
                        alertMessage = "Created \(name), but failed to enable launch on boot: \(error.localizedDescription)"
                    }
                }
                installs[name] = nil
                refresh()
                if runSetupAfter {
                    // Let the installer's VM release its lock on the auxiliary
                    // storage before the setup runner boots the same bundle.
                    installs[name] = InstallProgress(
                        status: "Waiting for the installer to release the bundle…",
                        fraction: nil,
                        command: installCommand
                    )
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    installs[name] = nil
                    let withIdentity = try service.ensureNetworkIdentity(vm)
                    startSetup(
                        for: withIdentity,
                        options: SetupOptions(
                            xcodeXIPURL: setupXcodeXIPURL,
                            provisioningSelection: setupSelection
                        )
                    )
                }
            } catch {
                installs[name] = nil
                refresh()
                presentCreationFailure(
                    name: name,
                    error: error,
                    bundleExistedBeforeCreation: bundleExistedBeforeCreation
                )
            }
        }
    }

    func presentCreationFailure(
        name: String,
        error: Error,
        bundleExistedBeforeCreation: Bool
    ) {
        alertMessage = "Failed to create \(name):\n\n\(error.localizedDescription)"
        let bundleExistsNow = (try? service.resolveRemovalTarget(identifier: name)) != nil
        alertRemovalCandidate = !bundleExistedBeforeCreation && bundleExistsNow ? name : nil
    }

    private func applyInstallEvent(_ event: VMOperationEvent, name: String) {
        switch event {
        case .status(let message):
            installs[name]?.status = message
        case .progress(_, let fractionComplete):
            installs[name]?.fraction = fractionComplete
        case .setupStep, .setupAccess, .setupLog:
            break
        }
    }

    // MARK: - Setup

    func setProfile(_ id: String, selected: Bool, forProvisioning: Bool = false) {
        if selected {
            do {
                for profile in try profileCatalog.resolve([id]) where profile.source != .bundled {
                    if !confirmTrust(profile) { return }
                }
            } catch {
                alertMessage = error.localizedDescription
                return
            }
        }
        if forProvisioning {
            if selected { provisionProfileIDs.insert(id) } else { provisionProfileIDs.remove(id) }
        } else {
            if selected {
                selectedProfileIDs.insert(id)
                setupAfterInstall = true
            } else {
                selectedProfileIDs.remove(id)
            }
        }
    }

    private func confirmTrust(_ profile: ProvisioningProfile) -> Bool {
        let key = "trusted-profile-\(profile.definitionDigest)"
        if UserDefaults.standard.bool(forKey: key) { return true }
        let alert = NSAlert()
        alert.messageText = "Run local profile “\(profile.manifest.name)”?"
        alert.informativeText = "Local Ansible profiles are executable code and may also run commands on this Mac. Source: \(profile.directoryURL.path)"
        alert.addButton(withTitle: "Trust and Select")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: key)
        return true
    }

    func setProfileInput(
        profileID: String,
        key: String,
        value: String,
        forProvisioning: Bool = false
    ) {
        if forProvisioning {
            provisionInputValues[profileID, default: [:]][key] = value
        } else {
            profileInputValues[profileID, default: [:]][key] = value
        }
    }

    func openProvisionSheet(_ vm: ManagedVM) {
        profileCatalog = service.provisioningCatalog(for: vm)
        provisionProfileIDs = []
        provisionInputValues = [:]
        provisionSheetVMName = vm.metadata.name
    }

    func submitProvision() {
        guard let name = provisionSheetVMName,
              let vm = vm(named: name),
              !provisionProfileIDs.isEmpty else { return }
        let selection = ProvisioningSelection(
            profileIDs: Array(provisionProfileIDs),
            inputs: provisionInputValues
        )
        do {
            try service.preflightProvisioning(selection: selection, vm: vm)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        provisionSheetVMName = nil
        provisioningStatus[name] = "Preparing provisioning…"
        lastCommand = CLIEquivalent.provision(name, profileIDs: Array(provisionProfileIDs))
        Task { @MainActor in
            do {
                try await service.provision(vm, selection: selection) { [weak self] event in
                    guard case .status(let message) = event else { return }
                    DispatchQueue.main.async { self?.provisioningStatus[name] = message }
                }
                provisioningStatus[name] = nil
                provisioningStates[name] = service.provisioningState(for: vm)
            } catch {
                provisioningStatus[name] = "Failed: \(error.localizedDescription)"
                alertMessage = error.localizedDescription
                provisioningStates[name] = service.provisioningState(for: vm)
            }
        }
    }

    func startSetup(for vm: ManagedVM, options: SetupOptions = SetupOptions()) {
        let name = vm.metadata.name
        guard setups[name] == nil else { return }
        guard setups.isEmpty else {
            alertMessage = "Another VM is already being set up. One setup runs at a time."
            return
        }

        let plan: SetupPlan
        do {
            plan = try service.setupPlan(for: vm, options: options)
        } catch {
            alertMessage = "Unable to prepare setup for \(name): \(error.localizedDescription)"
            return
        }

        let runner = HeadlessRunner(
            managedVM: vm,
            requestedPort: options.requestedVNCPort,
            forceSharedDirectory: true,
            nativeProvisioning: plan.usesNativeGuestProvisioning ? options : nil,
            installSignalHandlers: false,
            processRuntimeRole: .manager
        )

        runner.onStop = { [weak self] in
            guard let self else { return }
            self.headlessRunners[name] = nil
            self.setups[name] = nil
            self.refresh()
        }

        do {
            let session = try runner.start()
            headlessRunners[name] = runner

            setups[name] = SetupProgress(
                phases: plan.phases,
                currentPhaseID: nil,
                vncURL: session.vncURLString,
                username: options.username,
                ipAddress: nil,
                sshReady: false,
                statusMessage: "Booting \(name) headless",
                logMessages: ["Booting \(name) headless"],
                activeLog: nil,
                activeLogSnapshot: nil,
                thumbnail: nil,
                failureMessage: nil
            )
            startThumbnailLoop(vm: vm)

            let native = runner.usedNativeProvisioning
            Task { @MainActor in
                do {
                    _ = try await service.provisionSetup(
                        vm,
                        session: session,
                        options: options,
                        plan: plan,
                        nativeProvisioning: native
                    ) { [weak self] event in
                        DispatchQueue.main.async {
                            self?.applySetupEvent(event, name: name)
                        }
                    }
                    // Setup done; the VM stays running headless like the CLI.
                    setups[name] = nil
                    refresh()
                } catch {
                    setups[name]?.failureMessage = error.localizedDescription
                    appendSetupLog("Setup failed: \(error.localizedDescription)", name: name)
                }
            }
        } catch {
            headlessRunners[name] = nil
            alertMessage = "Failed to boot \(name) for setup: \(error.localizedDescription)"
        }
    }

    private func applySetupEvent(_ event: VMOperationEvent, name: String) {
        switch event {
        case .setupStep(let step):
            setups[name]?.currentPhaseID = step.phaseIndex
            setups[name]?.statusMessage = step.title
            setups[name]?.activeLog = nil
            setups[name]?.activeLogSnapshot = nil
            appendSetupLog("Setup [\(step.phaseIndex + 1)/\(step.phaseCount)] \(step.title)", name: name)
        case .status(let message):
            setups[name]?.statusMessage = message
            appendSetupLog(message, name: name)
        case .progress(let label, _):
            setups[name]?.statusMessage = label
            appendSetupLog(label, name: name)
        case .setupAccess(let access):
            setups[name]?.ipAddress = access.ipAddress
            setups[name]?.sshReady = access.sshReady
            guestIPs[name] = access.ipAddress
        case .setupLog(let artifact):
            setups[name]?.activeLog = artifact
            if let vm = vm(named: name) {
                setups[name]?.activeLogSnapshot = service.setupLogSnapshot(for: vm, artifact: artifact)
            }
        }
    }

    private func appendSetupLog(_ message: String, name: String) {
        guard !message.isEmpty else { return }
        guard setups[name]?.logMessages.last != message else { return }
        setups[name]?.logMessages.append(message)
        if let count = setups[name]?.logMessages.count, count > Self.maxSetupLogMessages {
            setups[name]?.logMessages.removeFirst(count - Self.maxSetupLogMessages)
        }
    }

    private func startThumbnailLoop(vm: ManagedVM) {
        let name = vm.metadata.name
        Task { @MainActor [weak self] in
            while true {
                guard let store = self, store.setups[name] != nil else { return }
                if let data = store.service.setupPreviewPNG(for: vm),
                   let image = NSImage(data: data) {
                    store.setups[name]?.thumbnail = image
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    // MARK: - Restore images

    func importRestoreImage(from sourceURL: URL, selectForCreate: Bool = false) {
        guard !restoreImageImportInProgress else { return }

        let root = service.rootDirectory
        restoreImageImportInProgress = true
        latestCheckStatus = "Importing \(sourceURL.lastPathComponent)…"

        Task { @MainActor in
            let result = await Task.detached {
                do {
                    let entry = try RestoreImageCatalog.importImage(from: sourceURL, root: root)
                    return (entry: entry as RestoreImageEntry?, errorMessage: nil as String?)
                } catch {
                    return (entry: nil as RestoreImageEntry?, errorMessage: error.localizedDescription)
                }
            }.value

            restoreImageImportInProgress = false
            refresh()

            if let entry = result.entry {
                restoreImageLabels[entry.name] = nil
                latestCheckStatus = "Imported \(entry.name)"
                if selectForCreate {
                    draft.restoreMode = .localFile
                    draft.localRestoreImageURL = entry.url
                }
            } else if let errorMessage = result.errorMessage {
                latestCheckStatus = nil
                alertMessage = "Failed to import restore image: \(errorMessage)"
            }
        }
    }

    func loadRestoreImageLabel(for entry: RestoreImageEntry) async {
        guard restoreImageLabels[entry.name] == nil else { return }
        guard let info = await Self.loadRestoreImageInfo(at: entry.url) else { return }
        restoreImageLabels[entry.name] =
            "macOS \(info.version.majorVersion).\(info.version.minorVersion).\(info.version.patchVersion) (\(info.build))"
    }

    func deleteRestoreImage(_ entry: RestoreImageEntry) {
        do {
            try RestoreImageCatalog.delete(entry, root: service.rootDirectory)
            restoreImageLabels[entry.name] = nil
            latestCheckStatus = "Deleted \(entry.name)"
            refresh()
        } catch {
            alertMessage = "Failed to delete \(entry.name): \(error.localizedDescription)"
        }
    }

    private static func loadRestoreImageInfo(at url: URL) async -> (version: OperatingSystemVersion, build: String)? {
        await withCheckedContinuation { continuation in
            VZMacOSRestoreImage.load(from: url) { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: (image.operatingSystemVersion, image.buildVersion))
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Xcode archives

    func importXcodeArchive(from sourceURL: URL, selectForCreate: Bool = false) {
        guard !xcodeImportInProgress else { return }

        let root = service.rootDirectory
        xcodeImportInProgress = true
        xcodeImportStatus = "Importing \(sourceURL.lastPathComponent)…"

        Task { @MainActor in
            let result = await Task.detached {
                do {
                    let entry = try XcodeArchiveCatalog.importArchive(from: sourceURL, root: root)
                    return (entry: entry as XcodeArchiveEntry?, errorMessage: nil as String?)
                } catch {
                    return (entry: nil as XcodeArchiveEntry?, errorMessage: error.localizedDescription)
                }
            }.value

            xcodeImportInProgress = false
            refresh()

            if let entry = result.entry {
                xcodeImportStatus = "Imported \(entry.name)"
                if selectForCreate {
                    selectedXcodeXIPURL = entry.url
                }
            } else if let errorMessage = result.errorMessage {
                xcodeImportStatus = nil
                alertMessage = "Failed to import Xcode archive: \(errorMessage)"
            }
        }
    }

    func deleteXcodeArchive(_ entry: XcodeArchiveEntry) {
        do {
            try XcodeArchiveCatalog.delete(entry, root: service.rootDirectory)
            if selectedXcodeXIPURL?.standardizedFileURL == entry.url.standardizedFileURL {
                selectedXcodeXIPURL = nil
            }
            xcodeImportStatus = "Deleted \(entry.name)"
            refresh()
        } catch {
            alertMessage = "Failed to delete \(entry.name): \(error.localizedDescription)"
        }
    }

    func checkForLatest() {
        latestCheckStatus = "Checking…"
        Task { @MainActor in
            do {
                let image = try await VZMacOSRestoreImage.latestSupported
                let version = image.operatingSystemVersion
                let name = image.url.lastPathComponent.isEmpty ? "latest-supported.ipsw" : image.url.lastPathComponent
                let metadata = LatestSupportedRestoreImageMetadata(
                    imageName: name,
                    sourceURLString: image.url.absoluteString,
                    buildVersion: image.buildVersion,
                    majorVersion: version.majorVersion,
                    minorVersion: version.minorVersion,
                    patchVersion: version.patchVersion
                )
                try RestoreImageCacheMetadata.writeLatestSupported(
                    metadata,
                    in: RestoreImageCatalog.cacheDirectory(root: service.rootDirectory)
                )
                refresh()
                let cached = restoreImages.contains { $0.name == name }
                latestCheckStatus = "Latest supported: macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (\(image.buildVersion)) — \(cached ? "already cached" : "downloads on first use")"
            } catch {
                latestCheckStatus = "Check failed: \(error.localizedDescription)"
            }
        }
    }
}
