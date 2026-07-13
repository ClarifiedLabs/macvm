import Foundation
import MacVMHostKit

/// Renders the exact `macvm` command line equivalent to a GUI action, for the
/// CLI bar and the create sheet's live preview.
enum CLIEquivalent {
    static func list() -> String {
        "macvm list"
    }

    static func show(_ name: String) -> String {
        "macvm show \(name)"
    }

    static func run(_ name: String, recovery: Bool = false) -> String {
        recovery ? "macvm run \(name) --recovery" : "macvm run \(name)"
    }

    static func stop(_ name: String) -> String {
        "macvm stop \(name)"
    }

    static func attach(_ name: String) -> String {
        "macvm attach \(name)"
    }

    static func shutDown(_ name: String) -> String {
        "macvm shutdown \(name)"
    }

    static func ip(_ name: String) -> String {
        "macvm ip \(name)"
    }

    static func ssh(_ name: String) -> String {
        "macvm ssh \(name)"
    }

    static func inventory(_ name: String) -> String {
        "macvm inventory \(name)"
    }

    static func vnc(_ name: String, open: Bool = false) -> String {
        open ? "macvm vnc \(name) --open" : "macvm vnc \(name)"
    }

    static func rm(_ name: String) -> String {
        // The GUI's confirmation dialog stands in for the CLI's y/N prompt.
        "macvm rm \(name)"
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
        "macvm autostart status \(name)"
    }

    static func autostartEnable(_ name: String) -> String {
        "macvm autostart enable \(name)"
    }

    static func autostartDisable(_ name: String) -> String {
        "macvm autostart disable \(name)"
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
            if let xcodeXIPURL {
                command += " --xcode \(abbreviatePath(xcodeXIPURL.path))"
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
        "macvm provision \(name) " + profileIDs.sorted().map { "--profile \($0)" }.joined(separator: " ")
    }

    /// Abbreviate the current user's home directory to `~`.
    static func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }
}
