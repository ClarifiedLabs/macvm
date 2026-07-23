import AppKit
import MacVMHostKit
import SwiftUI

struct AppRuntimePolicy: Equatable {
    let isUnitTestHost: Bool

    var usesSharedControlQueue: Bool { !isUnitTestHost }
    var requestsLocalNetworkAccess: Bool { !isUnitTestHost }

    static func resolve(environment: [String: String], xctestLoaded: Bool) -> AppRuntimePolicy {
        AppRuntimePolicy(
            isUnitTestHost: environment["XCTestConfigurationFilePath"] != nil || xctestLoaded
        )
    }
}

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
        let runtimePolicy = AppRuntimePolicy.resolve(
            environment: ProcessInfo.processInfo.environment,
            xctestLoaded: NSClassFromString("XCTestCase") != nil
        )
        let testRoot = runtimePolicy.isUnitTestHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent("macvm-app-test-host-\(getpid())", isDirectory: true)
            : nil
        let controlQueue: MacVMAppControlQueue? = runtimePolicy.usesSharedControlQueue
            ? MacVMAppControlQueue()
            : nil
        let triggerLocalNetworkPrivacyAlert: () -> Void
        if runtimePolicy.requestsLocalNetworkAccess {
            triggerLocalNetworkPrivacyAlert = LocalNetworkPrivacy.triggerAlert
        } else {
            triggerLocalNetworkPrivacyAlert = {}
        }
        let store = AppStore(
            service: MacVMService(rootDirectory: testRoot ?? MacVMSettings.shared.configuredVMRootDirectory),
            controlQueue: controlQueue,
            triggerLocalNetworkPrivacyAlert: triggerLocalNetworkPrivacyAlert
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
                Button {
                    store.activeViewer?.copyHostPasteboardToGuest(nil)
                } label: {
                    Label("Paste to VM →", systemImage: "arrow.right")
                }
                .disabled(!(store.activeViewer?.isRunning ?? false))

                Button {
                    store.activeViewer?.copyGuestPasteboardToHost(nil)
                } label: {
                    Label("← Copy from VM", systemImage: "arrow.left")
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
