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
