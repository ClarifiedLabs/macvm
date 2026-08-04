import Darwin
import Foundation

@_silgen_name("_NSGetEnviron")
private func _NSGetEnviron() -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>

struct DockerGuestProcessRunner {
    static let maximumCapturedStreamSize = 1024 * 1024

    enum StandardOutputPolicy {
        case inherit
        case discard
        case capture
    }

    struct CapturedStream {
        let data: Data
        let wasTruncated: Bool
    }

    enum Completion {
        case exited(status: Int32, reason: Process.TerminationReason)
        case timedOut(status: Int32, reason: Process.TerminationReason)
    }

    struct Result {
        let processIdentifier: Int32
        let completion: Completion
        let standardOutput: CapturedStream?
        let standardError: CapturedStream

        var didTimeOut: Bool {
            if case .timedOut = completion { return true }
            return false
        }

        var terminationStatus: Int32 {
            switch completion {
            case .exited(let status, _), .timedOut(let status, _):
                return status
            }
        }

        var terminationReason: Process.TerminationReason {
            switch completion {
            case .exited(_, let reason), .timedOut(_, let reason):
                return reason
            }
        }
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        standardOutput: StandardOutputPolicy,
        timeout: TimeInterval? = nil,
        terminationGracePeriod: TimeInterval = 5,
        maximumCapturedStreamSize: Int = maximumCapturedStreamSize
    ) throws -> Result {
        precondition(maximumCapturedStreamSize >= 0)

        let outputPipe: OwnedPipe?
        switch standardOutput {
        case .inherit, .discard:
            outputPipe = nil
        case .capture:
            outputPipe = try OwnedPipe()
        }
        let errorPipe = try OwnedPipe()
        let pipes = [outputPipe, errorPipe].compactMap { $0 }
        let readers = DispatchGroup()
        let outputCollector = outputPipe.map {
            StreamCollector(
                handle: $0.readHandle,
                maximumRetainedSize: maximumCapturedStreamSize
            )
        }
        let errorCollector = StreamCollector(
            handle: errorPipe.readHandle,
            maximumRetainedSize: maximumCapturedStreamSize
        )
        let collectors = [outputCollector, errorCollector].compactMap { $0 }
        var processIdentifier: pid_t = 0
        var didLaunch = false
        var didReap = false
        var didStartReaders = false

        defer {
            if didLaunch && !didReap {
                terminateAndReapIfOwned(processIdentifier)
            }
            for pipe in pipes {
                close(pipe.writeHandle)
            }
            if didStartReaders {
                for collector in collectors {
                    collector.cancel()
                }
                readers.wait()
            }
            for pipe in pipes {
                close(pipe.readHandle)
                close(pipe.writeHandle)
            }
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        try throwIfPOSIXError(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try addOpen(
            to: &fileActions,
            descriptor: STDIN_FILENO,
            path: "/dev/null",
            flags: O_RDONLY
        )
        switch standardOutput {
        case .inherit:
            try throwIfPOSIXError(
                posix_spawn_file_actions_addinherit_np(
                    &fileActions,
                    STDOUT_FILENO
                )
            )
        case .discard:
            try addOpen(
                to: &fileActions,
                descriptor: STDOUT_FILENO,
                path: "/dev/null",
                flags: O_WRONLY
            )
        case .capture:
            if let outputPipe {
                try addPipe(
                    outputPipe,
                    to: &fileActions,
                    destinationDescriptor: STDOUT_FILENO
                )
            }
        }
        try addPipe(
            errorPipe,
            to: &fileActions,
            destinationDescriptor: STDERR_FILENO
        )

        var attributes: posix_spawnattr_t? = nil
        try throwIfPOSIXError(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try throwIfPOSIXError(posix_spawnattr_setpgroup(&attributes, 0))
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try throwIfPOSIXError(
            posix_spawnattr_setsigmask(&attributes, &signalMask)
        )
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        try throwIfPOSIXError(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        )
        try throwIfPOSIXError(
            posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_CLOEXEC_DEFAULT
                        | POSIX_SPAWN_SETPGROUP
                        | POSIX_SPAWN_SETSIGDEF
                        | POSIX_SPAWN_SETSIGMASK
                )
            )
        )

        let argumentArray = try CStringArray([executableURL.path] + arguments)
        for collector in collectors {
            collector.start(in: readers)
        }
        didStartReaders = true

        let launchResult = executableURL.path.withCString { executablePath in
            posix_spawn(
                &processIdentifier,
                executablePath,
                &fileActions,
                &attributes,
                argumentArray.pointer,
                _NSGetEnviron().pointee
            )
        }
        guard launchResult == 0 else {
            throw processCompatibleLaunchError(
                executableURL: executableURL,
                posixError: launchResult
            )
        }
        didLaunch = true

        let escapedProcessTracker = timeout.map { _ in
            EscapedProcessTracker(
                pipeReadHandles: pipes.map(\.readHandle),
                excludingProcessIdentifier: getpid(),
                excludingProcessGroupIdentifier: processIdentifier
            )
        }
        for pipe in pipes {
            close(pipe.writeHandle)
        }

        let rawStatus: Int32
        let didTimeOut: Bool
        if let timeout {
            let deadline = DispatchTime.now() + max(timeout, 0)
            if try waitForCompletion(
                processIdentifier,
                readers: readers,
                escapedProcessTracker: escapedProcessTracker,
                until: deadline
            ) {
                rawStatus = try waitForExit(processIdentifier)
                didTimeOut = false
            } else {
                didTimeOut = true
                let graceDeadline = DispatchTime.now() + max(terminationGracePeriod, 0)

                // The direct child remains live or waitable, so its PID and
                // process-group ID cannot be recycled while these signals run.
                _ = Darwin.kill(-processIdentifier, SIGTERM)
                _ = escapedProcessTracker?.refreshAndSignalNewProcesses(
                    SIGTERM,
                    forceRefresh: true
                )
                if try !waitForTimedProcessToQuiesce(
                    processIdentifier,
                    readers: readers,
                    escapedProcessTracker: escapedProcessTracker,
                    until: graceDeadline
                ) {
                    _ = Darwin.kill(-processIdentifier, SIGKILL)
                    escapedProcessTracker?.signalTrackedProcesses(SIGKILL)
                }
                rawStatus = try waitForExit(processIdentifier)
                escapedProcessTracker?.killAndWait(
                    until: .now() + 0.1
                )

                // As a final bound, cancel a stream if a process that could
                // not be inspected still retains an inherited pipe.
                if readers.wait(timeout: .now() + 0.1) == .timedOut {
                    for collector in collectors {
                        collector.cancel()
                    }
                }
            }
        } else {
            rawStatus = try waitForExit(processIdentifier)
            didTimeOut = false
        }
        didReap = true
        readers.wait()

        let (status, reason) = termination(from: rawStatus)
        let completion: Completion = didTimeOut
            ? .timedOut(status: status, reason: reason)
            : .exited(status: status, reason: reason)
        return Result(
            processIdentifier: processIdentifier,
            completion: completion,
            standardOutput: outputCollector?.capturedStream,
            standardError: errorCollector.capturedStream
        )
    }

    private static func addOpen(
        to fileActions: inout posix_spawn_file_actions_t?,
        descriptor: Int32,
        path: String,
        flags: Int32
    ) throws {
        let result = path.withCString {
            posix_spawn_file_actions_addopen(
                &fileActions,
                descriptor,
                $0,
                flags,
                0
            )
        }
        try throwIfPOSIXError(result)
    }

    private static func addPipe(
        _ pipe: OwnedPipe,
        to fileActions: inout posix_spawn_file_actions_t?,
        destinationDescriptor: Int32
    ) throws {
        let readDescriptor = pipe.readHandle.fileDescriptor
        let writeDescriptor = pipe.writeHandle.fileDescriptor
        try throwIfPOSIXError(
            posix_spawn_file_actions_adddup2(
                &fileActions,
                writeDescriptor,
                destinationDescriptor
            )
        )
        try throwIfPOSIXError(
            posix_spawn_file_actions_addclose(&fileActions, readDescriptor)
        )
        try throwIfPOSIXError(
            posix_spawn_file_actions_addclose(&fileActions, writeDescriptor)
        )
    }

    private static func waitForCompletion(
        _ processIdentifier: pid_t,
        readers: DispatchGroup,
        escapedProcessTracker: EscapedProcessTracker?,
        until deadline: DispatchTime
    ) throws -> Bool {
        while true {
            escapedProcessTracker?.refreshAndTrackProcesses()
            if try isExitPending(processIdentifier),
                readers.wait(timeout: .now()) == .success {
                return true
            }
            let now = DispatchTime.now()
            guard now < deadline else { return false }
            sleep(until: deadline, from: now)
        }
    }

    private static func waitForTimedProcessToQuiesce(
        _ processIdentifier: pid_t,
        readers: DispatchGroup,
        escapedProcessTracker: EscapedProcessTracker?,
        until deadline: DispatchTime
    ) throws -> Bool {
        while true {
            let hasEscapedProcesses = escapedProcessTracker?
                .refreshAndSignalNewProcesses(SIGTERM) ?? false
            if try isExitPending(processIdentifier),
                !processGroupContainsDescendants(processIdentifier),
                !hasEscapedProcesses,
                readers.wait(timeout: .now()) == .success {
                return true
            }
            let now = DispatchTime.now()
            guard now < deadline else { return false }
            sleep(until: deadline, from: now)
        }
    }

    private static func isExitPending(_ processIdentifier: pid_t) throws -> Bool {
        while true {
            var information = siginfo_t()
            let result = waitid(
                P_PID,
                id_t(processIdentifier),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            )
            if result == 0 {
                return information.si_pid == processIdentifier
            }
            if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
            }
        }
    }

    private static func processGroupContainsDescendants(
        _ processIdentifier: pid_t
    ) -> Bool {
        var processIdentifiers = [pid_t](repeating: 0, count: 256)
        let count = processIdentifiers.withUnsafeMutableBytes {
            proc_listpgrppids(
                processIdentifier,
                $0.baseAddress,
                Int32($0.count)
            )
        }
        guard count >= 0 else { return true }
        for groupMember in processIdentifiers.prefix(Int(count))
        where groupMember != 0 && groupMember != processIdentifier {
            var information = proc_bsdshortinfo()
            let received = proc_pidinfo(
                groupMember,
                PROC_PIDT_SHORTBSDINFO,
                0,
                &information,
                Int32(MemoryLayout<proc_bsdshortinfo>.size)
            )
            if received == MemoryLayout<proc_bsdshortinfo>.size,
                information.pbsi_status != UInt32(SZOMB) {
                return true
            }
        }
        return false
    }

    fileprivate static func sleep(until deadline: DispatchTime, from now: DispatchTime) {
        let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
        Thread.sleep(forTimeInterval: min(remaining, 0.01))
    }

    private static func waitForExit(_ processIdentifier: pid_t) throws -> Int32 {
        while true {
            var status: Int32 = 0
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier {
                return status
            }
            if result == -1 && errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
            }
        }
    }

    private static func terminateAndReapIfOwned(_ processIdentifier: pid_t) {
        while true {
            var status: Int32 = 0
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier {
                return
            }
            if result == 0 {
                _ = Darwin.kill(-processIdentifier, SIGKILL)
                while waitpid(processIdentifier, nil, 0) == -1 && errno == EINTR {}
                return
            }
            if result == -1 && errno == EINTR {
                continue
            }
            // ECHILD means another component already reaped the child. Do not
            // signal a PID that may now belong to an unrelated process.
            return
        }
    }

    private static func termination(
        from status: Int32
    ) -> (status: Int32, reason: Process.TerminationReason) {
        let waitStatus = status & 0x7f
        if waitStatus == 0 {
            return ((status >> 8) & 0xff, .exit)
        }
        return (waitStatus, .uncaughtSignal)
    }

    private static func processCompatibleLaunchError(
        executableURL: URL,
        posixError: Int32
    ) -> Error {
        let path = executableURL.path
        if !FileManager.default.isExecutableFile(atPath: path) {
            return NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileNoSuchFileError,
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        return POSIXError(POSIXErrorCode(rawValue: posixError) ?? .EINVAL)
    }

    private static func throwIfPOSIXError(_ error: Int32) throws {
        guard error != 0 else { return }
        throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL)
    }

    private static func close(_ handle: FileHandle) {
        try? handle.close()
    }
}

private final class OwnedPipe {
    let readHandle: FileHandle
    let writeHandle: FileHandle

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
        }

        var normalizedReadDescriptor: Int32 = -1
        var normalizedWriteDescriptor: Int32 = -1
        do {
            normalizedReadDescriptor = try Self.normalize(descriptors[0])
            normalizedWriteDescriptor = try Self.normalize(descriptors[1])
            if normalizedReadDescriptor != descriptors[0] {
                Darwin.close(descriptors[0])
            }
            if normalizedWriteDescriptor != descriptors[1] {
                Darwin.close(descriptors[1])
            }
            readHandle = FileHandle(
                fileDescriptor: normalizedReadDescriptor,
                closeOnDealloc: false
            )
            writeHandle = FileHandle(
                fileDescriptor: normalizedWriteDescriptor,
                closeOnDealloc: false
            )
        } catch {
            Set(descriptors + [normalizedReadDescriptor, normalizedWriteDescriptor])
                .filter { $0 >= 0 }
                .forEach { Darwin.close($0) }
            throw error
        }
    }

    deinit {
        try? readHandle.close()
        try? writeHandle.close()
    }

    private static func normalize(_ descriptor: Int32) throws -> Int32 {
        if descriptor <= STDERR_FILENO {
            let duplicated = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
            guard duplicated >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
            }
            return duplicated
        }

        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EBADF)
        }
        return descriptor
    }
}

private final class EscapedProcessTracker {
    private struct ProcessKey: Hashable {
        let processIdentifier: pid_t
        let version: UInt32
    }

    private struct TrackedProcess {
        let key: ProcessKey
        let processGroupIdentifier: pid_t
        var auditToken: audit_token_t
    }

    private struct AuditContext {
        let auditUserIdentifier: UInt32
        let auditSessionIdentifier: UInt32

        static func current() -> AuditContext? {
            var token = audit_token_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &token) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(
                        mach_task_self_,
                        task_flavor_t(TASK_AUDIT_TOKEN),
                        $0,
                        &count
                    )
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return AuditContext(
                auditUserIdentifier: token.val.0,
                auditSessionIdentifier: token.val.6
            )
        }
    }

    private static let processUniqueIdentifierInfoFlavor: Int32 = 17
    private static let processUniqueIdentifierInfoSize = 56
    private static let processVersionOffset = 32
    private let pipeHandles: Set<UInt64>
    private let excludedProcessIdentifier: pid_t
    private let excludedProcessGroupIdentifier: pid_t
    private let auditContext: AuditContext?
    private var trackedProcesses: [ProcessKey: TrackedProcess] = [:]
    private var termSignaledProcesses: Set<ProcessKey> = []
    private var nextRefresh = DispatchTime.now()

    init(
        pipeReadHandles: [FileHandle],
        excludingProcessIdentifier: pid_t,
        excludingProcessGroupIdentifier: pid_t
    ) {
        pipeHandles = Set(pipeReadHandles.compactMap(Self.peerPipeHandle))
        self.excludedProcessIdentifier = excludingProcessIdentifier
        self.excludedProcessGroupIdentifier = excludingProcessGroupIdentifier
        auditContext = AuditContext.current()
    }

    func refreshAndTrackProcesses() {
        refreshIfNeeded()
    }

    @discardableResult
    func refreshAndSignalNewProcesses(
        _ signal: Int32,
        forceRefresh: Bool = false
    ) -> Bool {
        refreshIfNeeded(force: forceRefresh)
        for process in trackedProcesses.values
        where !termSignaledProcesses.contains(process.key) {
            signalProcess(process, signal: signal)
            termSignaledProcesses.insert(process.key)
        }
        return trackedProcesses.values.contains(where: isCurrentProcess)
    }

    private func refreshIfNeeded(force: Bool = false) {
        let now = DispatchTime.now()
        guard force || now >= nextRefresh else { return }
        nextRefresh = now + 0.05
        for process in discoverProcesses() {
            trackedProcesses[process.key] = process
        }
    }

    func signalTrackedProcesses(_ signal: Int32) {
        for process in trackedProcesses.values {
            signalProcess(process, signal: signal)
        }
    }

    func killAndWait(until deadline: DispatchTime) {
        while true {
            let discovered = discoverProcesses()
            for process in discovered {
                trackedProcesses[process.key] = process
            }
            let liveProcesses = trackedProcesses.values.filter(isCurrentProcess)
            guard !liveProcesses.isEmpty else { return }
            for process in liveProcesses {
                signalProcess(process, signal: SIGKILL)
            }

            let now = DispatchTime.now()
            guard now < deadline else { return }
            DockerGuestProcessRunner.sleep(until: deadline, from: now)
        }
    }

    private func discoverProcesses() -> [TrackedProcess] {
        guard !pipeHandles.isEmpty, let auditContext else { return [] }
        var processIdentifiers = [pid_t](
            repeating: 0,
            count: max(Int(proc_listallpids(nil, 0)), 1)
        )
        let processCount = processIdentifiers.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard processCount > 0 else { return [] }

        return processIdentifiers.prefix(Int(processCount)).compactMap { processIdentifier in
            guard processIdentifier > 0,
                processIdentifier != excludedProcessIdentifier,
                processIdentifier != excludedProcessGroupIdentifier,
                let identityBeforeInspection = trackedProcess(
                    processIdentifier,
                    auditContext: auditContext
                ),
                processHoldsTrackedPipe(processIdentifier),
                let identityAfterInspection = trackedProcess(
                    processIdentifier,
                    auditContext: auditContext
                ),
                identityBeforeInspection.key == identityAfterInspection.key,
                identityAfterInspection.processGroupIdentifier
                    != excludedProcessGroupIdentifier
            else { return nil }
            return identityAfterInspection
        }
    }

    private func processHoldsTrackedPipe(_ processIdentifier: pid_t) -> Bool {
        let requiredSize = proc_pidinfo(
            processIdentifier,
            PROC_PIDLISTFDS,
            0,
            nil,
            0
        )
        guard requiredSize > 0 else { return false }
        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(requiredSize) / MemoryLayout<proc_fdinfo>.size + 16
        )
        let receivedSize = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(
                processIdentifier,
                PROC_PIDLISTFDS,
                0,
                $0.baseAddress,
                Int32($0.count)
            )
        }
        guard receivedSize > 0 else { return false }

        let count = Int(receivedSize) / MemoryLayout<proc_fdinfo>.size
        for descriptor in descriptors.prefix(count)
        where descriptor.proc_fdtype == PROX_FDTYPE_PIPE {
            var information = pipe_fdinfo()
            let received = proc_pidfdinfo(
                processIdentifier,
                descriptor.proc_fd,
                PROC_PIDFDPIPEINFO,
                &information,
                Int32(MemoryLayout<pipe_fdinfo>.size)
            )
            if received == MemoryLayout<pipe_fdinfo>.size,
                pipeHandles.contains(information.pipeinfo.pipe_handle) {
                return true
            }
        }
        return false
    }

    private func trackedProcess(
        _ processIdentifier: pid_t,
        auditContext: AuditContext
    ) -> TrackedProcess? {
        guard let versionBeforeInformation = processVersion(processIdentifier) else {
            return nil
        }
        var information = proc_bsdinfo()
        guard proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &information,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        ) == MemoryLayout<proc_bsdinfo>.size,
            let version = processVersion(processIdentifier),
            version == versionBeforeInformation
        else {
            return nil
        }
        let key = ProcessKey(
            processIdentifier: processIdentifier,
            version: version
        )
        let token = audit_token_t(
            val: (
                auditContext.auditUserIdentifier,
                information.pbi_uid,
                information.pbi_gid,
                information.pbi_ruid,
                information.pbi_rgid,
                UInt32(bitPattern: processIdentifier),
                auditContext.auditSessionIdentifier,
                version
            )
        )
        return TrackedProcess(
            key: key,
            processGroupIdentifier: pid_t(information.pbi_pgid),
            auditToken: token
        )
    }

    private func processVersion(_ processIdentifier: pid_t) -> UInt32? {
        var uniqueInformation = [UInt8](
            repeating: 0,
            count: Self.processUniqueIdentifierInfoSize
        )
        let received = uniqueInformation.withUnsafeMutableBytes {
            proc_pidinfo(
                processIdentifier,
                Self.processUniqueIdentifierInfoFlavor,
                0,
                $0.baseAddress,
                Int32($0.count)
            )
        }
        guard received == Self.processUniqueIdentifierInfoSize else { return nil }
        return uniqueInformation.withUnsafeBytes {
            $0.loadUnaligned(
                fromByteOffset: Self.processVersionOffset,
                as: UInt32.self
            )
        }
    }

    private func isCurrentProcess(_ process: TrackedProcess) -> Bool {
        processVersion(process.key.processIdentifier) == process.key.version
    }

    private func signalProcess(_ process: TrackedProcess, signal: Int32) {
        var auditToken = process.auditToken
        _ = proc_signal_with_audittoken(&auditToken, signal)
    }

    private static func peerPipeHandle(_ handle: FileHandle) -> UInt64? {
        var information = pipe_fdinfo()
        let received = proc_pidfdinfo(
            getpid(),
            handle.fileDescriptor,
            PROC_PIDFDPIPEINFO,
            &information,
            Int32(MemoryLayout<pipe_fdinfo>.size)
        )
        guard received == MemoryLayout<pipe_fdinfo>.size else { return nil }
        return information.pipeinfo.pipe_peerhandle
    }
}

private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) throws {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        pointer.initialize(repeating: nil, count: count + 1)
        for (index, string) in strings.enumerated() {
            guard let value = strdup(string) else {
                throw POSIXError(.ENOMEM)
            }
            pointer[index] = value
        }
    }

    deinit {
        for index in 0..<count {
            free(pointer[index])
        }
        pointer.deinitialize(count: count + 1)
        pointer.deallocate()
    }
}

private final class StreamCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let maximumRetainedSize: Int
    private let queue = DispatchQueue(label: "dev.macvm.process-stream-reader", qos: .utility)
    private let lock = NSLock()
    private var channel: DispatchIO?
    private var data = Data()
    private var wasTruncated = false
    private var didFinish = false

    init(handle: FileHandle, maximumRetainedSize: Int) {
        self.handle = handle
        self.maximumRetainedSize = maximumRetainedSize
    }

    var capturedStream: DockerGuestProcessRunner.CapturedStream {
        lock.lock()
        defer { lock.unlock() }
        return DockerGuestProcessRunner.CapturedStream(
            data: data,
            wasTruncated: wasTruncated
        )
    }

    func start(in group: DispatchGroup) {
        group.enter()
        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: handle.fileDescriptor,
            queue: queue
        ) { [self] _ in
            finish(group)
        }
        channel.setLimit(highWater: 64 * 1024)
        lock.lock()
        self.channel = channel
        lock.unlock()
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, chunk, error in
            if let chunk, !chunk.isEmpty {
                chunk.enumerateBytes { buffer, _, _ in
                    append(Data(buffer))
                }
            }
            if done || error != 0 {
                channel.close()
            }
        }
    }

    func cancel() {
        lock.lock()
        let channel = channel
        lock.unlock()
        channel?.close(flags: .stop)
    }

    private func finish(_ group: DispatchGroup) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        channel = nil
        lock.unlock()
        group.leave()
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let retainedCount = min(chunk.count, maximumRetainedSize - data.count)
        if retainedCount > 0 {
            data.append(chunk.prefix(retainedCount))
        }
        if retainedCount < chunk.count {
            wasTruncated = true
        }
    }
}
