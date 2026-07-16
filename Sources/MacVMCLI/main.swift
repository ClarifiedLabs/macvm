import AppKit
import ArgumentParser
import Foundation
import MacVMHostKit

struct StorageOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Base directory for VM bundles. Overrides the shared MacVM setting."
    )
    var root: String?

    var resolvedURL: URL? {
        root.map(MacVMSettings.directoryURL(forPath:))
            ?? MacVMSettings.shared.configuredVMRootDirectory
    }
}

struct DebugOptions: ParsableArguments {
    @Flag(name: [.short, .long], help: "Enable verbose debug logging.")
    var debug = false

    func apply() {
        DebugLog.setEnabled(debug)
    }
}

struct SetupArguments: ParsableArguments {
    @Option(name: .long, help: "Admin account username to create. Defaults to admin.")
    var username: String = "admin"

    @Option(name: .long, help: "Admin account password. Defaults to admin.")
    var password: String = "admin"

    @Option(name: .long, help: "Full name for the admin account.")
    var fullName: String = "Administrator"

    @Option(name: .long, help: "Additional SSH public key file to authorize for the account.")
    var sshAuthorizedKey: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Enable auto-login for the created account.")
    var autoLogin = true

    @Option(name: .long, help: "Per-pane timeout in seconds while driving Setup Assistant.")
    var timeout: Double = 120

    @Option(name: .long, help: "VNC port to use during setup. Defaults to an auto-assigned port.")
    var vncPort: Int?

    @Flag(name: .long, help: "Shut the guest OS down after provisioning instead of leaving it running.")
    var shutdownAfter = false

    @Option(name: .long, help: "Path to a custom setup step-list (JSON) overriding the built-in flow.")
    var script: String?

    @Option(name: .long, help: "Provisioning profile to apply after setup. Repeat for multiple profiles.")
    var profile: [String] = []

    @Option(name: .long, help: "Profile input in PROFILE.KEY=VALUE form. Repeat for multiple inputs.")
    var profileInput: [String] = []

    func makeOptions(xcodeXIPURL: URL? = nil) throws -> SetupOptions {
        var profileIDs = profile
        if xcodeXIPURL != nil && !profileIDs.contains("apple-development") {
            profileIDs.append("apple-development")
        }
        return SetupOptions(
            username: username,
            password: password,
            fullName: fullName,
            authorizedKeyPath: sshAuthorizedKey.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            autoLogin: autoLogin,
            perPaneTimeout: timeout,
            requestedVNCPort: UInt(vncPort ?? 0),
            shutdownAfter: shutdownAfter,
            scriptOverride: script.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            xcodeXIPURL: xcodeXIPURL,
            provisioningSelection: try provisioningSelection(profileIDs: profileIDs, values: profileInput)
        )
    }
}

func provisioningSelection(profileIDs: [String], values: [String]) throws -> ProvisioningSelection {
    var inputs: [String: [String: String]] = [:]
    for value in values {
        guard let equals = value.firstIndex(of: "=") else {
            throw ValidationError("Profile inputs must use PROFILE.KEY=VALUE form: \(value)")
        }
        let qualifiedKey = String(value[..<equals])
        let inputValue = String(value[value.index(after: equals)...])
        guard let dot = qualifiedKey.firstIndex(of: ".") else {
            throw ValidationError("Profile inputs must use PROFILE.KEY=VALUE form: \(value)")
        }
        let profileID = String(qualifiedKey[..<dot])
        let key = String(qualifiedKey[qualifiedKey.index(after: dot)...])
        guard !profileID.isEmpty, !key.isEmpty else {
            throw ValidationError("Profile inputs must use PROFILE.KEY=VALUE form: \(value)")
        }
        inputs[profileID, default: [:]][key] = inputValue
    }
    return ProvisioningSelection(profileIDs: profileIDs, inputs: inputs)
}

final class CLIReporter: @unchecked Sendable {
    private var lastProgressPercent = -1
    private var progressActive = false

    func handle(_ event: VMOperationEvent) {
        switch event {
        case .status(let message):
            if progressActive {
                FileHandle.standardOutput.write(Data("\n".utf8))
                progressActive = false
            }

            print(message)

        case .progress(let label, let fractionComplete):
            let percent = Int(fractionComplete * 100)
            guard percent != lastProgressPercent else {
                return
            }

            lastProgressPercent = percent
            progressActive = true
            let line = "\r\(label): \(percent)%"
            FileHandle.standardOutput.write(Data(line.utf8))

        case .setupStep(let step):
            if progressActive {
                FileHandle.standardOutput.write(Data("\n".utf8))
                progressActive = false
            }

            print("Setup [\(step.phaseIndex + 1)/\(step.phaseCount)] \(step.title)")

        case .setupAccess:
            break

        case .setupLog(let artifact):
            print("Log: \(artifact.bundleRelativePath)")
        }
    }
}

enum PasteboardEndpoint {
    case host
    case vm(String)

    init(_ rawValue: String) {
        if rawValue.lowercased() == "host" {
            self = .host
        } else {
            self = .vm(rawValue)
        }
    }
}

enum HostPasteboard {
    static func readString() async throws -> String {
        try await MainActor.run {
            guard let value = NSPasteboard.general.string(forType: .string) else {
                throw ValidationError("Host pasteboard does not contain plain text.")
            }
            return value
        }
    }

    static func writeString(_ value: String) async {
        await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }
    }
}

func readStandardInputString() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if let text = String(data: data, encoding: .utf8) {
        return text
    }
    if let text = String(data: data, encoding: .isoLatin1) {
        return text
    }
    throw ValidationError("Standard input is not valid plain text.")
}

@main
struct MacVMCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macvm",
        abstract: "Create and run macOS virtual machines on Apple silicon.",
        version: MacVMVersion.shortVersion(),
        subcommands: [
            List.self,
            Show.self,
            Remove.self,
            Create.self,
            Clone.self,
            Run.self,
            Attach.self,
            Stop.self,
            Config.self,
            Autostart.self,
            Shutdown.self,
            IP.self,
            SSH.self,
            Exec.self,
            Inventory.self,
            PBCopy.self,
            PBPaste.self,
            PBSync.self,
            VNC.self,
            Screenshot.self,
            TypeText.self,
            Keys.self,
            Click.self,
            WaitText.self,
            ClickText.self,
            Setup.self,
            Profiles.self,
            Provision.self,
        ],
        defaultSubcommand: List.self
    )
}

extension MacVMCommand {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the VM bundles stored on disk.")

        @OptionGroup var storage: StorageOptions

        func run() throws {
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachines = try service.listVMs()

            guard !virtualMachines.isEmpty else {
                print("No VM bundles found under \(service.rootDirectory.path)")
                return
            }

            print(VMListFormatter.table(for: virtualMachines))
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show details for one VM.")

        @OptionGroup var storage: StorageOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() throws {
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let metadata = virtualMachine.metadata

            print("Name: \(metadata.name)")
            print("Bundle: \(virtualMachine.bundleURL.path)")
            print("Created: \(VMText.formatDate(metadata.createdAt))")
            print("CPU: \(metadata.cpuCount)")
            print("Memory: \(metadata.memoryDescription)")
            print("Disk: \(metadata.diskDescription)")
            print("Default Display: \(metadata.displayDescription) points (\(metadata.displayPixelDescription) pixels @2x)")
            if let currentDisplay = service.liveDisplayRuntimeState(for: virtualMachine) {
                let pixelSuffix = currentDisplay.pixelDescription.map { " (\($0) pixels)" } ?? ""
                print("Current Display: \(currentDisplay.displayDescription) points\(pixelSuffix) (\(currentDisplay.source.description))")
            } else if service.liveVNCSession(for: virtualMachine) != nil {
                print("Current Display: \(metadata.displayDescription) points (\(metadata.displayPixelDescription) pixels, headless)")
            } else {
                print("Current Display: not running")
            }
            print("Bootstrap Share: \(metadata.bootstrapShareEnabled ? "enabled" : "disabled")")
            print("Launch On Boot: \(service.launchOnBootStatus(for: virtualMachine).enabled ? "enabled" : "disabled")")
            if let restoreImageName = metadata.installedRestoreImageName {
                print("Restore Image: \(restoreImageName)")
            }
            if let release = metadata.installedMacOSRelease {
                print("Guest OS: \(release.displayDescription)")
            }

            if metadata.bootstrapShareEnabled {
                let sharedDirectory = virtualMachine.bundleURL.appendingPathComponent("Shared", isDirectory: true)
                print("Shared Folder: \(sharedDirectory.path)")
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Remove a VM bundle from disk."
        )

        @OptionGroup var storage: StorageOptions

        @Flag(name: [.short, .long], help: "Remove without prompting for confirmation.")
        var force = false

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() throws {
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let target = try service.resolveRemovalTarget(identifier: identifier)

            if !force && !confirmRemoval(of: target) {
                print("Cancelled.")
                return
            }

            try service.removeVM(target)
            print("Removed \(target.name) at \(target.bundleURL.path)")
        }

        private func confirmRemoval(of target: VMRemovalTarget) -> Bool {
            print(
                "Remove VM '\(target.name)' at \(target.bundleURL.path)? This cannot be undone. [y/N] ",
                terminator: ""
            )
            fflush(stdout)

            guard let response = readLine() else {
                return false
            }

            switch response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "y", "yes":
                return true
            default:
                return false
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create and install a new macOS VM.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Option(name: .long, help: "Name of the VM bundle to create.")
        var name: String

        @Option(name: .long, help: "Virtual CPU count.")
        var cpu: Int?

        @Option(name: .long, help: "Memory size in GiB. Defaults to 8.")
        var memoryGiB: Int?

        @Option(name: .long, help: "Disk size in GiB. Defaults to 80.")
        var diskGiB: Int?

        @Option(name: .long, help: "Effective guest display resolution in points, WIDTHxHEIGHT form. Defaults to 1280x720, backed by a 2560x1440 Retina framebuffer.")
        var display: String?

        @Option(name: .long, help: "Backing display resolution in pixels, WIDTHxHEIGHT form. Must be divisible by 2; 2560x1440 is equivalent to --display 1280x720.")
        var displayPixels: String?

        @Option(name: .long, help: "Path to a local macOS restore image (.ipsw).")
        var ipsw: String?

        @Flag(name: .long, help: "Fetch the latest restore image supported by this host from Apple. This is the default if --ipsw isn't provided.")
        var latest = false

        @Flag(
            inversion: .prefixedNo,
            help: "Create an automounted shared folder with a bootstrap script."
        )
        var bootstrap = true

        @Flag(name: .long, help: "After install, drive a supported macOS 15, 26, or 27 guest to an SSH/Ansible-ready state.")
        var setup = false

        @Flag(name: .long, help: "Launch this VM headless at macOS user login.")
        var launchOnBoot = false

        @Option(name: .long, help: "Path to an Xcode .xip to install during --setup.")
        var xcode: String?

        @OptionGroup var setupArguments: SetupArguments

        mutating func validate() throws {
            if latest && ipsw != nil {
                throw ValidationError("Use either --latest or --ipsw, not both.")
            }
            if display != nil && displayPixels != nil {
                throw ValidationError("Use either --display or --display-pixels, not both.")
            }
            if let xcode {
                let expandedPath = NSString(string: xcode).expandingTildeInPath
                let url = URL(fileURLWithPath: expandedPath)
                guard url.pathExtension.lowercased() == "xip" else {
                    throw ValidationError("--xcode requires an Xcode .xip file.")
                }

                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw ValidationError("Xcode .xip not found: \(url.path)")
                }
            }
        }

        mutating func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let xcodeURL = xcode.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            let setupOptions = try setupArguments.makeOptions(xcodeXIPURL: xcodeURL)
            let shouldSetup = setup || !setupOptions.provisioningSelection.profileIDs.isEmpty || xcodeURL != nil
            if shouldSetup {
                try service.preflightProvisioning(
                    selection: setupOptions.provisioningSelection,
                    xcodeXIPURL: xcodeURL,
                    freshVM: true
                )
            }
            var draft = service.defaultDraft(named: name)

            if let cpu {
                draft.cpuCount = cpu
            }

            if let memoryGiB {
                draft.memoryGiB = memoryGiB
            }

            if let diskGiB {
                draft.diskGiB = diskGiB
            }

            if let display {
                let size = try parseDisplaySize(display)
                draft.displayWidth = size.width
                draft.displayHeight = size.height
            } else if let displayPixels {
                let size = try parseDisplayPixelSizeAsEffectiveSize(displayPixels)
                draft.displayWidth = size.width
                draft.displayHeight = size.height
            }

            draft.createBootstrapShare = bootstrap
            draft.launchOnBoot = launchOnBoot

            if let ipsw {
                let expandedPath = NSString(string: ipsw).expandingTildeInPath
                draft.restoreMode = .localFile
                draft.localRestoreImageURL = URL(fileURLWithPath: expandedPath)
            } else {
                draft.restoreMode = .latestSupported
            }

            let reporter = CLIReporter()
            let virtualMachine = try await service.createVM(
                from: draft,
                setupOptions: shouldSetup ? setupOptions : nil
            ) { event in
                reporter.handle(event)
            }

            print("Created VM bundle at \(virtualMachine.bundleURL.path)")

            if launchOnBoot {
                do {
                    try service.setLaunchOnBoot(true, for: virtualMachine)
                    let status = service.launchOnBootStatus(for: virtualMachine)
                    print("Launch on boot enabled: \(status.plistURL.path)")
                } catch {
                    fputs("Warning: created \(virtualMachine.metadata.name), but failed to enable launch on boot: \(error.localizedDescription)\n", stderr)
                }
            }

            if shouldSetup {
                // Let the installer's VM release its lock on the auxiliary storage
                // before the setup runner boots a new VM against the same bundle.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let withIdentity = try service.ensureNetworkIdentity(virtualMachine)
                try await performSetup(service: service, virtualMachine: withIdentity, options: setupOptions)
            } else {
                print("Run it with: macvm run \(virtualMachine.metadata.name)")
            }
        }
    }

    struct Clone: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clone a stopped VM without reinstalling macOS."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "Source VM name, bundle basename, or full bundle path.")
        var source: String

        @Option(name: .long, help: "Name of the cloned VM bundle to create.")
        var name: String

        @Option(name: .long, help: "Virtual CPU count. Inherits the source VM when omitted.")
        var cpu: Int?

        @Option(name: .long, help: "Memory size in GiB. Inherits the source VM when omitted.")
        var memoryGiB: Int?

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let sourceVM = try service.resolveVM(identifier: source)
            let reporter = CLIReporter()
            let clonedVM = try await service.cloneVM(
                from: sourceVM,
                named: name,
                cpuCount: cpu,
                memoryGiB: memoryGiB
            ) { event in
                reporter.handle(event)
            }

            print("Cloned \(sourceVM.metadata.name) to \(clonedVM.metadata.name) at \(clonedVM.bundleURL.path)")
            print("Run it with: macvm run \(clonedVM.metadata.name)")
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Ask MacVM.app to boot an existing VM.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Flag(name: .long, help: "Start the VM in macOS recovery.")
        var recovery = false

        @Flag(name: .long, help: "Boot without initially opening a native display window.")
        var headless = false

        @Option(name: .long, help: "VNC port for --headless. Defaults to an auto-assigned port.")
        var vncPort: Int?

        func run() async throws {
            debugOptions.apply()
            guard vncPort == nil || headless else {
                throw ValidationError("--vnc-port requires --headless.")
            }
            guard (vncPort ?? 0) >= 0, (vncPort ?? 0) <= Int(UInt16.max) else {
                throw ValidationError("--vnc-port must be between 0 and \(UInt16.max).")
            }

            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let resolved = try service.resolveVM(identifier: identifier)
            let vm = headless ? try service.ensureNetworkIdentity(resolved) : resolved
            let response = try await AppControlClient().send(
                operation: .run(
                    headless: headless,
                    recovery: recovery,
                    vncPort: UInt(vncPort ?? 0)
                ),
                for: vm
            )

            print(headless ? "Booting \(vm.metadata.name) headless in MacVM." : "Opening \(vm.metadata.name) in MacVM.")
            if let ownerPID = response.ownerPID {
                print("Owner PID: \(ownerPID)")
            }
            if headless, let vncURL = response.vncURL {
                print("VNC: \(vncURL)")
            }
            print("Stop it with: macvm stop \(vm.metadata.name)")
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Ask MacVM.app to force-stop a running VM.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let vm = try service.resolveVM(identifier: identifier)
            let response = try await AppControlClient().send(operation: .stop, for: vm)
            if let ownerPID = response.ownerPID {
                print("Stopped \(vm.metadata.name) (owner PID \(ownerPID)).")
            } else {
                print("Stopped \(vm.metadata.name).")
            }
        }
    }

    struct Attach: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show a native display window for a VM owned by MacVM.app."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let vm = try service.resolveVM(identifier: identifier)
            _ = try await AppControlClient().send(operation: .attach, for: vm)
            print("Attached \(vm.metadata.name) in MacVM.")
        }
    }

    struct Config: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or change settings shared with MacVM.app.",
            subcommands: [Show.self, SetRoot.self, ResetRoot.self],
            defaultSubcommand: Show.self
        )

        struct Show: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show the effective VM root directory.")

            func run() {
                let settings = MacVMSettings.shared
                print("VM root: \(settings.effectiveVMRootDirectory.path)")
                print("Source: \(settings.configuredVMRootDirectory == nil ? "built-in default" : "shared setting")")
            }
        }

        struct SetRoot: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "set-root",
                abstract: "Set the default VM root directory for the app and CLI."
            )

            @Argument(help: "Directory that contains MacVM bundles.")
            var path: String

            func run() throws {
                let url = MacVMSettings.directoryURL(forPath: path)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                MacVMSettings.shared.setVMRootDirectory(url)
                print("VM root: \(url.path)")
            }
        }

        struct ResetRoot: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "reset-root",
                abstract: "Restore the built-in VM root directory."
            )

            func run() {
                MacVMSettings.shared.setVMRootDirectory(nil)
                print("VM root: \(MacVMSettings.shared.effectiveVMRootDirectory.path)")
            }
        }
    }

    struct Autostart: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage launch-on-boot for a VM.",
            subcommands: [
                Status.self,
                Enable.self,
                Disable.self,
            ],
            defaultSubcommand: Status.self
        )

        struct Status: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Show whether a VM launches at macOS user login.")

            @OptionGroup var storage: StorageOptions

            @Argument(help: "VM name, bundle basename, or full bundle path.")
            var identifier: String

            func run() throws {
                let service = MacVMService(rootDirectory: storage.resolvedURL)
                let virtualMachine = try service.resolveVM(identifier: identifier)
                let status = service.launchOnBootStatus(for: virtualMachine)
                print("\(virtualMachine.metadata.name): \(status.enabled ? "enabled" : "disabled")")
                print("LaunchAgent: \(status.plistURL.path)")
            }
        }

        struct Enable: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Launch a VM headless at macOS user login.")

            @OptionGroup var storage: StorageOptions

            @Argument(help: "VM name, bundle basename, or full bundle path.")
            var identifier: String

            func run() throws {
                let service = MacVMService(rootDirectory: storage.resolvedURL)
                let virtualMachine = try service.resolveVM(identifier: identifier)
                try service.setLaunchOnBoot(true, for: virtualMachine)
                let status = service.launchOnBootStatus(for: virtualMachine)
                print("Launch on boot enabled for \(virtualMachine.metadata.name).")
                print("LaunchAgent: \(status.plistURL.path)")
            }
        }

        struct Disable: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Disable launch-on-boot for a VM.")

            @OptionGroup var storage: StorageOptions

            @Argument(help: "VM name, bundle basename, or full bundle path.")
            var identifier: String

            func run() throws {
                let service = MacVMService(rootDirectory: storage.resolvedURL)
                let virtualMachine = try service.resolveVM(identifier: identifier)
                try service.setLaunchOnBoot(false, for: virtualMachine)
                let status = service.launchOnBootStatus(for: virtualMachine)
                print("Launch on boot disabled for \(virtualMachine.metadata.name).")
                print("LaunchAgent: \(status.plistURL.path)")
            }
        }
    }

    struct Shutdown: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Ask the guest OS to shut down over SSH.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Option(name: .long, help: "Login user. Defaults to the setup account, or 'admin'.")
        var user: String?

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let status = try service.shutdownGuest(virtualMachine, user: user)
            if status != 0 {
                throw ExitCode(status)
            }
            print("Shutdown requested for \(virtualMachine.metadata.name).")
        }
    }

    struct IP: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the guest's IP address from DHCP/ARP.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            print(try service.resolveGuestIP(virtualMachine))
        }
    }

    struct SSH: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open an SSH session to the guest. Append -- COMMAND to run a command instead."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Option(name: .long, help: "Login user. Defaults to the setup account, or 'admin'.")
        var user: String?

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Argument(parsing: .postTerminator, help: "Command to run on the guest (after --).")
        var command: [String] = []

        func run() throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let host = try service.resolveGuestIP(virtualMachine)
            let status = try service.runGuestSSH(
                virtualMachine,
                host: host,
                user: user,
                remoteCommand: command,
                allocateTTY: command.isEmpty
            )
            if status != 0 {
                throw ExitCode(status)
            }
        }
    }

    struct Exec: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a single command on the guest over SSH.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Option(name: .long, help: "Login user. Defaults to the setup account, or 'admin'.")
        var user: String?

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Argument(help: "Command to run on the guest.")
        var command: String

        func run() throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let host = try service.resolveGuestIP(virtualMachine)
            let status = try service.runGuestSSH(
                virtualMachine,
                host: host,
                user: user,
                remoteCommand: [command],
                allocateTTY: false
            )
            if status != 0 {
                throw ExitCode(status)
            }
        }
    }

    struct Inventory: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print an Ansible inventory line for the guest.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Option(name: .long, help: "Login user. Defaults to the setup account, or 'admin'.")
        var user: String?

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let host = try service.resolveGuestIP(virtualMachine)
            print(service.inventoryLine(virtualMachine, host: host, user: user))
        }
    }

    struct PBCopy: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pbcopy",
            abstract: "Copy standard input onto the VM pasteboard."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() async throws {
            debugOptions.apply()
            let text = try readStandardInputString()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            try await service.setGuestPasteboardText(virtualMachine, text: text)
        }
    }

    struct PBPaste: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pbpaste",
            abstract: "Print the next VM pasteboard text update to standard output."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Option(name: .long, help: "Timeout in seconds while waiting for the VM pasteboard to update. Defaults to 30.")
        var timeout: Double = 30

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let text = try await service.waitForGuestPasteboardText(virtualMachine, timeout: timeout)
            FileHandle.standardOutput.write(Data(text.utf8))
        }
    }

    struct PBSync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pbsync",
            abstract: "Sync plain text from one pasteboard to another."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "Source endpoint: 'host' or a VM name, bundle basename, or full bundle path.")
        var source: String

        @Argument(help: "Destination endpoint: 'host' or a VM name, bundle basename, or full bundle path.")
        var destination: String

        @Option(name: .long, help: "Timeout in seconds while waiting for a VM source pasteboard update. Defaults to 30.")
        var timeout: Double = 30

        func run() async throws {
            debugOptions.apply()

            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let text = try await readText(from: PasteboardEndpoint(source), service: service)
            try await writeText(text, to: PasteboardEndpoint(destination), service: service)
        }

        private func readText(from endpoint: PasteboardEndpoint, service: MacVMService) async throws -> String {
            switch endpoint {
            case .host:
                return try await HostPasteboard.readString()
            case .vm(let identifier):
                let virtualMachine = try service.resolveVM(identifier: identifier)
                return try await service.waitForGuestPasteboardText(virtualMachine, timeout: timeout)
            }
        }

        private func writeText(_ text: String, to endpoint: PasteboardEndpoint, service: MacVMService) async throws {
            switch endpoint {
            case .host:
                await HostPasteboard.writeString(text)
            case .vm(let identifier):
                let virtualMachine = try service.resolveVM(identifier: identifier)
                try await service.setGuestPasteboardText(virtualMachine, text: text)
            }
        }
    }

    struct VNC: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print or open the VNC URL for a running VM.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Flag(name: .long, help: "Open the VNC URL with the system default handler after printing it.")
        var open = false

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let vncURL = try service.vncURL(for: virtualMachine)
            print(vncURL)

            if open {
                try await openVNCURL(vncURL)
            }
        }

        private func openVNCURL(_ vncURL: String) async throws {
            guard let url = URL(string: vncURL) else {
                throw ValidationError("Invalid VNC URL: \(vncURL)")
            }

            let opened = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            guard opened else {
                throw ValidationError("Unable to open \(vncURL) with the system default handler.")
            }
        }
    }

    struct Screenshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Capture the guest screen (PNG) from a live VNC session.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Option(name: [.short, .long], help: "Output PNG path. Defaults to <name>-screenshot.png.")
        var output: String?

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let png = try await service.captureScreenshot(virtualMachine)

            let path = output ?? "\(virtualMachine.metadata.name)-screenshot.png"
            try png.write(to: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
            print("Wrote \(png.count) bytes to \(path)")
        }
    }

    struct TypeText: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type text into the guest over VNC."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Argument(help: "Text to type into the guest.")
        var text: String

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            try await service.sendText(virtualMachine, text: text)
        }
    }

    struct Keys: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "keys",
            abstract: "Send key presses to the guest, e.g. return tab 'cmd+space'."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Argument(parsing: .remaining, help: "Keys/chords to press in order (e.g. return, tab, cmd+space).")
        var keys: [String]

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            try await service.sendKeys(virtualMachine, chords: keys)
        }
    }

    struct Click: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "click",
            abstract: "Click a guest screen coordinate over VNC."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Option(name: .long, help: "Guest framebuffer X coordinate.")
        var x: Int

        @Option(name: .long, help: "Guest framebuffer Y coordinate.")
        var y: Int

        @Option(name: .long, help: "Mouse button number. Defaults to 1 (left).")
        var button: Int = 1

        mutating func validate() throws {
            if button < 1 || button > 8 {
                throw ValidationError("--button must be between 1 and 8.")
            }
        }

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            try await service.click(virtualMachine, x: x, y: y, button: UInt8(button))
        }
    }

    struct Setup: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Drive a supported fresh macOS 15, 26, or 27 VM to an SSH/Ansible-ready state."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions
        @OptionGroup var setup: SetupArguments

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let resolved = try service.resolveVM(identifier: identifier)
            let virtualMachine = try service.ensureNetworkIdentity(resolved)
            let options = try setup.makeOptions()
            try service.preflightProvisioning(selection: options.provisioningSelection, vm: virtualMachine)
            try await performSetup(service: service, virtualMachine: virtualMachine, options: options)
        }
    }

    struct Profiles: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inspect and validate provisioning profiles.",
            subcommands: [ListProfiles.self, Validate.self],
            defaultSubcommand: ListProfiles.self
        )

        struct ListProfiles: ParsableCommand {
            static let configuration = CommandConfiguration(commandName: "list")
            @OptionGroup var storage: StorageOptions
            @Flag(name: .long, help: "Include hidden dependency profiles.") var all = false

            func run() throws {
                let service = MacVMService(rootDirectory: storage.resolvedURL)
                let catalog = service.provisioningCatalog()
                for profile in catalog.profiles where all || !profile.manifest.hidden {
                    let dependencies = profile.manifest.dependencies.isEmpty
                        ? ""
                        : " [depends: \(profile.manifest.dependencies.joined(separator: ", "))]"
                    print("\(profile.id)\t\(profile.manifest.name)\t\(profile.source.label)\(dependencies)")
                }
                for diagnostic in catalog.diagnostics {
                    fputs("Invalid profile at \(diagnostic.path): \(diagnostic.message)\n", stderr)
                }
            }
        }

        struct Validate: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Validate one profile directory.")
            @Argument var directory: String

            func run() throws {
                let path = NSString(string: directory).expandingTildeInPath
                let profile = try ProvisioningCatalog.validateProfile(at: URL(fileURLWithPath: path, isDirectory: true))
                print("Valid profile '\(profile.id)' (version \(profile.manifest.version), digest \(profile.definitionDigest)).")
            }
        }
    }

    struct Provision: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Apply provisioning profiles to a running, SSH-ready VM."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions
        @Option(name: .long, help: "Provisioning profile to apply. Repeat for multiple profiles.")
        var profile: [String] = []
        @Option(name: .long, help: "Profile input in PROFILE.KEY=VALUE form.")
        var profileInput: [String] = []
        @Option(name: .long, help: "Login user. Defaults to the setup account, or 'admin'.")
        var user: String?
        @Option(name: .long, help: "Optional Xcode .xip to install before applying profiles.")
        var xcode: String?
        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() async throws {
            debugOptions.apply()
            guard !profile.isEmpty else { throw ValidationError("Provide at least one --profile.") }
            let selection = try provisioningSelection(profileIDs: profile, values: profileInput)
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let vm = try service.resolveVM(identifier: identifier)
            let xcodeURL = xcode.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            try service.preflightProvisioning(selection: selection, xcodeXIPURL: xcodeURL, vm: vm)
            if let xcodeURL {
                try await service.installXcode(vm, xipURL: xcodeURL, user: user) { event in
                    CLIReporter().handle(event)
                }
            }
            let reporter = CLIReporter()
            try await service.provision(vm, selection: selection, user: user) { event in reporter.handle(event) }
            print("Provisioning complete for \(vm.metadata.name).")
        }
    }

    struct WaitText: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wait-text",
            abstract: "Wait until on-screen text appears (via OCR)."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Argument(help: "Text to wait for (exact, substring, or regex).")
        var text: String

        @Option(name: .long, help: "Timeout in seconds. Defaults to 30.")
        var timeout: Double = 30

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let match = try await service.waitForText(virtualMachine, query: text, timeout: timeout)
            print("Found '\(match.text)' at \(match.x),\(match.y)")
        }
    }

    struct ClickText: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "click-text",
            abstract: "Wait for on-screen text (via OCR) and click it."
        )

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Argument(help: "Text to click (exact, substring, or regex).")
        var text: String

        @Option(name: .long, help: "Timeout in seconds. Defaults to 30.")
        var timeout: Double = 30

        @Option(name: .long, help: "Which match to click when several match (0 = topmost).")
        var occurrence: Int = 0

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let match = try await service.clickText(virtualMachine, query: text, timeout: timeout, occurrence: occurrence)
            print("Clicked '\(match.text)' at \(match.x),\(match.y)")
        }
    }
}

/// Boot a VM headless, drive it to an Ansible-ready state, and manage its
/// lifecycle. Shared by `macvm setup` and `macvm create --setup`.
private func performSetup(service: MacVMService, virtualMachine: ManagedVM, options: SetupOptions) async throws {
    let reporter = CLIReporter()
    let plan = try service.setupPlan(for: virtualMachine, options: options)
    reporter.handle(.status(
        "Selected setup flow \(plan.flowIdentifier) for \(plan.guestRelease?.displayDescription ?? "an unidentified guest")"
    ))
    let runner = await HeadlessRunner(
        managedVM: virtualMachine,
        requestedPort: options.requestedVNCPort,
        forceSharedDirectory: true,
        nativeProvisioning: plan.usesNativeGuestProvisioning ? options : nil,
        processRuntimeRole: .headless
    )
    let session = try await runner.start()
    let native = await runner.usedNativeProvisioning
    reporter.handle(.status("Booting \(virtualMachine.metadata.name) headless (VNC 127.0.0.1:\(session.port))\(native ? " with native provisioning" : "")"))

    let result: SetupResult
    do {
        result = try await service.provisionSetup(
            virtualMachine,
            session: session,
            options: options,
            plan: plan,
            nativeProvisioning: native
        ) { event in reporter.handle(event) }
    } catch {
        print("Setup failed: \(error.localizedDescription)")
        print("The VM is still running — inspect it at \(session.vncURLString) (trace and recent frames are in Setup/diagnostics).")
        print("Press Ctrl+C to stop it.")
        fflush(stdout)
        try await runner.waitUntilStopped()
        throw ExitCode.failure
    }

    if result.sshReady {
        print("Setup complete. \(virtualMachine.metadata.name) is Ansible-ready.")
        if let inventory = result.inventoryLine {
            print("Inventory: \(inventory)")
        }
        print("SSH: macvm ssh \(virtualMachine.metadata.name)")
    } else {
        print("Setup ran, but SSH did not come up\(result.ipAddress.map { " (guest IP \($0))" } ?? "").")
        print("Inspect the guest via \(session.vncURLString) or the Setup/diagnostics directory in the bundle.")
    }

    if options.shutdownAfter {
        guard result.sshReady else {
            print("Cannot shut the guest down cleanly because SSH is not ready.")
            print("The VM is still running — inspect it at \(session.vncURLString).")
            print("Press Ctrl+C to stop it.")
            fflush(stdout)
            try await runner.waitUntilStopped()
            throw ExitCode.failure
        }

        print("Shutting the guest OS down.")
        do {
            let status = try service.shutdownGuest(virtualMachine, user: result.username)
            guard status == 0 else {
                throw ValidationError("Shutdown command failed with exit code \(status).")
            }
            try await runner.waitUntilStopped()
        } catch {
            print("Shutdown failed: \(error.localizedDescription)")
            print("The VM is still running — inspect it at \(session.vncURLString).")
            print("Press Ctrl+C to stop it.")
            fflush(stdout)
            try await runner.waitUntilStopped()
            throw ExitCode.failure
        }
    } else {
        print("VM left running. Press Ctrl+C to stop it.")
        fflush(stdout)
        try await runner.waitUntilStopped()
    }
}
