import Darwin
import Foundation
import Virtualization

@MainActor
final class DockerSidecarRuntime: NSObject, VZVirtualMachineDelegate {
    private let ownerBundle: VMBundle
    private let sidecarBundle: DockerSidecarBundle
    private let settings: DockerSidecarSettings
    private let pairNetwork: DockerPairNetwork
    private let serialLogHandle: FileHandle
    private let ignitionServer: DockerIgnitionServer
    private var virtualMachine: VZVirtualMachine?
    private var readinessTimer: Timer?
    private var startedAt = Date()
    private var startupError: Error?
    private var currentState: DockerSidecarState = .stopped
    private var currentError: String?
    private var readinessObserved = false
    private var stopping = false
    private var finished = false

    var onStop: (@MainActor () -> Void)?

    init(ownerBundle: VMBundle, settings: DockerSidecarSettings, pairNetwork: DockerPairNetwork) throws {
        self.ownerBundle = ownerBundle
        self.sidecarBundle = ownerBundle.dockerSidecarBundle
        self.settings = settings
        self.pairNetwork = pairNetwork
        try FileManager.default.createDirectory(at: ownerBundle.runtimeDirectoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: ownerBundle.dockerSidecarSerialLogURL.path) {
            guard FileManager.default.createFile(
                atPath: ownerBundle.dockerSidecarSerialLogURL.path,
                contents: nil
            ) else {
                throw MacVMError.message("Couldn't create the Docker sidecar serial log.")
            }
        }
        let serialLogHandle = try FileHandle(forWritingTo: ownerBundle.dockerSidecarSerialLogURL)
        try serialLogHandle.truncate(atOffset: 0)
        self.serialLogHandle = serialLogHandle
        self.ignitionServer = DockerIgnitionServer(ignitionData: try Data(contentsOf: sidecarBundle.initialIgnitionURL))
        super.init()
    }

    var isRunning: Bool {
        virtualMachine?.state == .running
    }

    var isFinished: Bool { finished }

    func start() throws {
        let configuration = try DockerSidecarConfiguration(
            bundle: sidecarBundle,
            settings: settings,
            pairNetwork: pairNetwork,
            serialLogHandle: serialLogHandle
        ).makeConfiguration()
        let virtualMachine = VZVirtualMachine(configuration: configuration, queue: .main)
        virtualMachine.delegate = self
        try ignitionServer.install(on: virtualMachine)
        self.virtualMachine = virtualMachine
        startedAt = Date()
        publish(state: .starting)
        startReadinessMonitor()
        virtualMachine.start { [weak self] result in
            guard let self else { return }
            MainActor.assumeIsolated {
                if case .failure(let error) = result {
                    self.startupError = error
                    self.publish(state: .degraded, error: error.localizedDescription)
                    self.finish()
                }
            }
        }
    }

    func waitUntilRunning(timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let startupError { throw startupError }
            if virtualMachine?.state == .running { return }
            if finished {
                throw MacVMError.message("The Docker sidecar stopped before reaching the running state.")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MacVMError.message("Timed out waiting for the Docker sidecar to start.")
    }

    func waitUntilServicesReady(timeout: TimeInterval = 180) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let startupError { throw startupError }
            if readinessObserved, [.pendingGuestProvisioning, .ready].contains(currentState) {
                return
            }
            if currentState == .degraded {
                throw MacVMError.message(currentError ?? "The Docker sidecar did not become ready.")
            }
            if finished {
                throw MacVMError.message("The Docker sidecar stopped before its services became ready.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MacVMError.message("Timed out waiting for Docker sidecar services.")
    }

    func markGuestProvisioningReady() {
        guard readinessObserved, !finished else { return }
        publish(state: .ready)
    }

    func markGuestProvisioningFailed(_ error: Error) {
        guard !finished else { return }
        publish(state: .degraded, error: "Docker guest integration failed: \(error.localizedDescription)")
    }

    func stop(timeout: TimeInterval = 30) async throws {
        if finished { return }
        if stopping {
            let deadline = Date().addingTimeInterval(timeout)
            while stopping, !finished, Date() < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard finished else {
                throw MacVMError.message("Timed out waiting for the Docker sidecar stop already in progress.")
            }
            return
        }

        stopping = true
        readinessTimer?.invalidate()
        readinessTimer = nil
        defer { stopping = false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if finished { return }
            guard let virtualMachine else {
                publish(state: .stopped)
                finish()
                return
            }
            if virtualMachine.state == .stopped || virtualMachine.state == .error {
                publish(state: .stopped)
                finish()
                return
            }
            if virtualMachine.canStop {
                try await VirtualizationAsync.stop(virtualMachine)
                continue
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let error = MacVMError.message("Timed out stopping the Docker sidecar while it was in a transitional state.")
        publish(state: .degraded, error: error.localizedDescription)
        throw error
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.publish(state: .stopped)
                self.finish()
            }
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.startupError = error
                if self.stopping {
                    self.publish(state: .stopped)
                } else {
                    self.publish(state: .degraded, error: error.localizedDescription)
                }
                self.finish()
            }
        }
    }

    private func startReadinessMonitor() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkReadiness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        readinessTimer = timer
    }

    private func checkReadiness() {
        guard !finished else { return }
        if !readinessObserved,
           let data = try? Data(contentsOf: ownerBundle.dockerSidecarSerialLogURL),
           let output = String(data: data.suffix(128 * 1024), encoding: .utf8),
           Self.containsReadinessMarker(output) {
            readinessObserved = true
            let state = (try? ownerBundle.readMetadata().dockerSidecar?.guestProvisioningState) ?? settings.guestProvisioningState
            publish(state: state == .ready ? .ready : .pendingGuestProvisioning)
            return
        }
        if !readinessObserved, Date().timeIntervalSince(startedAt) >= 180 {
            publish(
                state: .degraded,
                error: "Timed out waiting for Fedora CoreOS, SSH, and Docker services to become ready."
            )
            return
        }
        if readinessObserved, currentState == .pendingGuestProvisioning,
           let state = try? ownerBundle.readMetadata().dockerSidecar?.guestProvisioningState {
            if state == .ready {
                publish(state: .ready)
                return
            }
        }
        publish(state: currentState, error: currentError)
    }

    private func publish(
        state: DockerSidecarState,
        error: String? = nil,
        pid: Int32 = getpid()
    ) {
        currentState = state
        currentError = error
        let descriptor = DockerSidecarRuntimeDescriptor(
            state: state,
            pid: pid,
            startedAt: startedAt,
            updatedAt: Date(),
            fcosVersion: settings.imageVersion ?? "unknown",
            mobyVersion: settings.mobyVersion,
            amd64Available: Self.rosettaAvailable(settings: settings),
            lastError: error
        )
        try? ownerBundle.writeDockerSidecarRuntimeDescriptor(descriptor)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        stopping = false
        publish(state: currentState, error: currentError, pid: 0)
        readinessTimer?.invalidate()
        readinessTimer = nil
        ignitionServer.stop()
        try? serialLogHandle.close()
        virtualMachine = nil
        onStop?()
    }

    nonisolated static func containsReadinessMarker(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces) == "MACVM_DOCKER_READY"
        }
    }

    nonisolated static func rosettaAvailable(settings: DockerSidecarSettings) -> Bool {
        !settings.amd64Enabled || VZLinuxRosettaDirectoryShare.availability == .installed
    }
}

extension VMBundle {
    var dockerSidecarSerialLogURL: URL {
        runtimeDirectoryURL.appendingPathComponent("docker-sidecar-serial.log")
    }
}
