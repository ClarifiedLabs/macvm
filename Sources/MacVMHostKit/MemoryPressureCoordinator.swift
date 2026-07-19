import Foundation
import Virtualization

enum MemoryBalloonGuestKind: String, Sendable {
    case macOS
    case docker
}

enum HostMemoryPressureLevel: Equatable, Sendable {
    case normal
    case warning
    case critical
}

enum MemoryBalloonConfiguration {
    static func install(on configuration: VZVirtualMachineConfiguration) {
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }
}

enum MemoryBalloonPolicy {
    private static let oneMiB: UInt64 = 1024 * 1024
    private static let macOSFloor = 4 * oneGiB
    private static let dockerFloor = 2 * oneGiB

    static func targetMemorySize(
        configuredMemorySize: UInt64,
        guestKind: MemoryBalloonGuestKind,
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
            minimumMemorySize(configuredMemorySize: configuredMemorySize, guestKind: guestKind),
            alignDownToMiB(proportionalTarget)
        )
    }

    static func minimumMemorySize(
        configuredMemorySize: UInt64,
        guestKind: MemoryBalloonGuestKind
    ) -> UInt64 {
        let guestFloor = switch guestKind {
        case .macOS: macOSFloor
        case .docker: dockerFloor
        }
        return min(
            configuredMemorySize,
            max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, guestFloor)
        )
    }

    private static func alignDownToMiB(_ value: UInt64) -> UInt64 {
        value - (value % oneMiB)
    }
}

/// Coordinates pressure-driven memory balloon requests for every VM owned by
/// the current process. Virtualization.framework exposes requested targets but
/// does not report how many pages a guest actually returns, so all bookkeeping
/// here deliberately tracks requested rather than reclaimed memory.
@MainActor
final class MemoryPressureCoordinator: NSObject {
    static let shared = MemoryPressureCoordinator(
        monitorsSystemPressure: true,
        schedulesRecoveryAutomatically: true
    )

    private struct Registration {
        let label: String
        let guestKind: MemoryBalloonGuestKind
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
        }
    }

    func register(
        virtualMachine: VZVirtualMachine,
        label: String,
        guestKind: MemoryBalloonGuestKind,
        configuredMemorySize: UInt64
    ) -> UUID? {
        guard let device = virtualMachine.memoryBalloonDevices.first
            as? VZVirtioTraditionalMemoryBalloonDevice else {
            DebugLog.log("Memory reclamation unavailable for \(label): no virtio balloon device was created")
            return nil
        }

        return register(
            label: label,
            guestKind: guestKind,
            configuredMemorySize: configuredMemorySize
        ) { [weak device] target in
            device?.targetVirtualMachineMemorySize = target
        }
    }

    func register(
        label: String,
        guestKind: MemoryBalloonGuestKind,
        configuredMemorySize: UInt64,
        setTarget: @escaping @MainActor (UInt64) -> Void
    ) -> UUID {
        let id = UUID()
        registrations[id] = Registration(
            label: label,
            guestKind: guestKind,
            configuredMemorySize: configuredMemorySize,
            requestedMemorySize: configuredMemorySize,
            setTarget: setTarget
        )
        registrationOrder.append(id)

        if currentPressure != .normal {
            applyElevatedPressure(to: id)
        }
        return id
    }

    func unregister(_ id: UUID) {
        registrations[id] = nil
        registrationOrder.removeAll { $0 == id }
        recoveryCursor = 0
        if !hasReducedRegistrations {
            cancelRecovery()
        }
    }

    func handleMemoryPressure(_ pressure: HostMemoryPressureLevel) {
        guard pressure != currentPressure else {
            return
        }

        currentPressure = pressure
        DebugLog.log("Host memory pressure changed to \(pressure)")
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
            requestTarget(registration)

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
            guestKind: registration.guestKind,
            pressure: currentPressure
        )
        guard target < registration.requestedMemorySize else {
            return
        }

        registration.requestedMemorySize = target
        registrations[id] = registration
        requestTarget(registration)
    }

    private func requestTarget(_ registration: Registration) {
        DebugLog.log(
            "Memory reclamation request for \(registration.label) [\(registration.guestKind.rawValue)]: "
                + "target=\(VMText.gibLabel(for: registration.requestedMemorySize)) "
                + "configured=\(VMText.gibLabel(for: registration.configuredMemorySize))"
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
    }

    private func cancelRecovery() {
        recoveryDelayTimer?.invalidate()
        recoveryDelayTimer = nil
        recoveryStepTimer?.invalidate()
        recoveryStepTimer = nil
    }

    @objc private func recoveryDelayTimerFired() {
        beginRecoveryAfterDelay()
    }

    @objc private func recoveryStepTimerFired() {
        performRecoveryStep()
    }
}
