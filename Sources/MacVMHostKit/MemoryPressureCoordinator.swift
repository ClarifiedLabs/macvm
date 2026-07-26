import Foundation
import Virtualization

enum HostMemoryPressureLevel: Equatable, Sendable {
    case normal
    case warning
    case critical
}

enum MemoryBalloonConfiguration {
    /// Dynamic ballooning is intentionally unavailable to macOS guests. A
    /// pressure-triggered target change can deadlock the guest and its
    /// Virtualization.framework worker process.
    static func disableForMacOS(on configuration: VZVirtualMachineConfiguration) {
        configuration.memoryBalloonDevices = []
    }

    static func installForDocker(on configuration: VZVirtualMachineConfiguration) {
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }
}

enum MemoryBalloonPolicy {
    private static let oneMiB: UInt64 = 1024 * 1024
    private static let dockerFloor = 2 * oneGiB

    static func targetMemorySize(
        configuredMemorySize: UInt64,
        pressure: HostMemoryPressureLevel
    ) -> UInt64 {
        guard pressure != .normal else {
            return configuredMemorySize
        }

        let proportionalTarget: UInt64
        switch pressure {
        case .normal:
            proportionalTarget = configuredMemorySize
        case .warning:
            proportionalTarget = (configuredMemorySize / 4) * 3
        case .critical:
            proportionalTarget = configuredMemorySize / 2
        }

        return max(
            minimumMemorySize(configuredMemorySize: configuredMemorySize),
            alignDownToMiB(proportionalTarget)
        )
    }

    static func minimumMemorySize(configuredMemorySize: UInt64) -> UInt64 {
        return min(
            configuredMemorySize,
            max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, dockerFloor)
        )
    }

    private static func alignDownToMiB(_ value: UInt64) -> UInt64 {
        value - (value % oneMiB)
    }
}

/// Coordinates pressure-driven memory balloon requests for Docker sidecars
/// owned by the current process. Virtualization.framework exposes requested
/// targets but does not report how many pages a guest actually returns, so all
/// bookkeeping here deliberately tracks requested rather than reclaimed memory.
@MainActor
final class MemoryPressureCoordinator: NSObject {
    static let shared = MemoryPressureCoordinator(
        monitorsSystemPressure: true,
        schedulesRecoveryAutomatically: true
    )

    /// Starts the process-wide pressure observer even when no Docker sidecar is
    /// present, so pressure transitions remain available in incident logs.
    static func activateSystemMonitoring() {
        _ = shared
    }

    private struct Registration {
        let label: String
        let configuredMemorySize: UInt64
        var requestedMemorySize: UInt64
        let setTarget: @MainActor (UInt64) -> Void
    }

    private static let recoveryStepBytes = oneGiB
    private static let recoveryDelay: TimeInterval = 30
    private static let recoveryInterval: TimeInterval = 10

    private let schedulesRecoveryAutomatically: Bool
    private var registrations: [UUID: Registration] = [:]
    private var registrationOrder: [UUID] = []
    private var recoveryCursor = 0
    private var currentPressure: HostMemoryPressureLevel = .normal
    private var pressureSource: DispatchSourceMemoryPressure?
    private var recoveryDelayTimer: Timer?
    private var recoveryStepTimer: Timer?

    init(
        monitorsSystemPressure: Bool = false,
        schedulesRecoveryAutomatically: Bool = false
    ) {
        self.schedulesRecoveryAutomatically = schedulesRecoveryAutomatically
        super.init()
        if monitorsSystemPressure {
            startMonitoringSystemPressure()
            OperationalLog.memory(
                "monitor-started recoveryDelaySeconds=\(Int(Self.recoveryDelay)) "
                    + "recoveryIntervalSeconds=\(Int(Self.recoveryInterval)) "
                    + "recoveryStepBytes=\(Self.recoveryStepBytes)"
            )
        }
    }

    func register(
        virtualMachine: VZVirtualMachine,
        label: String,
        configuredMemorySize: UInt64
    ) -> UUID? {
        guard let device = virtualMachine.memoryBalloonDevices.first
            as? VZVirtioTraditionalMemoryBalloonDevice else {
            DebugLog.log("Memory reclamation unavailable for \(label): no virtio balloon device was created")
            OperationalLog.memoryError(
                "registration-skipped label=\(label) reason=no-virtio-balloon "
                    + "configuredBytes=\(configuredMemorySize)"
            )
            return nil
        }

        return register(
            label: label,
            configuredMemorySize: configuredMemorySize
        ) { [weak device] target in
            device?.targetVirtualMachineMemorySize = target
        }
    }

    func register(
        label: String,
        configuredMemorySize: UInt64,
        setTarget: @escaping @MainActor (UInt64) -> Void
    ) -> UUID {
        let id = UUID()
        registrations[id] = Registration(
            label: label,
            configuredMemorySize: configuredMemorySize,
            requestedMemorySize: configuredMemorySize,
            setTarget: setTarget
        )
        registrationOrder.append(id)
        OperationalLog.memory(
            "registration-added id=\(id.uuidString) label=\(label) guest=docker "
                + "configuredBytes=\(configuredMemorySize) pressure=\(currentPressure) "
                + "registrationCount=\(registrations.count)"
        )

        if currentPressure != .normal {
            applyElevatedPressure(to: id)
        }
        return id
    }

    func unregister(_ id: UUID) {
        let label = registrations[id]?.label ?? "unknown"
        registrations[id] = nil
        registrationOrder.removeAll { $0 == id }
        recoveryCursor = 0
        OperationalLog.memory(
            "registration-removed id=\(id.uuidString) label=\(label) "
                + "registrationCount=\(registrations.count)"
        )
        if !hasReducedRegistrations {
            cancelRecovery()
        }
    }

    func handleMemoryPressure(_ pressure: HostMemoryPressureLevel) {
        guard pressure != currentPressure else {
            return
        }

        let previousPressure = currentPressure
        currentPressure = pressure
        DebugLog.log("Host memory pressure changed to \(pressure)")
        OperationalLog.memory(
            "pressure-changed previous=\(previousPressure) current=\(pressure) "
                + "registrationCount=\(registrations.count) targets=\(registrationSummary)"
        )
        cancelRecovery()

        switch pressure {
        case .normal:
            scheduleRecoveryIfNeeded()
        case .warning, .critical:
            for id in registrationOrder {
                applyElevatedPressure(to: id)
            }
        }
    }

    /// Starts recovery after the normal-pressure cooldown. Internal so tests can
    /// exercise deterministic restoration without waiting on the main run loop.
    func beginRecoveryAfterDelay() {
        recoveryDelayTimer?.invalidate()
        recoveryDelayTimer = nil
        guard currentPressure == .normal else {
            return
        }

        performRecoveryStep()
        guard hasReducedRegistrations, schedulesRecoveryAutomatically else {
            return
        }

        let timer = Timer(
            timeInterval: Self.recoveryInterval,
            target: self,
            selector: #selector(recoveryStepTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        recoveryStepTimer = timer
    }

    /// Restores at most one GiB to one VM, selecting registrations round-robin.
    func performRecoveryStep() {
        guard currentPressure == .normal, !registrationOrder.isEmpty else {
            return
        }

        let count = registrationOrder.count
        for offset in 0..<count {
            let index = (recoveryCursor + offset) % count
            let id = registrationOrder[index]
            guard var registration = registrations[id],
                  registration.requestedMemorySize < registration.configuredMemorySize else {
                continue
            }

            let remaining = registration.configuredMemorySize - registration.requestedMemorySize
            let increment = min(Self.recoveryStepBytes, remaining)
            registration.requestedMemorySize += increment
            registrations[id] = registration
            recoveryCursor = (index + 1) % count
            requestTarget(
                registration,
                previousTarget: registration.requestedMemorySize - increment,
                reason: "normal-pressure-recovery"
            )

            if !hasReducedRegistrations {
                recoveryStepTimer?.invalidate()
                recoveryStepTimer = nil
            }
            return
        }

        recoveryStepTimer?.invalidate()
        recoveryStepTimer = nil
    }

    func requestedMemorySize(for id: UUID) -> UInt64? {
        registrations[id]?.requestedMemorySize
    }

    var recoveryIsScheduled: Bool {
        recoveryDelayTimer != nil || recoveryStepTimer != nil
    }

    private var hasReducedRegistrations: Bool {
        registrations.values.contains {
            $0.requestedMemorySize < $0.configuredMemorySize
        }
    }

    private func startMonitoringSystemPressure() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            let events = source.data
            MainActor.assumeIsolated {
                self?.handleMemoryPressure(Self.pressureLevel(for: events))
            }
        }
        source.resume()
        pressureSource = source
    }

    static func pressureLevel(
        for events: DispatchSource.MemoryPressureEvent
    ) -> HostMemoryPressureLevel {
        if events.contains(.critical) {
            return .critical
        }
        if events.contains(.warning) {
            return .warning
        }
        return .normal
    }

    private func applyElevatedPressure(to id: UUID) {
        guard var registration = registrations[id] else {
            return
        }

        let target = MemoryBalloonPolicy.targetMemorySize(
            configuredMemorySize: registration.configuredMemorySize,
            pressure: currentPressure
        )
        guard target < registration.requestedMemorySize else {
            return
        }

        let previousTarget = registration.requestedMemorySize
        registration.requestedMemorySize = target
        registrations[id] = registration
        requestTarget(
            registration,
            previousTarget: previousTarget,
            reason: "host-pressure-\(currentPressure)"
        )
    }

    private func requestTarget(
        _ registration: Registration,
        previousTarget: UInt64,
        reason: String
    ) {
        DebugLog.log(
            "Memory reclamation request for \(registration.label) [docker]: "
                + "target=\(VMText.gibLabel(for: registration.requestedMemorySize)) "
                + "configured=\(VMText.gibLabel(for: registration.configuredMemorySize))"
        )
        OperationalLog.memory(
            "target-request label=\(registration.label) guest=docker reason=\(reason) "
                + "previousBytes=\(previousTarget) targetBytes=\(registration.requestedMemorySize) "
                + "configuredBytes=\(registration.configuredMemorySize)"
        )
        registration.setTarget(registration.requestedMemorySize)
    }

    private func scheduleRecoveryIfNeeded() {
        guard hasReducedRegistrations, schedulesRecoveryAutomatically else {
            return
        }

        let timer = Timer(
            timeInterval: Self.recoveryDelay,
            target: self,
            selector: #selector(recoveryDelayTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        recoveryDelayTimer = timer
        OperationalLog.memory(
            "recovery-scheduled delaySeconds=\(Int(Self.recoveryDelay)) targets=\(registrationSummary)"
        )
    }

    private func cancelRecovery() {
        recoveryDelayTimer?.invalidate()
        recoveryDelayTimer = nil
        recoveryStepTimer?.invalidate()
        recoveryStepTimer = nil
    }

    private var registrationSummary: String {
        if registrationOrder.isEmpty {
            return "none"
        }
        return registrationOrder.compactMap { id in
            registrations[id].map {
                "\($0.label):\($0.requestedMemorySize)/\($0.configuredMemorySize)"
            }
        }.joined(separator: ",")
    }

    @objc private func recoveryDelayTimerFired() {
        beginRecoveryAfterDelay()
    }

    @objc private func recoveryStepTimerFired() {
        performRecoveryStep()
    }
}
