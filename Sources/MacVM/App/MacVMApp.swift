import AppKit
import MacVMHostKit
import SwiftUI

@main
struct MacVMApp: App {
    @NSApplicationDelegateAdaptor(MacVMApplicationDelegate.self) private var applicationDelegate
    @State private var store: AppStore
    private let controlOnlyLaunch: Bool

    init() {
        let controlOnlyLaunch = CommandLine.arguments.contains(
            MacVMAppControlQueue.controlOnlyArgument
        )
        self.controlOnlyLaunch = controlOnlyLaunch
        let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        let testRoot = isUnitTestHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent("macvm-app-test-host-\(getpid())", isDirectory: true)
            : nil
        let store = AppStore(
            service: MacVMService(rootDirectory: testRoot ?? MacVMSettings.shared.configuredVMRootDirectory),
            controlQueue: MacVMAppControlQueue()
        )
        _store = State(initialValue: store)
        MacVMApplicationDelegate.store = store
        MacVMApplicationDelegate.controlOnlyLaunch = controlOnlyLaunch

        DispatchQueue.main.async {
            if controlOnlyLaunch {
                NSApplication.shared.setActivationPolicy(.accessory)
            } else if Bundle.main.bundleIdentifier == nil {
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

        Settings {
            MacVMSettingsView()
                .environment(store)
        }
    }
}
