import Foundation
import MacVMHostKit

/// Renders the exact `macvm` command line equivalent to a GUI action, for the
/// CLI bar and the create sheet's live preview.
enum CLIEquivalent {
    static func list() -> String {
        "macvm list"
    }

    static func show(_ name: String) -> String {
        "macvm show \(argument(name))"
    }

    static func run(_ name: String, recovery: Bool = false) -> String {
        recovery ? "macvm run \(argument(name)) --recovery" : "macvm run \(argument(name))"
    }

    static func stop(_ name: String) -> String {
        "macvm stop \(argument(name))"
    }

    static func attach(_ name: String) -> String {
        "macvm attach \(argument(name))"
    }

    static func shutDown(_ name: String) -> String {
        "macvm shutdown \(argument(name))"
    }

    static func ip(_ name: String) -> String {
        "macvm ip \(argument(name))"
    }

    static func ssh(_ name: String) -> String {
        "macvm ssh \(argument(name))"
    }

    static func inventory(_ name: String) -> String {
        "macvm inventory \(argument(name))"
    }

    static func vnc(_ name: String, open: Bool = false) -> String {
        open ? "macvm vnc \(argument(name)) --open" : "macvm vnc \(argument(name))"
    }

    static func rm(_ name: String) -> String {
        // The GUI's confirmation dialog stands in for the CLI's y/N prompt.
        "macvm rm \(name)"
    }

    static func diskResize(_ name: String, sizeGiB: Int) -> String {
        "macvm disk resize \(name) --size-gi-b \(sizeGiB)"
    }

    static func clone(
        _ source: String,
        name: String,
        cpuCount: Int? = nil,
        memoryGiB: Int? = nil
    ) -> String {
        var command = "macvm clone \(source) --name \(name.isEmpty ? "<name>" : name)"
        if let cpuCount {
            command += " --cpu \(cpuCount)"
        }
        if let memoryGiB {
            command += " --memory-gi-b \(memoryGiB)"
        }
        return command
    }

    static func autostartStatus(_ name: String) -> String {
        "macvm autostart status \(argument(name))"
    }

    static func autostartEnable(_ name: String) -> String {
        "macvm autostart enable \(argument(name))"
    }

    static func autostartDisable(_ name: String) -> String {
        "macvm autostart disable \(argument(name))"
    }

    static func dockerEnable(_ name: String) -> String {
        "macvm docker enable \(argument(name))"
    }

    static func dockerDisable(_ name: String) -> String {
        "macvm docker disable \(argument(name))"
    }

    static func dockerUpdate(_ name: String) -> String {
        "macvm docker update \(argument(name))"
    }

    static func dockerReset(_ name: String) -> String {
        "macvm docker reset \(argument(name)) --force"
    }

    static func listRestoreImages(rootPath: String) -> String {
        "ls \(abbreviatePath(rootPath))/.restore-images"
    }

    static func listXcodeArchives(rootPath: String) -> String {
        "ls \(abbreviatePath(rootPath))/.xcode"
    }

    /// `macvm create` with only the flags that differ from the default draft, in
    /// the CLI's flag order.
    static func create(
        _ draft: VMCreationDraft,
        defaults: VMCreationDraft,
        setupAfter: Bool,
        installHomebrew: Bool = true,
        installClipboardHelper: Bool = true,
        xcodeXIPURL: URL? = nil,
        profileIDs: [String] = [],
        profileInputs: [String: [String: String]] = [:]
    ) -> String {
        var command = "macvm create --name \(draft.name.isEmpty ? "<name>" : draft.name)"
        if draft.cpuCount != defaults.cpuCount {
            command += " --cpu \(draft.cpuCount)"
        }
        if draft.memoryGiB != defaults.memoryGiB {
            command += " --memory-gi-b \(draft.memoryGiB)"
        }
        if draft.diskGiB != defaults.diskGiB {
            command += " --disk-gi-b \(draft.diskGiB)"
        }
        if draft.displayWidth != defaults.displayWidth || draft.displayHeight != defaults.displayHeight {
            command += " --display \(draft.displayWidth)x\(draft.displayHeight)"
        }
        if draft.restoreMode == .localFile, let url = draft.localRestoreImageURL {
            command += " --ipsw \(abbreviatePath(url.path))"
        }
        if !draft.createBootstrapShare {
            command += " --no-bootstrap"
        }
        if draft.launchOnBoot {
            command += " --launch-on-boot"
        }
        if setupAfter {
            command += " --setup"
            if !installHomebrew {
                command += " --no-homebrew"
            }
            if !installClipboardHelper {
                command += " --no-clipboard-helper"
            }
            if let xcodeXIPURL {
                command += " --xcode \(abbreviatePath(xcodeXIPURL.path))"
            }
        }
        if draft.dockerEnabled {
            command += " --docker"
            if draft.dockerCPUCount != DockerSidecarSettings.defaultCPUCount {
                command += " --docker-cpu \(draft.dockerCPUCount)"
            }
            if draft.dockerMemoryGiB != DockerSidecarSettings.defaultMemoryGiB {
                command += " --docker-memory-gi-b \(draft.dockerMemoryGiB)"
            }
            if draft.dockerDiskGiB != DockerSidecarSettings.defaultDiskGiB {
                command += " --docker-disk-gi-b \(draft.dockerDiskGiB)"
            }
            if !draft.dockerAMD64Enabled {
                command += " --no-docker-amd64"
            }
        }
        for id in profileIDs.sorted() {
            command += " --profile \(id)"
        }
        for profileID in profileInputs.keys.sorted() {
            for key in (profileInputs[profileID] ?? [:]).keys.sorted() {
                let value = profileInputs[profileID]?[key] ?? ""
                command += " --profile-input \(profileID).\(key)=\(value.isEmpty ? "<value>" : value)"
            }
        }
        return command
    }

    static func provision(_ name: String, profileIDs: [String]) -> String {
        "macvm provision \(argument(name)) " + profileIDs.sorted().map { "--profile \($0)" }.joined(separator: " ")
    }

    /// Abbreviate the current user's home directory to `~`.
    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }

    private static func argument(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/"))
        if !value.isEmpty, value.unicodeScalars.allSatisfy(safe.contains) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
