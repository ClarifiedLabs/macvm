import AppKit
import SwiftUI

@main
struct MacVMApp: App {
    @State private var store = AppStore()

    init() {
        // Unbundled executable launches have no app bundle, so AppKit starts
        // with the accessory activation policy.
        if Bundle.main.bundleIdentifier == nil {
            DispatchQueue.main.async {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ManagerWindow()
                .environment(store)
        }
        .commands {
            CommandMenu("VM") {
                Button("Copy Host Pasteboard to VM Pasteboard") {
                    store.activeViewer?.copyHostPasteboardToGuest(nil)
                }
                .disabled(!(store.activeViewer?.isRunning ?? false))

                Button("Copy Next VM Pasteboard Update to Host") {
                    store.activeViewer?.copyGuestPasteboardToHost(nil)
                }
                .disabled(!(store.activeViewer?.isRunning ?? false))
            }
        }
    }
}
