import MacVMHostKit
import SwiftUI

/// The "Driving Setup Assistant" card: live framebuffer thumbnail + vnc:// URL
/// on the left, the OCR-anchored phase list on the right.
struct SetupProgressCard: View {
    let setup: SetupProgress

    @AppStorage("setupProgressPreviewWidth") private var previewWidth = 520.0
    @State private var resizeStartWidth: Double?

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
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            Text(setup.vncURL)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: CGFloat(previewWidth), alignment: .center)
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .quaternarySystemFill))
            if let image = setup.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 2) {
                    Text("live framebuffer")
                    Text("connecting · RFB")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
            resizeHandle
        }
        .frame(width: CGFloat(previewWidth), height: CGFloat(previewWidth * 9 / 16))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
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
                Text("Driving Setup Assistant")
                    .font(.system(size: 13, weight: .semibold))
                Text("OCR-anchored flow · creating account “\(setup.username)”")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            if let status = setup.statusMessage {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
            VStack(alignment: .leading, spacing: 7) {
                ForEach(setup.phases) { phase in
                    phaseRow(phase)
                }
            }
        }
    }

    private enum PhaseState {
        case done, active, pending
    }

    private func state(of phase: SetupPhase) -> PhaseState {
        let current = setup.currentPhaseID ?? 0
        if phase.id < current {
            return .done
        }
        if phase.id == current {
            return .active
        }
        return .pending
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
    let install: InstallProgress

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Installing macOS")
                    .font(.system(size: 13, weight: .semibold))
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
