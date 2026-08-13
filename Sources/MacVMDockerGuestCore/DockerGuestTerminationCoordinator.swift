import Foundation

public final class DockerGuestTerminationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var terminationRequested = false
    private var cleanups: [@Sendable () -> Void] = []

    public init() {}

    public var isTerminationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminationRequested
    }

    public func registerCleanup(_ cleanup: @escaping @Sendable () -> Void) {
        lock.lock()
        let runImmediately = terminationRequested
        if !runImmediately {
            cleanups.append(cleanup)
        }
        lock.unlock()

        if runImmediately {
            cleanup()
        }
    }

    public func requestTermination() {
        lock.lock()
        guard !terminationRequested else {
            lock.unlock()
            return
        }
        terminationRequested = true
        let pendingCleanups = cleanups.reversed()
        cleanups.removeAll()
        lock.unlock()

        for cleanup in pendingCleanups {
            cleanup()
        }
    }
}
