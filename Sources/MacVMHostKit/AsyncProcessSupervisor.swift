import Darwin
import Foundation

/// Launches finite child processes in their own process group and guarantees
/// that timeout and task cancellation terminate the group and reap its leader.
/// This is intended for async host automation whose subprocesses may themselves
/// create long-lived descendants (for example ssh and ansible-playbook).
struct AsyncProcessSupervisor {
    enum StandardStream {
        case inherit
        case null
        case fileHandle(FileHandle)
    }

    struct Configuration {
        var executableURL: URL
        var arguments: [String]
        var currentDirectoryURL: URL?
        var environment: [String: String]?
        var standardInput: StandardStream
        var standardOutput: StandardStream
        var standardError: StandardStream
        var timeout: TimeInterval?
        var terminationGracePeriod: TimeInterval
        var timeoutDescription: String

        init(
            executableURL: URL,
            arguments: [String] = [],
            currentDirectoryURL: URL? = nil,
            environment: [String: String]? = nil,
            standardInput: StandardStream = .null,
            standardOutput: StandardStream = .inherit,
            standardError: StandardStream = .inherit,
            timeout: TimeInterval? = nil,
            terminationGracePeriod: TimeInterval = 2,
            timeoutDescription: String = "Process"
        ) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.currentDirectoryURL = currentDirectoryURL
            self.environment = environment
            self.standardInput = standardInput
            self.standardOutput = standardOutput
            self.standardError = standardError
            self.timeout = timeout
            self.terminationGracePeriod = terminationGracePeriod
            self.timeoutDescription = timeoutDescription
        }
    }

    struct Result: Equatable, Sendable {
        var processIdentifier: Int32
        var terminationStatus: Int32
        var terminatedBySignal: Bool
    }

    private enum TerminationCause {
        case timedOut
        case cancelled
    }

    static func run(_ configuration: Configuration) async throws -> Result {
        try Task.checkCancellation()
        let processIdentifier = try launch(configuration)
        let state = ProcessState(
            processIdentifier: processIdentifier,
            gracePeriod: configuration.terminationGracePeriod
        )
        let timeoutTask = configuration.timeout.map { timeout in
            Task {
                try await Task.sleep(for: .seconds(max(0, timeout)))
                state.requestTermination(cause: .timedOut)
            }
        }
        defer { timeoutTask?.cancel() }

        let rawStatus = await withTaskCancellationHandler {
            await waitForExit(processIdentifier)
        } onCancel: {
            state.requestTermination(cause: .cancelled)
        }
        state.didReap()
        await state.waitForTerminationSweep()

        switch state.terminationCause {
        case .timedOut:
            throw MacVMError.message(
                "\(configuration.timeoutDescription) timed out after \(Int(configuration.timeout ?? 0)) seconds."
            )
        case .cancelled:
            throw CancellationError()
        case nil:
            let signal = rawStatus & 0x7f
            return Result(
                processIdentifier: processIdentifier,
                terminationStatus: signal == 0 ? (rawStatus >> 8) & 0xff : signal,
                terminatedBySignal: signal != 0
            )
        }
    }

    private static func launch(_ configuration: Configuration) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t? = nil
        try throwIfPOSIXError(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try configure(configuration.standardInput, descriptor: STDIN_FILENO, actions: &fileActions)
        try configure(configuration.standardOutput, descriptor: STDOUT_FILENO, actions: &fileActions)
        try configure(configuration.standardError, descriptor: STDERR_FILENO, actions: &fileActions)
        if let currentDirectoryURL = configuration.currentDirectoryURL {
            try currentDirectoryURL.path.withCString {
                try throwIfPOSIXError(posix_spawn_file_actions_addchdir(&fileActions, $0))
            }
        }

        var attributes: posix_spawnattr_t? = nil
        try throwIfPOSIXError(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try throwIfPOSIXError(posix_spawnattr_setpgroup(&attributes, 0))
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try throwIfPOSIXError(posix_spawnattr_setsigmask(&attributes, &signalMask))
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        try throwIfPOSIXError(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        try throwIfPOSIXError(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        ))

        let arguments = try ProcessCStringArray([configuration.executableURL.path] + configuration.arguments)
        let environment = try ProcessCStringArray(
            (configuration.environment ?? ProcessInfo.processInfo.environment)
                .map { "\($0.key)=\($0.value)" }
                .sorted()
        )
        var processIdentifier: pid_t = 0
        let result = configuration.executableURL.path.withCString {
            posix_spawn(
                &processIdentifier,
                $0,
                &fileActions,
                &attributes,
                arguments.pointer,
                environment.pointer
            )
        }
        guard result == 0 else {
            if !FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: configuration.executableURL.path])
            }
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
        return processIdentifier
    }

    private static func configure(
        _ stream: StandardStream,
        descriptor: Int32,
        actions: inout posix_spawn_file_actions_t?
    ) throws {
        switch stream {
        case .inherit:
            try throwIfPOSIXError(posix_spawn_file_actions_addinherit_np(&actions, descriptor))
        case .null:
            let flags = descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY
            try "/dev/null".withCString {
                try throwIfPOSIXError(posix_spawn_file_actions_addopen(&actions, descriptor, $0, flags, 0))
            }
        case .fileHandle(let handle):
            try throwIfPOSIXError(posix_spawn_file_actions_adddup2(
                &actions,
                handle.fileDescriptor,
                descriptor
            ))
        }
    }

    private static func waitForExit(_ processIdentifier: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                while Darwin.waitpid(processIdentifier, &status, 0) == -1 && errno == EINTR {}
                continuation.resume(returning: status)
            }
        }
    }

    private static func throwIfPOSIXError(_ value: Int32) throws {
        guard value != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: value) ?? .EINVAL)
    }

    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private let processIdentifier: pid_t
        private let gracePeriod: TimeInterval
        private let sweepGroup = DispatchGroup()
        private var reaped = false
        private var cause: TerminationCause?

        init(processIdentifier: pid_t, gracePeriod: TimeInterval) {
            self.processIdentifier = processIdentifier
            self.gracePeriod = gracePeriod
        }

        var terminationCause: TerminationCause? {
            lock.withLock { cause }
        }

        func requestTermination(cause: TerminationCause) {
            let shouldSignal = lock.withLock { () -> Bool in
                guard self.cause == nil, !reaped else { return false }
                self.cause = cause
                sweepGroup.enter()
                return true
            }
            guard shouldSignal else { return }
            _ = Darwin.kill(-processIdentifier, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, gracePeriod)) { [self] in
                lock.withLock {
                    if !reaped || Darwin.kill(-processIdentifier, 0) == 0 {
                        _ = Darwin.kill(-processIdentifier, SIGKILL)
                    }
                }
                sweepGroup.leave()
            }
        }

        func didReap() {
            lock.withLock { reaped = true }
        }

        func waitForTerminationSweep() async {
            await withCheckedContinuation { continuation in
                sweepGroup.notify(queue: .global(qos: .utility)) {
                    continuation.resume()
                }
            }
        }
    }
}

private final class ProcessCStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) throws {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        pointer.initialize(repeating: nil, count: count + 1)
        for (index, string) in strings.enumerated() {
            guard let value = strdup(string) else { throw POSIXError(.ENOMEM) }
            pointer[index] = value
        }
    }

    deinit {
        for index in 0..<count { free(pointer[index]) }
        pointer.deinitialize(count: count + 1)
        pointer.deallocate()
    }
}
