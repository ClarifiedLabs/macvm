import Foundation
import OSLog

enum DockerGuestLog {
    static let subsystem = "dev.macvm.macvm.docker-guest"

    private static let logger = Logger(subsystem: subsystem, category: "runtime")
    private static let writer = DockerGuestLogWriter()

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        writer.write(level: "info", message: message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        writer.write(level: "error", message: message)
    }
}

private final class DockerGuestLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.formatter = formatter
    }

    func write(level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = formatter.string(from: Date())
        let singleLineMessage = message.replacingOccurrences(of: "\n", with: "\\n")
        let line = "\(timestamp) level=\(level) \(singleLineMessage)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

/// Preserves useful SSH diagnostics while suppressing the OpenSSH warning
/// emitted for every connection accepted by a stream-local forward. The
/// warning is expected because TCP_NODELAY does not apply to Unix sockets.
final class DockerGuestSSHStderrMonitor: @unchecked Sendable {
    let pipe = Pipe()

    private let label: String
    private let lock = NSLock()
    private var bufferedData = Data()
    private var suppressedTCPNoDelayCount: UInt64 = 0
    private var lastReportedSuppressedCount: UInt64 = 0
    private var stopStarted = false
    private var stopped = false

    init(label: String) {
        self.label = label
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.consume(data)
        }
    }

    func stop() {
        lock.lock()
        guard !stopStarted else {
            lock.unlock()
            return
        }
        stopStarted = true
        lock.unlock()

        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()

        lock.lock()
        consumeLocked(remaining)
        flushPartialLineLocked()
        reportSuppressedLocked(final: true)
        stopped = true
        lock.unlock()
        try? pipe.fileHandleForReading.close()
    }

    private func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        consumeLocked(data)
    }

    private func consumeLocked(_ data: Data) {
        bufferedData.append(data)
        while let newline = bufferedData.firstIndex(of: 0x0A) {
            let line = Data(bufferedData[..<newline])
            bufferedData.removeSubrange(...newline)
            recordLocked(line)
        }
    }

    private func flushPartialLineLocked() {
        guard !bufferedData.isEmpty else { return }
        let line = bufferedData
        bufferedData.removeAll(keepingCapacity: false)
        recordLocked(line)
    }

    private func recordLocked(_ data: Data) {
        let line = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        if line.contains("setsockopt TCP_NODELAY") {
            suppressedTCPNoDelayCount += 1
            if suppressedTCPNoDelayCount == 1
                || suppressedTCPNoDelayCount.isMultiple(of: 1_000) {
                reportSuppressedLocked(final: false)
            }
            return
        }
        DockerGuestLog.error("ssh-stderr label=\(label) message=\(line)")
    }

    private func reportSuppressedLocked(final: Bool) {
        guard suppressedTCPNoDelayCount > lastReportedSuppressedCount else { return }
        lastReportedSuppressedCount = suppressedTCPNoDelayCount
        DockerGuestLog.info(
            "ssh-stderr-filter label=\(label) suppressedTCPNoDelay=\(suppressedTCPNoDelayCount) "
                + "final=\(final)"
        )
    }
}
