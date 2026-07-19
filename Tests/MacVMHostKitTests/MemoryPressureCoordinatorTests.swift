import Foundation
import Testing
import Virtualization
@testable import MacVMHostKit

@Test
func memoryBalloonConfigurationInstallsOneVirtioDevice() {
    let configuration = VZVirtualMachineConfiguration()

    MemoryBalloonConfiguration.install(on: configuration)

    #expect(configuration.memoryBalloonDevices.count == 1)
    #expect(configuration.memoryBalloonDevices.first is VZVirtioTraditionalMemoryBalloonDeviceConfiguration)
}

@Test
func memoryBalloonPolicyUsesConservativeTargetsAndGuestFloors() {
    #expect(MemoryBalloonPolicy.targetMemorySize(
        configuredMemorySize: 8 * oneGiB,
        guestKind: .macOS,
        pressure: .normal
    ) == 8 * oneGiB)
    #expect(MemoryBalloonPolicy.targetMemorySize(
        configuredMemorySize: 8 * oneGiB,
        guestKind: .macOS,
        pressure: .warning
    ) == 6 * oneGiB)
    #expect(MemoryBalloonPolicy.targetMemorySize(
        configuredMemorySize: 8 * oneGiB,
        guestKind: .macOS,
        pressure: .critical
    ) == 4 * oneGiB)
    #expect(MemoryBalloonPolicy.targetMemorySize(
        configuredMemorySize: 4 * oneGiB,
        guestKind: .macOS,
        pressure: .critical
    ) == 4 * oneGiB)
    #expect(MemoryBalloonPolicy.targetMemorySize(
        configuredMemorySize: 4 * oneGiB,
        guestKind: .docker,
        pressure: .warning
    ) == 3 * oneGiB)
    #expect(MemoryBalloonPolicy.targetMemorySize(
        configuredMemorySize: 4 * oneGiB,
        guestKind: .docker,
        pressure: .critical
    ) == 2 * oneGiB)
}

@Test
func memoryBalloonPolicyAlignsTargetsDownToOneMiB() {
    let halfMiB: UInt64 = 512 * 1024
    let configuredMemory = 8 * oneGiB + halfMiB
    let target = MemoryBalloonPolicy.targetMemorySize(
        configuredMemorySize: configuredMemory,
        guestKind: .docker,
        pressure: .warning
    )

    #expect(target % (1024 * 1024) == 0)
    #expect(target <= configuredMemory * 3 / 4)
}

@Test @MainActor
func memoryPressureCoordinatorShrinksWithoutInflatingWhilePressureIsElevated() {
    let coordinator = MemoryPressureCoordinator()
    var targets: [UInt64] = []
    let id = coordinator.register(
        label: "dev",
        guestKind: .macOS,
        configuredMemorySize: 8 * oneGiB
    ) { targets.append($0) }

    coordinator.handleMemoryPressure(.warning)
    coordinator.handleMemoryPressure(.critical)
    coordinator.handleMemoryPressure(.warning)

    #expect(targets == [6 * oneGiB, 4 * oneGiB])
    #expect(coordinator.requestedMemorySize(for: id) == 4 * oneGiB)
}

@Test @MainActor
func memoryPressureCoordinatorRestoresOneGiBAtATimeRoundRobin() {
    let coordinator = MemoryPressureCoordinator()
    var macOSTargets: [UInt64] = []
    var dockerTargets: [UInt64] = []
    let macOSID = coordinator.register(
        label: "dev",
        guestKind: .macOS,
        configuredMemorySize: 8 * oneGiB
    ) { macOSTargets.append($0) }
    let dockerID = coordinator.register(
        label: "dev Docker sidecar",
        guestKind: .docker,
        configuredMemorySize: 8 * oneGiB
    ) { dockerTargets.append($0) }

    coordinator.handleMemoryPressure(.critical)
    coordinator.handleMemoryPressure(.normal)
    coordinator.beginRecoveryAfterDelay()
    coordinator.performRecoveryStep()
    coordinator.performRecoveryStep()

    #expect(macOSTargets == [4 * oneGiB, 5 * oneGiB, 6 * oneGiB])
    #expect(dockerTargets == [4 * oneGiB, 5 * oneGiB])
    #expect(coordinator.requestedMemorySize(for: macOSID) == 6 * oneGiB)
    #expect(coordinator.requestedMemorySize(for: dockerID) == 5 * oneGiB)
}

@Test @MainActor
func memoryPressureCoordinatorCancelsRecoveryWhenPressureReturns() {
    let coordinator = MemoryPressureCoordinator(schedulesRecoveryAutomatically: true)
    var targets: [UInt64] = []
    let id = coordinator.register(
        label: "dev",
        guestKind: .macOS,
        configuredMemorySize: 8 * oneGiB
    ) { targets.append($0) }

    coordinator.handleMemoryPressure(.critical)
    coordinator.handleMemoryPressure(.normal)
    #expect(coordinator.recoveryIsScheduled)

    coordinator.handleMemoryPressure(.warning)
    #expect(!coordinator.recoveryIsScheduled)
    coordinator.performRecoveryStep()

    #expect(targets == [4 * oneGiB])
    #expect(coordinator.requestedMemorySize(for: id) == 4 * oneGiB)
}

@Test @MainActor
func memoryPressureCoordinatorAppliesExistingPressureAndUnregistersCleanly() {
    let coordinator = MemoryPressureCoordinator()
    coordinator.handleMemoryPressure(.critical)
    var targets: [UInt64] = []
    let id = coordinator.register(
        label: "dev Docker sidecar",
        guestKind: .docker,
        configuredMemorySize: 4 * oneGiB
    ) { targets.append($0) }

    #expect(targets == [2 * oneGiB])
    coordinator.unregister(id)
    coordinator.handleMemoryPressure(.normal)
    coordinator.beginRecoveryAfterDelay()

    #expect(coordinator.requestedMemorySize(for: id) == nil)
    #expect(targets == [2 * oneGiB])
}

@Test @MainActor
func memoryPressureCoordinatorPrioritizesCriticalCoalescedEvents() {
    #expect(MemoryPressureCoordinator.pressureLevel(for: [.normal, .warning]) == .warning)
    #expect(MemoryPressureCoordinator.pressureLevel(for: [.normal, .critical]) == .critical)
    #expect(MemoryPressureCoordinator.pressureLevel(for: [.normal]) == .normal)
}
