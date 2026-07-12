import SwiftUI

struct ManagerWindow: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
        } detail: {
            VStack(spacing: 0) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                CLIBar()
            }
            .navigationTitle(contextTitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.openCreateSheet()
                    } label: {
                        Label("New VM", systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 620)
        .sheet(isPresented: $store.localNetworkOnboardingPresented) {
            LocalNetworkOnboardingView {
                store.acknowledgeLocalNetworkOnboarding()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $store.sheetPresented) {
            CreateVMSheet()
        }
        .sheet(
            isPresented: Binding(
                get: { store.cloneSheetSourceName != nil },
                set: { if !$0 { store.cloneSheetSourceName = nil } }
            )
        ) {
            CloneVMSheet()
        }
        .sheet(
            isPresented: Binding(
                get: { store.provisionSheetVMName != nil },
                set: { if !$0 { store.provisionSheetVMName = nil } }
            )
        ) {
            ProvisionVMSheet()
        }
        .alert(
            "MacVM Manager",
            isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.dismissAlert() } }
            )
        ) {
            if store.alertRemovalCandidate != nil {
                Button("Remove Incomplete VM", role: .destructive) {
                    store.requestAlertRemoval()
                }
            }
            Button("OK", role: .cancel) {
                store.dismissAlert()
            }
        } message: {
            Text(store.alertMessage ?? "")
        }
        .confirmationDialog(
            "Remove VM “\(store.pendingRemoval ?? "")”?",
            isPresented: Binding(
                get: { store.pendingRemoval != nil },
                set: { if !$0 { store.pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                store.confirmRemove()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
        .confirmationDialog(
            powerActionTitle,
            isPresented: Binding(
                get: { store.pendingPowerAction != nil },
                set: { if !$0 { store.pendingPowerAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(powerActionButtonTitle, role: .destructive) {
                store.confirmPowerAction()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(powerActionMessage)
        }
    }

    private var removalMessage: String {
        guard let name = store.pendingRemoval else { return "" }
        let path = store.vm(named: name)
            .map { CLIEquivalent.abbreviatePath($0.bundleURL.path) } ?? name
        return "The bundle at \(path) will be deleted. This cannot be undone."
    }

    private var powerActionTitle: String {
        guard let action = store.pendingPowerAction else { return "" }
        switch action.kind {
        case .stop:
            return "Stop VM “\(action.name)”?"
        case .shutDown:
            return "Shut Down VM “\(action.name)”?"
        }
    }

    private var powerActionButtonTitle: String {
        guard let action = store.pendingPowerAction else { return "" }
        switch action.kind {
        case .stop:
            return "Stop"
        case .shutDown:
            return "Shut Down"
        }
    }

    private var powerActionMessage: String {
        guard let action = store.pendingPowerAction else { return "" }
        switch action.kind {
        case .stop:
            return "The VM will be powered off immediately. Unsaved guest work may be lost."
        case .shutDown:
            return "The guest will be asked to shut down cleanly."
        }
    }

    private var contextTitle: String {
        switch store.selection {
        case .vm(let name): name
        case .images: "Restore Images"
        case .xcode: "Xcode"
        case nil: "MacVM Manager"
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch store.selection {
        case .vm(let name):
            VMDetailView(name: name)
        case .images:
            RestoreImagesView()
        case .xcode:
            XcodeArchivesView()
        case nil:
            ContentUnavailableView(
                "No VM Selected",
                systemImage: "desktopcomputer",
                description: Text("Select a virtual machine or create one with New VM.")
            )
        }
    }
}

private struct LocalNetworkOnboardingView: View {
    let continueAction: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Local Network Access")
                .font(.title2.bold())

            Text("MacVM Manager connects to your virtual machines over a private virtual network for setup, SSH, and management. macOS will ask for Local Network access when the first virtual machine needs it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Continue", action: continueAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 460)
    }
}
