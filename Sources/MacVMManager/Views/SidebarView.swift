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
                ForEach(store.sidebarVMNames, id: \.self) { name in
                    VMRow(name: name)
                        .tag(SidebarItem.vm(name))
                        .contextMenu {
                            Button("Remove…", role: .destructive) {
                                store.requestRemove(name)
                            }
                            .disabled(store.status(forName: name) != .stopped)
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
            if case .vm(let name) = store.selection {
                store.requestRemove(name)
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
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: store.status(forName: name))
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Text(store.sidebarSubtitle(forName: name))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
