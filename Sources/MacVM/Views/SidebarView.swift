import MacVMHostKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var isFocused: Bool
    @State private var initialFocusPolicy = SidebarInitialFocusPolicy()

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section("Virtual Machines") {
                ForEach(store.sidebarLibraryVMReferences, id: \.self) { reference in
                    VMRow(reference: reference)
                        .tag(SidebarItem.vm(reference))
                        .contextMenu {
                            Button("Clone…") {
                                if let vm = store.vm(for: reference) {
                                    store.requestClone(vm)
                                }
                            }
                            .disabled(store.status(for: reference) != .stopped)

                            Button("Remove…", role: .destructive) {
                                store.requestRemove(store.name(for: reference))
                            }
                            .disabled(store.status(for: reference) != .stopped)
                        }
                }
            }
            if !store.sidebarExternalVMReferences.isEmpty {
                Section("Running Outside Library") {
                    ForEach(store.sidebarExternalVMReferences, id: \.self) { reference in
                        VMRow(reference: reference, showsBundlePath: true)
                            .tag(SidebarItem.vm(reference))
                    }
                }
            }
            Section("Library") {
                Label("Restore Images", systemImage: "clock")
                    .tag(SidebarItem.images)
                Label("Xcode", systemImage: "hammer")
                    .tag(SidebarItem.xcode)
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case .vm(let reference) = store.selection,
               store.sidebarLibraryVMReferences.contains(reference) {
                store.requestRemove(store.name(for: reference))
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 320)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
        .onChange(of: store.selection) {
            store.updateCommandForSelection()
        }
        .focused($isFocused)
        .task {
            guard initialFocusPolicy.consumeFocusRequest(for: store.selection) else { return }
            await Task.yield()
            isFocused = true
        }
    }
}

private struct VMRow: View {
    @Environment(AppStore.self) private var store
    let reference: VMReference
    var showsBundlePath = false

    var body: some View {
        let name = store.name(for: reference)
        HStack(spacing: 8) {
            StatusDot(status: store.status(for: reference))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text(store.sidebarSubtitle(for: reference))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if showsBundlePath, let vm = store.vm(for: reference) {
                    Text(CLIEquivalent.abbreviatePath(vm.bundleURL.path))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SidebarFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            if let icon = AppIconLoader.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("MacVM")
                        .font(.system(size: 11, weight: .semibold))
                    Text(MacVMVersion.displayVersion())
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text(CLIEquivalent.abbreviatePath(store.service.rootDirectory.path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
