import Darwin
import Foundation
import Virtualization

private final class InstallationProgressState: @unchecked Sendable {
    var lastPercent = -1
}

private final class SetupRuntimePublisher: @unchecked Sendable {
    private static let maxLogMessages = 10

    private let bundle: VMBundle
    private let progress: VMOperationHandler?
    private let lock = NSLock()
    private var state: VMSetupRuntimeState

    init(bundle: VMBundle, state: VMSetupRuntimeState, progress: VMOperationHandler?) {
        self.bundle = bundle
        self.state = state
        self.progress = progress
    }

    func start() {
        update { _ in }
    }

    func publish(_ event: VMOperationEvent) {
        switch event {
        case .setupStep(let step):
            update { state in
                state.phaseIndex = step.phaseIndex
                state.phaseCount = step.phaseCount
                state.statusMessage = step.title
                state.failureMessage = nil
                Self.appendLog("Setup [\(step.phaseIndex + 1)/\(step.phaseCount)] \(step.title)", to: &state)
            }
        case .status(let message):
            update { state in
                state.statusMessage = message
                Self.appendLog(message, to: &state)
            }
        case .progress(let label, _):
            update { state in
                state.statusMessage = label
                Self.appendLog(label, to: &state)
            }
        }
        progress?(event)
    }

    func fail(_ error: Error) {
        update { state in
            state.failureMessage = error.localizedDescription
            Self.appendLog("Setup failed: \(error.localizedDescription)", to: &state)
        }
    }

    func clear() {
        bundle.clearSetupRuntimeState()
    }

    private func update(_ body: (inout VMSetupRuntimeState) -> Void) {
        let stateToWrite = lock.withLock {
            body(&state)
            state.updatedAt = Date()
            return state
        }
        try? bundle.writeSetupRuntimeState(stateToWrite)
    }

    private static func appendLog(_ message: String, to state: inout VMSetupRuntimeState) {
        guard !message.isEmpty else { return }
        if state.logMessages.last == message {
            return
        }
        state.logMessages.append(message)
        if state.logMessages.count > maxLogMessages {
            state.logMessages.removeFirst(state.logMessages.count - maxLogMessages)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

public final class MacVMService: Sendable {
    private static let cloneExcludedRelativePaths: Set<String> = [
        "Runtime",
        "Shared/.DocumentRevisions-V100",
        "Shared/.Spotlight-V100",
        "Shared/.TemporaryItems",
        "Shared/.Trashes",
        "Shared/.fseventsd",
    ]

    private let storage: VMStorage
    private let launchOnBoot: VMLaunchOnBootController

    public init(
        rootDirectory: URL? = nil,
        launchAgentsDirectory: URL? = nil,
        executableURL: URL? = nil
    ) {
        self.storage = VMStorage(rootDirectory: rootDirectory)
        self.launchOnBoot = VMLaunchOnBootController(
            launchAgentsDirectory: launchAgentsDirectory,
            executableURL: executableURL
        )
    }

    public var rootDirectory: URL {
        storage.rootDirectory
    }

    public func defaultDraft(named name: String = "") -> VMCreationDraft {
        let recommendedCPUCount = Self.recommendedCPUCount(
            hostCPUCount: ProcessInfo.processInfo.processorCount,
            minimumAllowedCPUCount: Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount),
            maximumAllowedCPUCount: Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        )

        // 1280x720 effective points maps to a 2560x1440 Retina framebuffer;
        // anything much smaller can't fit Setup Assistant comfortably.
        return VMCreationDraft(
            name: name,
            cpuCount: recommendedCPUCount,
            memoryGiB: 8,
            diskGiB: 80,
            displayWidth: 1280,
            displayHeight: 720,
            restoreMode: .latestSupported,
            createBootstrapShare: true
        )
    }

    static func recommendedCPUCount(
        hostCPUCount: Int,
        minimumAllowedCPUCount: Int,
        maximumAllowedCPUCount: Int
    ) -> Int {
        let halfHostCPUCount = hostCPUCount / 2
        return min(max(halfHostCPUCount, minimumAllowedCPUCount), maximumAllowedCPUCount)
    }

    public func listVMs() throws -> [ManagedVM] {
        try storage.loadManagedVMs()
    }

    public func resolveVM(identifier: String) throws -> ManagedVM {
        try storage.resolveVM(identifier: identifier)
    }

    public func resolveRemovalTarget(identifier: String) throws -> VMRemovalTarget {
        try storage.resolveRemovalTarget(identifier: identifier)
    }

    @discardableResult
    public func removeVM(identifier: String) throws -> VMRemovalTarget {
        let target = try resolveRemovalTarget(identifier: identifier)
        try removeVM(target)
        return target
    }

    public func removeVM(_ vm: ManagedVM) throws {
        launchOnBoot.removeLaunchAgent(for: VMRemovalTarget(bundleURL: vm.bundleURL, metadata: vm.metadata))
        try VMBundle(url: vm.bundleURL).removeFromDisk()
    }

    public func removeVM(_ target: VMRemovalTarget) throws {
        launchOnBoot.removeLaunchAgent(for: target)
        try VMBundle(url: target.bundleURL).removeFromDisk()
    }

    public func launchOnBootStatus(for vm: ManagedVM) -> VMLaunchOnBootStatus {
        launchOnBoot.status(for: vm)
    }

    public func setLaunchOnBoot(_ enabled: Bool, for vm: ManagedVM) throws {
        try launchOnBoot.setEnabled(enabled, for: vm)
    }

    /// Ensure the VM has a persisted MAC, backfilling one if it predates the
    /// `macAddress` metadata field. Returns the (possibly updated) VM.
    public func ensureNetworkIdentity(_ vm: ManagedVM) throws -> ManagedVM {
        let bundle = VMBundle(url: vm.bundleURL)
        let updated = try bundle.ensureNetworkIdentity(vm.metadata)
        return ManagedVM(bundleURL: vm.bundleURL, metadata: updated)
    }

    /// Clone a stopped VM into a new bundle. Persistent guest and platform
    /// state is copied, while macvm's bundle identity, creation date, network
    /// identity, and ephemeral runtime descriptors are refreshed.
    public func cloneVM(
        from source: ManagedVM,
        named name: String,
        progress: VMOperationHandler? = nil
    ) async throws -> ManagedVM {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacVMError.invalidName
        }

        try storage.ensureRootDirectories()
        let destinationURL = storage.bundleURL(for: name)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw MacVMError.bundleAlreadyExists(destinationURL)
        }

        let sourceBundle = VMBundle(url: source.bundleURL)
        guard sourceBundle.liveVMProcessRuntimeState() == nil,
              sourceBundle.liveVNCSession() == nil,
              sourceBundle.liveDisplayRuntimeState() == nil,
              sourceBundle.liveSetupRuntimeState() == nil else {
            throw MacVMError.message(
                "'\(source.metadata.name)' is running or setting up. Stop it before cloning: macvm stop \(source.metadata.name)"
            )
        }

        let temporaryURL = storage.rootDirectory.appendingPathComponent(
            ".clone-\(sanitizedBundleName(name))-\(UUID().uuidString)",
            isDirectory: true
        )
        let sourceURL = source.bundleURL
        var metadata = source.metadata
        metadata.id = UUID()
        metadata.name = name
        metadata.createdAt = Date()
        metadata.macAddress = VZMACAddress.randomLocallyAdministered().string

        progress?(.status("Cloning \(source.metadata.name)..."))
        return try await Task.detached {
            let fileManager = FileManager.default
            defer {
                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try? VMBundle(url: temporaryURL).removeFromDisk()
                }
            }

            try MacVMFileStager.copyDirectoryCloneFirst(
                from: sourceURL,
                to: temporaryURL,
                excludingRelativePaths: Self.cloneExcludedRelativePaths
            )
            let temporaryBundle = VMBundle(url: temporaryURL)
            try temporaryBundle.writeMetadata(metadata)
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)

            progress?(.status("Clone complete."))
            return ManagedVM(bundleURL: destinationURL, metadata: metadata)
        }.value
    }

    private static func diskSizeBytes(fromGiB diskGiB: Int) throws -> UInt64 {
        guard diskGiB > 0 else {
            throw MacVMError.invalidDiskGiB(diskGiB)
        }

        let (bytes, overflow) = UInt64(diskGiB).multipliedReportingOverflow(by: oneGiB)
        guard !overflow, bytes <= UInt64(Int64.max) else {
            throw MacVMError.message("Disk size \(diskGiB) GiB exceeds the supported file size.")
        }

        return bytes
    }

    /// Discover the guest's IP via DHCP leases (or ARP fallback). Throws a
    /// descriptive error when no lease exists yet.
    public func resolveGuestIP(_ vm: ManagedVM) throws -> String {
        let vmWithIdentity = try ensureNetworkIdentity(vm)
        guard let macAddress = vmWithIdentity.metadata.macAddress else {
            throw MacVMError.message("The VM has no network identity yet. Boot it at least once.")
        }
        guard let ip = GuestNetwork.resolveIP(macAddress: macAddress) else {
            throw MacVMError.message(
                "Couldn't find a DHCP lease or ARP entry for '\(vm.metadata.name)' (MAC \(macAddress)). Is the VM running and connected to the network?"
            )
        }
        return ip
    }

    /// The default login user for SSH/Ansible: an explicit override, else the
    /// account created during setup, else `admin`.
    public func guestUser(for vm: ManagedVM, override: String?) -> String {
        override ?? vm.metadata.setupUsername ?? "admin"
    }

    /// The per-VM SSH private key, if one was generated during setup.
    public func guestIdentityFile(for vm: ManagedVM) -> URL? {
        let bundle = VMBundle(url: vm.bundleURL)
        let keyURL = bundle.setupPrivateKeyURL
        return FileManager.default.fileExists(atPath: keyURL.path) ? keyURL : nil
    }

    /// Run `ssh` against the guest, inheriting the terminal. Returns the exit code.
    @discardableResult
    public func runGuestSSH(
        _ vm: ManagedVM,
        host: String,
        user: String?,
        remoteCommand: [String],
        allocateTTY: Bool
    ) throws -> Int32 {
        let ssh = GuestSSH(
            host: host,
            user: guestUser(for: vm, override: user),
            identityFile: guestIdentityFile(for: vm)
        )
        return try ssh.run(remoteCommand: remoteCommand, allocateTTY: allocateTTY)
    }

    /// Render an Ansible inventory line for the guest.
    public func inventoryLine(_ vm: ManagedVM, host: String, user: String?) -> String {
        AnsibleInventory.render(
            name: vm.metadata.name,
            host: host,
            user: guestUser(for: vm, override: user),
            identityFile: guestIdentityFile(for: vm)
        )
    }

    // MARK: - VNC client primitives (attach to any live VM session)

    /// The live VNC session for the VM, if its owner is currently serving it.
    public func liveVNCSession(for vm: ManagedVM) -> VNCSession? {
        VMBundle(url: vm.bundleURL).liveVNCSession()
    }

    /// The current effective display size published by a live viewer/headless process, if any.
    public func liveDisplayRuntimeState(for vm: ManagedVM) -> VMDisplayRuntimeState? {
        VMBundle(url: vm.bundleURL).liveDisplayRuntimeState()
    }

    /// The live process that owns the VM, if it was launched as a single-VM owner.
    public func liveVMProcessRuntimeState(for vm: ManagedVM) -> VMProcessRuntimeState? {
        VMBundle(url: vm.bundleURL).liveVMProcessRuntimeState()
    }

    /// Whether any live runtime marker shows that a process currently owns the VM.
    public func hasLiveRuntime(for vm: ManagedVM) -> Bool {
        let bundle = VMBundle(url: vm.bundleURL)
        return bundle.liveVMProcessRuntimeState() != nil
            || bundle.liveVNCSession() != nil
            || bundle.liveDisplayRuntimeState() != nil
            || bundle.liveSetupRuntimeState() != nil
    }

    /// The live setup operation for the VM, if a setup driver is currently running.
    public func liveSetupRuntimeState(for vm: ManagedVM) -> VMSetupRuntimeState? {
        VMBundle(url: vm.bundleURL).liveSetupRuntimeState()
    }

    /// Clear the setup marker for a VM after an in-process setup has failed and no
    /// VM runtime remains to stop.
    public func clearSetupRuntimeState(for vm: ManagedVM) {
        VMBundle(url: vm.bundleURL).clearSetupRuntimeState()
    }

    /// Stop the single-VM owner process recorded in the bundle runtime state.
    @discardableResult
    public func stopVM(_ vm: ManagedVM, timeout: TimeInterval = 5) throws -> VMProcessRuntimeState {
        let bundle = VMBundle(url: vm.bundleURL)
        guard let process = liveOwnerProcessRuntimeState(in: bundle) else {
            throw MacVMError.message("No live VM process for '\(vm.metadata.name)'.")
        }

        guard process.role != .manager else {
            throw MacVMError.message("Refusing to terminate MacVM Manager for '\(vm.metadata.name)'. Stop this Manager-owned VM from MacVM Manager.")
        }

        guard process.pid != getpid() else {
            throw MacVMError.message("Refusing to stop the current process for '\(vm.metadata.name)'.")
        }

        try signalProcess(pid: process.pid, signal: SIGTERM, vmName: vm.metadata.name)
        if waitForProcessExit(pid: process.pid, timeout: timeout) {
            bundle.clearVMProcessRuntimeState()
            bundle.clearVNCSession()
            bundle.clearDisplayRuntimeState()
            bundle.clearSetupRuntimeState()
            return process
        }

        try signalProcess(pid: process.pid, signal: SIGKILL, vmName: vm.metadata.name)
        if waitForProcessExit(pid: process.pid, timeout: 2) {
            bundle.clearVMProcessRuntimeState()
            bundle.clearVNCSession()
            bundle.clearDisplayRuntimeState()
            bundle.clearSetupRuntimeState()
            return process
        }

        throw MacVMError.message("Failed to stop '\(vm.metadata.name)' (pid \(process.pid) is still running).")
    }

    private func liveOwnerProcessRuntimeState(in bundle: VMBundle) -> VMProcessRuntimeState? {
        if let process = bundle.liveVMProcessRuntimeState() {
            return process
        }

        if bundle.readVMProcessRuntimeState() != nil {
            bundle.clearVMProcessRuntimeState()
        }

        if let session = bundle.liveVNCSession() {
            return VMProcessRuntimeState(role: session.ownerRole, pid: session.pid, startedAt: session.startedAt)
        }

        if let setup = bundle.liveSetupRuntimeState() {
            return VMProcessRuntimeState(role: .headless, pid: setup.pid, startedAt: setup.startedAt)
        }

        if let display = bundle.liveDisplayRuntimeState() {
            return VMProcessRuntimeState(
                role: display.source.processRuntimeRole,
                pid: display.pid,
                startedAt: display.updatedAt
            )
        }

        return nil
    }

    /// Ask the guest OS to shut down through SSH.
    @discardableResult
    public func shutdownGuest(_ vm: ManagedVM, user: String? = nil) throws -> Int32 {
        let host = try resolveGuestIP(vm)
        return try runGuestSSH(
            vm,
            host: host,
            user: user,
            remoteCommand: ["sudo", "shutdown", "-h", "now"],
            allocateTTY: false
        )
    }

    /// The `vnc://` URL for any live VM session, or a descriptive error if none.
    public func vncURL(for vm: ManagedVM) throws -> String {
        guard let session = liveVNCSession(for: vm) else {
            throw MacVMError.message("No attachable VNC session for '\(vm.metadata.name)'. Confirm the VM owner is still running, then restart the VM if needed.")
        }
        return session.vncURLString
    }

    /// Capture the guest framebuffer as PNG data.
    public func captureScreenshot(_ vm: ManagedVM) async throws -> Data {
        try await withRFBClient(vm) { client, _ in
            let framebuffer = try await client.captureFramebuffer()
            guard let png = framebuffer.pngData() else {
                throw MacVMError.message("Failed to encode the framebuffer as PNG.")
            }
            return png
        }
    }

    /// Type literal text into the guest over VNC.
    public func sendText(_ vm: ManagedVM, text: String) async throws {
        try await withRFBClient(vm) { client, _ in
            try await client.typeText(text)
        }
    }

    /// Copy plain text into the guest VNC pasteboard/cut buffer.
    public func setGuestPasteboardText(_ vm: ManagedVM, text: String) async throws {
        try await withRFBClient(vm) { client, _ in
            try await client.setClipboardText(text)
        }
    }

    /// Wait for the guest VNC server to publish a plain-text pasteboard update.
    public func waitForGuestPasteboardText(_ vm: ManagedVM, timeout: TimeInterval = 30) async throws -> String {
        try await withRFBClient(vm) { client, _ in
            try await client.waitForClipboardText(timeout: timeout)
        }
    }

    /// Send a sequence of key presses/chords (e.g. `return`, `tab`, `cmd+space`).
    public func sendKeys(_ vm: ManagedVM, chords: [String]) async throws {
        let parsed = try chords.map { token -> (modifiers: [UInt32], key: UInt32) in
            guard let chord = Keysym.parseChord(token) else {
                throw MacVMError.message("Unknown key or chord: '\(token)'. Try characters, 'return', 'tab', 'esc', arrows, or combos like 'cmd+space'.")
            }
            return chord
        }
        try await withRFBClient(vm) { client, _ in
            for chord in parsed {
                try await client.pressKey(chord.key, modifiers: chord.modifiers)
            }
        }
    }

    /// Click a pixel coordinate in the guest over VNC.
    public func click(_ vm: ManagedVM, x: Int, y: Int, button: UInt8 = 1) async throws {
        try await withRFBClient(vm) { client, _ in
            try await client.click(x: x, y: y, button: button)
        }
    }

    /// Find on-screen text once, returning its pixel center or nil if absent.
    public func findText(_ vm: ManagedVM, query: String, occurrence: Int = 0) async throws -> GuestTextMatch? {
        try await withRFBClient(vm) { client, _ in
            let framebuffer = try await client.captureFramebuffer()
            return OCRService.match(query, in: framebuffer, occurrence: occurrence)
        }
    }

    /// Poll the framebuffer until `query` appears (via OCR) or the timeout elapses.
    @discardableResult
    public func waitForText(
        _ vm: ManagedVM,
        query: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 1,
        occurrence: Int = 0
    ) async throws -> GuestTextMatch {
        try await withRFBClient(vm) { client, session in
            try await Self.pollForText(
                client,
                freshCaptureSession: session,
                query: query,
                timeout: timeout,
                pollInterval: pollInterval,
                occurrence: occurrence
            )
        }
    }

    /// Wait for `query` to appear, then click its center.
    public func clickText(
        _ vm: ManagedVM,
        query: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 1,
        occurrence: Int = 0
    ) async throws -> GuestTextMatch {
        try await withRFBClient(vm) { client, session in
            let match = try await Self.pollForText(
                client,
                freshCaptureSession: session,
                query: query,
                timeout: timeout,
                pollInterval: pollInterval,
                occurrence: occurrence
            )
            try await Self.withInputClient(freshCaptureSession: session, fallback: client) { inputClient in
                try await inputClient.click(x: match.x, y: match.y)
            }
            return match
        }
    }

    private static func pollForText(
        _ client: RFBClient,
        freshCaptureSession: VNCSession?,
        query: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        occurrence: Int
    ) async throws -> GuestTextMatch {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // Nudge, then let the display wake before capturing (an immediate capture
            // of a dimmed headless screen can be blank).
            try? await withInputClient(freshCaptureSession: freshCaptureSession, fallback: client) { inputClient in
                try await inputClient.nudgePointer()
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            let framebuffer = try await captureFramebufferForOCR(
                freshCaptureSession: freshCaptureSession,
                fallback: client
            )
            if let match = OCRService.match(query, in: framebuffer, occurrence: occurrence) {
                return match
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        } while Date() < deadline

        throw MacVMError.message("Timed out after \(Int(timeout))s waiting for text matching '\(query)'.")
    }

    private static func captureFramebufferForOCR(
        freshCaptureSession: VNCSession?,
        fallback client: RFBClient
    ) async throws -> Framebuffer {
        if let session = freshCaptureSession {
            do {
                return try await RFBClient.captureOnce(port: session.port, password: session.password)
            } catch {
                DebugLog.log("Fresh VNC OCR capture failed (\(error.localizedDescription)); falling back to the control connection.")
            }
        }

        return try await client.captureFramebuffer()
    }

    private static func withInputClient<T>(
        freshCaptureSession: VNCSession?,
        fallback client: RFBClient,
        _ body: (RFBClient) async throws -> T
    ) async throws -> T {
        if let session = freshCaptureSession {
            return try await RFBClient.withConnection(port: session.port, password: session.password, body)
        }

        return try await body(client)
    }

    // MARK: - Setup pipeline

    /// Drive a booted, VNC-serving guest through Setup Assistant and provisioning to
    /// an Ansible-ready state. The caller owns the `HeadlessRunner` (and thus the VM
    /// lifecycle); this connects the RFB client, runs the flow, hardens the guest,
    /// and verifies SSH. Metadata credentials are persisted on success.
    public func provisionSetup(
        _ vm: ManagedVM,
        session: VNCSession,
        options: SetupOptions,
        nativeProvisioning: Bool = false,
        progress: VMOperationHandler? = nil
    ) async throws -> SetupResult {
        guard GuestProvisioningScript.isValidUsername(options.username) else {
            throw MacVMError.message("Invalid username '\(options.username)'. Use only letters, digits, '.', '_', or '-' (max 32).")
        }
        if let xcodeXIPURL = options.xcodeXIPURL {
            _ = try Self.normalizedXcodeXIPURL(xcodeXIPURL)
        }
        let bundle = VMBundle(url: vm.bundleURL)
        let plan = try SetupFlows.resolvePlan(bundle: bundle, options: options, hostMajor: Self.hostMacOSMajor())
        let runtimePublisher = SetupRuntimePublisher(
            bundle: bundle,
            state: VMSetupRuntimeState(
                username: options.username,
                fullName: options.fullName,
                phaseCount: plan.phases.count,
                installsXcode: options.xcodeXIPURL != nil,
                pid: session.pid,
                startedAt: Date(),
                updatedAt: Date()
            ),
            progress: progress
        )
        runtimePublisher.start()
        let setupProgress: VMOperationHandler = { event in
            runtimePublisher.publish(event)
        }
        let emitPhase: (Int) -> Void = { id in
            guard let phase = plan.phases.first(where: { $0.id == id }) else { return }
            setupProgress(.setupStep(SetupStepProgress(
                phaseIndex: phase.id,
                phaseCount: plan.phases.count,
                title: phase.title,
                anchor: phase.anchor
            )))
        }
        let emitPhaseWithAnchor: (String) -> Void = { anchor in
            guard let phase = plan.phases.first(where: { $0.anchor == anchor }) else { return }
            emitPhase(phase.id)
        }

        do {
            emitPhase(0)
            try await Self.withSetupRFBConnection(port: session.port, password: session.password, progress: setupProgress) { client in
                if nativeProvisioning {
                    // The framework created the account, enabled SSH, and auto-logs in.
                    // Wait for the desktop, then still harden (sudo, our key, sleep).
                    setupProgress(.status("Native provisioning: waiting for the desktop"))
                    try await Task.sleep(nanoseconds: 45_000_000_000)
                } else {
                    let runner = SetupStepRunner(
                        client: client,
                        bundle: bundle,
                        defaultTimeout: options.perPaneTimeout,
                        progress: setupProgress,
                        phases: plan.phases
                    )
                    let driver = VNCSetupDriver(runner: runner, steps: plan.steps)
                    try await driver.reachLoggedInDesktop(progress: setupProgress)
                }
            }

            emitPhaseWithAnchor(SetupFlows.provisioningAnchor)
            try await RFBClient.withConnection(port: session.port, password: session.password) { hardenerClient in
                let hardener = GuestHardener(client: hardenerClient, bundle: bundle, options: options, progress: setupProgress)
                try await hardener.harden()
            }

            emitPhaseWithAnchor(SetupFlows.sshReadyAnchor)
            setupProgress(.status("Waiting for the guest to obtain an IP and accept SSH"))
            let result = try await waitForSSHReady(vm, options: options, progress: setupProgress)
            if options.xcodeXIPURL != nil && result.sshReady {
                emitPhaseWithAnchor(SetupFlows.xcodeInstallAnchor)
            }
            try await installXcodeIfRequested(for: vm, bundle: bundle, options: options, setupResult: result, progress: setupProgress)

            var metadata = vm.metadata
            metadata.setupUsername = options.username
            metadata.setupFullName = options.fullName
            metadata.setupCompletedAt = Date()
            try bundle.writeMetadata(metadata)
            runtimePublisher.clear()

            return result
        } catch {
            runtimePublisher.fail(error)
            throw error
        }
    }

    static func withSetupRFBConnection<T>(
        port: Int,
        password: String?,
        progress: VMOperationHandler? = nil,
        retryTimeout: TimeInterval = 60,
        retryDelayNanoseconds: UInt64 = 1_000_000_000,
        _ body: (RFBClient) async throws -> T
    ) async throws -> T {
        let client = try await connectSetupRFBClient(
            port: port,
            password: password,
            progress: progress,
            retryTimeout: retryTimeout,
            retryDelayNanoseconds: retryDelayNanoseconds
        )
        do {
            let result = try await body(client)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    private static func connectSetupRFBClient(
        port: Int,
        password: String?,
        progress: VMOperationHandler?,
        retryTimeout: TimeInterval,
        retryDelayNanoseconds: UInt64
    ) async throws -> RFBClient {
        let deadline = Date().addingTimeInterval(retryTimeout)
        var attempt = 0
        var publishedWaitStatus = false

        while true {
            attempt += 1
            let client = RFBClient(port: port)
            do {
                try await client.connect(password: password)
                _ = try await client.captureFramebuffer()
                return client
            } catch {
                await client.close()
                guard shouldRetryInitialSetupRFBError(error), Date() < deadline else {
                    if shouldRetryInitialSetupRFBError(error), retryTimeout > 0 {
                        throw MacVMError.message("Timed out waiting for the VM's VNC setup channel: \(error.localizedDescription)")
                    }
                    throw error
                }

                if !publishedWaitStatus {
                    progress?(.status("Waiting for the VM's VNC setup channel"))
                    publishedWaitStatus = true
                }
                DebugLog.log("Setup RFB connection attempt \(attempt) failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
    }

    private static func shouldRetryInitialSetupRFBError(_ error: Error) -> Bool {
        if let error = error as? RFBError {
            switch error {
            case .authenticationFailed, .passwordRequired, .noSupportedSecurityType, .unsupportedEncoding, .unexpectedMessage:
                return false
            case .connectionClosed, .handshakeFailed, .notConnected, .clipboardTimeout, .invalidClipboardText:
                return true
            }
        }

        return true
    }

    private func installXcodeIfRequested(
        for vm: ManagedVM,
        bundle: VMBundle,
        options: SetupOptions,
        setupResult: SetupResult,
        progress: VMOperationHandler?
    ) async throws {
        guard let xcodeXIPURL = options.xcodeXIPURL else {
            return
        }

        guard setupResult.sshReady, let ipAddress = setupResult.ipAddress else {
            return
        }

        let sourceURL = try Self.normalizedXcodeXIPURL(xcodeXIPURL)
        let guestXIPPath = try stageXcodeXIP(sourceURL, in: bundle, progress: progress)
        let bootstrapPath = try stageBootstrapScriptForXcode(in: bundle, progress: progress)
        let command = [
            GuestProvisioningScript.shellQuote(bootstrapPath),
            "--install-xcode",
            "--xcode-source",
            GuestProvisioningScript.shellQuote(guestXIPPath),
            "--skip-packages",
        ].joined(separator: " ")

        progress?(.status("Xcode: installing \(sourceURL.lastPathComponent) in the guest"))
        let ssh = GuestSSH(host: ipAddress, user: options.username, identityFile: guestIdentityFile(for: vm))
        let logURL = bundle.setupDirectoryURL.appendingPathComponent("xcode-install.log")
        let status = try ssh.runLogged(remoteCommand: [command], logFile: logURL)
        guard status == 0 else {
            let tail = Self.logTail(from: logURL)
            let detail = tail.map { "\nLast log output:\n\($0)" } ?? ""
            throw MacVMError.message(
                "Xcode installation failed with exit code \(status). Log: \(logURL.path)\(detail)"
            )
        }
        progress?(.status("Xcode installation complete."))
    }

    static func logTail(from url: URL, maxBytes: Int = 2_000, maxLines: Int = 12) -> String? {
        guard maxBytes > 0, maxLines > 0, let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { handle.closeFile() }

        let size = handle.seekToEndOfFile()
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        guard var text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return nil
        }

        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .suffix(maxLines)
        let tail = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? nil : tail
    }

    private func stageXcodeXIP(_ sourceURL: URL, in bundle: VMBundle, progress: VMOperationHandler?) throws -> String {
        progress?(.status("Xcode: staging \(sourceURL.lastPathComponent) in Transfers"))
        try bundle.prepareSharedDirectory(includeBootstrapShare: true)
        let destinationURL = bundle.transfersDirectoryURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        try MacVMFileStager.copyCloneFirst(from: sourceURL, to: destinationURL)
        return "\(GuestHardener.guestTransfersPath)/\(sourceURL.lastPathComponent)"
    }

    private func stageBootstrapScriptForXcode(in bundle: VMBundle, progress: VMOperationHandler?) throws -> String {
        progress?(.status("Xcode: staging bootstrap installer in Transfers"))
        try bundle.prepareSharedDirectory(includeBootstrapShare: true)
        let fileName = "bootstrap-tools-\(UUID().uuidString).sh"
        let scriptURL = bundle.transfersDirectoryURL.appendingPathComponent(fileName, isDirectory: false)
        try BootstrapAssets.loadBootstrapScript().write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return "\(GuestHardener.guestTransfersPath)/\(fileName)"
    }

    private static func normalizedXcodeXIPURL(_ url: URL) throws -> URL {
        let expandedPath = NSString(string: url.path).expandingTildeInPath
        let normalizedURL = URL(fileURLWithPath: expandedPath)
        guard normalizedURL.pathExtension.lowercased() == "xip" else {
            throw MacVMError.message("Xcode source must be a .xip file: \(normalizedURL.path)")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw MacVMError.message("Xcode .xip not found: \(normalizedURL.path)")
        }
        return normalizedURL
    }

    private func waitForSSHReady(
        _ vm: ManagedVM,
        options: SetupOptions,
        timeout: TimeInterval = 300,
        progress: VMOperationHandler?
    ) async throws -> SetupResult {
        let identity = guestIdentityFile(for: vm)
        let deadline = Date().addingTimeInterval(timeout)
        var ipAddress: String?

        repeat {
            if ipAddress == nil {
                ipAddress = try? resolveGuestIP(vm)
                if let ipAddress {
                    progress?(.status("Guest IP: \(ipAddress)"))
                }
            }
            if let ipAddress {
                let ssh = GuestSSH(host: ipAddress, user: options.username, identityFile: identity)
                if ssh.waitForSSH(timeout: 0) {
                    return SetupResult(
                        username: options.username,
                        ipAddress: ipAddress,
                        sshReady: true,
                        inventoryLine: inventoryLine(vm, host: ipAddress, user: options.username)
                    )
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        } while Date() < deadline

        return SetupResult(
            username: options.username,
            ipAddress: ipAddress,
            sshReady: false,
            inventoryLine: ipAddress.map { inventoryLine(vm, host: $0, user: options.username) }
        )
    }

    private static func hostMacOSMajor() -> Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    private func signalProcess(pid: Int32, signal: Int32, vmName: String) throws {
        if kill(pid, signal) == 0 {
            return
        }

        if errno == ESRCH {
            return
        }

        throw MacVMError.message("Failed to stop '\(vmName)' (pid \(pid)): \(String(cString: strerror(errno)))")
    }

    private func waitForProcessExit(pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !processExists(pid: pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        return !processExists(pid: pid)
    }

    private func withRFBClient<T>(_ vm: ManagedVM, _ body: (RFBClient, VNCSession) async throws -> T) async throws -> T {
        guard let session = liveVNCSession(for: vm) else {
            throw MacVMError.message("No live VNC session for '\(vm.metadata.name)'. Start one with: macvm run \(vm.metadata.name) --headless")
        }
        let client = RFBClient(port: session.port)
        do {
            try await client.connect(password: session.password)
            let result = try await body(client, session)
            await client.close()
            return result
        } catch {
            await client.close()
            throw error
        }
    }

    @MainActor
    public func createVM(from draft: VMCreationDraft, progress: VMOperationHandler? = nil) async throws -> ManagedVM {
        DebugLog.log("Create requested for '\(draft.name)' with cpu=\(draft.cpuCount) memoryGiB=\(draft.memoryGiB) diskGiB=\(draft.diskGiB) display=\(draft.displayDescription) points (\(draft.displayPixelDescription) pixels) restoreMode=\(String(describing: draft.restoreMode)) bootstrap=\(draft.createBootstrapShare)")
        try validate(draft)
        try storage.ensureRootDirectories()

        let bundleURL = storage.bundleURL(for: draft.name)
        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw MacVMError.bundleAlreadyExists(bundleURL)
        }
        DebugLog.log("Creating bundle at \(bundleURL.path)")

        let bundle = VMBundle(url: bundleURL)
        try bundle.createDirectory()

        progress?(.status("Resolving restore image..."))
        let restoreImageURL = try await resolveRestoreImage(for: draft, progress: progress)
        DebugLog.log("Using restore image at \(restoreImageURL.path)")

        progress?(.status("Loading restore image metadata from \(restoreImageURL.lastPathComponent)..."))
        let restoreImage = try await VirtualizationAsync.loadRestoreImage(from: restoreImageURL)
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw MacVMError.unsupportedHardwareModel
        }

        guard requirements.hardwareModel.isSupported else {
            throw MacVMError.unsupportedHardwareModel
        }
        DebugLog.log("Restore image requirements: minCPU=\(requirements.minimumSupportedCPUCount) minMemoryBytes=\(requirements.minimumSupportedMemorySize) hardwareModelSupported=\(requirements.hardwareModel.isSupported)")

        var metadata = VMMetadata(
            name: draft.name,
            cpuCount: draft.cpuCount,
            memorySizeBytes: UInt64(draft.memoryGiB) * oneGiB,
            diskSizeBytes: try Self.diskSizeBytes(fromGiB: draft.diskGiB),
            displayWidth: draft.displayWidth,
            displayHeight: draft.displayHeight,
            bootstrapShareEnabled: draft.createBootstrapShare,
            installedRestoreImageName: restoreImageURL.lastPathComponent,
            macAddress: VZMACAddress.randomLocallyAdministered().string
        )

        let adjustedCPUCount = max(
            Int(requirements.minimumSupportedCPUCount),
            min(metadata.cpuCount, Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        )
        if adjustedCPUCount != metadata.cpuCount {
            progress?(.status("Adjusted CPU count from \(metadata.cpuCount) to \(adjustedCPUCount) to satisfy host and guest constraints."))
            metadata.cpuCount = adjustedCPUCount
        }

        let minimumMemoryBytes = max(
            requirements.minimumSupportedMemorySize,
            VZVirtualMachineConfiguration.minimumAllowedMemorySize
        )
        let adjustedMemoryBytes = max(
            minimumMemoryBytes,
            min(metadata.memorySizeBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        )
        if adjustedMemoryBytes != metadata.memorySizeBytes {
            progress?(.status("Adjusted memory from \(VMText.gibLabel(for: metadata.memorySizeBytes)) to \(VMText.gibLabel(for: adjustedMemoryBytes)) to satisfy host and guest constraints."))
            metadata.memorySizeBytes = adjustedMemoryBytes
        }
        DebugLog.log("Final VM metadata: cpu=\(metadata.cpuCount) memoryBytes=\(metadata.memorySizeBytes) diskBytes=\(metadata.diskSizeBytes) display=\(metadata.displayDescription) points (\(metadata.displayPixelDescription) pixels)")

        try bundle.writeMetadata(metadata)
        try bundle.savePlatformArtifacts(
            hardwareModel: requirements.hardwareModel,
            machineIdentifier: VZMacMachineIdentifier()
        )

        progress?(.status("Creating auxiliary storage and sparse disk image..."))
        try bundle.createAuxiliaryStorage(for: requirements.hardwareModel)
        try bundle.createDiskImage(sizeBytes: metadata.diskSizeBytes)
        try bundle.prepareSharedDirectory(includeBootstrapShare: metadata.bootstrapShareEnabled)

        progress?(.status("Validating VM configuration..."))
        let configuration = try bundle.makeConfiguration(metadata: metadata)
        DebugLog.log("Configuration validated successfully for \(draft.name)")
        let virtualMachine = VZVirtualMachine(configuration: configuration)
        DebugLog.log("Created VZVirtualMachine on queue \(String(cString: __dispatch_queue_get_label(virtualMachine.queue)))")
        let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: restoreImageURL)
        DebugLog.log("Created VZMacOSInstaller for \(draft.name)")

        let progressState = InstallationProgressState()
        let progressObservation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { observedProgress, _ in
            let percent = Int(observedProgress.fractionCompleted * 100)
            guard percent != progressState.lastPercent else {
                return
            }

            progressState.lastPercent = percent
            progress?(.progress(label: "Installing macOS", fractionComplete: observedProgress.fractionCompleted))
        }

        defer {
            progressObservation.invalidate()
        }

        progress?(.status("Installing macOS. This can take a while..."))
        DebugLog.log("Starting macOS installation for \(draft.name)")
        try await VirtualizationAsync.install(installer)
        DebugLog.log("macOS installation finished for \(draft.name)")
        progress?(.status("Installation complete. Use `macvm run \(draft.name)` for first boot."))

        return ManagedVM(bundleURL: bundleURL, metadata: metadata)
    }

    private func validate(_ draft: VMCreationDraft) throws {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacVMError.invalidName
        }

        guard draft.cpuCount > 0 else {
            throw MacVMError.invalidCPUCount(draft.cpuCount)
        }

        guard draft.memoryGiB > 0 else {
            throw MacVMError.invalidMemoryGiB(draft.memoryGiB)
        }

        guard draft.diskGiB > 0 else {
            throw MacVMError.invalidDiskGiB(draft.diskGiB)
        }

        guard draft.displayWidth > 0, draft.displayHeight > 0 else {
            throw MacVMError.invalidDisplaySize(draft.displayDescription)
        }
    }

    @MainActor
    private func resolveRestoreImage(for draft: VMCreationDraft, progress: VMOperationHandler?) async throws -> URL {
        switch draft.restoreMode {
        case .localFile:
            guard let restoreImageURL = draft.localRestoreImageURL else {
                throw MacVMError.restoreImageRequired
            }

            let expandedPath = NSString(string: restoreImageURL.path).expandingTildeInPath
            let normalizedURL = URL(fileURLWithPath: expandedPath)
            guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
                throw MacVMError.invalidRestoreImage(normalizedURL)
            }

            DebugLog.log("Using local restore image \(normalizedURL.path)")
            return normalizedURL

        case .latestSupported:
            progress?(.status("Fetching Apple's latest restore image supported by this host..."))
            let restoreImage = try await VirtualizationAsync.fetchLatestSupportedRestoreImage()
            let restoreImageName = restoreImage.url.lastPathComponent.isEmpty ? "latest-supported.ipsw" : restoreImage.url.lastPathComponent
            let cachedRestoreImageURL = storage.restoreCacheDirectory.appendingPathComponent(restoreImageName)
            DebugLog.log("Latest supported restore image URL is \(restoreImage.url.absoluteString)")

            if FileManager.default.fileExists(atPath: cachedRestoreImageURL.path) {
                recordLatestSupportedRestoreImage(restoreImage, imageName: restoreImageName)
                progress?(.status("Using cached restore image at \(cachedRestoreImageURL.path)"))
                DebugLog.log("Restore image cache hit at \(cachedRestoreImageURL.path)")
                return cachedRestoreImageURL
            }

            progress?(.status("Downloading \(restoreImageName) from Apple..."))
            DebugLog.log("Downloading restore image to \(cachedRestoreImageURL.path)")
            let (temporaryURL, _) = try await URLSession.shared.download(from: restoreImage.url)
            try? FileManager.default.removeItem(at: cachedRestoreImageURL)
            try FileManager.default.moveItem(at: temporaryURL, to: cachedRestoreImageURL)
            recordLatestSupportedRestoreImage(restoreImage, imageName: restoreImageName)
            DebugLog.log("Restore image download complete: \(cachedRestoreImageURL.path)")
            return cachedRestoreImageURL
        }
    }

    private func recordLatestSupportedRestoreImage(_ restoreImage: VZMacOSRestoreImage, imageName: String) {
        let version = restoreImage.operatingSystemVersion
        let metadata = LatestSupportedRestoreImageMetadata(
            imageName: imageName,
            sourceURLString: restoreImage.url.absoluteString,
            buildVersion: restoreImage.buildVersion,
            majorVersion: version.majorVersion,
            minorVersion: version.minorVersion,
            patchVersion: version.patchVersion
        )
        do {
            try RestoreImageCacheMetadata.writeLatestSupported(metadata, in: storage.restoreCacheDirectory)
        } catch {
            DebugLog.log("Failed to record latest supported restore image metadata: \(error.localizedDescription)")
        }
    }
}

private extension VMDisplayRuntimeSource {
    var processRuntimeRole: VMProcessRuntimeRole {
        switch self {
        case .viewer:
            return .viewer
        case .headless:
            return .headless
        }
    }
}
