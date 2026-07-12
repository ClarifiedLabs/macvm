import AppKit
import MacVMHostKit
import SwiftUI
import UniformTypeIdentifiers

struct CreateVMSheet: View {
    @Environment(AppStore.self) private var store

    private static let displayOptions: [(label: String, width: Int, height: Int)] = [
        ("1280 × 720", 1280, 720),
        ("1440 × 900", 1440, 900),
        ("1512 × 982", 1512, 982),
    ]

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 16) {
            Text("New Virtual Machine")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    fieldLabel("Name:")
                    TextField("dev-01", text: $store.draft.name)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow(alignment: .top) {
                    fieldLabel("Restore image:")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Picker("", selection: restoreImageSelection) {
                                Text("Latest supported").tag("")
                                ForEach(store.restoreImages) { entry in
                                    Text(entry.name).tag(entry.url.path)
                                }
                                if let url = uncachedSelectedRestoreImage {
                                    Text(url.lastPathComponent).tag(url.path)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 240)

                            Button("Choose…") { chooseIPSW() }
                                .controlSize(.small)
                                .disabled(store.restoreImageImportInProgress)
                                .help("Import a local IPSW into the restore image cache")
                        }
                        Text(restoreImageSelectionDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                stepperRow(
                    label: "CPU:",
                    value: $store.draft.cpuCount,
                    range: 2...12,
                    step: 1,
                    display: "\(store.draft.cpuCount)",
                    hint: "host has \(ProcessInfo.processInfo.processorCount) cores"
                )
                stepperRow(
                    label: "Memory:",
                    value: $store.draft.memoryGiB,
                    range: 4...64,
                    step: 4,
                    display: "\(store.draft.memoryGiB) GiB",
                    hint: Self.hostMemoryHint()
                )
                stepperRow(
                    label: "Disk:",
                    value: $store.draft.diskGiB,
                    range: 40...500,
                    step: 20,
                    display: "\(store.draft.diskGiB) GiB",
                    hint: "fixed after create"
                )

                GridRow {
                    fieldLabel("Display:")
                    HStack(spacing: 8) {
                        Picker("", selection: displaySelection) {
                            ForEach(Self.displayOptions, id: \.label) { option in
                                Text(option.label).tag(option.label)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        Text("Retina 2x · \(store.draft.displayPixelWidth) × \(store.draft.displayPixelHeight) pixels")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }

                GridRow(alignment: .top) {
                    Color.clear
                        .frame(width: 110, height: 1)
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Create shared folder with bootstrap script", isOn: $store.draft.createBootstrapShare)
                        Toggle("Launch on boot", isOn: $store.draft.launchOnBoot)
                        Toggle(isOn: $store.setupAfterInstall) {
                            HStack(spacing: 4) {
                                Text("Run setup after install")
                                Text("— SSH-ready, admin/admin")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if store.setupAfterInstall {
                            HStack(spacing: 8) {
                                Text("Xcode:")
                                    .foregroundStyle(.secondary)
                                Picker("", selection: xcodeSelection) {
                                    Text("Do not install").tag("")
                                    ForEach(store.xcodeArchives) { entry in
                                        Text(entry.name).tag(entry.url.path)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(width: 220)
                                Button("Choose .xip…") { chooseXcode() }
                                    .controlSize(.small)
                                    .disabled(store.xcodeImportInProgress)
                            }
                            if let status = store.xcodeImportStatus, store.xcodeImportInProgress {
                                Text(status)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            Divider()
                                .padding(.vertical, 3)
                            Text("Provisioning profiles")
                                .font(.system(size: 12, weight: .semibold))
                            ProvisioningProfilePicker()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13))
                }
            }

            CLICommandStrip(command: store.createCommandPreview)

            HStack {
                Spacer()
                Button("Cancel") {
                    store.sheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Create") {
                    store.submitCreate()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!createEnabled)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var createEnabled: Bool {
        let name = store.draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        if store.draft.restoreMode == .localFile && store.draft.localRestoreImageURL == nil {
            return false
        }
        if store.restoreImageImportInProgress {
            return false
        }
        if store.xcodeImportInProgress {
            return false
        }
        return true
    }

    nonisolated static func hostMemoryHint(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        let bytesPerGiB = 1024.0 * 1024.0 * 1024.0
        let memoryGiB = Int((Double(physicalMemoryBytes) / bytesPerGiB).rounded())
        return "host has \(memoryGiB) GB"
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .gridColumnAlignment(.trailing)
            .frame(width: 110, alignment: .trailing)
    }

    private func stepperRow(
        label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        display: String,
        hint: String
    ) -> some View {
        GridRow {
            fieldLabel(label)
            HStack(spacing: 8) {
                Stepper(value: value, in: range, step: step) {
                    Text(display)
                        .font(.system(size: 13, weight: .medium))
                        .frame(minWidth: 52, alignment: .center)
                }
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var displaySelection: Binding<String> {
        @Bindable var store = store
        return Binding(
            get: {
                Self.displayOptions.first {
                    $0.width == store.draft.displayWidth && $0.height == store.draft.displayHeight
                }?.label ?? "\(store.draft.displayWidth) × \(store.draft.displayHeight)"
            },
            set: { label in
                guard let option = Self.displayOptions.first(where: { $0.label == label }) else { return }
                store.draft.displayWidth = option.width
                store.draft.displayHeight = option.height
            }
        )
    }

    private var xcodeSelection: Binding<String> {
        @Bindable var store = store
        return Binding(
            get: {
                store.selectedXcodeXIPURL?.path ?? ""
            },
            set: { path in
                store.selectedXcodeXIPURL = path.isEmpty ? nil : URL(fileURLWithPath: path)
                if !path.isEmpty {
                    store.setProfile("apple-development", selected: true)
                }
            }
        )
    }

    private var restoreImageSelection: Binding<String> {
        @Bindable var store = store
        return Binding(
            get: {
                guard store.draft.restoreMode == .localFile else { return "" }
                return store.draft.localRestoreImageURL?.path ?? ""
            },
            set: { path in
                if path.isEmpty {
                    store.draft.restoreMode = .latestSupported
                    store.draft.localRestoreImageURL = nil
                } else {
                    store.draft.restoreMode = .localFile
                    store.draft.localRestoreImageURL = URL(fileURLWithPath: path)
                }
            }
        )
    }

    private var uncachedSelectedRestoreImage: URL? {
        guard store.draft.restoreMode == .localFile,
              let url = store.draft.localRestoreImageURL else {
            return nil
        }
        let selectedURL = url.standardizedFileURL
        let isCached = store.restoreImages.contains {
            $0.url.standardizedFileURL == selectedURL
        }
        return isCached ? nil : url
    }

    private var restoreImageSelectionDetail: String {
        if store.restoreImageImportInProgress, let status = store.latestCheckStatus {
            return status
        }
        guard store.draft.restoreMode == .localFile,
              let url = store.draft.localRestoreImageURL else {
            return "Fetched from Apple, cached"
        }
        let selectedURL = url.standardizedFileURL
        if let entry = store.restoreImages.first(where: { $0.url.standardizedFileURL == selectedURL }) {
            return [
                RestoreImageCatalog.formattedSize(entry.sizeBytes),
                "cached \(DateFormatter.mediumDate.string(from: entry.modifiedAt))",
            ].joined(separator: " · ")
        }
        return "Local IPSW file"
    }

    private func chooseIPSW() {
        let panel = NSOpenPanel()
        if let ipswType = UTType(filenameExtension: "ipsw") {
            panel.allowedContentTypes = [ipswType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            store.importRestoreImage(from: url, selectForCreate: true)
        }
    }

    private func chooseXcode() {
        let panel = NSOpenPanel()
        if let xipType = UTType(filenameExtension: "xip") {
            panel.allowedContentTypes = [xipType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            store.importXcodeArchive(from: url, selectForCreate: true)
        }
    }
}
