import AppKit
import SwiftUI

/// Design-token colors from the handoff that have no exact system semantic
/// equivalent. Everything else uses system colors so vibrancy and appearance
/// switching behave natively.
enum Theme {
    static let cardBackground = dynamic(
        light: NSColor(red: 0.980, green: 0.980, blue: 0.988, alpha: 1),
        dark: NSColor(red: 0.165, green: 0.169, blue: 0.188, alpha: 1)
    )

    static let cliBarBackground = dynamic(
        light: NSColor(red: 0.965, green: 0.965, blue: 0.973, alpha: 1),
        dark: NSColor(red: 0.114, green: 0.118, blue: 0.129, alpha: 1)
    )

    static let hairline = dynamic(
        light: NSColor(white: 0, alpha: 0.08),
        dark: NSColor(white: 1, alpha: 0.08)
    )

    static let statusStopped = dynamic(
        light: NSColor(white: 0, alpha: 0.28),
        dark: NSColor(white: 1, alpha: 0.30)
    )

    static let runGreen = dynamic(
        light: NSColor(red: 0.157, green: 0.655, blue: 0.271, alpha: 1),
        dark: NSColor(red: 0.184, green: 0.749, blue: 0.318, alpha: 1)
    )

    static let shutDownRed = dynamic(
        light: NSColor(red: 0.878, green: 0.220, blue: 0.243, alpha: 1),
        dark: NSColor(red: 0.910, green: 0.282, blue: 0.306, alpha: 1)
    )

    static let stopRed = dynamic(
        light: NSColor(red: 0.690, green: 0.118, blue: 0.145, alpha: 1),
        dark: NSColor(red: 0.780, green: 0.176, blue: 0.204, alpha: 1)
    )

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// The app icon, shown in the sidebar footer. Resolved from the Xcode asset
/// catalog, falling back to the MacVMHostKit resource bundle next to the
/// executable for unbundled development builds.
enum AppIconLoader {
    static let icon: NSImage? = {
        if let image = NSImage(named: "AppIcon") {
            return image
        }
        let devURL = Bundle.main.bundleURL
            .appendingPathComponent("macvm_MacVMHostKit.bundle/Resources/AppIcon.icns")
        return NSImage(contentsOf: devURL)
    }()
}

extension DateFormatter {
    /// "Jun 12, 2026" — the design's date style for Created/cached labels.
    static let mediumDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
