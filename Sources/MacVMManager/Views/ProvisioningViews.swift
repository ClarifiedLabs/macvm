import AppKit
import MacVMHostKit
import SwiftUI

struct ProvisioningProfilePicker: View {
    @Environment(AppStore.self) private var store
    var forProvisioning = false

    private var selectedIDs: Set<String> {
        forProvisioning ? store.provisionProfileIDs : store.selectedProfileIDs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groupedCategories, id: \.0) { category, profiles in
                VStack(alignment: .leading, spacing: 5) {
                    Text(category.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(profiles) { profile in
                        VStack(alignment: .leading, spacing: 5) {
                            Toggle(
                                isOn: Binding(
                                    get: { selectedIDs.contains(profile.id) },
                                    set: { store.setProfile(profile.id, selected: $0, forProvisioning: forProvisioning) }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 5) {
                                        Text(profile.manifest.name)
                                        if profile.source != .bundled {
                                            Text(profile.source.label)
                                                .font(.system(size: 9, weight: .medium))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(.quaternary)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(profile.manifest.description)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if selectedIDs.contains(profile.id) {
                                profileInputs(profile)
                                    .padding(.leading, 22)
                            }
                        }
                    }
                }
            }

            if !store.profileCatalog.diagnostics.isEmpty {
                ForEach(store.profileCatalog.diagnostics) { diagnostic in
                    Label(diagnostic.message, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .help(diagnostic.path)
                }
            }

            Button("Open Profiles Folder") {
                let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("macvm/Profiles", isDirectory: true)
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                NSWorkspace.shared.open(base)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func profileInputs(_ profile: ProvisioningProfile) -> some View {
        ForEach(profile.manifest.inputs) { input in
            HStack(spacing: 8) {
                Text(input.label + ":")
                    .font(.system(size: 11))
                    .frame(width: 100, alignment: .trailing)
                inputControl(profileID: profile.id, input: input)
            }
        }
    }

    @ViewBuilder
    private func inputControl(profileID: String, input: ProvisioningInputDefinition) -> some View {
        let value = inputBinding(profileID: profileID, input: input)
        switch input.type {
        case .boolean:
            Toggle("", isOn: Binding(
                get: { ["true", "yes", "1"].contains(value.wrappedValue.lowercased()) },
                set: { value.wrappedValue = $0 ? "true" : "false" }
            ))
            .labelsHidden()
        case .choice:
            Picker("", selection: value) {
                ForEach(input.choices ?? [], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
        case .secret:
            HStack(spacing: 6) {
                SecureField(input.help ?? "Secret", text: value)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        value.wrappedValue = "file:\(url.path)"
                    }
                }
            }
        case .string:
            TextField(input.help ?? "", text: value)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func inputBinding(profileID: String, input: ProvisioningInputDefinition) -> Binding<String> {
        Binding(
            get: {
                let values = forProvisioning ? store.provisionInputValues : store.profileInputValues
                return values[profileID]?[input.id] ?? input.defaultValue?.stringValue ?? ""
            },
            set: {
                store.setProfileInput(
                    profileID: profileID,
                    key: input.id,
                    value: $0,
                    forProvisioning: forProvisioning
                )
            }
        )
    }

    private var groupedCategories: [(String, [ProvisioningProfile])] {
        let visible = store.profileCatalog.profiles.filter { !$0.manifest.hidden }
        return Dictionary(grouping: visible, by: { $0.manifest.category })
            .map { ($0.key, $0.value.sorted { $0.manifest.name < $1.manifest.name }) }
            .sorted { $0.0 < $1.0 }
    }
}

struct ProvisionVMSheet: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Provision \(store.provisionSheetVMName ?? "VM")")
                .font(.system(size: 15, weight: .semibold))
            ScrollView {
                ProvisioningProfilePicker(forProvisioning: true)
            }
            .frame(maxHeight: 480)
            HStack {
                Spacer()
                Button("Cancel") { store.provisionSheetVMName = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Provision") { store.submitProvision() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(store.provisionProfileIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 620)
    }
}

struct ProvisioningSectionView: View {
    @Environment(AppStore.self) private var store
    let vm: ManagedVM
    let status: VMStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Provisioning")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    if let message = store.provisioningStatus[vm.metadata.name] {
                        Label(message, systemImage: "gearshape.2")
                            .font(.system(size: 12))
                    }
                    let records = store.provisioningStates[vm.metadata.name]?.profiles.values.sorted {
                        $0.profileID < $1.profileID
                    } ?? []
                    if records.isEmpty {
                        Text("No provisioning profiles have been recorded.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(records, id: \.profileID) { record in
                            let currentDigest = store.profileCatalog.profile(id: record.profileID)?.definitionDigest
                            let outdated = currentDigest != nil && currentDigest != record.definitionDigest
                            HStack {
                                Image(systemName: outdated ? "arrow.triangle.2.circlepath.circle.fill" : (record.status == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill"))
                                    .foregroundStyle(outdated ? .orange : (record.status == .succeeded ? .green : .red))
                                Text(record.profileID)
                                Spacer()
                                Text(outdated ? "Update available" : "v\(record.version)")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                        }
                    }
                    Button("Provision…") { store.openProvisionSheet(vm) }
                        .disabled(status != .running || store.provisioningStatus[vm.metadata.name] != nil)
                        .help(status == .running ? "Apply provisioning profiles" : "Start the VM before provisioning")
                }
            }
        }
    }
}
