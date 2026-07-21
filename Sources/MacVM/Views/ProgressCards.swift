import AppKit
import MacVMHostKit
import SwiftUI
import Virtualization

enum SetupPhaseState: Equatable {
    case done, active, failed, pending
}

enum SetupPreviewMode: String, CaseIterable, Identifiable {
    case live
    case analyzed

    var id: Self { self }

    var label: String {
        switch self {
        case .live: "Live"
        case .analyzed: "Analyzed Frame"
        }
    }

    static func resolved(_ requested: Self, hasLiveDisplay: Bool) -> Self {
        hasLiveDisplay ? requested : .analyzed
    }
}

enum SetupInputDecision: Equatable {
    case disable
    case enable
    case confirm
}

enum SetupInputPolicy {
    static func decision(requested: Bool, warningAcknowledged: Bool) -> SetupInputDecision {
        guard requested else { return .disable }
        return warningAcknowledged ? .enable : .confirm
    }
}

/// Hosts Virtualization.framework's native display while preventing it from
/// receiving mouse or keyboard input until the user explicitly opts in.
@MainActor
final class SetupVirtualMachineDisplayView: NSView {
    let displayView = VZVirtualMachineView()
    private(set) var allowsGuestInput = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayView.translatesAutoresizingMaskIntoConstraints = false
        displayView.automaticallyReconfiguresDisplay = false
        displayView.capturesSystemKeys = false
        addSubview(displayView)
        NSLayoutConstraint.activate([
            displayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            displayView.topAnchor.constraint(equalTo: topAnchor),
            displayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setAllowsGuestInput(_ allowed: Bool) {
        guard allowsGuestInput != allowed else { return }
        allowsGuestInput = allowed
        displayView.capturesSystemKeys = allowed

        if !allowed,
           let firstResponder = window?.firstResponder as? NSView,
           firstResponder === displayView || firstResponder.isDescendant(of: displayView) {
            window?.makeFirstResponder(nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowsGuestInput else { return nil }
        return super.hitTest(point)
    }
}

struct SetupLiveDisplay: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine
    let allowsInput: Bool

    func makeNSView(context: Context) -> SetupVirtualMachineDisplayView {
        let view = SetupVirtualMachineDisplayView()
        view.displayView.virtualMachine = virtualMachine
        view.setAllowsGuestInput(allowsInput)
        return view
    }

    func updateNSView(_ view: SetupVirtualMachineDisplayView, context: Context) {
        if view.displayView.virtualMachine !== virtualMachine {
            view.displayView.virtualMachine = virtualMachine
        }
        view.setAllowsGuestInput(allowsInput)
    }

    static func dismantleNSView(_ view: SetupVirtualMachineDisplayView, coordinator: ()) {
        view.setAllowsGuestInput(false)
        view.displayView.virtualMachine = nil
    }
}

/// Live setup progress: native guest display + analyzed framebuffer on the left,
/// with the current activity, diagnostics, and full phase list on the right.
struct SetupProgressCard: View {
    @Environment(AppStore.self) private var store
    let setup: SetupProgress
    let vm: ManagedVM

    @AppStorage("setupProgressPreviewWidth") private var previewWidth = 520.0
    @AppStorage("setupInteractionWarningAcknowledged-v1") private var interactionWarningAcknowledged = false
    @State private var resizeStartWidth: Double?
    @State private var requestedPreviewMode = SetupPreviewMode.live
    @State private var allowsGuestInput = false
    @State private var presentsInputWarning = false

    private static let minPreviewWidth = 420.0
    private static let maxPreviewWidth = 900.0

    var body: some View {
        Card {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    previewColumn
                    phaseList
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 16) {
                    previewColumn
                    phaseList
                }
            }
            .padding(16)
        }
        .confirmationDialog(
            "Allow Input During Automated Setup?",
            isPresented: $presentsInputWarning,
            titleVisibility: .visible
        ) {
            Button("Allow Input") {
                interactionWarningAcknowledged = true
                allowsGuestInput = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MacVM is still sending input to the guest. Your clicks and keystrokes can change the active screen and cause automated setup to fail.")
        }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            previewControls
            preview
            Text(setup.vncURL)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: CGFloat(previewWidth), alignment: .center)
        }
    }

    private var liveVirtualMachine: VZVirtualMachine? {
        store.setupVirtualMachine(forName: vm.metadata.name)
    }

    private var effectivePreviewMode: SetupPreviewMode {
        SetupPreviewMode.resolved(
            requestedPreviewMode,
            hasLiveDisplay: liveVirtualMachine != nil
        )
    }

    private var previewMode: Binding<SetupPreviewMode> {
        Binding(
            get: { effectivePreviewMode },
            set: { mode in
                requestedPreviewMode = mode
                if mode != .live {
                    allowsGuestInput = false
                }
            }
        )
    }

    private var inputToggle: Binding<Bool> {
        Binding(
            get: { allowsGuestInput },
            set: { enabled in
                switch SetupInputPolicy.decision(
                    requested: enabled,
                    warningAcknowledged: interactionWarningAcknowledged
                ) {
                case .disable:
                    allowsGuestInput = false
                case .enable:
                    allowsGuestInput = true
                case .confirm:
                    presentsInputWarning = true
                }
            }
        )
    }

    @ViewBuilder
    private var previewControls: some View {
        HStack(spacing: 10) {
            if liveVirtualMachine != nil {
                Picker("Setup preview", selection: previewMode) {
                    ForEach(SetupPreviewMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)

                if effectivePreviewMode == .live {
                    Toggle("Allow Input", isOn: inputToggle)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Enable mouse and keyboard input for manual setup recovery")
                }
            } else {
                Text(SetupPreviewMode.analyzed.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(width: CGFloat(previewWidth), alignment: .leading)
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .quaternarySystemFill))

            switch effectivePreviewMode {
            case .live:
                if let liveVirtualMachine {
                    SetupLiveDisplay(
                        virtualMachine: liveVirtualMachine,
                        allowsInput: allowsGuestInput
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            case .analyzed:
                if let image = setup.thumbnail {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 2) {
                        Text("analyzed frame")
                        Text("waiting for setup capture")
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                }
            }
            resizeHandle
        }
        .frame(width: CGFloat(previewWidth), height: previewHeight)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
    }

    private var previewHeight: CGFloat {
        guard vm.metadata.displayWidth > 0, vm.metadata.displayHeight > 0 else {
            return CGFloat(previewWidth * 9 / 16)
        }
        return CGFloat(previewWidth) * CGFloat(vm.metadata.displayHeight) / CGFloat(vm.metadata.displayWidth)
    }

    private var resizeHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Theme.cardBackground.opacity(0.82))
                .overlay {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(90))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 18, height: 46)
                .padding(.trailing, 6)
                .help("Resize setup preview")
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = resizeStartWidth ?? previewWidth
                            resizeStartWidth = start
                            previewWidth = min(
                                max(start + value.translation.width, Self.minPreviewWidth),
                                Self.maxPreviewWidth
                            )
                        }
                        .onEnded { _ in
                            resizeStartWidth = nil
                        }
                )
        }
    }

    private var phaseList: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.heading(for: setup))
                    .font(.system(size: 13, weight: .semibold))
                if let status = setup.statusMessage,
                   status != setup.currentPhase?.title {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let failure = setup.failureMessage {
                Text("Setup failed: \(failure)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            if !setup.logMessages.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(setup.logMessages.suffix(6).enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
            }
            diagnostics
            VStack(alignment: .leading, spacing: 7) {
                ForEach(setup.phases) { phase in
                    phaseRow(phase)
                }
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let artifact = setup.activeLog {
                    Text(artifact.label)
                        .font(.system(size: 11, weight: .medium))
                    if let modifiedAt = setup.activeLogSnapshot?.modifiedAt {
                        Text("· output updated \(modifiedAt, style: .relative)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if let url = setup.activeLogSnapshot?.url {
                    Button("Open Log") {
                        store.openSetupLog(url)
                    }
                    .controlSize(.small)
                }
                Button("Reveal Setup Folder") {
                    store.revealSetupArtifacts(for: vm)
                }
                .controlSize(.small)
            }

            if setup.activeLog != nil {
                Text(setup.activeLogSnapshot?.tail ?? "Waiting for log output…")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    static func heading(for setup: SetupProgress) -> String {
        setup.currentPhase?.title ?? "Starting setup"
    }

    static func phaseState(
        phaseID: Int,
        currentPhaseID: Int?,
        failureMessage: String?
    ) -> SetupPhaseState {
        let current = currentPhaseID ?? 0
        if phaseID < current { return .done }
        if phaseID == current && failureMessage != nil { return .failed }
        if phaseID == current { return .active }
        return .pending
    }

    private func state(of phase: SetupPhase) -> SetupPhaseState {
        Self.phaseState(
            phaseID: phase.id,
            currentPhaseID: setup.currentPhaseID,
            failureMessage: setup.failureMessage
        )
    }

    private func phaseRow(_ phase: SetupPhase) -> some View {
        let state = state(of: phase)
        return HStack(spacing: 8) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                case .active:
                    ProgressView()
                        .controlSize(.mini)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .systemRed))
                case .pending:
                    Image(systemName: "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .opacity(0.5)
                }
            }
            .frame(width: 16, height: 16)

            Text(phase.title)
                .font(.system(size: 13))
                .opacity(state == .pending ? 0.5 : 1)
            Spacer(minLength: 12)
            Text(phase.anchor)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// The "Installing macOS" card with the installer's status line and a
/// determinate progress bar once install progress starts flowing.
struct InstallingCard: View {
    @Environment(AppStore.self) private var store
    let name: String
    let install: InstallProgress

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Installing macOS")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Cancel Install") {
                        store.requestInstallCancellation(name)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                Text(install.status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let fraction = install.fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                CLICommandStrip(command: install.command)
                    .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CloningCard: View {
    let clone: CloneProgress

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Cloning to \(clone.destinationName)")
                    .font(.system(size: 13, weight: .semibold))
                Text(clone.status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ProgressView()
                    .progressViewStyle(.linear)
                CLICommandStrip(command: clone.command)
                    .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
