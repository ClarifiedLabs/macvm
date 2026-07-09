import AppKit
import ArgumentParser
import Foundation
import MacVMHostKit

struct StorageOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Base directory for VM bundles. Defaults to ~/VirtualMachines/MacVMHost."
    )
    var root: String?

    var resolvedURL: URL? {
        guard let root else {
            return nil
        }

        let expanded = NSString(string: root).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
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

    @Flag(name: .long, help: "Power the VM off after provisioning instead of leaving it running.")
    var shutdownAfter = false

    @Option(name: .long, help: "Path to a custom setup step-list (JSON) overriding the built-in flow.")
    var script: String?

    func makeOptions(xcodeXIPURL: URL? = nil) -> SetupOptions {
        SetupOptions(
            username: username,
            password: password,
            fullName: fullName,
            authorizedKeyPath: sshAuthorizedKey.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            autoLogin: autoLogin,
            perPaneTimeout: timeout,
            requestedVNCPort: UInt(vncPort ?? 0),
            shutdownAfter: shutdownAfter,
            scriptOverride: script.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) },
            xcodeXIPURL: xcodeXIPURL
        )
    }
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

enum ViewerAppBundle {
    private static let relaunchEnvironmentKey = "MACVM_BUNDLED_VIEWER"
    private static let iconResourceName = "AppIcon"
    private static let iconResourceExtension = "icns"
    private static let resourceBundleName = "macvm_MacVMHostKit.bundle"
    private static let resourcesDirectoryName = "Resources"

    static func launchDetached(logURL: URL) throws -> Bool {
        if ProcessInfo.processInfo.environment[relaunchEnvironmentKey] == "1" {
            return false
        }

        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" {
            return false
        }

        let fileManager = FileManager.default
        let bundleURL = try wrapperBundleURL()
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent(resourcesDirectoryName, isDirectory: true)
        let executableURL = macOSURL.appendingPathComponent("macvm", isDirectory: false)
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)

        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try writeInfoPlist(to: infoPlistURL)
        try copyIconResource(to: resourcesURL)
        try replaceExecutableLink(at: executableURL, with: try currentExecutableURL())

        let process = Process()
        process.executableURL = executableURL
        process.arguments = Array(CommandLine.arguments.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        process.environment = ProcessInfo.processInfo.environment.merging([
            relaunchEnvironmentKey: "1",
            VMOwnerProcessEnvironment.detachedOwnerKey: "1",
            VMOwnerProcessEnvironment.logPathKey: logURL.path,
        ]) { _, new in new }
        let logHandle = try VMOwnerProcessEnvironment.openLogHandle(at: logURL)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        try? logHandle.close()

        return true
    }

    private static func wrapperBundleURL() throws -> URL {
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("macvm", isDirectory: true)

        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("macvm-viewer", isDirectory: true).appendingPathExtension("app")
    }

    private static func currentExecutableURL() throws -> URL {
        if let url = Bundle.main.executableURL {
            return url
        }

        let executablePath = NSString(string: CommandLine.arguments[0]).expandingTildeInPath
        return URL(fileURLWithPath: executablePath)
    }

    private static func replaceExecutableLink(at destinationURL: URL, with sourceURL: URL) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
    }

    private static func writeInfoPlist(to url: URL) throws {
        let info: [String: String] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "macvm",
            "CFBundleIdentifier": "dev.macvm.macvm.viewer",
            "CFBundleIconFile": iconResourceName,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "macvm",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private static func copyIconResource(to resourcesURL: URL) throws {
        let fileManager = FileManager.default

        guard let iconURL = try bundledIconURL(fileManager: fileManager) else {
            DebugLog.log("Missing bundled viewer icon resource: \(iconResourceName).\(iconResourceExtension)")
            return
        }

        let destinationURL = resourcesURL.appendingPathComponent(
            "\(iconResourceName).\(iconResourceExtension)",
            isDirectory: false
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: iconURL, to: destinationURL)
    }

    private static func bundledIconURL(fileManager: FileManager) throws -> URL? {
        let executableURL = try currentExecutableURL()
        let candidateDirectories = [
            executableURL.deletingLastPathComponent(),
            executableURL.resolvingSymlinksInPath().deletingLastPathComponent(),
        ]

        var seenPaths = Set<String>()
        for directoryURL in candidateDirectories where seenPaths.insert(directoryURL.path).inserted {
            let iconURL = directoryURL
                .appendingPathComponent(resourceBundleName, isDirectory: true)
                .appendingPathComponent(resourcesDirectoryName, isDirectory: true)
                .appendingPathComponent("\(iconResourceName).\(iconResourceExtension)", isDirectory: false)

            if fileManager.fileExists(atPath: iconURL.path) {
                return iconURL
            }
        }

        return nil
    }
}

enum VMOwnerProcessEnvironment {
    static let headlessOwnerKey = "MACVM_HEADLESS_OWNER"
    static let detachedOwnerKey = "MACVM_DETACHED_OWNER"
    static let logPathKey = "MACVM_OWNER_LOG_PATH"

    static var isHeadlessOwner: Bool {
        ProcessInfo.processInfo.environment[headlessOwnerKey] == "1"
    }

    static var isDetachedOwner: Bool {
        ProcessInfo.processInfo.environment[detachedOwnerKey] == "1"
    }

    static var logPath: String? {
        ProcessInfo.processInfo.environment[logPathKey]
    }

    static func logURL(for vm: ManagedVM, role: VMProcessRuntimeRole) throws -> URL {
        let runtimeDirectory = vm.bundleURL.appendingPathComponent("Runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        let basename: String
        switch role {
        case .viewer:
            basename = "viewer.log"
        case .headless:
            basename = "headless.log"
        }
        return runtimeDirectory.appendingPathComponent(basename, isDirectory: false)
    }

    static func openLogHandle(at url: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            _ = fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    static func currentExecutableURL() throws -> URL {
        if let url = Bundle.main.executableURL {
            return url
        }

        let executablePath = NSString(string: CommandLine.arguments[0]).expandingTildeInPath
        return URL(fileURLWithPath: executablePath)
    }
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
            Run.self,
            Stop.self,
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
        ],
        defaultSubcommand: List.self
    )

    /// Synchronous entry point that bypasses Swift concurrency for the viewer
    /// child process. NSApplication.run() must enter the AppKit run loop at
    /// the top level of the main thread so GCD's main queue drains normally —
    /// VZVirtualMachineView depends on this for framebuffer delivery.
    static func main() {
        if ProcessInfo.processInfo.environment["MACVM_BUNDLED_VIEWER"] == "1" {
            viewerMain()
            return
        }

        Task {
            do {
                var command = try parseAsRoot()
                if var asyncCommand = command as? AsyncParsableCommand {
                    try await asyncCommand.run()
                } else {
                    try command.run()
                }
            } catch {
                exit(withError: error)
            }
            Darwin.exit(0)
        }
        dispatchMain()
    }

    private static func viewerMain() {
        MainActor.assumeIsolated {
            do {
                guard let command = try parseAsRoot() as? Run else {
                    fputs("Expected 'run' command in viewer process.\n", stderr)
                    Darwin.exit(1)
                }
                command.debugOptions.apply()
                let service = MacVMService(rootDirectory: command.storage.resolvedURL)
                let vm = try service.resolveVM(identifier: command.identifier)

                print("Opening \(vm.metadata.name).")
                print("Stop it with: macvm stop \(vm.metadata.name)")

                let detached = VMOwnerProcessEnvironment.isDetachedOwner
                let viewer = VMViewer(
                    managedVM: vm,
                    monitorsParent: !detached,
                    processRuntimeRole: detached ? .viewer : nil,
                    processLogPath: VMOwnerProcessEnvironment.logPath
                )
                try viewer.run(startInRecovery: command.recovery)
            } catch {
                fputs("\(error)\n", stderr)
                Darwin.exit(1)
            }
        }
    }
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

        @Flag(name: .long, help: "After install, drive Setup Assistant to an SSH/Ansible-ready state.")
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
            if xcode != nil && !setup {
                throw ValidationError("--xcode requires --setup.")
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
            let virtualMachine = try await service.createVM(from: draft) { event in
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

            if setup {
                // Let the installer's VM release its lock on the auxiliary storage
                // before the setup runner boots a new VM against the same bundle.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let withIdentity = try service.ensureNetworkIdentity(virtualMachine)
                let xcodeURL = xcode.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
                try await performSetup(service: service, virtualMachine: withIdentity, options: setupArguments.makeOptions(xcodeXIPURL: xcodeURL))
            } else {
                print("Run it with: macvm run \(virtualMachine.metadata.name)")
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Boot an existing VM in a background owner process.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        @Flag(name: .long, help: "Start the VM in macOS recovery.")
        var recovery = false

        @Flag(name: .long, help: "Boot without a window and publish a VNC server for headless/remote access.")
        var headless = false

        @Option(name: .long, help: "VNC port for --headless. Defaults to an auto-assigned port.")
        var vncPort: Int?

        func run() async throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let resolved = try service.resolveVM(identifier: identifier)

            if headless {
                let virtualMachine = try service.ensureNetworkIdentity(resolved)
                if VMOwnerProcessEnvironment.isHeadlessOwner {
                    try await runHeadlessOwner(virtualMachine)
                } else {
                    try await launchHeadlessOwner(service: service, virtualMachine: virtualMachine)
                }
                return
            }

            if service.liveVMProcessRuntimeState(for: resolved) != nil {
                throw ValidationError("'\(resolved.metadata.name)' is already running. Stop it first with: macvm stop \(resolved.metadata.name)")
            }

            let logURL = try VMOwnerProcessEnvironment.logURL(for: resolved, role: .viewer)
            if try ViewerAppBundle.launchDetached(logURL: logURL) {
                DebugLog.log("Launched detached viewer owner.")
                let process = try await waitForOwnerProcess(service: service, virtualMachine: resolved, role: .viewer)
                print("Opening \(resolved.metadata.name) in a background viewer.")
                print("Owner PID: \(process.pid)")
                print("Log: \(logURL.path)")
                print("Stop it with: macvm stop \(resolved.metadata.name)")
                return
            }

            print("Opening \(resolved.metadata.name).")
            print("Stop it with: macvm stop \(resolved.metadata.name)")

            try await MainActor.run {
                let viewer = VMViewer(managedVM: resolved)
                try viewer.run(startInRecovery: recovery)
            }
        }

        private func runHeadlessOwner(_ virtualMachine: ManagedVM) async throws {
            let runner = await HeadlessRunner(
                managedVM: virtualMachine,
                requestedPort: UInt(vncPort ?? 0),
                processRuntimeRole: .headless,
                processLogPath: VMOwnerProcessEnvironment.logPath
            )
            let session = try await runner.start()

            print("Booting \(virtualMachine.metadata.name) headless.")
            print("VNC: \(session.vncURLString)")
            print("Stop it with: macvm stop \(virtualMachine.metadata.name)")
            fflush(stdout) // long-running foreground command: flush before we block

            try await runner.waitUntilStopped()
            print("\(virtualMachine.metadata.name) stopped.")
        }

        private func launchHeadlessOwner(service: MacVMService, virtualMachine: ManagedVM) async throws {
            if service.liveVMProcessRuntimeState(for: virtualMachine) != nil {
                throw ValidationError("'\(virtualMachine.metadata.name)' is already running. Stop it first with: macvm stop \(virtualMachine.metadata.name)")
            }

            let logURL = try VMOwnerProcessEnvironment.logURL(for: virtualMachine, role: .headless)
            let logHandle = try VMOwnerProcessEnvironment.openLogHandle(at: logURL)
            let process = Process()
            process.executableURL = try VMOwnerProcessEnvironment.currentExecutableURL()
            process.arguments = Array(CommandLine.arguments.dropFirst())
            process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            process.environment = ProcessInfo.processInfo.environment.merging([
                VMOwnerProcessEnvironment.headlessOwnerKey: "1",
                VMOwnerProcessEnvironment.detachedOwnerKey: "1",
                VMOwnerProcessEnvironment.logPathKey: logURL.path,
            ]) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = logHandle
            process.standardError = logHandle
            try process.run()
            try? logHandle.close()

            let state = try await waitForOwnerProcess(service: service, virtualMachine: virtualMachine, role: .headless)
            let vncURL = try service.vncURL(for: virtualMachine)
            print("Booting \(virtualMachine.metadata.name) headless in the background.")
            print("Owner PID: \(state.pid)")
            print("VNC: \(vncURL)")
            print("Log: \(logURL.path)")
            print("Stop it with: macvm stop \(virtualMachine.metadata.name)")
        }

        private func waitForOwnerProcess(
            service: MacVMService,
            virtualMachine: ManagedVM,
            role: VMProcessRuntimeRole,
            timeout: TimeInterval = 15
        ) async throws -> VMProcessRuntimeState {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let process = service.liveVMProcessRuntimeState(for: virtualMachine), process.role == role {
                    return process
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < deadline

            throw ValidationError("Timed out waiting for \(virtualMachine.metadata.name) to publish its owner process.")
        }
    }

    struct Stop: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Force-stop a VM by terminating its background owner process.")

        @OptionGroup var storage: StorageOptions
        @OptionGroup var debugOptions: DebugOptions

        @Argument(help: "VM name, bundle basename, or full bundle path.")
        var identifier: String

        func run() throws {
            debugOptions.apply()
            let service = MacVMService(rootDirectory: storage.resolvedURL)
            let virtualMachine = try service.resolveVM(identifier: identifier)
            let process = try service.stopVM(virtualMachine)
            print("Stopped \(virtualMachine.metadata.name) (pid \(process.pid)).")
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
        static let configuration = CommandConfiguration(abstract: "Print or open the VNC URL for a live headless session.")

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
        static let configuration = CommandConfiguration(abstract: "Capture the guest screen (PNG) from a live headless session.")

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
            abstract: "Drive a fresh VM through Setup Assistant to an SSH/Ansible-ready state."
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
            try await performSetup(service: service, virtualMachine: virtualMachine, options: setup.makeOptions())
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
    let runner = await HeadlessRunner(
        managedVM: virtualMachine,
        requestedPort: options.requestedVNCPort,
        forceSharedDirectory: true,
        nativeProvisioning: options,
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
            nativeProvisioning: native
        ) { event in reporter.handle(event) }
    } catch {
        print("Setup failed: \(error.localizedDescription)")
        print("The VM is still running — inspect it at \(session.vncURLString) (screenshots in the bundle's Setup/screenshots).")
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
        print("Inspect the guest via \(session.vncURLString) or the Setup/screenshots in the bundle.")
    }

    if options.shutdownAfter {
        print("Shutting the VM down.")
        await runner.stop()
    } else {
        print("VM left running. Press Ctrl+C to stop it.")
        fflush(stdout)
        try await runner.waitUntilStopped()
    }
}
