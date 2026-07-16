import AppKit

@MainActor
final class MacVMApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var store: AppStore?
    static var controlOnlyLaunch = false

    private weak var managerWindow: NSWindow?
    private var terminationInProgress = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if Self.controlOnlyLaunch {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.controlOnlyLaunch else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            managerWindow = NSApplication.shared.windows.first
            managerWindow?.orderOut(nil)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        sender.setActivationPolicy(.regular)
        if !flag {
            let window = managerWindow ?? sender.windows.first
            window?.makeKeyAndOrderFront(nil)
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationInProgress, let store = Self.store else {
            return .terminateNow
        }
        guard store.ownedRuntimeCount > 0 else {
            store.prepareForTermination()
            return .terminateNow
        }

        sender.setActivationPolicy(.regular)
        sender.activate(ignoringOtherApps: true)

        let count = store.ownedRuntimeCount
        let alert = NSAlert()
        alert.messageText = "Quit MacVM and stop running VMs?"
        alert.informativeText = "MacVM currently owns \(count) running VM\(count == 1 ? "" : "s"). Quitting the app will force-stop \(count == 1 ? "it" : "all of them")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit and Stop VMs")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        terminationInProgress = true
        Task { @MainActor in
            store.prepareForTermination()
            await store.stopAllOwnedRuntimes()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
