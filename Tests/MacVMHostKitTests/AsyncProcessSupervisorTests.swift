import Darwin
import Foundation
import Testing
@testable import MacVMHostKit

@Test
func asyncProcessSupervisorReapsAProcessGroupOnTimeout() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pidURL = root.appendingPathComponent("child.pid")

    await #expect(throws: (any Error).self) {
        _ = try await AsyncProcessSupervisor.run(.init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > '\(pidURL.path)'; exec sleep 60"],
            timeout: 0.2,
            terminationGracePeriod: 0.1,
            timeoutDescription: "test process"
        ))
    }
    let pid = try #require(Int32(
        String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

@Test
func asyncProcessSupervisorReturnsNormalExitAndHandlesCancellation() async throws {
    let normal = try await AsyncProcessSupervisor.run(.init(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exit 7"],
        timeout: 2
    ))
    #expect(normal.terminationStatus == 7)
    #expect(!normal.terminatedBySignal)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pidURL = root.appendingPathComponent("cancelled.pid")
    let task = Task {
        try await AsyncProcessSupervisor.run(.init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > '\(pidURL.path)'; exec sleep 60"],
            terminationGracePeriod: 0.1
        ))
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let pid = try #require(Int32(
        String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    ))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(kill(pid, 0) == -1)
    #expect(errno == ESRCH)
}

@Test
func asyncProcessSupervisorReapsATermIgnoringProcessGroup() async throws {
    for _ in 0..<3 {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let leaderURL = root.appendingPathComponent("leader.pid")
        let childURL = root.appendingPathComponent("child.pid")
        await #expect(throws: (any Error).self) {
            _ = try await AsyncProcessSupervisor.run(.init(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "trap '' TERM; echo $$ > '\(leaderURL.path)'; "
                        + "sh -c 'trap \"\" TERM; echo $$ > \"\(childURL.path)\"; while :; do sleep 1; done' & wait",
                ],
                timeout: 0.2,
                terminationGracePeriod: 0.1
            ))
        }
        for url in [leaderURL, childURL] {
            let pid = try #require(Int32(
                String(contentsOf: url, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            #expect(kill(pid, 0) == -1)
            #expect(errno == ESRCH)
        }
        try FileManager.default.removeItem(at: root)
    }
}

private struct DockerTransactionTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@Test
func dockerDiskGrowthTransactionRollsBackAndCombinesRollbackFailure() throws {
    var size: UInt64 = 64
    #expect(throws: DockerTransactionTestError.self) {
        _ = try DockerDiskGrowthTransaction.perform(
            targetSizeBytes: 128,
            readActualSize: { size },
            grow: { size = $0 },
            persist: { throw DockerTransactionTestError(message: "metadata failed") },
            rollback: { size = $0 }
        ) as Void
    }
    #expect(size == 64)

    do {
        _ = try DockerDiskGrowthTransaction.perform(
            targetSizeBytes: 128,
            readActualSize: { size },
            grow: { size = $0 },
            persist: { throw DockerTransactionTestError(message: "metadata failed") },
            rollback: { _ in throw DockerTransactionTestError(message: "truncate failed") }
        ) as Void
        Issue.record("Expected combined transaction failure")
    } catch {
        #expect(error.localizedDescription.contains("metadata failed"))
        #expect(error.localizedDescription.contains("truncate failed"))
    }
}

@Test
func dockerResourcePatchPreservesOmittedValuesAndAllowsResetShrink() {
    let gib: UInt64 = 1024 * 1024 * 1024
    let existing = DockerSidecarSettings(
        amd64Enabled: false,
        cpuCount: 7,
        memorySizeBytes: 9 * gib,
        dataDiskSizeBytes: 120 * gib,
        macOSMACAddress: "02:00:00:00:00:01",
        linuxPrivateMACAddress: "02:00:00:00:00:02",
        linuxNATMACAddress: "02:00:00:00:00:03"
    )
    #expect(DockerSidecarResourcePatch().resolve(existing: existing) == DockerSidecarResourceConfiguration(
        cpuCount: 7, memorySizeBytes: 9 * gib, dataDiskSizeBytes: 120 * gib, amd64Enabled: false
    ))
    #expect(DockerSidecarResourcePatch().resolve(
        existing: existing,
        actualDataDiskSizeBytes: 128 * gib
    ).dataDiskSizeBytes == 128 * gib)
    #expect(DockerSidecarResourcePatch(dataDiskSizeBytes: 32 * gib).resolve(existing: existing).dataDiskSizeBytes == 32 * gib)
}
