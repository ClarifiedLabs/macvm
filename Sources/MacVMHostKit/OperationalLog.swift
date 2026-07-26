import OSLog

/// Low-volume, always-on diagnostics for lifecycle transitions and resource
/// decisions that need to survive when `--debug` was not enabled.
enum OperationalLog {
    static let subsystem = "dev.macvm.macvm"

    private static let lifecycleLogger = Logger(subsystem: subsystem, category: "vm-lifecycle")
    private static let memoryLogger = Logger(subsystem: subsystem, category: "memory-pressure")
    private static let dockerLogger = Logger(subsystem: subsystem, category: "docker-sidecar")

    static func lifecycle(_ message: String) {
        lifecycleLogger.notice("\(message, privacy: .public)")
    }

    static func lifecycleError(_ message: String) {
        lifecycleLogger.error("\(message, privacy: .public)")
    }

    static func memory(_ message: String) {
        memoryLogger.notice("\(message, privacy: .public)")
    }

    static func memoryError(_ message: String) {
        memoryLogger.error("\(message, privacy: .public)")
    }

    static func docker(_ message: String) {
        dockerLogger.notice("\(message, privacy: .public)")
    }

    static func dockerError(_ message: String) {
        dockerLogger.error("\(message, privacy: .public)")
    }
}
