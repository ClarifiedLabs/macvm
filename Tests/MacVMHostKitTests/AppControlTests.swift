import Foundation
import Testing
@testable import MacVMHostKit

@Test
func sharedSettingsPersistAndResetVMRoot() throws {
    let suiteName = "dev.macvm.macvm.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let settings = MacVMSettings(defaults: defaults)
    #expect(settings.configuredVMRootDirectory == nil)
    #expect(settings.effectiveVMRootDirectory == MacVMSettings.defaultVMRootDirectory)
    #expect(settings.dockerImageAutoRefreshEnabled)

    settings.setDockerImageAutoRefreshEnabled(false)
    #expect(!settings.dockerImageAutoRefreshEnabled)
    settings.setDockerImageAutoRefreshEnabled(true)
    #expect(settings.dockerImageAutoRefreshEnabled)

    let configured = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("MacVM Settings Test", isDirectory: true)
    settings.setVMRootDirectory(configured)

    #expect(settings.configuredVMRootDirectory == configured.standardizedFileURL.resolvingSymlinksInPath())
    #expect(settings.effectiveVMRootDirectory == configured.standardizedFileURL.resolvingSymlinksInPath())

    settings.setVMRootDirectory(nil)
    #expect(settings.configuredVMRootDirectory == nil)
    #expect(settings.effectiveVMRootDirectory == MacVMSettings.defaultVMRootDirectory)
}

@Test
func appControlQueueRoundTripsFullBundlePathAndResponse() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let controlURL = rootURL.appendingPathComponent("Control", isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("VMs with spaces", isDirectory: true)
        .appendingPathComponent("Développement.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let queue = MacVMAppControlQueue(directoryURL: controlURL)
    let request = MacVMAppControlRequest(
        operation: .run(headless: true, recovery: false, vncPort: 5901),
        bundleURL: bundleURL
    )
    try queue.submit(request)

    let pending = try #require(queue.pendingRequests().first)
    #expect(pending.protocolVersion == request.protocolVersion)
    #expect(pending.id == request.id)
    #expect(pending.operation == request.operation)
    #expect(abs(pending.createdAt.timeIntervalSince(request.createdAt)) < 0.001)
    #expect(pending.bundlePath == bundleURL.standardizedFileURL.resolvingSymlinksInPath().path)

    let response = MacVMAppControlResponse(
        requestID: request.id,
        succeeded: true,
        message: "Booting headless in MacVM.",
        vmName: "Développement",
        vncURL: "vnc://:secret@127.0.0.1:5901",
        ownerPID: 42
    )
    try queue.complete(request, with: response)

    #expect(try queue.pendingRequests().isEmpty)
    #expect(try queue.response(for: request.id) == response)

    try queue.removeResponse(for: request.id)
    #expect(try queue.response(for: request.id) == nil)
}

@Test
func appControlQueueKeepsConcurrentRequestsDistinct() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let queue = MacVMAppControlQueue(directoryURL: rootURL)
    let first = MacVMAppControlRequest(
        createdAt: Date(timeIntervalSince1970: 1),
        operation: .attach,
        bundleURL: URL(fileURLWithPath: "/tmp/first.macvm")
    )
    let second = MacVMAppControlRequest(
        createdAt: Date(timeIntervalSince1970: 2),
        operation: .stop,
        bundleURL: URL(fileURLWithPath: "/tmp/second.macvm")
    )

    try queue.submit(second)
    try queue.submit(first)

    #expect(try queue.pendingRequests().map(\.id) == [first.id, second.id])
}

@Test
func appControlQueueClaimsARequestExactlyOnceAcrossConsumers() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("macvm-control-claim-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let queue = MacVMAppControlQueue(directoryURL: rootURL)
    let request = MacVMAppControlRequest(
        operation: .attach,
        bundleURL: URL(fileURLWithPath: "/tmp/atomic-claim.macvm")
    )
    try queue.submit(request)

    let claims = try await withThrowingTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<16 {
            group.addTask { try queue.claim(request) }
        }
        var values: [Bool] = []
        for try await value in group {
            values.append(value)
        }
        return values
    }

    #expect(claims.filter { $0 }.count == 1)
    #expect(try queue.pendingRequests().isEmpty)
    #expect(try queue.interruptedRequests().map(\.id) == [request.id])
    #expect(queue.isClaimed(request.id))
}

@Test
func appControlQueueAllowsOnlyOneLiveConsumerAndReleasesAfterExit() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("macvm-control-lease-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let queue = MacVMAppControlQueue(directoryURL: rootURL)
    var first = try queue.acquireConsumerLease()
    #expect(first != nil)
    #expect(try queue.acquireConsumerLease() == nil)

    let attributes = try FileManager.default.attributesOfItem(
        atPath: rootURL.appendingPathComponent("consumer.lock").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    first = nil
    #expect(try queue.acquireConsumerLease() != nil)
}

@Test
func appControlQueueTreatsAnExistingProcessingFileAsALostClaim() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("macvm-control-existing-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let queue = MacVMAppControlQueue(directoryURL: rootURL)
    let request = MacVMAppControlRequest(
        operation: .stop,
        bundleURL: URL(fileURLWithPath: "/tmp/existing-claim.macvm")
    )
    try queue.submit(request)
    #expect(try queue.claim(request))

    // Model a duplicate submission with the same request ID while recovery owns
    // the processing file. The second consumer must not replace that claim.
    try queue.submit(request)
    #expect(try !queue.claim(request))
    #expect(try queue.pendingRequests().map(\.id) == [request.id])
    #expect(try queue.interruptedRequests().map(\.id) == [request.id])
}
