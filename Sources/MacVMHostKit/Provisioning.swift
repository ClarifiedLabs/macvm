import CryptoKit
import Foundation

public enum ProvisioningInputKind: String, Codable, Sendable {
    case string
    case boolean
    case choice
    case secret
}

public enum ProvisioningInputDefault: Codable, Equatable, Sendable {
    case string(String)
    case boolean(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        }
    }

    public var stringValue: String {
        switch self {
        case .string(let value): value
        case .boolean(let value): value ? "true" : "false"
        }
    }
}

public struct ProvisioningInputDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var help: String?
    public var type: ProvisioningInputKind
    public var required: Bool
    public var defaultValue: ProvisioningInputDefault?
    public var choices: [String]?

    enum CodingKeys: String, CodingKey {
        case id, label, help, type, required, choices
        case defaultValue = "default"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        help = try container.decodeIfPresent(String.self, forKey: .help)
        type = try container.decode(ProvisioningInputKind.self, forKey: .type)
        required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
        defaultValue = try container.decodeIfPresent(ProvisioningInputDefault.self, forKey: .defaultValue)
        choices = try container.decodeIfPresent([String].self, forKey: .choices)
    }

    public init(
        id: String,
        label: String,
        help: String? = nil,
        type: ProvisioningInputKind,
        required: Bool = false,
        defaultValue: ProvisioningInputDefault? = nil,
        choices: [String]? = nil
    ) {
        self.id = id
        self.label = label
        self.help = help
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.choices = choices
    }
}

public struct ProvisioningProfileManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var description: String
    public var category: String
    public var version: String
    public var playbook: String
    public var dependencies: [String]
    public var hidden: Bool
    public var requirements: [String]
    public var inputs: [ProvisioningInputDefinition]

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        description: String,
        category: String,
        version: String,
        playbook: String = "playbook.yml",
        dependencies: [String] = [],
        hidden: Bool = false,
        requirements: [String] = [],
        inputs: [ProvisioningInputDefinition] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.version = version
        self.playbook = playbook
        self.dependencies = dependencies
        self.hidden = hidden
        self.requirements = requirements
        self.inputs = inputs
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, description, category, version, playbook
        case dependencies, hidden, requirements, inputs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decode(String.self, forKey: .category)
        version = try container.decode(String.self, forKey: .version)
        playbook = try container.decodeIfPresent(String.self, forKey: .playbook) ?? "playbook.yml"
        dependencies = try container.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        requirements = try container.decodeIfPresent([String].self, forKey: .requirements) ?? []
        inputs = try container.decodeIfPresent([ProvisioningInputDefinition].self, forKey: .inputs) ?? []
    }
}

public enum ProvisioningProfileSource: Equatable, Sendable {
    case bundled
    case applicationSupport
    case xdg
    case vmRoot
    case vmBundle

    public var label: String {
        switch self {
        case .bundled: "Bundled"
        case .applicationSupport: "Application Support"
        case .xdg: "~/.config"
        case .vmRoot: "VM root"
        case .vmBundle: "VM bundle"
        }
    }
}

public struct ProvisioningProfile: Identifiable, Equatable, Sendable {
    public let manifest: ProvisioningProfileManifest
    public let directoryURL: URL
    public let source: ProvisioningProfileSource
    public let definitionDigest: String

    public var id: String { manifest.id }
    public var playbookURL: URL { directoryURL.appendingPathComponent(manifest.playbook) }
}

public struct ProvisioningCatalogDiagnostic: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
        self.id = "\(path):\(message)"
    }
}

public struct ProvisioningCatalog: Sendable {
    public let profiles: [ProvisioningProfile]
    public let diagnostics: [ProvisioningCatalogDiagnostic]

    public init(profiles: [ProvisioningProfile], diagnostics: [ProvisioningCatalogDiagnostic]) {
        self.profiles = profiles
        self.diagnostics = diagnostics
    }

    public func profile(id: String) -> ProvisioningProfile? {
        profiles.first { $0.id == id }
    }

    public func resolve(_ selectedIDs: [String]) throws -> [ProvisioningProfile] {
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var visiting = Set<String>()
        var visited = Set<String>()
        var resolved: [ProvisioningProfile] = []

        func visit(_ id: String) throws {
            guard let profile = byID[id] else {
                throw MacVMError.message("Unknown provisioning profile '\(id)'. Run 'macvm profiles list' to see available profiles.")
            }
            guard !visiting.contains(id) else {
                throw MacVMError.message("Provisioning profile dependency cycle includes '\(id)'.")
            }
            guard !visited.contains(id) else { return }
            visiting.insert(id)
            for dependency in profile.manifest.dependencies {
                try visit(dependency)
            }
            visiting.remove(id)
            visited.insert(id)
            resolved.append(profile)
        }

        for id in selectedIDs {
            try visit(id)
        }
        return resolved
    }

    public func validate(_ selection: ProvisioningSelection) throws -> [ProvisioningProfile] {
        let resolved = try resolve(selection.profileIDs)
        let resolvedIDs = Set(resolved.map(\.id))
        if let unknownProfile = selection.inputs.keys.first(where: { !resolvedIDs.contains($0) }) {
            throw MacVMError.message("Inputs were supplied for unselected profile '\(unknownProfile)'.")
        }
        for profile in resolved {
            let provided = selection.inputs[profile.id] ?? [:]
            let definitions = Dictionary(uniqueKeysWithValues: profile.manifest.inputs.map { ($0.id, $0) })
            if let unknown = provided.keys.first(where: { definitions[$0] == nil }) {
                throw MacVMError.message("Unknown input '\(profile.id).\(unknown)'.")
            }
            for definition in profile.manifest.inputs {
                let value = provided[definition.id]
                if definition.required && definition.defaultValue == nil && (value?.isEmpty ?? true) {
                    throw MacVMError.message("Missing required input '\(profile.id).\(definition.id)'.")
                }
                if let value, definition.type == .choice, definition.choices?.contains(value) != true {
                    throw MacVMError.message("Invalid choice for '\(profile.id).\(definition.id)'.")
                }
                if let value, definition.type == .boolean,
                   !["true", "false", "yes", "no", "1", "0"].contains(value.lowercased()) {
                    throw MacVMError.message("Input '\(profile.id).\(definition.id)' must be true or false.")
                }
                if let value, definition.type == .secret,
                   !value.hasPrefix("env:"), !value.hasPrefix("file:"),
                   ProcessInfo.processInfo.environment["MACVM_MANAGER_PROCESS"] != "1" {
                    throw MacVMError.message("Secret input '\(profile.id).\(definition.id)' must use env:NAME or file:/path.")
                }
            }
        }
        return resolved
    }

    public static func load(rootDirectory: URL, vmBundleURL: URL? = nil) -> ProvisioningCatalog {
        let fileManager = FileManager.default
        var roots: [(URL, ProvisioningProfileSource)] = []
        if let bundled = Bundle.module.url(
            forResource: "Profiles",
            withExtension: nil,
            subdirectory: "Resources/Provisioning"
        ) {
            roots.append((bundled, .bundled))
        }
        if let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append((support.appendingPathComponent("macvm/Profiles", isDirectory: true), .applicationSupport))
        }
        roots.append((
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(".config/macvm/profiles", isDirectory: true),
            .xdg
        ))
        roots.append((rootDirectory.appendingPathComponent(".profiles", isDirectory: true), .vmRoot))
        if let vmBundleURL {
            roots.append((vmBundleURL.appendingPathComponent("Setup/Profiles", isDirectory: true), .vmBundle))
        }

        var seenRoots = Set<String>()
        var loaded: [ProvisioningProfile] = []
        var diagnostics: [ProvisioningCatalogDiagnostic] = []
        let decoder = JSONDecoder()

        for (root, source) in roots {
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenRoots.insert(canonical).inserted,
                  fileManager.fileExists(atPath: root.path),
                  let children = try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for directory in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
                    guard values.isDirectory == true else { continue }
                    let manifestURL = directory.appendingPathComponent("profile.json")
                    guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
                    let manifest = try decoder.decode(
                        ProvisioningProfileManifest.self,
                        from: Data(contentsOf: manifestURL)
                    )
                    try validate(manifest, directory: directory)
                    loaded.append(ProvisioningProfile(
                        manifest: manifest,
                        directoryURL: directory,
                        source: source,
                        definitionDigest: try digest(directory: directory)
                    ))
                } catch {
                    diagnostics.append(.init(path: directory.path, message: error.localizedDescription))
                }
            }
        }

        var duplicates = Set<String>()
        let grouped = Dictionary(grouping: loaded, by: \.id)
        for (id, values) in grouped where values.count > 1 {
            duplicates.insert(id)
            for value in values {
                diagnostics.append(.init(path: value.directoryURL.path, message: "Duplicate provisioning profile ID '\(id)'."))
            }
        }
        let uniqueProfiles = loaded
            .filter { !duplicates.contains($0.id) }
            .sorted {
                if $0.manifest.category != $1.manifest.category {
                    return $0.manifest.category.localizedCaseInsensitiveCompare($1.manifest.category) == .orderedAscending
                }
                return $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
            }
        let provisionalCatalog = ProvisioningCatalog(profiles: uniqueProfiles, diagnostics: diagnostics)
        var invalidDependencies = Set<String>()
        for profile in uniqueProfiles {
            do {
                _ = try provisionalCatalog.resolve([profile.id])
            } catch {
                invalidDependencies.insert(profile.id)
                diagnostics.append(.init(path: profile.directoryURL.path, message: error.localizedDescription))
            }
        }
        return ProvisioningCatalog(
            profiles: uniqueProfiles.filter { !invalidDependencies.contains($0.id) },
            diagnostics: diagnostics
        )
    }

    public static func validateProfile(at directory: URL) throws -> ProvisioningProfile {
        let manifestURL = directory.appendingPathComponent("profile.json")
        let manifest = try JSONDecoder().decode(
            ProvisioningProfileManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        try validate(manifest, directory: directory)
        return ProvisioningProfile(
            manifest: manifest,
            directoryURL: directory,
            source: .vmRoot,
            definitionDigest: try digest(directory: directory)
        )
    }

    private static func validate(_ manifest: ProvisioningProfileManifest, directory: URL) throws {
        guard manifest.schemaVersion == 1 else {
            throw MacVMError.message("Unsupported profile schema version \(manifest.schemaVersion).")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard !manifest.id.isEmpty,
              manifest.id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw MacVMError.message("Profile ID must use lowercase letters, digits, and hyphens.")
        }
        guard !manifest.playbook.isEmpty,
              !manifest.playbook.hasPrefix("/"),
              !manifest.playbook.split(separator: "/").contains("..") else {
            throw MacVMError.message("Profile playbook must be a relative path inside the profile directory.")
        }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifest.playbook).path) else {
            throw MacVMError.message("Missing profile playbook '\(manifest.playbook)'.")
        }
        guard Set(manifest.inputs.map(\.id)).count == manifest.inputs.count else {
            throw MacVMError.message("Profile input IDs must be unique.")
        }
        for input in manifest.inputs {
            if input.type == .secret && input.defaultValue != nil {
                throw MacVMError.message("Secret input '\(input.id)' cannot have a default.")
            }
            if input.type == .choice {
                guard let choices = input.choices, !choices.isEmpty else {
                    throw MacVMError.message("Choice input '\(input.id)' must declare choices.")
                }
                if let value = input.defaultValue?.stringValue, !choices.contains(value) {
                    throw MacVMError.message("Default for '\(input.id)' is not one of its choices.")
                }
            }
        }
    }

    private static func digest(directory: URL) throws -> String {
        let fileManager = FileManager.default
        let files = try fileManager.subpathsOfDirectory(atPath: directory.path).sorted()
        var hasher = SHA256()
        for relativePath in files {
            let url = directory.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: try Data(contentsOf: url))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ProvisioningRunStatus: String, Codable, Sendable {
    case succeeded
    case failed
}

public struct ProvisioningProfileRunRecord: Codable, Equatable, Sendable {
    public var profileID: String
    public var source: String
    public var version: String
    public var definitionDigest: String
    public var status: ProvisioningRunStatus
    public var startedAt: Date
    public var finishedAt: Date
    public var logPath: String
    public var error: String?
}

public struct ProvisioningState: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var profiles: [String: ProvisioningProfileRunRecord] = [:]

    public init(profiles: [String: ProvisioningProfileRunRecord] = [:]) {
        self.profiles = profiles
    }
}

public struct ProvisioningSelection: Equatable, Sendable {
    public var profileIDs: [String]
    public var inputs: [String: [String: String]]

    public init(profileIDs: [String] = [], inputs: [String: [String: String]] = [:]) {
        self.profileIDs = profileIDs
        self.inputs = inputs
    }
}

struct AnsibleProvisioner {
    let vm: ManagedVM
    let host: String
    let user: String
    let identityFile: URL
    let profiles: [ProvisioningProfile]
    let inputs: [String: [String: String]]
    let executableURL: URL
    let progress: VMOperationHandler?

    static func findExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        if let override = environment["MACVM_ANSIBLE_PLAYBOOK"], fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let pathDirectories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in candidates {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("ansible-playbook").path
            if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    func run() throws {
        let bundle = VMBundle(url: vm.bundleURL)
        try FileManager.default.createDirectory(at: bundle.provisioningLogsDirectoryURL, withIntermediateDirectories: true)
        var state = bundle.readProvisioningState() ?? ProvisioningState()

        for profile in profiles {
            let startedAt = Date()
            progress?(.status("Provisioning: \(profile.manifest.name)"))
            let stamp = Self.timestamp(startedAt)
            let logName = "\(stamp)-\(profile.id).log"
            let logURL = bundle.provisioningLogsDirectoryURL.appendingPathComponent(logName)
            do {
                try run(profile, logURL: logURL)
                state.profiles[profile.id] = record(
                    profile: profile,
                    status: .succeeded,
                    startedAt: startedAt,
                    logName: logName,
                    error: nil
                )
                try bundle.writeProvisioningState(state)
            } catch {
                state.profiles[profile.id] = record(
                    profile: profile,
                    status: .failed,
                    startedAt: startedAt,
                    logName: logName,
                    error: error.localizedDescription
                )
                try? bundle.writeProvisioningState(state)
                throw MacVMError.message("Provisioning profile '\(profile.id)' failed. Log: \(logURL.path)\n\(error.localizedDescription)")
            }
        }
    }

    private func run(_ profile: ProvisioningProfile, logURL: URL) throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("macvm-ansible-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let inventoryURL = temporary.appendingPathComponent("inventory.ini")
        let inventory = AnsibleInventory.render(name: vm.metadata.name, host: host, user: user, identityFile: identityFile)
        try ("[macvm]\n\(inventory)\n").write(to: inventoryURL, atomically: true, encoding: .utf8)

        let variablesURL = temporary.appendingPathComponent("vars.json")
        let resolvedInputs = try resolveInputs(for: profile)
        let variables: [String: Any] = [
            "macvm_context": [
                "vm_name": vm.metadata.name,
                "guest_user": user,
                "architecture": "arm64",
                "bundle_path": vm.bundleURL.path,
                "profile_id": profile.id,
                "profile_version": profile.manifest.version,
                "xcode_configured": profile.manifest.requirements.contains("xcode"),
            ],
            "macvm_inputs": resolvedInputs,
        ]
        try JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])
            .write(to: variablesURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: variablesURL.path)

        _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = profile.directoryURL
        process.arguments = [
            "-i", inventoryURL.path,
            profile.playbookURL.path,
            "--extra-vars", "@\(variablesURL.path)",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "ANSIBLE_NOCOLOR": "1",
            "ANSIBLE_HOST_KEY_CHECKING": "False",
            "ANSIBLE_ROLES_PATH": profile.directoryURL.appendingPathComponent("roles").path,
        ]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MacVMError.message("ansible-playbook exited with status \(process.terminationStatus).")
        }
    }

    private func resolveInputs(for profile: ProvisioningProfile) throws -> [String: Any] {
        let provided = inputs[profile.id] ?? [:]
        var result: [String: Any] = [:]
        for definition in profile.manifest.inputs {
            if let value = provided[definition.id] {
                switch definition.type {
                case .boolean:
                    guard let boolean = Self.parseBoolean(value) else {
                        throw MacVMError.message("Input '\(profile.id).\(definition.id)' must be true or false.")
                    }
                    result[definition.id] = boolean
                case .choice:
                    guard definition.choices?.contains(value) == true else {
                        throw MacVMError.message("Invalid choice for '\(profile.id).\(definition.id)'.")
                    }
                    result[definition.id] = value
                case .secret:
                    result[definition.id] = try Self.resolveSecret(value)
                case .string:
                    result[definition.id] = value
                }
            } else if let defaultValue = definition.defaultValue {
                switch defaultValue {
                case .boolean(let value): result[definition.id] = value
                case .string(let value): result[definition.id] = value
                }
            } else if definition.required {
                throw MacVMError.message("Missing required input '\(profile.id).\(definition.id)'.")
            }
        }
        let known = Set(profile.manifest.inputs.map(\.id))
        if let unknown = provided.keys.first(where: { !known.contains($0) }) {
            throw MacVMError.message("Unknown input '\(profile.id).\(unknown)'.")
        }
        return result
    }

    private static func resolveSecret(_ reference: String) throws -> String {
        if reference.hasPrefix("env:") {
            let name = String(reference.dropFirst(4))
            guard let value = ProcessInfo.processInfo.environment[name] else {
                throw MacVMError.message("Secret environment variable '\(name)' is not set.")
            }
            return value
        }
        if reference.hasPrefix("file:") {
            let path = NSString(string: String(reference.dropFirst(5))).expandingTildeInPath
            return try String(contentsOfFile: path, encoding: .utf8)
        }
        // Manager-supplied values never appear in a process argument and may be literal.
        if ProcessInfo.processInfo.environment["MACVM_MANAGER_PROCESS"] == "1" { return reference }
        throw MacVMError.message("Secret inputs must use env:NAME or file:/path.")
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "yes", "1": true
        case "false", "no", "0": false
        default: nil
        }
    }

    private func record(
        profile: ProvisioningProfile,
        status: ProvisioningRunStatus,
        startedAt: Date,
        logName: String,
        error: String?
    ) -> ProvisioningProfileRunRecord {
        ProvisioningProfileRunRecord(
            profileID: profile.id,
            source: profile.source.label,
            version: profile.manifest.version,
            definitionDigest: profile.definitionDigest,
            status: status,
            startedAt: startedAt,
            finishedAt: Date(),
            logPath: "Provisioning/\(logName)",
            error: error
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}
