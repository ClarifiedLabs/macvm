import Foundation

/// Preferences shared by the MacVM app and its bundled command-line helper.
public struct MacVMSettings: @unchecked Sendable {
    public static let domain = "dev.macvm.macvm"
    public static let vmRootKey = "vmRootDirectory-v1"
    public static let shared = MacVMSettings(
        defaults: UserDefaults(suiteName: domain) ?? .standard
    )

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var configuredVMRootDirectory: URL? {
        guard let path = defaults.string(forKey: Self.vmRootKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public var effectiveVMRootDirectory: URL {
        configuredVMRootDirectory ?? Self.defaultVMRootDirectory
    }

    public static var defaultVMRootDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("VirtualMachines", isDirectory: true)
            .appendingPathComponent("MacVMHost", isDirectory: true)
    }

    public func setVMRootDirectory(_ url: URL?) {
        guard let url else {
            defaults.removeObject(forKey: Self.vmRootKey)
            return
        }
        defaults.set(Self.normalizedDirectoryURL(url).path, forKey: Self.vmRootKey)
    }

    public static func directoryURL(forPath path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        return normalizedDirectoryURL(URL(fileURLWithPath: expanded, isDirectory: true))
    }

    private static func normalizedDirectoryURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
