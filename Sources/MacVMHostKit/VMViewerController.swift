import AppKit
import Darwin
import Foundation
import MacVMClipboardProtocol
import MacVMPrivateVZ
import Virtualization

private extension NSToolbar.Identifier {
    static let vmViewer = NSToolbar.Identifier("dev.macvm.viewer")
}

private extension NSToolbarItem.Identifier {
    static let clipboardControls = NSToolbarItem.Identifier(
        "dev.macvm.viewer.clipboard-controls"
    )
}

enum ClipboardToolbarStatusTone: Equatable {
    case off
    case inactive
    case connecting
    case connected
    case warning

    var color: NSColor {
        switch self {
        case .off:
            return .tertiaryLabelColor
        case .inactive:
            return .secondaryLabelColor
        case .connecting:
            return .systemOrange
        case .connected:
            return .systemGreen
        case .warning:
            return .systemRed
        }
    }
}

struct ClipboardToolbarStatusPresentation: Equatable {
    let symbolName: String
    let tone: ClipboardToolbarStatusTone
    let toolTip: String
}

/// Owns one VM and its optional native display: the `VZVirtualMachine`
/// lifecycle, VNC publication, lazily created `NSWindow` +
/// `VZVirtualMachineView`, geometry persistence, and clipboard transfers.
///
/// Deliberately free of `NSApplication` lifecycle concerns so MacVM.app can
/// retain many runtimes and add a native display after a headless start.
@MainActor
public final class VMViewerController:
    NSObject,
    VZVirtualMachineDelegate,
    NSMenuItemValidation,
    NSWindowDelegate,
    NSToolbarDelegate,
    NSToolbarItemValidation
{
    private struct VMSnapshot {
        let state: VZVirtualMachine.State
        let canStart: Bool
    }

    private struct DisplayRuntimeSize: Equatable {
        let effectiveWidth: Int
        let effectiveHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private let managedVM: ManagedVM
    private let bundle: VMBundle
    private let vmName: String
    private let requestedVNCPort: UInt
    private var startInRecovery = false
    public private(set) var window: NSWindow?
    private var displayView: VZVirtualMachineView?
    private var virtualMachine: VZVirtualMachine?
    private var memoryBalloonRegistrationID: UUID?
    private var dockerSidecarRuntime: DockerSidecarRuntime?
    /// Retains both datagram file handles for the complete joint lifetime.
    private var dockerPairNetwork: DockerPairNetwork?
    private let processRuntimeRole: VMProcessRuntimeRole?
    private var vncServer: MacVMVNCServer?
    private var vncSession: VNCSession?
    private let clipboardRuntime: ClipboardRuntime
    private let clipboardSyncCoordinator: ClipboardSyncCoordinator
    private let clipboardActivationOwnerID = UUID()
    private var clipboardActivationGeneration: UInt64?
    private weak var clipboardToggle: NSSwitch?
    private weak var clipboardStatusImageView: NSImageView?
    private weak var copyHostPasteboardToGuestButton: NSButton?
    private weak var copyGuestPasteboardToHostButton: NSButton?
    private var lastClipboardHelperState: ClipboardHelperConnectionState = .connecting
    private var clipboardTransferInProgress = false
    private var startHeartbeatTimer: Timer?
    private var startupFailureMessage: String?
    private var lastPublishedDisplaySize: DisplayRuntimeSize?
    private var lastPersistedWindowFrame: NSRect?
    private var dockerProvisioningTask: Task<Void, Never>?
    private var dockerStartupOperationLock: DockerSidecarOperationLock?
    private var finishError: Error?
    private var finishing = false
    private var finished = false

    /// Called once when the VM reaches a terminal state (guest shutdown, error,
    /// or failed start). The CLI wrapper terminates the process; a host app
    /// closes the window and releases the controller.
    public var onStop: (@MainActor () -> Void)?
    public var onClipboardStatusChange: (@MainActor (ClipboardRuntimeStatus) -> Void)?

    public init(
        managedVM: ManagedVM,
        requestedVNCPort: UInt = 0,
        processRuntimeRole: VMProcessRuntimeRole? = nil
    ) {
        self.managedVM = managedVM
        self.bundle = VMBundle(url: managedVM.bundleURL)
        self.vmName = managedVM.metadata.name
        self.requestedVNCPort = requestedVNCPort
        self.processRuntimeRole = processRuntimeRole
        let clipboardRuntime = ClipboardRuntime(managedVM: managedVM)
        self.clipboardRuntime = clipboardRuntime
        self.clipboardSyncCoordinator = ClipboardSyncCoordinator(runtime: clipboardRuntime)
        super.init()
        clipboardRuntime.onStatusChange = { [weak self] status in
            guard let self else { return }
            let reconnected = status.helper == .connected
                && self.lastClipboardHelperState != .connected
            self.lastClipboardHelperState = status.helper
            if reconnected, self.window?.isKeyWindow == true {
                self.activateClipboard()
            }
            self.refreshPasteboardCommandState()
            self.onClipboardStatusChange?(status)
        }
    }

    public var isRunning: Bool {
        virtualMachine?.state == .running
    }

    public var isFinished: Bool {
        finished
    }

    public var hasWindow: Bool {
        window != nil
    }

    public var publishedVNCSession: VNCSession? {
        vncSession
    }

    public var clipboardStatus: ClipboardRuntimeStatus {
        clipboardRuntime.status
    }

    public func setAutomaticClipboardSyncEnabled(_ enabled: Bool) throws {
        try clipboardRuntime.setEnabled(enabled)
        if enabled, let generation = clipboardActivationGeneration {
            clipboardSyncCoordinator.activate(generation: generation)
        }
    }

    public func reloadClipboardPairing() throws {
        guard let virtualMachine else {
            throw MacVMError.message("The VM is not running.")
        }
        clipboardRuntime.prepare(on: virtualMachine)
    }

    /// Build the window (restoring persisted geometry) without starting the VM.
    @discardableResult
    public func makeWindow() throws -> NSWindow {
        if let window {
            return window
        }
        try setUpWindow()
        recordWindowGeometry()
        guard let window else {
            throw MacVMError.message("Failed to create the viewer window.")
        }
        return window
    }

    /// Create the `VZVirtualMachine` and boot it into the existing window.
    public func start(startInRecovery: Bool = false) throws {
        self.startInRecovery = startInRecovery
        startupFailureMessage = nil
        try createAndStartVirtualMachine()
    }

    /// Wait until Virtualization.framework reports that the VM is running, so
    /// control clients receive startup failures rather than a premature success.
    public func waitUntilRunning(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let startupFailureMessage {
                throw MacVMError.message(startupFailureMessage)
            }
            if virtualMachine?.state == .running {
                return
            }
            if finished {
                throw MacVMError.message("The VM stopped before reaching the running state.")
            }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline

        throw MacVMError.message("Timed out waiting for \(vmName) to start.")
    }

    /// Wait for a newly prepared Docker sidecar to finish installing and
    /// validating its macOS guest integration on this run.
    public func waitUntilDockerGuestProvisioned(timeout: TimeInterval = 40 * 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let settings = try bundle.readMetadata().dockerSidecar
            let runtime = bundle.readDockerSidecarRuntimeDescriptor()
            switch DockerGuestProvisioningWaitDecision.make(
                settings: settings,
                runtime: runtime,
                ownerFinished: finished
            ) {
            case .waiting:
                try await Task.sleep(for: .milliseconds(250))
            case .ready:
                return
            case .failed(let message):
                throw MacVMError.message(message)
            }
        } while Date() < deadline

        throw MacVMError.message("Timed out waiting for Docker guest integration in \(vmName).")
    }

    /// Wait for guest shutdown and the paired sidecar teardown to finish.
    public func waitUntilStopped(timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if finished {
                if let finishError { throw finishError }
                return
            }
            if let finishError, !finishing { throw finishError }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline

        throw MacVMError.message("Timed out waiting for \(vmName) to shut down.")
    }

    /// Convenience for hosts: build the window, boot the VM, and return the
    /// window for presentation.
    @discardableResult
    public func makeWindowAndStart(startInRecovery: Bool = false) throws -> NSWindow {
        let window = try makeWindow()
        try start(startInRecovery: startInRecovery)
        return window
    }

    /// Lazily build and bring the native display window to the front. This can
    /// attach a VZVirtualMachineView after a headless VM has already started.
    @discardableResult
    public func makeWindowAndShow() throws -> NSWindow {
        let window = try makeWindow()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Bring the window to the front (re-showing it if it was hidden on close).
    public func showWindow() {
        window?.makeKeyAndOrderFront(nil)
    }

    /// Ask the guest OS to shut down cleanly (equivalent to choosing Shut Down
    /// inside the guest). The terminal state arrives via the delegate → `onStop`.
    public func requestGuestStop() throws {
        guard let virtualMachine, virtualMachine.state == .running else {
            throw MacVMError.message("The VM is not running.")
        }
        try virtualMachine.requestStop()
    }

    /// Force the VM to power off without asking the guest OS to shut down.
    public func stop() async {
        try? await stopReportingErrors()
    }

    /// Force-stop variant used by acknowledged app control requests.
    public func stopReportingErrors() async throws {
        if finished { return }
        if finishing {
            while finishing, !finished {
                try await Task.sleep(for: .milliseconds(50))
            }
            if let finishError { throw finishError }
            if finished { return }
        }

        finishing = true
        finishError = nil
        do {
            await cancelDockerProvisioning()
            // The owner always stops before its hidden sidecar. The socketpair
            // remains retained until both VZVirtualMachine instances are terminal.
            try await stopOwnerVirtualMachine()
            try await stopDockerSidecar()
            completeFinish()
        } catch {
            finishError = error
            finishing = false
            throw error
        }
    }

    /// Persist geometry, stop VNC, drop observers, and clear published state.
    /// Idempotent; also invoked from the terminal-state path.
    public func tearDown() {
        recordWindowGeometry()
        removeWindowObservers()
        stopHeartbeat()
        stopMemoryReclamation()
        deactivateClipboard()
        clipboardRuntime.stop()
        vncServer?.stop()
        vncServer = nil
        vncSession = nil
        bundle.clearVNCSession()
        bundle.clearDisplayRuntimeState()
        if processRuntimeRole != nil {
            bundle.clearVMProcessRuntimeState()
        }
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DebugLog.log("Guest requested stop for \(vmName)")
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finish() }
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DebugLog.log("VM stopped with error for \(vmName): \(error.localizedDescription)")
        fputs("VM stopped with error: \(error.localizedDescription)\n", stderr)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.startupFailureMessage = error.localizedDescription
                self.finish()
            }
        }
    }

    nonisolated public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        DebugLog.log("Network attachment disconnected for \(vmName): \(error.localizedDescription)")
        fputs("VM network attachment disconnected: \(error.localizedDescription)\n", stderr)
    }

    private func finish() {
        guard !finishing, !finished else { return }
        finishing = true
        finishError = nil
        Task { @MainActor in
            await cancelDockerProvisioning()
            do {
                try await stopDockerSidecar()
                completeFinish()
            } catch {
                finishError = error
                finishing = false
                DebugLog.log("Failed to finish Docker sidecar shutdown for \(vmName): \(error.localizedDescription)")
            }
        }
    }

    private func stopOwnerVirtualMachine(timeout: TimeInterval = 30) async throws {
        guard let virtualMachine else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if virtualMachine.state == .stopped || virtualMachine.state == .error {
                return
            }
            if virtualMachine.canStop {
                try await VirtualizationAsync.stop(virtualMachine)
                continue
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MacVMError.message("Timed out stopping \(vmName) while it was in a transitional state.")
    }

    private func stopDockerSidecar() async throws {
        if let dockerSidecarRuntime {
            try await dockerSidecarRuntime.stop()
        }
        dockerSidecarRuntime = nil
    }

    private func cancelDockerProvisioning() async {
        guard let task = dockerProvisioningTask else { return }
        task.cancel()
        await task.value
        dockerProvisioningTask = nil
    }

    private func completeFinish() {
        guard !finished else { return }
        finishing = false
        finishError = nil
        finished = true
        tearDown()
        virtualMachine = nil
        dockerSidecarRuntime = nil
        dockerStartupOperationLock = nil
        dockerPairNetwork = nil
        onStop?()
    }

    // MARK: - Window

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyHostPasteboardToGuest(_:)), #selector(copyGuestPasteboardToHost(_:)):
            return canTransferPasteboard
        default:
            return true
        }
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .clipboardControls:
            return true
        default:
            return true
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        deactivateClipboard()
        sender.orderOut(nil)
        return false
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        activateClipboard()
    }

    public func windowDidResignKey(_ notification: Notification) {
        deactivateClipboard()
    }

    public func windowDidMiniaturize(_ notification: Notification) {
        deactivateClipboard()
    }

    public func windowDidDeminiaturize(_ notification: Notification) {
        if window?.isKeyWindow == true {
            activateClipboard()
        }
    }

    private func activateClipboard() {
        let ownerID = clipboardActivationOwnerID
        let generation = ClipboardActivationCoordinator.shared.activate(ownerID: ownerID) { [weak self] in
            guard let self else { return }
            let oldGeneration = self.clipboardActivationGeneration
            self.clipboardActivationGeneration = nil
            self.clipboardSyncCoordinator.deactivate(generation: oldGeneration)
        }
        clipboardActivationGeneration = generation
        clipboardSyncCoordinator.activate(generation: generation)
    }

    private func deactivateClipboard() {
        ClipboardActivationCoordinator.shared.deactivate(
            ownerID: clipboardActivationOwnerID,
            generation: clipboardActivationGeneration
        )
    }

    private func setUpWindow() throws {
        let displayView = VZVirtualMachineView()
        displayView.postsFrameChangedNotifications = true
        displayView.capturesSystemKeys = true
        displayView.automaticallyReconfiguresDisplay = true
        self.displayView = displayView
        displayView.virtualMachine = virtualMachine

        let baseWidth = min(CGFloat(managedVM.metadata.displayWidth), 1600)
        let baseHeight = min(CGFloat(managedVM.metadata.displayHeight), 1000)
        let contentRect = NSRect(x: 0, y: 0, width: baseWidth, height: baseHeight)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        if let frame = restoredWindowFrame() {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        window.title = vmName
        window.contentView = displayView
        window.delegate = self
        installToolbar(on: window)
        self.window = window
        installWindowObservers(window: window, displayView: displayView)
        DebugLog.log("Created window for \(vmName) frame=\(describe(window.frame)) displayViewFrame=\(describe(displayView.frame))")
    }

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: .vmViewer)
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        // The custom clipboard view supplies its own concise labels, allowing
        // AppKit to keep the controls in the compact titlebar row.
        window.toolbarStyle = .unifiedCompact
        window.toolbar = toolbar
        toolbar.displayMode = .iconOnly
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .clipboardControls,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .clipboardControls,
        ]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self

        switch itemIdentifier {
        case .clipboardControls:
            item.label = "Clipboard"
            item.paletteLabel = "Clipboard"

            let headingLabel = clipboardToolbarLabel("Clipboard:", weight: .semibold)
            let toggle = NSSwitch()
            toggle.target = self
            toggle.action = #selector(automaticClipboardSyncChanged(_:))
            toggle.state = clipboardRuntime.enabled ? .on : .off
            toggle.controlSize = .small
            toggle.isEnabled = virtualMachine?.state == .running
            toggle.setAccessibilityLabel("Automatic Clipboard Sync")
            let automaticSyncLabel = clipboardToolbarLabel("Auto Sync")

            let statusImageView = NSImageView()
            statusImageView.imageScaling = .scaleProportionallyDown
            statusImageView.translatesAutoresizingMaskIntoConstraints = false
            statusImageView.widthAnchor.constraint(equalToConstant: 14).isActive = true
            statusImageView.heightAnchor.constraint(equalToConstant: 14).isActive = true
            statusImageView.setAccessibilityElement(true)
            statusImageView.setAccessibilityLabel("Automatic Clipboard Sync status")
            applyClipboardToolbarStatusPresentation(to: statusImageView)

            let copyInButton = clipboardToolbarButton(
                title: "In",
                systemImage: "arrow.right",
                accessibilityLabel: "Copy Host Pasteboard into VM",
                toolTip: "Copy plain text from the host pasteboard into the VM pasteboard.",
                action: #selector(copyHostPasteboardToGuest(_:))
            )
            let copyOutButton = clipboardToolbarButton(
                title: "Out",
                systemImage: "arrow.left",
                accessibilityLabel: "Copy VM Pasteboard out to Host",
                toolTip: "Copy current plain text from the VM pasteboard to the host pasteboard.",
                action: #selector(copyGuestPasteboardToHost(_:))
            )
            copyInButton.isEnabled = canTransferPasteboard
            copyOutButton.isEnabled = canTransferPasteboard

            let stack = NSStackView(views: [
                headingLabel,
                toggle,
                automaticSyncLabel,
                statusImageView,
                clipboardToolbarSeparator(),
                copyInButton,
                clipboardToolbarSeparator(),
                copyOutButton,
            ])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY
            stack.setHuggingPriority(.required, for: .horizontal)
            stack.setContentCompressionResistancePriority(.required, for: .horizontal)
            item.view = stack

            clipboardToggle = toggle
            clipboardStatusImageView = statusImageView
            copyHostPasteboardToGuestButton = copyInButton
            copyGuestPasteboardToHostButton = copyOutButton
        default:
            return nil
        }

        item.isEnabled = true
        return item
    }

    private func clipboardToolbarLabel(
        _ title: String,
        weight: NSFont.Weight = .regular
    ) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: weight)
        return label
    }

    private func clipboardToolbarButton(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        toolTip: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: accessibilityLabel
        )
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    private func clipboardToolbarSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return separator
    }

    private func restoredWindowFrame() -> NSRect? {
        guard let state = bundle.readViewerWindowState() else {
            return nil
        }

        let frame = NSRect(x: state.x, y: state.y, width: state.width, height: state.height)
        guard frame.width >= 320, frame.height >= 240, isWindowFrameReachable(frame) else {
            return nil
        }
        return frame
    }

    private func isWindowFrameReachable(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return intersection.width >= 160 && intersection.height >= 120
        }
    }

    private func installWindowObservers(window: NSWindow, displayView: VZVirtualMachineView) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)), name: NSWindow.didResizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)), name: NSWindow.didMoveNotification, object: window)
        center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)), name: NSWindow.didEndLiveResizeNotification, object: window)
        center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)), name: NSWindow.didChangeScreenNotification, object: window)
        center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)), name: NSView.frameDidChangeNotification, object: displayView)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(hostWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(hostDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func removeWindowObservers() {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func hostWillSleep(_ notification: Notification) {
        deactivateClipboard()
    }

    @objc private func hostDidWake(_ notification: Notification) {
        if window?.isKeyWindow == true {
            activateClipboard()
        }
    }

    @objc private func windowGeometryDidChange(_ notification: Notification) {
        recordWindowGeometry()
    }

    private func recordWindowGeometry() {
        persistViewerWindowState()
        publishDisplayRuntimeState()
    }

    private func persistViewerWindowState() {
        guard let window else { return }

        let frame = window.frame
        guard frame.width > 0, frame.height > 0, lastPersistedWindowFrame != frame else {
            return
        }

        do {
            try bundle.writeViewerWindowState(VMViewerWindowState(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height,
                updatedAt: Date()
            ))
            lastPersistedWindowFrame = frame
        } catch {
            DebugLog.log("Failed to persist viewer window state for \(vmName): \(error.localizedDescription)")
        }
    }

    private func publishDisplayRuntimeState() {
        guard let size = currentDisplaySize(), lastPublishedDisplaySize != size else {
            return
        }

        do {
            try bundle.writeDisplayRuntimeState(VMDisplayRuntimeState(
                width: size.effectiveWidth,
                height: size.effectiveHeight,
                pixelWidth: size.pixelWidth,
                pixelHeight: size.pixelHeight,
                source: .viewer,
                pid: getpid(),
                updatedAt: Date()
            ))
            lastPublishedDisplaySize = size
        } catch {
            DebugLog.log("Failed to publish viewer display state for \(vmName): \(error.localizedDescription)")
        }
    }

    private func currentDisplaySize() -> DisplayRuntimeSize? {
        guard let displayView else {
            return nil
        }

        let bounds = displayView.bounds
        let backingBounds = displayView.convertToBacking(displayView.bounds)
        let effectiveWidth = Int(bounds.width.rounded())
        let effectiveHeight = Int(bounds.height.rounded())
        let pixelWidth = Int(backingBounds.width.rounded())
        let pixelHeight = Int(backingBounds.height.rounded())
        guard effectiveWidth > 0, effectiveHeight > 0, pixelWidth > 0, pixelHeight > 0 else {
            return nil
        }
        return DisplayRuntimeSize(
            effectiveWidth: effectiveWidth,
            effectiveHeight: effectiveHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    // MARK: - VM lifecycle

    private func createAndStartVirtualMachine() throws {
        let additionalNetworkDevices = try prepareDockerSidecarIfNeeded()
        let configuration: VZVirtualMachineConfiguration
        do {
            configuration = try bundle.makeConfiguration(
                metadata: managedVM.metadata,
                additionalNetworkDevices: additionalNetworkDevices
            )
        } catch {
            abortDockerSidecar()
            throw error
        }

        DebugLog.log("Creating VZVirtualMachine for \(vmName) on main queue")

        let virtualMachine = VZVirtualMachine(configuration: configuration, queue: DispatchQueue.main)
        virtualMachine.delegate = self
        self.virtualMachine = virtualMachine
        displayView?.virtualMachine = virtualMachine

        clipboardRuntime.prepare(on: virtualMachine)

        // _VZVNCServer binds all interfaces, so every viewer session must use
        // a per-run password even when its primary display is a local window.
        let password = Self.randomVNCPassword()
        var server: MacVMVNCServer?
        do {
            let createdServer = try MacVMVNCServer(
                virtualMachine: virtualMachine,
                port: requestedVNCPort,
                password: password
            )
            server = createdServer
            let port = try createdServer.start().intValue
            vncServer = createdServer
            let session = VNCSession(
                port: port,
                password: password,
                pid: getpid(),
                startedAt: Date(),
                ownerRole: processRuntimeRole ?? .viewer
            )
            try bundle.writeVNCSession(session)
            vncSession = session
            if let processRuntimeRole {
                try bundle.writeVMProcessRuntimeState(VMProcessRuntimeState(
                    role: processRuntimeRole,
                    pid: getpid(),
                    startedAt: session.startedAt
                ))
            }
            if displayView == nil {
                try bundle.writeDisplayRuntimeState(VMDisplayRuntimeState(
                    width: managedVM.metadata.displayWidth,
                    height: managedVM.metadata.displayHeight,
                    pixelWidth: managedVM.metadata.displayPixelWidth,
                    pixelHeight: managedVM.metadata.displayPixelHeight,
                    source: .headless,
                    pid: getpid(),
                    updatedAt: Date()
                ))
            }
        } catch {
            server?.stop()
            vncServer = nil
            bundle.clearVNCSession()
            bundle.clearVMProcessRuntimeState()
            displayView?.virtualMachine = nil
            self.virtualMachine = nil
            abortDockerSidecar()
            throw error
        }

        let snapshot = snapshot(for: virtualMachine)
        DebugLog.log("Viewer VM canStart=\(snapshot.canStart) currentState=\(describe(snapshot.state))")

        startHeartbeat()
        try startVirtualMachine()
    }

    private func prepareDockerSidecarIfNeeded() throws -> [VZNetworkDeviceConfiguration] {
        guard !startInRecovery else { return [] }
        let operationLock = try bundle.acquireDockerSidecarOperationLock(operation: "start the VM")
        dockerStartupOperationLock = operationLock
        do {
            let currentMetadata = try bundle.recoverDockerSidecarReplacementIfNeeded()
            guard let settings = currentMetadata.dockerSidecar, settings.enabled else {
                dockerStartupOperationLock = nil
                return []
            }
            _ = try bundle.dockerSidecarBundle.validateIntegrity()
            let pairNetwork = try DockerPairNetwork()
            let runtime = try DockerSidecarRuntime(
                ownerBundle: bundle,
                settings: settings,
                pairNetwork: pairNetwork
            )
            try runtime.start()
            self.dockerPairNetwork = pairNetwork
            self.dockerSidecarRuntime = runtime
            dockerStartupOperationLock = nil
            return [try pairNetwork.makeMacOSNetworkDevice(macAddress: settings.macOSMACAddress)]
        } catch {
            dockerStartupOperationLock = nil
            abortDockerSidecar()
            throw error
        }
    }

    private func abortDockerSidecar() {
        guard dockerSidecarRuntime != nil else {
            dockerPairNetwork = nil
            return
        }
        Task { @MainActor in
            do {
                try await stopDockerSidecar()
                dockerPairNetwork = nil
            } catch {
                DebugLog.log("Failed to abort Docker sidecar startup for \(vmName): \(error.localizedDescription)")
            }
        }
    }

    private func startVirtualMachine() throws {
        guard let virtualMachine else {
            throw MacVMError.message("The virtual machine wasn't initialized.")
        }

        let snapshot = snapshot(for: virtualMachine)
        DebugLog.log("Attempting VM start for \(vmName) recovery=\(startInRecovery) canStart=\(snapshot.canStart) state=\(describe(snapshot.state))")

        let vmName = self.vmName
        let handleFailure: @Sendable (Error) -> Void = { error in
            DebugLog.log("Failed to start VM \(vmName): \(error.localizedDescription)")
            fputs("Failed to start VM: \(error.localizedDescription)\n", stderr)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.startupFailureMessage = error.localizedDescription
                    self.finish()
                }
            }
        }

        if startInRecovery {
            let options = VZMacOSVirtualMachineStartOptions()
            options.startUpFromMacOSRecovery = true
            virtualMachine.start(options: options) { error in
                if let error {
                    handleFailure(error)
                } else {
                    DebugLog.log("start(options:) completion returned success for \(vmName)")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.refreshPasteboardCommandState()
                            self.startMemoryReclamation(for: virtualMachine)
                        }
                    }
                }
            }
        } else {
            virtualMachine.start { result in
                if case .failure(let error) = result {
                    handleFailure(error)
                } else {
                    DebugLog.log("start() completion returned success for \(vmName)")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.refreshPasteboardCommandState()
                            self.startMemoryReclamation(for: virtualMachine)
                            self.provisionDockerGuestIntegrationIfNeeded()
                        }
                    }
                }
            }
        }
    }

    private func startMemoryReclamation(for virtualMachine: VZVirtualMachine) {
        guard memoryBalloonRegistrationID == nil else { return }
        memoryBalloonRegistrationID = MemoryPressureCoordinator.shared.register(
            virtualMachine: virtualMachine,
            label: vmName,
            guestKind: .macOS,
            configuredMemorySize: managedVM.metadata.memorySizeBytes
        )
    }

    private func stopMemoryReclamation() {
        guard let memoryBalloonRegistrationID else { return }
        MemoryPressureCoordinator.shared.unregister(memoryBalloonRegistrationID)
        self.memoryBalloonRegistrationID = nil
    }

    private func provisionDockerGuestIntegrationIfNeeded() {
        guard dockerProvisioningTask == nil,
              !startInRecovery,
              let settings = managedVM.metadata.dockerSidecar,
              settings.enabled,
              settings.guestProvisioningState != .ready
                || settings.guestProvisioningVersion < DockerSidecarSettings.currentGuestProvisioningVersion,
              let dockerSidecarRuntime else {
            return
        }
        let service = MacVMService(rootDirectory: managedVM.bundleURL.deletingLastPathComponent())
        let managedVM = self.managedVM
        let vmName = self.vmName
        dockerProvisioningTask = Task { @MainActor [weak self] in
            defer { self?.dockerProvisioningTask = nil }
            do {
                try await dockerSidecarRuntime.waitUntilServicesReady()
                try Task.checkCancellation()
                _ = try await service.provisionDockerGuestIntegration(for: managedVM)
                try Task.checkCancellation()
                dockerSidecarRuntime.markGuestProvisioningReady()
                DebugLog.log("Docker guest integration completed for \(vmName)")
            } catch is CancellationError {
                DebugLog.log("Docker guest integration cancelled for \(vmName)")
            } catch {
                dockerSidecarRuntime.markGuestProvisioningFailed(error)
                DebugLog.log("Docker guest integration degraded for \(vmName): \(error.localizedDescription)")
            }
        }
    }

    private func snapshot(for virtualMachine: VZVirtualMachine) -> VMSnapshot {
        VMSnapshot(state: virtualMachine.state, canStart: virtualMachine.canStart)
    }

    private func startHeartbeat() {
        stopHeartbeat()

        let timer = Timer(timeInterval: 2.0, target: self, selector: #selector(heartbeatFired), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        startHeartbeatTimer = timer
    }

    private func stopHeartbeat() {
        startHeartbeatTimer?.invalidate()
        startHeartbeatTimer = nil
    }

    @objc private func heartbeatFired() {
        guard let virtualMachine else {
            stopHeartbeat()
            return
        }

        let snapshot = snapshot(for: virtualMachine)
        DebugLog.log(
            "Startup heartbeat for \(vmName): state=\(describe(snapshot.state)) canStart=\(snapshot.canStart) windowVisible=\(window?.isVisible == true) viewFrame=\(describe(displayView?.bounds))"
        )

        switch snapshot.state {
        case .running:
            DebugLog.log("VM reached running state for \(vmName)")
            stopHeartbeat()
            refreshPasteboardCommandState()
        case .stopped, .error:
            DebugLog.log("VM reached terminal state for \(vmName): \(describe(snapshot.state))")
            stopHeartbeat()
            finish()
        default:
            break
        }
    }

    // MARK: - Clipboard over RFB

    private var canTransferPasteboard: Bool {
        virtualMachine?.state == .running
            && clipboardActivationGeneration != nil
            && !clipboardTransferInProgress
    }

    static func clipboardToolbarStatusPresentation(
        for status: ClipboardRuntimeStatus
    ) -> ClipboardToolbarStatusPresentation {
        if !status.enabled {
            return ClipboardToolbarStatusPresentation(
                symbolName: "minus.circle.fill",
                tone: .off,
                toolTip: "Automatic Clipboard Sync is off. Clipboard helper: \(status.helper.displayName)."
            )
        }
        if !status.viewerActive {
            return ClipboardToolbarStatusPresentation(
                symbolName: "pause.circle.fill",
                tone: .inactive,
                toolTip: "Automatic Clipboard Sync is inactive until this VM viewer is the key window. Clipboard helper: \(status.helper.displayName)."
            )
        }
        switch status.helper {
        case .connecting:
            return ClipboardToolbarStatusPresentation(
                symbolName: "ellipsis.circle.fill",
                tone: .connecting,
                toolTip: "Automatic Clipboard Sync is connecting to the guest clipboard helper."
            )
        case .connected:
            return ClipboardToolbarStatusPresentation(
                symbolName: "checkmark.circle.fill",
                tone: .connected,
                toolTip: "Automatic Clipboard Sync is connected."
            )
        case .disconnected, .unpaired, .outdatedHelper, .hostUpdateRequired, .unavailable:
            return ClipboardToolbarStatusPresentation(
                symbolName: "exclamationmark.triangle.fill",
                tone: .warning,
                toolTip: "Automatic Clipboard Sync is unavailable. Clipboard helper: \(status.helper.displayName)."
            )
        }
    }

    private func applyClipboardToolbarStatusPresentation(to imageView: NSImageView) {
        let presentation = Self.clipboardToolbarStatusPresentation(for: clipboardRuntime.status)
        let symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12,
            weight: .semibold
        )
        imageView.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.toolTip
        )?.withSymbolConfiguration(symbolConfiguration)
        imageView.contentTintColor = presentation.tone.color
        imageView.toolTip = presentation.toolTip
        imageView.setAccessibilityValue(presentation.toolTip)
    }

    @objc private func automaticClipboardSyncChanged(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        do {
            try setAutomaticClipboardSyncEnabled(enabled)
        } catch {
            sender.state = clipboardRuntime.enabled ? .on : .off
            presentClipboardError(error.localizedDescription)
        }
        refreshPasteboardCommandState()
    }

    @objc public func copyHostPasteboardToGuest(_ sender: Any?) {
        guard let generation = clipboardActivationGeneration,
              let text = NSPasteboard.general.string(forType: .string) else {
            presentClipboardError("Host pasteboard does not contain plain text or this viewer is inactive.")
            return
        }
        do {
            _ = try ClipboardPayload.encodeText(text)
        } catch {
            presentClipboardError(error.localizedDescription)
            return
        }

        runClipboardTransfer {
            guard self.clipboardActivationGeneration == generation else {
                throw MacVMError.message("The viewer is no longer active.")
            }
            do {
                _ = try await self.clipboardRuntime.writeText(text, timeout: 1)
            } catch {
                guard Self.shouldFallbackToClipboardVNC(for: error) else { throw error }
                guard self.clipboardActivationGeneration == generation else {
                    throw MacVMError.message("The viewer is no longer active.")
                }
                try await self.withClipboardRFBClient { client in
                    try await client.setClipboardText(text)
                }
            }
        }
    }

    @objc public func copyGuestPasteboardToHost(_ sender: Any?) {
        guard let generation = clipboardActivationGeneration else {
            presentClipboardError("This viewer is not active.")
            return
        }
        runClipboardTransfer {
            let text: String
            do {
                text = try await self.clipboardRuntime.readText(timeout: 1)
            } catch {
                guard Self.shouldFallbackToClipboardVNC(for: error) else { throw error }
                guard self.clipboardActivationGeneration == generation else {
                    throw MacVMError.message("The viewer is no longer active.")
                }
                text = try await self.withClipboardRFBClient { client in
                    try await client.waitForClipboardText(timeout: 30)
                }
            }
            _ = try ClipboardPayload.encodeText(text)
            guard self.clipboardActivationGeneration == generation else {
                throw MacVMError.message("The viewer is no longer active.")
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    private func runClipboardTransfer(_ operation: @escaping () async throws -> Void) {
        guard !clipboardTransferInProgress else { return }
        clipboardTransferInProgress = true
        refreshPasteboardCommandState()

        Task { @MainActor in
            defer {
                clipboardTransferInProgress = false
                refreshPasteboardCommandState()
            }

            do {
                try await operation()
            } catch {
                presentClipboardError(error.localizedDescription)
            }
        }
    }

    private func refreshPasteboardCommandState() {
        clipboardToggle?.state = clipboardRuntime.enabled ? .on : .off
        clipboardToggle?.isEnabled = virtualMachine?.state == .running
        if let clipboardStatusImageView {
            applyClipboardToolbarStatusPresentation(to: clipboardStatusImageView)
        }
        copyHostPasteboardToGuestButton?.isEnabled = canTransferPasteboard
        copyGuestPasteboardToHostButton?.isEnabled = canTransferPasteboard
        NSApplication.shared.mainMenu?.update()
        window?.toolbar?.validateVisibleItems()
    }

    private func withClipboardRFBClient<T>(_ body: (RFBClient) async throws -> T) async throws -> T {
        guard virtualMachine?.state == .running else {
            throw MacVMError.message("The VM must be running before its pasteboard can be accessed.")
        }
        guard let session = vncSession, let password = session.password else {
            throw MacVMError.message("The viewer VNC session is unavailable.")
        }

        let client = RFBClient(port: session.port)
        do {
            try await client.connect(password: password)
            let result = try await body(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    private func presentClipboardError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Pasteboard Transfer Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        if let window = window ?? NSApplication.shared.keyWindow {
            alert.beginSheetModal(for: window) { _ in }
        } else {
            alert.runModal()
        }
    }

    static func shouldFallbackToClipboardVNC(for error: Error) -> Bool {
        if let unavailable = error as? ClipboardHelperUnavailableError,
           case .unavailable(let state) = unavailable {
            switch state {
            case .connecting, .disconnected, .unavailable:
                return true
            case .connected, .unpaired, .outdatedHelper, .hostUpdateRequired:
                return false
            }
        }
        if let protocolError = error as? ClipboardProtocolError {
            switch protocolError {
            case .connectionClosed, .timedOut:
                return true
            default:
                return false
            }
        }
        return error is POSIXError
    }

    private static func randomVNCPassword() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }

    // MARK: - Debug helpers

    private func describe(_ rect: NSRect?) -> String {
        guard let rect else {
            return "nil"
        }

        return "{x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) w=\(Int(rect.size.width)) h=\(Int(rect.size.height))}"
    }

    private func describe(_ state: VZVirtualMachine.State?) -> String {
        guard let state else {
            return "nil"
        }

        switch state {
        case .stopped:
            return "stopped"
        case .running:
            return "running"
        case .paused:
            return "paused"
        case .error:
            return "error"
        case .starting:
            return "starting"
        case .pausing:
            return "pausing"
        case .resuming:
            return "resuming"
        case .stopping:
            return "stopping"
        case .saving:
            return "saving"
        case .restoring:
            return "restoring"
        @unknown default:
            return "unknown"
        }
    }
}

enum DockerGuestProvisioningWaitDecision: Equatable {
    case waiting
    case ready
    case failed(String)

    static func make(
        settings: DockerSidecarSettings?,
        runtime: DockerSidecarRuntimeDescriptor?,
        ownerFinished: Bool
    ) -> Self {
        guard let settings, settings.enabled else {
            return .failed("Docker was disabled while guest integration was being installed.")
        }
        if settings.guestProvisioningState == .ready,
           settings.guestProvisioningVersion >= DockerSidecarSettings.currentGuestProvisioningVersion {
            return .ready
        }
        if runtime?.state == .degraded {
            return .failed(runtime?.lastError ?? "Docker guest integration failed.")
        }
        if ownerFinished {
            return .failed("The macOS VM stopped before Docker guest integration completed.")
        }
        return .waiting
    }
}
