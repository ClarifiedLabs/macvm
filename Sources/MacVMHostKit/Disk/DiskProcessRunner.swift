import Foundation

/// The command-running seam used by disk-image operations.
///
/// Conformers must treat a nonzero termination status as an error. Tests can
/// either provide a small conformer or use `DiskProcessRunner.init(operation:)`.
protocol DiskProcessRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String]
    ) throws -> DiskProcessRunner.Result
}

extension DiskProcessRunning {
    /// Runs a command whose standard output must be a dictionary property list.
    func runPropertyList(
        executableURL: URL,
        arguments: [String]
    ) throws -> [String: Any] {
        let result = try run(executableURL: executableURL, arguments: arguments)
        try DiskProcessRunner.checkTermination(
            result,
            executableURL: executableURL,
            arguments: arguments
        )

        guard !result.standardOutput.wasTruncated else {
            throw MacVMError.message(
                "Disk command \(DiskProcessRunner.commandDescription(executableURL, arguments)) "
                    + "returned truncated property-list output."
            )
        }

        let propertyList: Any
        do {
            propertyList = try PropertyListSerialization.propertyList(
                from: result.standardOutput.data,
                options: [],
                format: nil
            )
        } catch {
            throw MacVMError.message(
                "Disk command \(DiskProcessRunner.commandDescription(executableURL, arguments)) "
                    + "returned malformed property-list output."
            )
        }

        guard let dictionary = propertyList as? [String: Any] else {
            throw MacVMError.message(
                "Disk command \(DiskProcessRunner.commandDescription(executableURL, arguments)) "
                    + "returned a non-dictionary property list."
            )
        }
        return dictionary
    }
}

/// Synchronously launches disk utilities without involving a shell.
///
/// Standard output and standard error are drained on separate queues while the
/// process runs, preventing a full pipe from blocking either stream. Only the
/// first `maximumCapturedStreamSize` bytes of each stream are retained; all
/// later bytes are still drained.
struct DiskProcessRunner: DiskProcessRunning {
    static let maximumCapturedStreamSize = 1024 * 1024

    struct CapturedStream: Equatable, Sendable {
        let data: Data
        let wasTruncated: Bool

        var string: String {
            String(decoding: data, as: UTF8.self)
        }
    }

    struct Result: Equatable, Sendable {
        let terminationStatus: Int32
        let standardOutput: CapturedStream
        let standardError: CapturedStream
    }

    typealias Operation = @Sendable (
        _ executableURL: URL,
        _ arguments: [String]
    ) throws -> Result

    private static let maximumDiagnosticSize = 4 * 1024
    private let operation: Operation

    init(maximumCapturedStreamSize: Int = maximumCapturedStreamSize) {
        precondition(maximumCapturedStreamSize >= 0)
        operation = { executableURL, arguments in
            try Self.launch(
                executableURL: executableURL,
                arguments: arguments,
                maximumCapturedStreamSize: maximumCapturedStreamSize
            )
        }
    }

    /// Creates a checked runner around a test operation. URL validation and
    /// nonzero-status handling remain identical to the production runner.
    init(operation: @escaping Operation) {
        self.operation = operation
    }

    func run(
        executableURL: URL,
        arguments: [String]
    ) throws -> Result {
        try Self.validate(executableURL: executableURL)
        let result = try operation(executableURL, arguments)
        try Self.checkTermination(
            result,
            executableURL: executableURL,
            arguments: arguments
        )
        return result
    }

    fileprivate static func checkTermination(
        _ result: Result,
        executableURL: URL,
        arguments: [String]
    ) throws {
        guard result.terminationStatus != 0 else { return }

        var message = "Disk command \(commandDescription(executableURL, arguments)) "
            + "failed with status \(result.terminationStatus)."
        let diagnostics = [
            diagnostic(result.standardError, label: "stderr"),
            diagnostic(result.standardOutput, label: "stdout"),
        ].compactMap { $0 }
        if !diagnostics.isEmpty {
            message += " " + diagnostics.joined(separator: " ")
        }
        throw MacVMError.message(message)
    }

    fileprivate static func commandDescription(
        _ executableURL: URL,
        _ arguments: [String]
    ) -> String {
        ([executableURL.path] + arguments)
            .map { String(reflecting: $0) }
            .joined(separator: " ")
    }

    private static func validate(executableURL: URL) throws {
        let host = executableURL.host
        guard executableURL.isFileURL,
              executableURL.baseURL == nil,
              (executableURL.path as NSString).isAbsolutePath,
              host == nil || host == "" || host == "localhost" else {
            throw MacVMError.message(
                "Disk commands require an absolute local executable URL."
            )
        }
    }

    private static func launch(
        executableURL: URL,
        arguments: [String],
        maximumCapturedStreamSize: Int
    ) throws -> Result {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCollector = DiskBoundedStreamCollector(
            handle: outputPipe.fileHandleForReading,
            maximumRetainedSize: maximumCapturedStreamSize
        )
        let errorCollector = DiskBoundedStreamCollector(
            handle: errorPipe.fileHandleForReading,
            maximumRetainedSize: maximumCapturedStreamSize
        )
        let readers = DispatchGroup()
        outputCollector.start(in: readers)
        errorCollector.start(in: readers)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            readers.wait()
            throw MacVMError.message(
                "Couldn't run disk command \(commandDescription(executableURL, arguments)): "
                    + "\(error.localizedDescription)"
            )
        }

        // Process has duplicated these descriptors for the child. Closing the
        // parent's copies lets the readers observe EOF as soon as the child exits.
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        readers.wait()

        if let error = outputCollector.readError {
            throw streamReadError(
                streamName: "standard output",
                executableURL: executableURL,
                arguments: arguments,
                underlyingError: error
            )
        }
        if let error = errorCollector.readError {
            throw streamReadError(
                streamName: "standard error",
                executableURL: executableURL,
                arguments: arguments,
                underlyingError: error
            )
        }

        return Result(
            terminationStatus: process.terminationStatus,
            standardOutput: outputCollector.capturedStream,
            standardError: errorCollector.capturedStream
        )
    }

    private static func streamReadError(
        streamName: String,
        executableURL: URL,
        arguments: [String],
        underlyingError: Error
    ) -> MacVMError {
        .message(
            "Couldn't read \(streamName) from disk command "
                + "\(commandDescription(executableURL, arguments)): "
                + "\(underlyingError.localizedDescription)"
        )
    }

    private static func diagnostic(
        _ stream: CapturedStream,
        label: String
    ) -> String? {
        guard !stream.data.isEmpty else {
            return stream.wasTruncated ? "\(label): [truncated]" : nil
        }

        let displayedData = stream.data.prefix(maximumDiagnosticSize)
        let text = String(decoding: displayedData, as: UTF8.self)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !text.isEmpty else {
            return stream.wasTruncated ? "\(label): [truncated]" : nil
        }

        let wasAbbreviated = stream.wasTruncated || stream.data.count > displayedData.count
        return "\(label): \(text)\(wasAbbreviated ? " [truncated]" : "")"
    }
}

private final class DiskBoundedStreamCollector: @unchecked Sendable {
    private static let readSize = 64 * 1024
    private static let queue = DispatchQueue(
        label: "dev.macvm.disk-process-stream-reader",
        qos: .utility,
        attributes: .concurrent
    )

    private let handle: FileHandle
    private let maximumRetainedSize: Int
    private var data = Data()
    private var wasTruncated = false
    private(set) var readError: Error?

    init(handle: FileHandle, maximumRetainedSize: Int) {
        self.handle = handle
        self.maximumRetainedSize = maximumRetainedSize
    }

    var capturedStream: DiskProcessRunner.CapturedStream {
        DiskProcessRunner.CapturedStream(
            data: data,
            wasTruncated: wasTruncated
        )
    }

    func start(in group: DispatchGroup) {
        group.enter()
        Self.queue.async { [self] in
            defer {
                try? handle.close()
                group.leave()
            }

            do {
                while let chunk = try handle.read(upToCount: Self.readSize),
                      !chunk.isEmpty {
                    append(chunk)
                }
            } catch {
                readError = error
            }
        }
    }

    private func append(_ chunk: Data) {
        let availableSize = max(0, maximumRetainedSize - data.count)
        let retainedSize = min(availableSize, chunk.count)
        if retainedSize > 0 {
            data.append(chunk.prefix(retainedSize))
        }
        if retainedSize < chunk.count {
            wasTruncated = true
        }
    }
}
