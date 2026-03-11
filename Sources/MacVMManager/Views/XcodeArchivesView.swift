import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let xcodeDownloadURL = URL(string: "https://developer.apple.com/download/applications/")!

struct XcodeArchivesView: View {
    @Environment(AppStore.self) private var store
    @State private var pendingDeletion: XcodeArchiveEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Xcode")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Xcode .xip archives available for VM setup")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        DownloadLinkRow(
                            label: "Download:",
                            url: xcodeDownloadURL,
                            copyKey: "xcode-download-url"
                        )
                    }
                    Spacer()
                    Button {
                        chooseXcodeArchive(selectForCreate: false)
                    } label: {
                        Label("Add Xcode…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(store.xcodeImportInProgress)
                }

                if let status = store.xcodeImportStatus {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Card {
                    if store.xcodeArchives.isEmpty {
                        Text("No Xcode archives yet. Add an Xcode .xip to make it available during VM setup.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.xcodeArchives.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 {
                                    Divider().overlay(Theme.hairline)
                                }
                                XcodeArchiveRow(entry: entry) {
                                    pendingDeletion = entry
                                }
                            }
                        }
                    }
                }

                Text(footnote)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            pendingDeletion.map { "Delete “\($0.name)”?" } ?? "Delete Xcode archive?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDeletion {
                    store.deleteXcodeArchive(entry)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cached Xcode .xip will be removed from disk. VMs that already installed Xcode are not affected.")
        }
    }

    private var footnote: String {
        let path = CLIEquivalent.abbreviatePath(
            XcodeArchiveCatalog.cacheDirectory(root: store.service.rootDirectory).path
        )
        let total = XcodeArchiveCatalog.totalSizeBytes(store.xcodeArchives)
        return "\(path) · \(RestoreImageCatalog.formattedSize(total)) on disk"
    }

    private func chooseXcodeArchive(selectForCreate: Bool) {
        let panel = NSOpenPanel()
        if let xipType = UTType(filenameExtension: "xip") {
            panel.allowedContentTypes = [xipType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            store.importXcodeArchive(from: url, selectForCreate: selectForCreate)
        }
    }
}

private struct XcodeArchiveRow: View {
    @Environment(AppStore.self) private var store
    let entry: XcodeArchiveEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hammer")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: 13, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("New VM…") {
                store.openCreateSheet(prefillXcode: entry.url)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)

            Button("Delete…", role: .destructive) {
                onDelete()
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var metaLine: String {
        [
            RestoreImageCatalog.formattedSize(entry.sizeBytes),
            "cached \(DateFormatter.mediumDate.string(from: entry.modifiedAt))",
        ].joined(separator: " · ")
    }
}
