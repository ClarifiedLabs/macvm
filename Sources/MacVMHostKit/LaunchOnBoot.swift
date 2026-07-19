import Foundation

public struct VMLaunchOnBootStatus: Equatable, Sendable {
    public let enabled: Bool
    public let label: String
    public let plistURL: URL

    public init(enabled: Bool, label: String, plistURL: URL) {
        self.enabled = enabled
        self.label = label
        self.plistURL = plistURL
    }
}

struct VMLaunchOnBootController: Sendable {
    private static let labelPrefix = "dev.macvm.macvm.launch-on-boot."
    private static let responsibleBundleIdentifier = "dev.macvm.macvm.cli"

    let launchAgentsDirectory: URL
    let executableURL: URL

    init(launchAgentsDirectory: URL? = nil, executableURL: URL? = nil) {
        self.launchAgentsDirectory = launchAgentsDirectory ?? Self.defaultLaunchAgentsDirectory
        self.executableURL = executableURL ?? Self.defaultExecutableURL
    }

    static var defaultLaunchAgentsDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
    }

    static var defaultExecutableURL: URL {
        resolveExecutableURL(
            mainBundleURL: Bundle.main.bundleURL,
            currentExecutableURL: Bundle.main.executableURL
        )
    }

    static func resolveExecutableURL(
        mainBundleURL: URL,
        currentExecutableURL: URL?,
        isExecutableFile: (String) -> Bool = VMLaunchOnBootController.isExecutableFile(atPath:)
    ) -> URL {
        let appHelperURL = mainBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("macvm", isDirectory: false)
        if mainBundleURL.pathExtension == "app", isExecutableFile(appHelperURL.path) {
            return appHelperURL.standardizedFileURL
        }

        if let currentExecutableURL {
            let executableURL = currentExecutableURL.standardizedFileURL
            if executableURL.lastPathComponent == "macvm", isExecutableFile(executableURL.path) {
                return executableURL.resolvingSymlinksInPath()
            }
        }

        for path in ["/opt/homebrew/bin/macvm", "/usr/local/bin/macvm"] where isExecutableFile(path) {
            return URL(fileURLWithPath: path, isDirectory: false).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: "/usr/local/bin/macvm", isDirectory: false)
    }

    private static func isExecutableFile(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    func status(for vm: ManagedVM) -> VMLaunchOnBootStatus {
        let label = self.label(for: vm.metadata)
        let plistURL = self.plistURL(forLabel: label)
        return VMLaunchOnBootStatus(
            enabled: plistMatchesExpectedConfiguration(at: plistURL, for: vm, label: label),
            label: label,
            plistURL: plistURL
        )
    }

    func setEnabled(_ enabled: Bool, for vm: ManagedVM) throws {
        if enabled {
            try writePlist(for: vm)
        } else {
            try removePlist(for: vm)
        }
    }

    func removeLaunchAgent(for target: VMRemovalTarget) {
        if let metadata = target.metadata {
            try? removeItemIfPresent(at: plistURL(forLabel: label(for: metadata)))
        }
        removeLaunchAgentsReferencingBundle(at: target.bundleURL)
    }

    private func writePlist(for vm: ManagedVM) throws {
        try FileManager.default.createDirectory(
            at: launchAgentsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: runtimeDirectory(for: vm),
            withIntermediateDirectories: true
        )

        let label = self.label(for: vm.metadata)
        let plistURL = self.plistURL(forLabel: label)
        let plist: [String: Any] = [
            "AssociatedBundleIdentifiers": Self.responsibleBundleIdentifier,
            "Label": label,
            "ProgramArguments": programArguments(for: vm),
            "RunAtLoad": true,
            "StandardOutPath": standardOutPath(for: vm),
            "StandardErrorPath": standardErrorPath(for: vm),
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)
    }

    private func removePlist(for vm: ManagedVM) throws {
        try removeItemIfPresent(at: plistURL(forLabel: label(for: vm.metadata)))
        removeLaunchAgentsReferencingBundle(at: vm.bundleURL)
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }

    private func removeLaunchAgentsReferencingBundle(at bundleURL: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: launchAgentsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let bundlePath = normalizedPath(bundleURL)
        for url in contents where isMacVMLaunchAgentPlist(url) {
            guard let arguments = plistProgramArguments(at: url),
                  arguments.contains(bundlePath) else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func plistMatchesExpectedConfiguration(at url: URL, for vm: ManagedVM, label: String) -> Bool {
        guard let plist = plistDictionary(at: url),
              plist["AssociatedBundleIdentifiers"] as? String == Self.responsibleBundleIdentifier,
              plist["Label"] as? String == label,
              plist["RunAtLoad"] as? Bool == true,
              plist["ProgramArguments"] as? [String] == programArguments(for: vm) else {
            return false
        }
        return true
    }

    private func plistDictionary(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private func plistProgramArguments(at url: URL) -> [String]? {
        plistDictionary(at: url)?["ProgramArguments"] as? [String]
    }

    private func isMacVMLaunchAgentPlist(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(Self.labelPrefix) && name.hasSuffix(".plist")
    }

    private func label(for metadata: VMMetadata) -> String {
        Self.labelPrefix + metadata.id.uuidString.lowercased()
    }

    private func plistURL(forLabel label: String) -> URL {
        launchAgentsDirectory.appendingPathComponent("\(label).plist", isDirectory: false)
    }

    private func programArguments(for vm: ManagedVM) -> [String] {
        [
            executableURL.path,
            "run",
            normalizedPath(vm.bundleURL),
            "--headless",
        ]
    }

    private func standardOutPath(for vm: ManagedVM) -> String {
        runtimeDirectory(for: vm)
            .appendingPathComponent("launch-on-boot.stdout.log", isDirectory: false)
            .path
    }

    private func standardErrorPath(for vm: ManagedVM) -> String {
        runtimeDirectory(for: vm)
            .appendingPathComponent("launch-on-boot.stderr.log", isDirectory: false)
            .path
    }

    private func runtimeDirectory(for vm: ManagedVM) -> URL {
        vm.bundleURL.appendingPathComponent("Runtime", isDirectory: true)
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}
