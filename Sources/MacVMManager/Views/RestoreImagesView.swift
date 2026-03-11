import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let restoreImageDownloadURL = URL(string: "https://developer.apple.com/download/os/")!

struct RestoreImagesView: View {
    @Environment(AppStore.self) private var store
    @State private var pendingDeletion: RestoreImageEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Restore Images")
                            .font(.system(size: 22, weight: .semibold))
                        Text("IPSWs cached for reuse when creating VMs")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        DownloadLinkRow(
                            label: "Download:",
                            url: restoreImageDownloadURL,
                            copyKey: "restore-image-download-url"
                        )
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button {
                            chooseRestoreImage()
                        } label: {
                            Label("Add Image…", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(store.restoreImageImportInProgress)

                        Button {
                            store.checkForLatest()
                        } label: {
                            Label("Check for Latest", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }

                if let status = store.latestCheckStatus {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Card {
                    if store.restoreImages.isEmpty {
                        Text("No cached restore images yet. Add an IPSW or run `macvm create` with the latest supported restore image.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(store.restoreImages.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 {
                                    Divider().overlay(Theme.hairline)
                                }
                                RestoreImageRow(entry: entry) {
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
            pendingDeletion.map { "Delete “\($0.name)”?" } ?? "Delete cached restore image?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = pendingDeletion {
                    store.deleteRestoreImage(entry)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The cached IPSW will be removed from disk. Creating a VM with the latest supported restore image may download it again.")
        }
    }

    private var footnote: String {
        let path = CLIEquivalent.abbreviatePath(
            RestoreImageCatalog.cacheDirectory(root: store.service.rootDirectory).path
        )
        let total = RestoreImageCatalog.totalSizeBytes(store.restoreImages)
        return "\(path) · \(RestoreImageCatalog.formattedSize(total)) on disk"
    }

    private func chooseRestoreImage() {
        let panel = NSOpenPanel()
        if let ipswType = UTType(filenameExtension: "ipsw") {
            panel.allowedContentTypes = [ipswType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            store.importRestoreImage(from: url)
        }
    }
}

private struct RestoreImageRow: View {
    @Environment(AppStore.self) private var store
    let entry: RestoreImageEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if entry.isLatest {
                        Text("Latest supported")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                Text(metaLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("New VM…") {
                store.openCreateSheet(prefillIPSW: entry.url)
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
        .task(id: entry.id) {
            await store.loadRestoreImageLabel(for: entry)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if let label = store.restoreImageLabels[entry.name] {
            parts.append(label)
        }
        parts.append(RestoreImageCatalog.formattedSize(entry.sizeBytes))
        parts.append("cached \(DateFormatter.mediumDate.string(from: entry.modifiedAt))")
        return parts.joined(separator: " · ")
    }
}
