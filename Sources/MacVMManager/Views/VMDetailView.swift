import MacVMHostKit
import SwiftUI

struct VMDetailView: View {
    @Environment(AppStore.self) private var store
    let name: String

    var body: some View {
        let vm = store.vm(named: name)
        let status = store.status(forName: name)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(vm: vm, status: status)

                if status == .settingUp, let setup = store.setups[name] {
                    SetupProgressCard(setup: setup)
                }
                if status == .installing, let install = store.installs[name] {
                    InstallingCard(install: install)
                }

                if let vm {
                    SpecCardsView(vm: vm, status: status)
                    AccessSectionView(vm: vm, status: status)
                    AutomationSectionView(vm: vm)
                    BundleSectionView(vm: vm)
                }
            }
            .padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(vm: ManagedVM?, status: VMStatus) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.system(size: 22, weight: .semibold))
                HStack(spacing: 6) {
                    StatusDot(status: status)
                    Text(status.headerLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let vm {
                actionButtons(vm: vm, status: status)
            }
        }
    }

    @ViewBuilder
    private func actionButtons(vm: ManagedVM, status: VMStatus) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .stopped:
                Button("Recovery") {
                    store.runViewer(vm, recovery: true)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                Button {
                    store.runViewer(vm)
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.runGreen)

            case .running:
                if store.hasViewer(forName: name) {
                    Button("Open Viewer") {
                        store.openViewer(vm)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }

                Button {
                    store.requestShutDown(vm)
                } label: {
                    Label("Shut Down", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.shutDownRed)

                Button {
                    store.requestStop(vm)
                } label: {
                    Label("Stop", systemImage: "xmark.octagon.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.stopRed)

            case .settingUp:
                Button {
                    store.requestShutDown(vm)
                } label: {
                    Label("Shut Down", systemImage: "power")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.shutDownRed)

                Button {
                    store.requestStop(vm)
                } label: {
                    Label("Stop", systemImage: "xmark.octagon.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.stopRed)

            case .installing:
                EmptyView()
            }
        }
        .controlSize(.regular)
    }
}

struct AutomationSectionView: View {
    @Environment(AppStore.self) private var store
    let vm: ManagedVM

    var body: some View {
        let name = vm.metadata.name
        let enabled = store.launchOnBootStatuses[name]?.enabled ?? false

        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Automation")
            Card {
                InfoRow(label: "Launch on boot", value: enabled ? "Enabled" : "Disabled") {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.launchOnBootStatuses[name]?.enabled ?? false },
                            set: { store.setLaunchOnBoot($0, for: vm) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }
}

struct SpecCardsView: View {
    @Environment(AppStore.self) private var store
    let vm: ManagedVM
    let status: VMStatus

    var body: some View {
        let metadata = vm.metadata
        let gib: (UInt64) -> String = { "\($0 / (1024 * 1024 * 1024))" }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            SpecCard(label: "CPU", value: "\(metadata.cpuCount)", unit: "cores")
            SpecCard(label: "Memory", value: gib(metadata.memorySizeBytes), unit: "GiB")
            SpecCard(label: "Disk", value: gib(metadata.diskSizeBytes), unit: "GiB")
            SpecCard(
                label: "Display",
                value: Self.displayResolutionText(
                    metadata: metadata,
                    status: status,
                    liveDisplay: store.liveDisplays[metadata.name]
                ),
                unit: "points"
            )
        }
    }

    nonisolated static func displayResolutionText(
        metadata: VMMetadata,
        status: VMStatus,
        liveDisplay: VMDisplayRuntimeState?
    ) -> String {
        let width: Int
        let height: Int
        if status != .stopped, let liveDisplay {
            width = liveDisplay.width
            height = liveDisplay.height
        } else {
            width = metadata.displayWidth
            height = metadata.displayHeight
        }
        return "\(width) × \(height)"
    }
}

private struct SpecCard: View {
    let label: String
    let value: String
    var unit: String?
    var detailLines: [String] = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(detailLines, id: \.self) { line in
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct AccessSectionView: View {
    @Environment(AppStore.self) private var store
    let vm: ManagedVM
    let status: VMStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Access")
            Card {
                if status == .running {
                    runningRows
                } else {
                    HStack(spacing: 6) {
                        Text(placeholderText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if status == .settingUp, let vncURL = setupVNCURL {
                            Button {
                                store.copy(vncURL, key: "access-vnc", command: CLIEquivalent.vnc(vm.metadata.name))
                            } label: {
                                Image(systemName: store.copiedKey == "access-vnc" ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundStyle(store.copiedKey == "access-vnc" ? .green : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy vnc:// URL")

                            Button {
                                store.openVNCURL(vncURL, name: vm.metadata.name)
                            } label: {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Open vnc:// URL")
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var runningRows: some View {
        let name = vm.metadata.name
        let user = store.service.guestUser(for: vm, override: nil)
        let ip = store.guestIPs[name]

        VStack(spacing: 0) {
            InfoRow(label: "IP address", value: ip ?? "Resolving…") {
                if let ip {
                    CopyButton(key: "access-ip", text: ip, command: CLIEquivalent.ip(name))
                }
            }
            Divider().overlay(Theme.hairline)
            InfoRow(label: "SSH", value: ip.map { "ssh \(user)@\($0)" } ?? "Waiting for IP…") {
                if let ip {
                    CopyButton(key: "access-ssh", text: "ssh \(user)@\(ip)", command: CLIEquivalent.ssh(name))
                }
            }
            Divider().overlay(Theme.hairline)
            InfoRow(
                label: "Ansible inventory",
                value: ip.map { store.service.inventoryLine(vm, host: $0, user: nil) } ?? "Waiting for IP…"
            ) {
                if let ip {
                    CopyButton(
                        key: "access-inventory",
                        text: store.service.inventoryLine(vm, host: ip, user: nil),
                        command: CLIEquivalent.inventory(name)
                    )
                }
            }
            if let vncURL = runningVNCURL {
                Divider().overlay(Theme.hairline)
                InfoRow(label: "VNC", value: vncURL) {
                    HStack(spacing: 6) {
                        CopyButton(key: "access-vnc", text: vncURL, command: CLIEquivalent.vnc(name))
                        Button {
                            store.openVNCURL(vncURL, name: name)
                        } label: {
                            Label("Open", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var runningVNCURL: String? {
        store.liveSessions[vm.metadata.name]?.vncURLString
    }

    private var setupVNCURL: String? {
        store.setups[vm.metadata.name]?.vncURL ?? (try? store.service.vncURL(for: vm))
    }

    private var placeholderText: String {
        switch status {
        case .stopped:
            "Start the VM to obtain an IP. For iCloud sign-in, run with the viewer window."
        case .settingUp:
            "SSH becomes available when setup finishes. Attach to the live session via its vnc:// URL."
        case .installing:
            "Access appears after installation and first boot."
        case .running:
            ""
        }
    }
}

struct BundleSectionView: View {
    @Environment(AppStore.self) private var store
    let vm: ManagedVM

    var body: some View {
        let metadata = vm.metadata
        let location = CLIEquivalent.abbreviatePath(vm.bundleURL.path)
        let created = DateFormatter.mediumDate.string(from: metadata.createdAt)
            + (metadata.macAddress.map { " · MAC \($0)" } ?? "")

        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Bundle")
            Card {
                VStack(spacing: 0) {
                    InfoRow(label: "Location", value: location) {
                        CopyButton(key: "bundle-location", text: vm.bundleURL.path)
                    }
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "Restore image", value: metadata.installedRestoreImageName ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "Created", value: created)
                }
            }
        }
    }
}
