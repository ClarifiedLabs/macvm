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
                    if let vm {
                        SetupProgressCard(setup: setup, vm: vm)
                    }
                }
                if status == .installing, let install = store.installs[name] {
                    InstallingCard(name: name, install: install)
                }
                if status == .cloning, let clone = store.clones[name] {
                    CloningCard(clone: clone)
                }

                if let vm {
                    SpecCardsView(vm: vm, status: status)
                    DockerSectionView(vm: vm, vmStatus: status)
                    AccessSectionView(vm: vm, status: status)
                    ClipboardSectionView(vm: vm, vmStatus: status)
                    AutomationSectionView(vm: vm)
                    ProvisioningSectionView(vm: vm, status: status)
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
                    Text(headerStatus(status: status))
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

    private func headerStatus(status: VMStatus) -> String {
        guard status == .settingUp,
              let phase = store.setups[name]?.currentPhase else {
            return status.headerLabel
        }
        return "Setting up — \(phase.title)"
    }

    @ViewBuilder
    private func actionButtons(vm: ManagedVM, status: VMStatus) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .stopped:
                Button("Clone…") {
                    store.requestClone(vm)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

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
                Button {
                    store.attach(vm)
                } label: {
                    Label("Attach", systemImage: "display")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)

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
                    store.attach(vm)
                } label: {
                    Label("Attach", systemImage: "display")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)

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

            case .cloning, .installing:
                EmptyView()
            }
        }
        .controlSize(.regular)
    }
}

struct DockerSectionView: View {
    @Environment(AppStore.self) private var store
    let vm: ManagedVM
    let vmStatus: VMStatus
    @State private var resources: DockerResourceFormValues

    init(vm: ManagedVM, vmStatus: VMStatus) {
        self.vm = vm
        self.vmStatus = vmStatus
        _resources = State(initialValue: DockerResourceFormValues(settings: vm.metadata.dockerSidecar))
    }

    var body: some View {
        let name = vm.metadata.name
        let dockerStatus = store.dockerStatuses[name] ?? store.service.dockerStatus(for: vm)
        let busy = store.dockerOperationMessages[name] != nil
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Docker")
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        StatusDot(status: dockerStatus.state == .ready ? .running : .stopped)
                        Text(dockerStatus.state.rawValue)
                            .font(.system(size: 13, weight: .medium))
                        if let version = dockerStatus.fcosVersion {
                            Text("Fedora CoreOS \(version)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        dockerActions(status: dockerStatus, busy: busy)
                    }
                    if let operation = store.dockerOperationMessages[name] {
                        ProgressView().controlSize(.small)
                        Text(operation).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if vm.metadata.dockerSidecar != nil {
                        Divider().overlay(Theme.hairline)
                        HStack(spacing: 12) {
                            Stepper("\(resources.cpuCount) CPU", value: $resources.cpuCount, in: 1...12)
                            Stepper("\(resources.memoryGiB) GiB", value: $resources.memoryGiB, in: 2...32, step: 2)
                            Stepper("\(resources.diskGiB) GiB disk", value: $resources.diskGiB, in: max(1, Int((vm.metadata.dockerSidecar?.dataDiskSizeBytes ?? 0) / (1024 * 1024 * 1024)))...512, step: 16)
                            Toggle("linux/amd64", isOn: $resources.amd64Enabled).toggleStyle(.checkbox)
                            Button("Apply") {
                                store.configureDocker(
                                    for: vm,
                                    cpuCount: resources.cpuCount,
                                    memoryGiB: resources.memoryGiB,
                                    diskGiB: resources.diskGiB,
                                    amd64Enabled: resources.amd64Enabled
                                )
                            }
                            .disabled(vmStatus != .stopped || busy)
                        }
                        .controlSize(.small)
                    }
                    if let error = dockerStatus.lastError {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    }
                }
                .padding(14)
            }
        }
        .onChange(of: vm.metadata.dockerSidecar) { _, settings in
            resources.synchronize(with: settings)
        }
    }

    @ViewBuilder
    private func dockerActions(status: DockerSidecarStatus, busy: Bool) -> some View {
        HStack(spacing: 6) {
            if status.state == .disabled {
                Button("Enable") { store.enableDocker(for: vm) }
            } else {
                Button("Disable") { store.disableDocker(for: vm) }
            }
            if status.amd64Requested && !status.amd64Available {
                Button("Install Rosetta…") { store.installDockerRosetta() }
            }
            if vm.metadata.dockerSidecar != nil {
                Button("Update") { store.updateDocker(for: vm) }
                Button("Reset…") { store.resetDocker(for: vm) }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(vmStatus != .stopped || busy || vm.metadata.setupCompletedAt == nil)
    }
}

struct DockerResourceFormValues: Equatable {
    private static let bytesPerGiB: UInt64 = 1024 * 1024 * 1024

    var cpuCount: Int
    var memoryGiB: Int
    var diskGiB: Int
    var amd64Enabled: Bool

    init(settings: DockerSidecarSettings?) {
        cpuCount = settings?.cpuCount ?? DockerSidecarSettings.defaultCPUCount
        memoryGiB = Int(
            (settings?.memorySizeBytes
                ?? UInt64(DockerSidecarSettings.defaultMemoryGiB) * Self.bytesPerGiB)
                / Self.bytesPerGiB
        )
        diskGiB = Int(
            (settings?.dataDiskSizeBytes
                ?? UInt64(DockerSidecarSettings.defaultDiskGiB) * Self.bytesPerGiB)
                / Self.bytesPerGiB
        )
        amd64Enabled = settings?.amd64Enabled ?? true
    }

    mutating func synchronize(with settings: DockerSidecarSettings?) {
        self = DockerResourceFormValues(settings: settings)
    }
}

struct ClipboardSectionView: View {
    @Environment(AppStore.self) private var store
    let vm: ManagedVM
    let vmStatus: VMStatus

    var body: some View {
        let status = store.clipboardStatus(for: vm)
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Clipboard")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle(
                            "Automatic Clipboard Sync",
                            isOn: Binding(
                                get: { status.enabled },
                                set: { store.setAutomaticClipboardSync($0, for: vm) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        Spacer()
                        Text(statusText(status))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Automatic Clipboard Sync status")
                            .accessibilityValue(statusText(status))
                    }
                    if let installError = vm.metadata.clipboardHelperInstallError {
                        Text(ClipboardSectionView.helperRepairText(installError, vmName: vm.metadata.name))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Clipboard helper repair needed")
                    }
                    Text(explanation(status))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }
        }
    }

    private func statusText(_ status: ClipboardRuntimeStatus) -> String {
        if !status.enabled {
            return "Off · Helper \(status.helper.displayName.lowercased())"
        }
        if !status.viewerActive {
            return "Inactive window · Helper \(status.helper.displayName.lowercased())"
        }
        return status.helper.displayName
    }

    private func explanation(_ status: ClipboardRuntimeStatus) -> String {
        if vmStatus == .stopped {
            return "Synchronization starts only after the VM boots and its native viewer becomes the key window."
        }
        if !status.viewerActive {
            return "Synchronization is inactive until this VM's native viewer is the key window."
        }
        return "Plain UTF-8 text only, up to 1 MiB."
    }

    /// The helper is optional: setup completed without it, so the VM stays usable
    /// and the failure is repaired explicitly with `macvm clipboard install`.
    static func helperRepairText(_ installError: String, vmName: String) -> String {
        "Clipboard helper unavailable: \(installError) The VM is otherwise ready; run `macvm clipboard install \(vmName)` while the VM is running to repair it."
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
    struct Capabilities: Equatable {
        var showsIP: Bool
        var showsSSH: Bool
        var showsInventory: Bool
        var showsVNC: Bool

        var hasRows: Bool {
            showsIP || showsSSH || showsInventory || showsVNC
        }
    }

    @Environment(AppStore.self) private var store
    let vm: ManagedVM
    let status: VMStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Access")
            Card {
                if capabilities.hasRows {
                    accessRows
                } else {
                    HStack(spacing: 6) {
                        Text(placeholderText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var accessRows: some View {
        let name = vm.metadata.name
        let setup = store.setups[name]
        let user = setup?.username ?? store.service.guestUser(for: vm, override: nil)
        let ip = setup?.ipAddress ?? store.guestIPs[name]
        let vncURL = liveVNCURL

        VStack(spacing: 0) {
            if capabilities.showsIP {
                InfoRow(label: "IP address", value: ip ?? "Resolving…") {
                    if let ip {
                        CopyButton(key: "access-ip", text: ip, command: CLIEquivalent.ip(name))
                    }
                }
            }
            if capabilities.showsSSH {
                if capabilities.showsIP {
                    Divider().overlay(Theme.hairline)
                }
                InfoRow(label: "SSH", value: ip.map { "ssh \(user)@\($0)" } ?? "Waiting for IP…") {
                    if let ip {
                        CopyButton(key: "access-ssh", text: "ssh \(user)@\(ip)", command: CLIEquivalent.ssh(name))
                    }
                }
            }
            if capabilities.showsInventory {
                if capabilities.showsIP || capabilities.showsSSH {
                    Divider().overlay(Theme.hairline)
                }
                InfoRow(
                    label: "Ansible inventory",
                    value: ip.map { store.service.inventoryLine(vm, host: $0, user: user) } ?? "Waiting for IP…"
                ) {
                    if let ip {
                        CopyButton(
                            key: "access-inventory",
                            text: store.service.inventoryLine(vm, host: ip, user: user),
                            command: CLIEquivalent.inventory(name)
                        )
                    }
                }
            }
            if capabilities.showsVNC, let vncURL {
                if capabilities.showsIP || capabilities.showsSSH || capabilities.showsInventory {
                    Divider().overlay(Theme.hairline)
                }
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

    private var capabilities: Capabilities {
        Self.capabilities(
            status: status,
            hasIP: (store.setups[vm.metadata.name]?.ipAddress ?? store.guestIPs[vm.metadata.name]) != nil,
            sshReady: store.setups[vm.metadata.name]?.sshReady == true,
            hasVNC: liveVNCURL != nil
        )
    }

    static func capabilities(
        status: VMStatus,
        hasIP: Bool,
        sshReady: Bool,
        hasVNC: Bool
    ) -> Capabilities {
        switch status {
        case .running:
            Capabilities(showsIP: true, showsSSH: true, showsInventory: true, showsVNC: hasVNC)
        case .settingUp:
            Capabilities(
                showsIP: hasIP,
                showsSSH: hasIP && sshReady,
                showsInventory: hasIP && sshReady,
                showsVNC: hasVNC
            )
        case .stopped, .cloning, .installing:
            Capabilities(showsIP: false, showsSSH: false, showsInventory: false, showsVNC: false)
        }
    }

    private var liveVNCURL: String? {
        if let liveURL = store.liveSessions[vm.metadata.name]?.vncURLString {
            return liveURL
        }
        guard let setupURL = store.setups[vm.metadata.name]?.vncURL,
              !setupURL.isEmpty else { return nil }
        return setupURL
    }

    private var placeholderText: String {
        switch status {
        case .stopped:
            "Start the VM to obtain an IP. For iCloud sign-in, run with the viewer window."
        case .cloning:
            "Access remains unavailable while the stopped VM is being cloned."
        case .settingUp:
            "Waiting for live access information…"
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
                    InfoRow(label: "Guest OS", value: metadata.installedMacOSRelease?.displayDescription ?? "—")
                    Divider().overlay(Theme.hairline)
                    InfoRow(label: "Created", value: created)
                }
            }
        }
    }
}
