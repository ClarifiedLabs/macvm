import Foundation

public enum VMListFormatter {
    public static func table(for virtualMachines: [ManagedVM]) -> String {
        ([header()] + virtualMachines.map(row(for:))).joined(separator: "\n")
    }

    public static func header() -> String {
        pad("NAME", 24) +
        pad("CPU", 6) +
        pad("MEM", 10) +
        pad("DISK", 10) +
        pad("DISPLAY", 14) +
        "BUNDLE PATH"
    }

    public static func row(for virtualMachine: ManagedVM) -> String {
        let metadata = virtualMachine.metadata
        return pad(metadata.name, 24) +
            pad(String(metadata.cpuCount), 6) +
            pad(metadata.memoryDescription, 10) +
            pad(metadata.diskDescription, 10) +
            pad(metadata.displayDescription, 14) +
            virtualMachine.bundleURL.path
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        if value.count >= width {
            return String(value.prefix(width - 1)) + " "
        }

        return value + String(repeating: " ", count: width - value.count)
    }
}
