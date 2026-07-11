import AppKit
import Darwin
import Foundation
import Virtualization

/// The CLI viewer process: wraps a `VMViewerController` in a full
/// `NSApplication` lifecycle for `macvm run`. It owns everything that only
/// makes sense when the viewer is the whole app — the main menu, the parent
/// process monitor, and process termination when the VM stops. Closing the
/// display only hides it; reopening the Dock app restores it.
@MainActor
public final class VMViewer: NSObject, NSApplicationDelegate {
    private let controller: VMViewerController
    private let bundle: VMBundle
    private let vmName: String
    private let monitorsParent: Bool
    private let processRuntimeRole: VMProcessRuntimeRole?
    private let processLogPath: String?
    private var startInRecovery = false
    private var parentMonitorSource: DispatchSourceProcess?

    public init(
        managedVM: ManagedVM,
        monitorsParent: Bool = true,
        processRuntimeRole: VMProcessRuntimeRole? = nil,
        processLogPath: String? = nil
    ) {
        self.controller = VMViewerController(managedVM: managedVM)
        self.bundle = VMBundle(url: managedVM.bundleURL)
        self.vmName = managedVM.metadata.name
        self.monitorsParent = monitorsParent
        self.processRuntimeRole = processRuntimeRole
        self.processLogPath = processLogPath
    }

    public func run(startInRecovery: Bool = false) throws {
        self.startInRecovery = startInRecovery
        DebugLog.log("Launching viewer for \(vmName) recovery=\(startInRecovery) bundleID=\(Bundle.main.bundleIdentifier ?? "nil") bundleURL=\(Bundle.main.bundleURL.path)")

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        installMenu()
        if monitorsParent {
            installParentMonitor()
        }
        try controller.makeWindow()
        if let processRuntimeRole {
            try bundle.writeVMProcessRuntimeState(VMProcessRuntimeState(
                role: processRuntimeRole,
                pid: getpid(),
                startedAt: Date(),
                logPath: processLogPath
            ))
        }
        controller.onStop = { [weak self] in
            self?.terminateApplication()
        }
        app.run()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("applicationDidFinishLaunching for \(vmName)")
        controller.showWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            try controller.start(startInRecovery: startInRecovery)
        } catch {
            fputs("Failed to start VM: \(error.localizedDescription)\n", stderr)
            NSApplication.shared.terminate(nil)
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showWindow()
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        controller.tearDown()
        if processRuntimeRole != nil {
            bundle.clearVMProcessRuntimeState()
        }
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)

        let applicationMenu = NSMenu()
        let quitTitle = "Quit \(ProcessInfo.processInfo.processName)"
        applicationMenu.addItem(withTitle: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenuItem.submenu = applicationMenu

        let vmMenuItem = NSMenuItem()
        mainMenu.addItem(vmMenuItem)

        let vmMenu = NSMenu(title: "VM")
        let copyToGuestItem = vmMenu.addItem(
            withTitle: "Copy Host Pasteboard to VM Pasteboard",
            action: #selector(VMViewerController.copyHostPasteboardToGuest(_:)),
            keyEquivalent: ""
        )
        copyToGuestItem.target = controller

        let copyToHostItem = vmMenu.addItem(
            withTitle: "Copy Next VM Pasteboard Update to Host",
            action: #selector(VMViewerController.copyGuestPasteboardToHost(_:)),
            keyEquivalent: ""
        )
        copyToHostItem.target = controller
        vmMenuItem.submenu = vmMenu

        NSApplication.shared.mainMenu = mainMenu
    }

    private func installParentMonitor() {
        let parentPID = getppid()
        guard parentPID > 1 else { return }

        let source = DispatchSource.makeProcessSource(
            identifier: parentPID, eventMask: .exit, queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            performSelector(
                onMainThread: #selector(terminateApplication),
                with: nil, waitUntilDone: false
            )
        }
        source.resume()
        self.parentMonitorSource = source
    }

    @objc private func terminateApplication() {
        NSApplication.shared.terminate(nil)
    }
}
