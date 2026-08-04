import Darwin
import Foundation
import Testing
@testable import MacVMHostKit

@Suite(.serialized)
struct DockerGuestProcessRunnerTests {
    @Test
    func successfulProcessesDoNotGrowDescriptorCount() throws {
        _ = try run("/usr/bin/true", standardOutput: .discard)
        let baseline = openDescriptorCount()

        for _ in 0..<100 {
            let result = try run("/usr/bin/true", standardOutput: .discard)
            #expect(result.terminationStatus == 0)
            #expect(!result.didTimeOut)
        }

        expectStableDescriptorCount(from: baseline)
    }

    @Test
    func nonzeroProcessesDoNotGrowDescriptorCount() throws {
        _ = try run("/usr/bin/false", standardOutput: .discard)
        let baseline = openDescriptorCount()

        for _ in 0..<100 {
            let result = try run("/usr/bin/false", standardOutput: .discard)
            #expect(result.terminationStatus != 0)
            #expect(!result.didTimeOut)
        }

        expectStableDescriptorCount(from: baseline)
    }

    @Test
    func capturesStandardOutputAndStandardErrorTogether() throws {
        let result = try run(
            "/bin/sh",
            arguments: ["-c", "printf 'stdout text'; printf 'stderr text' >&2; exit 7"],
            standardOutput: .capture
        )

        #expect(result.terminationStatus == 7)
        #expect(result.standardOutput?.data == Data("stdout text".utf8))
        #expect(result.standardError.data == Data("stderr text".utf8))
        #expect(result.standardOutput?.wasTruncated == false)
        #expect(!result.standardError.wasTruncated)
    }

    @Test
    func inheritAndDiscardPoliciesKeepStandardOutputOpen() throws {
        for policy: DockerGuestProcessRunner.StandardOutputPolicy in [.inherit, .discard] {
            let result = try run(
                "/bin/sh",
                arguments: ["-c", ": >&1"],
                standardOutput: policy
            )
            #expect(result.terminationStatus == 0)
        }
    }

    @Test
    func launchFailuresDoNotGrowDescriptorCount() throws {
        let executable = "/definitely/not/a/macvm/executable"
        let expectedError = try processLaunchError(for: executable)
        _ = try run("/usr/bin/true", standardOutput: .discard)
        let baseline = openDescriptorCount()
        var failureCount = 0

        for _ in 0..<100 {
            do {
                _ = try run(executable, standardOutput: .capture)
            } catch {
                let error = error as NSError
                #expect(error.domain == expectedError.domain)
                #expect(error.code == expectedError.code)
                #expect(
                    error.userInfo[NSFilePathErrorKey] as? String
                        == expectedError.userInfo[NSFilePathErrorKey] as? String
                )
                failureCount += 1
            }
        }

        #expect(failureCount == 100)
        expectStableDescriptorCount(from: baseline)
    }

    @Test
    func propagatesLessCommonProcessLaunchErrors() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macvm-process-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("symlink-loop")
        try FileManager.default.createSymbolicLink(
            atPath: executable.path,
            withDestinationPath: executable.lastPathComponent
        )
        let expectedError = try processLaunchError(for: executable.path)
        var observedError: NSError?

        do {
            _ = try run(executable.path, standardOutput: .capture)
        } catch {
            observedError = error as NSError
        }

        #expect(observedError?.domain == expectedError.domain)
        #expect(observedError?.code == expectedError.code)
        #expect(
            observedError?.userInfo[NSFilePathErrorKey] as? String
                == expectedError.userInfo[NSFilePathErrorKey] as? String
        )
    }

    @Test
    func timeoutKillsAndReapsProcessWithoutGrowingDescriptorCount() throws {
        _ = try run("/usr/bin/true", standardOutput: .discard)
        let baseline = openDescriptorCount()

        for _ in 0..<10 {
            let result = try run(
                "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                standardOutput: .capture,
                timeout: 0.02,
                terminationGracePeriod: 0.02
            )
            #expect(result.didTimeOut)
            #expect(result.terminationReason == .uncaughtSignal)

            errno = 0
            #expect(Darwin.kill(result.processIdentifier, 0) == -1)
            #expect(errno == ESRCH)
        }

        expectStableDescriptorCount(from: baseline)
    }

    @Test
    func timeoutReturnsPromptlyAfterTermResponsiveProcessExits() throws {
        let previousSignalDisposition = Darwin.signal(SIGTERM, SIG_IGN)
        defer { Darwin.signal(SIGTERM, previousSignalDisposition) }
        let startedAt = Date()
        let result = try run(
            "/bin/sleep",
            arguments: ["10"],
            standardOutput: .capture,
            timeout: 0.1,
            terminationGracePeriod: 2
        )

        #expect(result.didTimeOut)
        #expect(result.terminationStatus == SIGTERM)
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test
    func timeoutKillsDescendantsHoldingCapturedStreams() throws {
        let startedAt = Date()
        let result = try run(
            "/bin/sh",
            arguments: ["-c", "(trap '' TERM; /bin/sleep 2) & wait"],
            standardOutput: .capture,
            timeout: 0.02,
            terminationGracePeriod: 0.02
        )

        #expect(result.didTimeOut)
        #expect(result.terminationReason == .uncaughtSignal)
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test
    func timeoutIncludesStreamDrainAfterDirectChildExit() throws {
        let startedAt = Date()
        let result = try run(
            "/bin/sh",
            arguments: ["-c", "(trap '' TERM; /bin/sleep 2) & exit 0"],
            standardOutput: .capture,
            timeout: 0.02,
            terminationGracePeriod: 0.02
        )

        #expect(result.didTimeOut)
        #expect(result.terminationStatus == 0)
        #expect(Date().timeIntervalSince(startedAt) < 1)
    }

    @Test
    func timeoutKillsDescendantThatEscapesProcessGroup() throws {
        let processIdentifierURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macvm-escaped-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: processIdentifierURL) }
        let python = "import os,time; os.setsid(); "
            + "open(\"\(processIdentifierURL.path)\", \"w\").write(str(os.getpid())); "
            + "time.sleep(4)"
        let command = "/usr/bin/python3 -c '\(python)' & "
            + "while [ ! -s '\(processIdentifierURL.path)' ]; do /bin/sleep 0.01; done; "
            + "exit 0"
        let startedAt = Date()
        let result = try run(
            "/bin/sh",
            arguments: ["-c", command],
            standardOutput: .capture,
            timeout: 1,
            terminationGracePeriod: 0.05
        )

        #expect(result.didTimeOut)
        #expect(Date().timeIntervalSince(startedAt) < 2)
        let processIdentifier = try #require(
            Int32(String(contentsOf: processIdentifierURL, encoding: .utf8))
        )
        let deadline = Date().addingTimeInterval(1)
        while Darwin.kill(processIdentifier, 0) == 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        errno = 0
        #expect(Darwin.kill(processIdentifier, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func drainsLargeStreamsWhileBoundingRetainedOutput() throws {
        let limit = 32 * 1024
        let result = try run(
            "/bin/sh",
            arguments: [
                "-c",
                "/usr/bin/yes stdout | /usr/bin/head -c 262144; "
                    + "/usr/bin/yes stderr | /usr/bin/head -c 262144 >&2",
            ],
            standardOutput: .capture,
            maximumCapturedStreamSize: limit
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput?.data.count == limit)
        #expect(result.standardOutput?.wasTruncated == true)
        #expect(result.standardError.data.count == limit)
        #expect(result.standardError.wasTruncated)
    }

    private func run(
        _ executable: String,
        arguments: [String] = [],
        standardOutput: DockerGuestProcessRunner.StandardOutputPolicy,
        timeout: TimeInterval? = nil,
        terminationGracePeriod: TimeInterval = 5,
        maximumCapturedStreamSize: Int = DockerGuestProcessRunner.maximumCapturedStreamSize
    ) throws -> DockerGuestProcessRunner.Result {
        try DockerGuestProcessRunner.run(
            executableURL: URL(fileURLWithPath: executable),
            arguments: arguments,
            standardOutput: standardOutput,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            maximumCapturedStreamSize: maximumCapturedStreamSize
        )
    }

    private func processLaunchError(for executable: String) throws -> NSError {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        do {
            try process.run()
        } catch {
            return error as NSError
        }
        process.waitUntilExit()
        throw CocoaError(.executableLoad)
    }

    private func openDescriptorCount() -> Int {
        (0..<getdtablesize()).reduce(into: 0) { count, descriptor in
            errno = 0
            if fcntl(descriptor, F_GETFD) != -1 || errno != EBADF {
                count += 1
            }
        }
    }

    private func expectStableDescriptorCount(from baseline: Int) {
        let current = openDescriptorCount()
        #expect(
            current <= baseline + 4,
            "Open descriptor count grew from \(baseline) to \(current)"
        )
    }
}
