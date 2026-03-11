import Foundation

public enum DebugLog {
    private static let state = State()

    public static func setEnabled(_ enabled: Bool) {
        state.setEnabled(enabled)
    }

    public static func log(_ message: @autoclosure () -> String) {
        state.log(message())
    }
}

private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private let formatter = ISO8601DateFormatter()

    init() {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
        }
    }

    func log(_ message: String) {
        let line = lock.withLock { () -> String? in
            guard enabled else {
                return nil
            }

            let timestamp = formatter.string(from: Date())
            return "[debug] \(timestamp) \(message)\n"
        }

        guard let line else {
            return
        }

        fputs(line, stderr)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
