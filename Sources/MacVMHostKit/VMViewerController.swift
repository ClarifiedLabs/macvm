import AppKit
import Darwin
import Foundation
import MacVMPrivateVZ
import Virtualization

/// Owns one viewer window and its VM: the `NSWindow` + `VZVirtualMachineView`,
/// the `VZVirtualMachine` lifecycle, window-geometry persistence, live display
/// state publishing, and clipboard-over-RFB transfers.
///
/// Deliberately free of `NSApplication` concerns so it can serve both the CLI
/// viewer child process (`VMViewer` wraps it and owns the app lifecycle) and a
/// host app that presents many viewer windows inside one `NSApplication`.
@MainActor
public final class VMViewerController: NSObject, VZVirtualMachineDelegate, NSMenuItemValidation, NSWindowDelegate {
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
    private var startInRecovery = false
    public private(set) var window: NSWindow?
    private var displayView: VZVirtualMachineView?
    private var virtualMachine: VZVirtualMachine?
    private let processRuntimeRole: VMProcessRuntimeRole?
    private var vncServer: MacVMVNCServer?
    private var vncSession: VNCSession?
    private var clipboardTransferInProgress = false
    private var startHeartbeatTimer: Timer?
    private var lastPublishedDisplaySize: DisplayRuntimeSize?
    private var lastPersistedWindowFrame: NSRect?
    private var finished = false

    /// Called once when the VM reaches a terminal state (guest shutdown, error,
    /// or failed start). The CLI wrapper terminates the process; a host app
    /// closes the window and releases the controller.
    public var onStop: (@MainActor () -> Void)?

    public init(managedVM: ManagedVM, processRuntimeRole: VMProcessRuntimeRole? = nil) {
        self.managedVM = managedVM
        self.bundle = VMBundle(url: managedVM.bundleURL)
        self.vmName = managedVM.metadata.name
        self.processRuntimeRole = processRuntimeRole
    }

    public var isRunning: Bool {
        virtualMachine?.state == .running
    }

    public var isFinished: Bool {
        finished
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
        try createAndStartVirtualMachine()
    }

    /// Convenience for hosts: build the window, boot the VM, and return the
    /// window for presentation.
    @discardableResult
    public func makeWindowAndStart(startInRecovery: Bool = false) throws -> NSWindow {
        let window = try makeWindow()
        try start(startInRecovery: startInRecovery)
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
        if let virtualMachine, virtualMachine.state == .running || virtualMachine.state == .paused {
            try? await VirtualizationAsync.stop(virtualMachine)
        }
        finish()
    }

    /// Persist geometry, stop VNC, drop observers, and clear published state.
    /// Idempotent; also invoked from the terminal-state path.
    public func tearDown() {
        recordWindowGeometry()
        removeWindowObservers()
        stopHeartbeat()
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
            MainActor.assumeIsolated { self.finish() }
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
        guard !finished else { return }
        finished = true
        tearDown()
        virtualMachine = nil
        onStop?()
    }

    // MARK: - Window

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copyHostPasteboardToGuest(_:)), #selector(copyGuestPasteboardToHost(_:)):
            return virtualMachine?.state == .running && !clipboardTransferInProgress
        default:
            return true
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func setUpWindow() throws {
        let displayView = VZVirtualMachineView()
        displayView.postsFrameChangedNotifications = true
        displayView.capturesSystemKeys = true
        displayView.automaticallyReconfiguresDisplay = true
        self.displayView = displayView

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
        self.window = window
        installWindowObservers(window: window, displayView: displayView)
        DebugLog.log("Created window for \(vmName) frame=\(describe(window.frame)) displayViewFrame=\(describe(displayView.frame))")
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
    }

    private func removeWindowObservers() {
        NotificationCenter.default.removeObserver(self)
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
        let configuration = try bundle.makeConfiguration(metadata: managedVM.metadata)

        DebugLog.log("Creating VZVirtualMachine for \(vmName) on main queue")

        let virtualMachine = VZVirtualMachine(configuration: configuration, queue: DispatchQueue.main)
        virtualMachine.delegate = self
        self.virtualMachine = virtualMachine
        displayView?.virtualMachine = virtualMachine

        // _VZVNCServer binds all interfaces, so every viewer session must use
        // a per-run password even when its primary display is a local window.
        let password = Self.randomVNCPassword()
        let server = try MacVMVNCServer(virtualMachine: virtualMachine, port: 0, password: password)
        do {
            let port = try server.start().intValue
            vncServer = server
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
        } catch {
            server.stop()
            vncServer = nil
            bundle.clearVNCSession()
            bundle.clearVMProcessRuntimeState()
            displayView?.virtualMachine = nil
            self.virtualMachine = nil
            throw error
        }

        let snapshot = snapshot(for: virtualMachine)
        DebugLog.log("Viewer VM canStart=\(snapshot.canStart) currentState=\(describe(snapshot.state))")

        startHeartbeat()
        try startVirtualMachine()
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
                MainActor.assumeIsolated { self.finish() }
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
                }
            }
        } else {
            virtualMachine.start { result in
                if case .failure(let error) = result {
                    handleFailure(error)
                } else {
                    DebugLog.log("start() completion returned success for \(vmName)")
                }
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
        case .stopped, .error:
            DebugLog.log("VM reached terminal state for \(vmName): \(describe(snapshot.state))")
            stopHeartbeat()
            finish()
        default:
            break
        }
    }

    // MARK: - Clipboard over RFB

    @objc public func copyHostPasteboardToGuest(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            presentClipboardError("Host pasteboard does not contain plain text.")
            return
        }

        runClipboardTransfer {
            try await self.withClipboardRFBClient { client in
                try await client.setClipboardText(text)
            }
        }
    }

    @objc public func copyGuestPasteboardToHost(_ sender: Any?) {
        runClipboardTransfer {
            let text = try await self.withClipboardRFBClient { client in
                try await client.waitForClipboardText(timeout: 30)
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    private func runClipboardTransfer(_ operation: @escaping () async throws -> Void) {
        guard !clipboardTransferInProgress else { return }
        clipboardTransferInProgress = true
        NSApplication.shared.mainMenu?.update()

        Task { @MainActor in
            defer {
                clipboardTransferInProgress = false
                NSApplication.shared.mainMenu?.update()
            }

            do {
                try await operation()
            } catch {
                presentClipboardError(error.localizedDescription)
            }
        }
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
