import Foundation
import Testing
@testable import MacVMHostKit

@Test
func installCancellationRegistryCancelsRegisteredProgress() {
    let registry = InstallCancellationRegistry()
    let progress = Progress(totalUnitCount: 100)
    registry.register(name: "vm-a", progress: progress)

    #expect(!progress.isCancelled)
    registry.cancel(name: "vm-a")
    #expect(progress.isCancelled)
}

@Test
func installCancellationRegistryKeepsNamesIndependent() {
    let registry = InstallCancellationRegistry()
    let first = Progress(totalUnitCount: 100)
    let second = Progress(totalUnitCount: 100)
    registry.register(name: "vm-a", progress: first)
    registry.register(name: "vm-b", progress: second)

    registry.cancel(name: "vm-a")

    #expect(first.isCancelled)
    #expect(!second.isCancelled)
}

@Test
func installCancellationRegistryIgnoresUnknownAndUnregisteredNames() {
    let registry = InstallCancellationRegistry()
    let progress = Progress(totalUnitCount: 100)
    registry.register(name: "vm-a", progress: progress)
    registry.unregister(name: "vm-a")

    // Cancelling after unregister, or for a name that was never registered,
    // must leave the progress untouched and must not crash.
    registry.cancel(name: "vm-a")
    registry.cancel(name: "never-registered")

    #expect(!progress.isCancelled)
}
