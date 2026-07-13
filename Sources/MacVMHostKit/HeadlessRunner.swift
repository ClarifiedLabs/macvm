import Darwin
import Foundation
import MacVMPrivateVZ
import Virtualization

/// Boots a VM headlessly (no AppKit window) and publishes a private VNC server so
/// automation and remote viewers can attach over RFB.
///
/// This mirrors `VMViewer`'s VM lifecycle but drops everything AppKit: there is no
/// `NSApplication`, no window, and no `VZVirtualMachineView`. It relies on the
/// top-level `dispatchMain()` in `MacVMCommand.main()` to drain the main queue so
/// the main-queue `VZVirtualMachine` callbacks fire.
///
/// Usage is two-phase so the same runner serves both `macvm run --headless`
/// (start → wait) and the setup pipeline (start → drive over RFB → stop):
/// ```
/// let session = try await runner.start()
/// try await runner.waitUntilStopped()   // or: try await runner.stop()
/// ```
@MainActor
public final class HeadlessRunner: NSObject, VZVirtualMachineDelegate {
    private let managedVM: ManagedVM
    private let bundle: VMBundle
    private let requestedPort: UInt
    private let forceSharedDirectory: Bool
    private let nativeProvisioning: SetupOptions?
    private let installSignalHandlers: Bool
    private let processRuntimeRole: VMProcessRuntimeRole?
    private let processLogPath: String?

    private var virtualMachine: VZVirtualMachine?
    private var vncServer: MacVMVNCServer?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var signalSources: [DispatchSourceSignal] = []
    private var finished = false

    /// Called once after the VM and its published runtime state are torn down.
    public var onStop: (@MainActor () -> Void)?

    /// True when the selected setup plan started the VM with native guest
    /// provisioning, so the caller can skip the OCR-driven flow.
    public private(set) var usedNativeProvisioning = false

    /// `installSignalHandlers` should stay true for CLI processes (Ctrl+C stops
    /// the VM cleanly) and be false when a GUI app hosts the runner — the app
    /// must keep its own SIGINT/SIGTERM disposition.
    public init(
        managedVM: ManagedVM,
        requestedPort: UInt = 0,
        forceSharedDirectory: Bool = false,
        nativeProvisioning: SetupOptions? = nil,
        installSignalHandlers: Bool = true,
        processRuntimeRole: VMProcessRuntimeRole? = nil,
        processLogPath: String? = nil
    ) {
        self.managedVM = managedVM
        self.bundle = VMBundle(url: managedVM.bundleURL)
        self.requestedPort = requestedPort
        self.forceSharedDirectory = forceSharedDirectory
        self.nativeProvisioning = nativeProvisioning
        self.installSignalHandlers = installSignalHandlers
        self.processRuntimeRole = processRuntimeRole
        self.processLogPath = processLogPath
        super.init()
    }

    /// The running `VZVirtualMachine`, exposed so in-process drivers (setup) can
    /// observe state. Nil before `start()` or after the VM stops.
    public var runningVirtualMachine: VZVirtualMachine? {
        virtualMachine
    }

    public var isFinished: Bool {
        finished
    }

    /// Build the config, start the VNC server, publish the session, and boot the
    /// VM. Returns once the VM has begun running.
    @discardableResult
    public func start() throws -> VNCSession {
        let configuration = try bundle.makeConfiguration(metadata: managedVM.metadata, forceSharedDirectory: forceSharedDirectory)
        let virtualMachine = VZVirtualMachine(configuration: configuration, queue: DispatchQueue.main)
        virtualMachine.delegate = self
        self.virtualMachine = virtualMachine

        // The private _VZVNCServer binds all interfaces (not just loopback), so a
        // per-session password is mandatory — never start it without one.
        let password = Self.randomPassword()
        DebugLog.log("Starting private VNC server for \(managedVM.metadata.name) requestedPort=\(requestedPort)")
        let server = try MacVMVNCServer(virtualMachine: virtualMachine, port: requestedPort, password: password)

        let boundPort = try server.start().intValue
        self.vncServer = server
        DebugLog.log("VNC server listening on 127.0.0.1:\(boundPort)")

        let session = VNCSession(
            port: boundPort,
            password: password,
            pid: getpid(),
            startedAt: Date(),
            ownerRole: processRuntimeRole ?? .headless
        )
        try bundle.writeVNCSession(session)
        try bundle.writeDisplayRuntimeState(VMDisplayRuntimeState(
            width: managedVM.metadata.displayWidth,
            height: managedVM.metadata.displayHeight,
            pixelWidth: managedVM.metadata.displayPixelWidth,
            pixelHeight: managedVM.metadata.displayPixelHeight,
            source: .headless,
            pid: getpid(),
            updatedAt: Date()
        ))
        if let processRuntimeRole {
            try bundle.writeVMProcessRuntimeState(VMProcessRuntimeState(
                role: processRuntimeRole,
                pid: getpid(),
                startedAt: Date(),
                logPath: processLogPath
            ))
        }

        if installSignalHandlers {
            installSignalHandling()
        }
        startVirtualMachine(virtualMachine)
        return session
    }

    private func startVirtualMachine(_ virtualMachine: VZVirtualMachine) {
        let completion: (Error?) -> Void = { [weak self] error in
            if let error {
                DebugLog.log("Headless VM start failed for \(self?.managedVM.metadata.name ?? "?"): \(error.localizedDescription)")
                self?.finish(error: error)
            } else {
                DebugLog.log("Headless VM started")
            }
        }

        // Only the registered macOS 27 setup plan provides native provisioning
        // options. Older hosts and rejected option values fall back to VNC.
        if let nativeProvisioning, MacVMGuestProvisioning.isAvailable() {
            let startOptions = VZMacOSVirtualMachineStartOptions()
            do {
                try MacVMGuestProvisioning.apply(
                    toStartOptions: startOptions,
                    fullName: nativeProvisioning.fullName,
                    username: nativeProvisioning.username,
                    password: nativeProvisioning.password,
                    enablesRemoteLogin: true,
                    logsInAutomatically: nativeProvisioning.autoLogin
                )
                usedNativeProvisioning = true
                DebugLog.log("Starting VM with native guest provisioning")
                virtualMachine.start(options: startOptions, completionHandler: completion)
                return
            } catch {
                DebugLog.log("Native guest provisioning unavailable (\(error.localizedDescription)); falling back to the VNC flow.")
            }
        }

        virtualMachine.start { result in
            if case .failure(let error) = result {
                completion(error)
            } else {
                completion(nil)
            }
        }
    }

    /// Suspend until the guest stops (self shutdown, error, or a caught signal).
    public func waitUntilStopped() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if finished {
                continuation.resume()
            } else {
                stopContinuation = continuation
            }
        }
    }

    /// Force the VM to power off and tear the session down.
    public func stop() async {
        if let virtualMachine, virtualMachine.state == .running || virtualMachine.state == .paused {
            try? await VirtualizationAsync.stop(virtualMachine)
        }
        finish(error: nil)
    }

    /// Ask a Manager-owned guest to shut down through Virtualization.framework.
    public func requestGuestStop() throws {
        guard let virtualMachine, virtualMachine.state == .running else {
            throw MacVMError.message("The VM is not running.")
        }
        try virtualMachine.requestStop()
    }

    // MARK: - VZVirtualMachineDelegate

    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            DebugLog.log("Headless guest requested stop")
            finish(error: nil)
        }
    }

    nonisolated public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated {
            DebugLog.log("Headless guest stopped with error: \(error.localizedDescription)")
            finish(error: error)
        }
    }

    // MARK: - Teardown

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true

        for source in signalSources {
            source.cancel()
        }
        signalSources.removeAll()

        vncServer?.stop()
        vncServer = nil
        virtualMachine = nil
        if processRuntimeRole != nil {
            bundle.clearVMProcessRuntimeState()
        }
        bundle.clearSetupRuntimeState()
        bundle.clearVNCSession()
        bundle.clearDisplayRuntimeState()

        onStop?()

        if let continuation = stopContinuation {
            stopContinuation = nil
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func installSignalHandling() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.finish(error: nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func randomPassword() -> String {
        // VNC's DES auth scheme uses at most 8 bytes of the password.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    }
}
