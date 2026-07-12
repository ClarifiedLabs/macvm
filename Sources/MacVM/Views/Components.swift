import SwiftUI

/// Rounded group container: radius 10, hairline ring, grouped background.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Theme.hairline)
            )
    }
}

/// 13/600 section heading above a group.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
    }
}

/// Table-style row: fixed 120pt label column, mono value, trailing accessory.
struct InfoRow<Trailing: View>: View {
    let label: String
    let value: String
    @ViewBuilder var trailing: Trailing

    init(label: String, value: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.label = label
        self.value = value
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Capsule Copy button whose label flips to "Copied" for 1.4 s after use.
struct CopyButton: View {
    @Environment(AppStore.self) private var store
    let key: String
    let text: String
    var command: String?

    var body: some View {
        Button(store.copiedKey == key ? "Copied" : "Copy") {
            store.copy(text, key: key, command: command)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }
}

/// Compact external download URL with adjacent copy affordance.
struct DownloadLinkRow: View {
    let label: String
    let url: URL
    let copyKey: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Link(url.absoluteString, destination: url)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(url.absoluteString)
            CopyButton(key: copyKey, text: url.absoluteString)
        }
    }
}

/// 8pt status dot; pulses for the in-flight states.
struct StatusDot: View {
    let status: VMStatus
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(status.pulses && dimmed ? 0.3 : 1)
            .animation(
                status.pulses ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : nil,
                value: dimmed
            )
            .onAppear { dimmed = true }
    }

    private var color: Color {
        switch status {
        case .running: Color(nsColor: .systemGreen)
        case .settingUp: Color(nsColor: .systemOrange)
        case .cloning: Color.accentColor
        case .installing: Color.accentColor
        case .stopped: Theme.statusStopped
        }
    }
}

/// Small badge used anywhere a CLI-equivalent command is displayed.
struct CLIBadge: View {
    var body: some View {
        Text("CLI")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.hairline)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct CLICommandText: View {
    let command: String
    var lineLimit: Int? = 1
    var formatsLongCommands = false

    var body: some View {
        Text("$ \(formatsLongCommands ? CLICommandFormatter.multiline(command) : command)")
            .font(.system(size: 11.5, design: .monospaced))
            .textSelection(.enabled)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
    }
}

/// Breaks long generated commands between option/value groups while leaving
/// the original one-line command untouched for copying and execution.
enum CLICommandFormatter {
    static func multiline(_ command: String, maximumLineLength: Int = 100) -> String {
        guard command.count > maximumLineLength else {
            return command
        }

        let parts = command.components(separatedBy: " --")
        guard parts.count > 1 else {
            return command
        }

        var lines: [String] = []
        var line = parts[0]
        for part in parts.dropFirst() {
            let option = "--\(part)"
            if line.count + 1 + option.count <= maximumLineLength {
                line += " \(option)"
            } else {
                lines.append("\(line) \\")
                line = "  \(option)"
            }
        }
        lines.append(line)
        return lines.joined(separator: "\n")
    }
}

struct CLICommandStrip: View {
    let command: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CLIBadge()
                .padding(.top, 1)
            CLICommandText(command: command, lineLimit: nil, formatsLongCommands: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(key: "cli-command-\(command)", text: command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.cliBarBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
    }
}

/// Footer bar showing the CLI command equivalent to the last GUI action.
struct CLIBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CLIBadge()
                .padding(.top, 1)
            CLICommandText(command: store.lastCommand, lineLimit: nil, formatsLongCommands: true)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyButton(key: "cli-bar", text: store.lastCommand)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.cliBarBackground)
        .overlay(alignment: .top) {
            Theme.hairline.frame(height: 1)
        }
    }
}
