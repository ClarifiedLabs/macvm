import Foundation

public enum DockerExportKind: String, Codable, Equatable, Sendable {
    case directory
    case regularFile
}

public struct DockerExportCapability: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let authorizedKeyMarker = "macvm-export:"

    public var schemaVersion: Int
    public var filesystemID: String
    public var sourcePath: String
    public var kind: DockerExportKind

    public init(
        schemaVersion: Int = currentSchemaVersion,
        filesystemID: String,
        sourcePath: String,
        kind: DockerExportKind
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DockerGuestCoreError("Unsupported Docker export capability version.")
        }
        guard DockerMountBrokerCommand.isValidFilesystemID(filesystemID) else {
            throw DockerGuestCoreError("Invalid Docker export filesystem ID.")
        }
        guard Self.isValidAbsolutePath(sourcePath) else {
            throw DockerGuestCoreError("Invalid Docker export source path.")
        }
        self.schemaVersion = schemaVersion
        self.filesystemID = filesystemID
        self.sourcePath = sourcePath
        self.kind = kind
    }

    public func validate() throws {
        _ = try Self(
            schemaVersion: schemaVersion,
            filesystemID: filesystemID,
            sourcePath: sourcePath,
            kind: kind
        )
    }

    public func authorizedKeyLine(publicKey: String, executablePath: String, configurationPath: String) throws -> String {
        guard Self.isValidAbsolutePath(executablePath), Self.isValidAbsolutePath(configurationPath) else {
            throw DockerGuestCoreError("Invalid Docker export command path.")
        }
        let keyFields = publicKey.split(whereSeparator: { $0.isWhitespace })
        guard keyFields.count >= 2,
              keyFields[0] == "ssh-ed25519",
              Data(base64Encoded: String(keyFields[1])) != nil else {
            throw DockerGuestCoreError("Invalid Docker export public key.")
        }
        let command = "\(shellQuote(executablePath)) --serve-export \(filesystemID) --config \(shellQuote(configurationPath))"
        return "restrict,command=\"\(escapeAuthorizedKeysCommand(command))\" \(keyFields[0]) \(keyFields[1]) \(Self.authorizedKeyMarker)\(filesystemID)"
    }

    public static func replacingAuthorizedKey(
        in contents: String,
        filesystemID: String,
        with line: String?
    ) throws -> String {
        guard DockerMountBrokerCommand.isValidFilesystemID(filesystemID) else {
            throw DockerGuestCoreError("Invalid Docker export filesystem ID.")
        }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        lines.removeAll { exportFilesystemID(in: $0) == filesystemID }
        if let line { lines.append(line) }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func removingLegacyAndUnknownExportKeys(
        from contents: String,
        retaining filesystemIDs: Set<String>
    ) -> String {
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        lines.removeAll { line in
            if line.contains("macvm-filesystem") { return true }
            guard let identifier = exportFilesystemID(in: line) else { return false }
            return !retainingFilesystemID(identifier, in: filesystemIDs)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    public static func containsAuthorizedKey(in contents: String, filesystemID: String) -> Bool {
        guard DockerMountBrokerCommand.isValidFilesystemID(filesystemID) else { return false }
        return contents.split(separator: "\n").contains {
            exportFilesystemID(in: String($0)) == filesystemID
        }
    }

    private static func exportFilesystemID(in line: String) -> String? {
        guard let markerRange = line.range(of: authorizedKeyMarker) else { return nil }
        let identifier = line[markerRange.upperBound...].prefix { !$0.isWhitespace }
        return identifier.isEmpty ? nil : String(identifier)
    }

    private static func retainingFilesystemID(_ value: String, in values: Set<String>) -> Bool {
        values.contains(value)
    }

    private static func isValidAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value.utf8.count <= 4_096
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeAuthorizedKeysCommand(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum DockerExportInstallTransaction {
    public static func perform(
        installDescriptor: () throws -> Void,
        installAuthorization: () throws -> Void,
        restoreAuthorization: () throws -> Void,
        restoreDescriptor: () throws -> Void
    ) throws {
        do {
            try installDescriptor()
            try installAuthorization()
        } catch {
            let installationError = error
            var rollbackErrors: [String] = []
            do {
                try restoreAuthorization()
            } catch {
                rollbackErrors.append("restore authorization: \(error.localizedDescription)")
            }
            do {
                try restoreDescriptor()
            } catch {
                rollbackErrors.append("restore descriptor: \(error.localizedDescription)")
            }
            guard !rollbackErrors.isEmpty else { throw installationError }
            throw DockerGuestCoreError(
                "Couldn't install Docker export capability (\(installationError.localizedDescription)); "
                    + "rollback also failed: \(rollbackErrors.joined(separator: "; "))"
            )
        }
    }
}

public enum DockerMountBrokerCommand: Equatable, Sendable {
    case exportKey(filesystemID: String)
    case mountExport(filesystemID: String, remoteUser: String)
    case unmount(filesystemID: String)
    case removeExport(filesystemID: String)
    case prepareSocket(filesystemID: String)
    case waitSocket(filesystemID: String)
    case removeSocket(filesystemID: String)
    case resetPorts
    case publishPort(protocolName: String, port: Int)
    case unpublishPort(protocolName: String, port: Int)

    public var rendered: String {
        switch self {
        case .exportKey(let identifier): return "export-key \(identifier)"
        case .mountExport(let identifier, let user): return "mount-export \(identifier) \(user)"
        case .unmount(let identifier): return "unmount \(identifier)"
        case .removeExport(let identifier): return "remove-export \(identifier)"
        case .prepareSocket(let identifier): return "prepare-socket \(identifier)"
        case .waitSocket(let identifier): return "wait-socket \(identifier)"
        case .removeSocket(let identifier): return "remove-socket \(identifier)"
        case .resetPorts: return "reset-ports"
        case .publishPort(let protocolName, let port): return "publish-port \(protocolName) \(port)"
        case .unpublishPort(let protocolName, let port): return "unpublish-port \(protocolName) \(port)"
        }
    }

    public init(parsing value: String) throws {
        guard value.utf8.count <= 256,
              !value.contains("\0"),
              !value.contains("\n"),
              !value.contains("\r") else {
            throw DockerGuestCoreError("Invalid Docker mount broker command.")
        }
        let fields = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let action = fields.first else {
            throw DockerGuestCoreError("Invalid Docker mount broker command.")
        }
        switch (action, Array(fields.dropFirst())) {
        case ("export-key", let arguments) where arguments.count == 1:
            self = .exportKey(filesystemID: try Self.validatedFilesystemID(arguments[0]))
        case ("mount-export", let arguments) where arguments.count == 2:
            self = .mountExport(
                filesystemID: try Self.validatedFilesystemID(arguments[0]),
                remoteUser: try Self.validatedRemoteUser(arguments[1])
            )
        case ("unmount", let arguments) where arguments.count == 1:
            self = .unmount(filesystemID: try Self.validatedFilesystemID(arguments[0]))
        case ("remove-export", let arguments) where arguments.count == 1:
            self = .removeExport(filesystemID: try Self.validatedFilesystemID(arguments[0]))
        case ("prepare-socket", let arguments) where arguments.count == 1:
            self = .prepareSocket(filesystemID: try Self.validatedSocketID(arguments[0]))
        case ("wait-socket", let arguments) where arguments.count == 1:
            self = .waitSocket(filesystemID: try Self.validatedSocketID(arguments[0]))
        case ("remove-socket", let arguments) where arguments.count == 1:
            self = .removeSocket(filesystemID: try Self.validatedSocketID(arguments[0]))
        case ("reset-ports", let arguments) where arguments.isEmpty:
            self = .resetPorts
        case ("publish-port", let arguments) where arguments.count == 2:
            self = .publishPort(
                protocolName: try Self.validatedProtocol(arguments[0]),
                port: try Self.validatedPort(arguments[1])
            )
        case ("unpublish-port", let arguments) where arguments.count == 2:
            self = .unpublishPort(
                protocolName: try Self.validatedProtocol(arguments[0]),
                port: try Self.validatedPort(arguments[1])
            )
        default:
            throw DockerGuestCoreError("Invalid Docker mount broker command.")
        }
    }

    public static func isValidFilesystemID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func validatedFilesystemID(_ value: String) throws -> String {
        guard isValidFilesystemID(value) else { throw DockerGuestCoreError("Invalid Docker filesystem ID.") }
        return value
    }

    private static func validatedSocketID(_ value: String) throws -> String {
        guard value.hasPrefix("socket-"), isValidFilesystemID(value) else {
            throw DockerGuestCoreError("Invalid Docker socket ID.")
        }
        return value
    }

    private static func validatedRemoteUser(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 64, value.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || $0 == 45 || $0 == 46 || $0 == 95
        }) else {
            throw DockerGuestCoreError("Invalid Docker export user.")
        }
        return value
    }

    private static func validatedProtocol(_ value: String) throws -> String {
        guard value == "tcp" || value == "udp" else { throw DockerGuestCoreError("Invalid port protocol.") }
        return value
    }

    private static func validatedPort(_ value: String) throws -> Int {
        guard let port = Int(value), (1...65_535).contains(port), String(port) == value else {
            throw DockerGuestCoreError("Invalid published port.")
        }
        return port
    }
}

public struct DockerGuestCoreError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
