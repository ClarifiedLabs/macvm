import Foundation

public enum RestoreImageSelectionMode: String, CaseIterable, Codable, Sendable {
    case latestSupported
    case localFile
}

/// The macOS release installed from a restore image. The Apple build identifier
/// is retained because Setup Assistant can drift between builds of the same
/// semantic OS version.
public struct MacOSRelease: Codable, Equatable, Sendable {
    public let majorVersion: Int
    public let minorVersion: Int
    public let patchVersion: Int
    public let buildVersion: String

    public init(
        majorVersion: Int,
        minorVersion: Int,
        patchVersion: Int,
        buildVersion: String
    ) {
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.patchVersion = patchVersion
        self.buildVersion = buildVersion
    }

    public init(operatingSystemVersion: OperatingSystemVersion, buildVersion: String) {
        self.init(
            majorVersion: operatingSystemVersion.majorVersion,
            minorVersion: operatingSystemVersion.minorVersion,
            patchVersion: operatingSystemVersion.patchVersion,
            buildVersion: buildVersion
        )
    }

    public var versionDescription: String {
        "\(majorVersion).\(minorVersion).\(patchVersion)"
    }

    public var displayDescription: String {
        "macOS \(versionDescription) (\(buildVersion))"
    }
}

public struct VMCreationDraft: Equatable, Sendable {
    public var name: String
    public var cpuCount: Int
    public var memoryGiB: Int
    public var diskGiB: Int
    public var dockerEnabled: Bool
    public var dockerCPUCount: Int
    public var dockerMemoryGiB: Int
    public var dockerDiskGiB: Int
    public var dockerAMD64Enabled: Bool
    /// Effective guest workspace size in points. The VM uses a 2x Retina
    /// backing framebuffer derived from this value at boot.
    public var displayWidth: Int
    public var displayHeight: Int
    public var restoreMode: RestoreImageSelectionMode
    public var localRestoreImageURL: URL?
    public var createBootstrapShare: Bool
    public var launchOnBoot: Bool

    public init(
        name: String,
        cpuCount: Int,
        memoryGiB: Int,
        diskGiB: Int,
        displayWidth: Int,
        displayHeight: Int,
        restoreMode: RestoreImageSelectionMode,
        localRestoreImageURL: URL? = nil,
        createBootstrapShare: Bool = true,
        launchOnBoot: Bool = false,
        dockerEnabled: Bool = false,
        dockerCPUCount: Int = DockerSidecarSettings.defaultCPUCount,
        dockerMemoryGiB: Int = DockerSidecarSettings.defaultMemoryGiB,
        dockerDiskGiB: Int = DockerSidecarSettings.defaultDiskGiB,
        dockerAMD64Enabled: Bool = true
    ) {
        self.name = name
        self.cpuCount = cpuCount
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.restoreMode = restoreMode
        self.localRestoreImageURL = localRestoreImageURL
        self.createBootstrapShare = createBootstrapShare
        self.launchOnBoot = launchOnBoot
        self.dockerEnabled = dockerEnabled
        self.dockerCPUCount = dockerCPUCount
        self.dockerMemoryGiB = dockerMemoryGiB
        self.dockerDiskGiB = dockerDiskGiB
        self.dockerAMD64Enabled = dockerAMD64Enabled
    }

    public var displayDescription: String {
        "\(displayWidth)x\(displayHeight)"
    }

    public var displayPixelWidth: Int {
        VMDisplayMetrics.pixelWidth(forEffectiveWidth: displayWidth)
    }

    public var displayPixelHeight: Int {
        VMDisplayMetrics.pixelHeight(forEffectiveHeight: displayHeight)
    }

    public var displayPixelDescription: String {
        "\(displayPixelWidth)x\(displayPixelHeight)"
    }
}

public enum DockerGuestProvisioningState: String, Codable, Equatable, Sendable {
    case pending
    case provisioning
    case ready
    case failed
}

public struct DockerSidecarSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentGuestProvisioningVersion = 12
    public static let defaultCPUCount = 2
    public static let defaultMemoryGiB = 4
    public static let defaultDiskGiB = 64
    public static let defaultMacOSAddress = "192.168.127.1/30"
    public static let defaultLinuxAddress = "192.168.127.2/30"

    public var schemaVersion: Int
    public var enabled: Bool
    public var amd64Enabled: Bool
    public var cpuCount: Int
    public var memorySizeBytes: UInt64
    public var dataDiskSizeBytes: UInt64
    public var macOSAddress: String
    public var linuxAddress: String
    public var macOSMACAddress: String
    public var linuxPrivateMACAddress: String
    public var linuxNATMACAddress: String
    public var guestProvisioningState: DockerGuestProvisioningState
    public var guestProvisioningVersion: Int
    public var imageVersion: String?
    public var mobyVersion: String?

    public init(
        schemaVersion: Int = currentSchemaVersion,
        enabled: Bool = true,
        amd64Enabled: Bool = true,
        cpuCount: Int = defaultCPUCount,
        memorySizeBytes: UInt64 = UInt64(defaultMemoryGiB) * 1024 * 1024 * 1024,
        dataDiskSizeBytes: UInt64 = UInt64(defaultDiskGiB) * 1024 * 1024 * 1024,
        macOSAddress: String = defaultMacOSAddress,
        linuxAddress: String = defaultLinuxAddress,
        macOSMACAddress: String,
        linuxPrivateMACAddress: String,
        linuxNATMACAddress: String,
        guestProvisioningState: DockerGuestProvisioningState = .pending,
        guestProvisioningVersion: Int = 0,
        imageVersion: String? = nil,
        mobyVersion: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.amd64Enabled = amd64Enabled
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.dataDiskSizeBytes = dataDiskSizeBytes
        self.macOSAddress = macOSAddress
        self.linuxAddress = linuxAddress
        self.macOSMACAddress = macOSMACAddress
        self.linuxPrivateMACAddress = linuxPrivateMACAddress
        self.linuxNATMACAddress = linuxNATMACAddress
        self.guestProvisioningState = guestProvisioningState
        self.guestProvisioningVersion = guestProvisioningVersion
        self.imageVersion = imageVersion
        self.mobyVersion = mobyVersion
    }
}

public struct VMMetadata: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var cpuCount: Int
    public var memorySizeBytes: UInt64
    public var diskSizeBytes: UInt64
    /// Effective guest workspace size in points. The VM uses a 2x Retina
    /// backing framebuffer derived from this value at boot.
    public var displayWidth: Int
    public var displayHeight: Int
    public var bootstrapShareEnabled: Bool
    public var installedRestoreImageName: String?
    /// Release identity recorded from the restore image at installation time.
    /// Bundles created before this field was introduced remain manually usable,
    /// but require an explicit custom flow for automated setup.
    public var installedMacOSRelease: MacOSRelease?
    /// Stable MAC assigned at creation so host-side DHCP/ARP lookups can find
    /// the guest reliably. Optional so bundles created before this field decode
    /// cleanly; `VMBundle.ensureNetworkIdentity` backfills a value on demand.
    public var macAddress: String?
    /// Account created by `macvm setup`; used as the default SSH/Ansible user.
    public var setupUsername: String?
    public var setupFullName: String?
    public var setupCompletedAt: Date?
    /// Settings for the hidden Linux sidecar associated with this macOS VM.
    /// Nil for bundles created before Docker sidecar support and for VMs where
    /// Docker has never been enabled.
    public var dockerSidecar: DockerSidecarSettings?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        cpuCount: Int,
        memorySizeBytes: UInt64,
        diskSizeBytes: UInt64,
        displayWidth: Int,
        displayHeight: Int,
        bootstrapShareEnabled: Bool,
        installedRestoreImageName: String? = nil,
        installedMacOSRelease: MacOSRelease? = nil,
        macAddress: String? = nil,
        setupUsername: String? = nil,
        setupFullName: String? = nil,
        setupCompletedAt: Date? = nil,
        dockerSidecar: DockerSidecarSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.cpuCount = cpuCount
        self.memorySizeBytes = memorySizeBytes
        self.diskSizeBytes = diskSizeBytes
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.bootstrapShareEnabled = bootstrapShareEnabled
        self.installedRestoreImageName = installedRestoreImageName
        self.installedMacOSRelease = installedMacOSRelease
        self.macAddress = macAddress
        self.setupUsername = setupUsername
        self.setupFullName = setupFullName
        self.setupCompletedAt = setupCompletedAt
        self.dockerSidecar = dockerSidecar
    }

    public var memoryDescription: String {
        VMText.gibLabel(for: memorySizeBytes)
    }

    public var diskDescription: String {
        VMText.gibLabel(for: diskSizeBytes)
    }

    public var displayDescription: String {
        "\(displayWidth)x\(displayHeight)"
    }

    public var displayPixelWidth: Int {
        VMDisplayMetrics.pixelWidth(forEffectiveWidth: displayWidth)
    }

    public var displayPixelHeight: Int {
        VMDisplayMetrics.pixelHeight(forEffectiveHeight: displayHeight)
    }

    public var displayPixelDescription: String {
        "\(displayPixelWidth)x\(displayPixelHeight)"
    }
}

public enum VMDisplayMetrics {
    public static let retinaScale = 2
    public static let retinaPixelsPerInch = 226

    public static func pixelWidth(forEffectiveWidth width: Int) -> Int {
        width * retinaScale
    }

    public static func pixelHeight(forEffectiveHeight height: Int) -> Int {
        height * retinaScale
    }

    public static func effectiveSize(fromPixelWidth width: Int, height: Int) throws -> (width: Int, height: Int) {
        guard width > 0,
              height > 0,
              width.isMultiple(of: retinaScale),
              height.isMultiple(of: retinaScale) else {
            throw MacVMError.invalidDisplaySize("\(width)x\(height)")
        }
        return (width / retinaScale, height / retinaScale)
    }
}

public enum SetupCompletionDisposition: Equatable, Sendable {
    case stopped
    case restartInApp
}

public struct SetupOptions: Sendable {
    public var username: String
    public var password: String
    public var fullName: String
    /// An additional host public key to authorize (beyond the per-VM key).
    public var authorizedKeyPath: URL?
    public var autoLogin: Bool
    public var perPaneTimeout: TimeInterval
    public var requestedVNCPort: UInt
    /// Power the VM off after provisioning instead of restarting it under MacVM.app ownership.
    public var shutdownAfter: Bool

    public var completionDisposition: SetupCompletionDisposition {
        shutdownAfter ? .stopped : .restartInApp
    }
    /// Optional path to a custom setup step-list (JSON) overriding the built-in flow.
    public var scriptOverride: URL?
    /// Optional host-side Xcode .xip to stage and install during setup.
    public var xcodeXIPURL: URL?
    /// Install Homebrew as a first-class setup phase after SSH becomes ready.
    public var installHomebrew: Bool
    /// Composable Ansible profiles to apply after SSH becomes ready.
    public var provisioningSelection: ProvisioningSelection

    public init(
        username: String = "admin",
        password: String = "admin",
        fullName: String = "Administrator",
        authorizedKeyPath: URL? = nil,
        autoLogin: Bool = true,
        perPaneTimeout: TimeInterval = 120,
        requestedVNCPort: UInt = 0,
        shutdownAfter: Bool = false,
        scriptOverride: URL? = nil,
        xcodeXIPURL: URL? = nil,
        installHomebrew: Bool = true,
        provisioningSelection: ProvisioningSelection = ProvisioningSelection()
    ) {
        self.username = username
        self.password = password
        self.fullName = fullName
        self.authorizedKeyPath = authorizedKeyPath
        self.autoLogin = autoLogin
        self.perPaneTimeout = perPaneTimeout
        self.requestedVNCPort = requestedVNCPort
        self.shutdownAfter = shutdownAfter
        self.scriptOverride = scriptOverride
        self.xcodeXIPURL = xcodeXIPURL
        self.installHomebrew = installHomebrew
        self.provisioningSelection = provisioningSelection
    }
}

public struct SetupResult: Sendable {
    public let username: String
    public let ipAddress: String?
    public let sshReady: Bool
    public let inventoryLine: String?

    public init(username: String, ipAddress: String?, sshReady: Bool, inventoryLine: String?) {
        self.username = username
        self.ipAddress = ipAddress
        self.sshReady = sshReady
        self.inventoryLine = inventoryLine
    }
}

public struct ManagedVM: Identifiable, Equatable, Sendable {
    public let bundleURL: URL
    public let metadata: VMMetadata

    public init(bundleURL: URL, metadata: VMMetadata) {
        self.bundleURL = bundleURL
        self.metadata = metadata
    }

    public var id: UUID {
        metadata.id
    }
}

public struct VMRemovalTarget: Equatable, Sendable {
    public let bundleURL: URL
    public let metadata: VMMetadata?

    public init(bundleURL: URL, metadata: VMMetadata? = nil) {
        self.bundleURL = bundleURL
        self.metadata = metadata
    }

    public var name: String {
        metadata?.name ?? bundleURL.deletingPathExtension().lastPathComponent
    }
}

/// Structured notification that the setup pipeline entered a new phase, so UIs
/// can render a step list instead of parsing status strings.
public struct SetupStepProgress: Equatable, Sendable {
    public let phaseIndex: Int
    public let phaseCount: Int
    public let title: String
    public let anchor: String

    public init(phaseIndex: Int, phaseCount: Int, title: String, anchor: String) {
        self.phaseIndex = phaseIndex
        self.phaseCount = phaseCount
        self.title = title
        self.anchor = anchor
    }
}

public struct SetupAccessProgress: Codable, Equatable, Sendable {
    public let ipAddress: String
    public let sshReady: Bool

    public init(ipAddress: String, sshReady: Bool) {
        self.ipAddress = ipAddress
        self.sshReady = sshReady
    }
}

public struct SetupLogArtifact: Codable, Equatable, Sendable {
    public let label: String
    public let bundleRelativePath: String

    public init(label: String, bundleRelativePath: String) {
        self.label = label
        self.bundleRelativePath = bundleRelativePath
    }
}

public struct SetupLogSnapshot: Equatable, Sendable {
    public let url: URL
    public let tail: String?
    public let modifiedAt: Date?

    public init(url: URL, tail: String?, modifiedAt: Date?) {
        self.url = url
        self.tail = tail
        self.modifiedAt = modifiedAt
    }
}

public enum VMOperationEvent: Sendable {
    case status(String)
    case progress(label: String, fractionComplete: Double)
    case setupStep(SetupStepProgress)
    case setupAccess(SetupAccessProgress)
    case setupLog(SetupLogArtifact)
}

public typealias VMOperationHandler = @Sendable (VMOperationEvent) -> Void

public enum VMText {
    public static func gibLabel(for bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(oneGiB)
        if gib.rounded() == gib {
            return "\(Int(gib)) GiB"
        }
        return String(format: "%.1f GiB", gib)
    }

    public static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

let oneGiB: UInt64 = 1024 * 1024 * 1024

func sanitizedBundleName(_ rawName: String) -> String {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let pieces = trimmed.unicodeScalars.map { scalar -> String in
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" || scalar == "." {
            return String(scalar)
        }

        if CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return "-"
        }

        return ""
    }

    let collapsed = pieces.joined()
        .replacingOccurrences(of: "--", with: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: "-."))

    return collapsed.isEmpty ? "vm" : collapsed
}

public func parseDisplaySize(_ rawValue: String) throws -> (width: Int, height: Int) {
    let parts = rawValue.lowercased().split(separator: "x", omittingEmptySubsequences: true)
    guard parts.count == 2,
          let width = Int(parts[0]),
          let height = Int(parts[1]),
          width > 0,
          height > 0 else {
        throw MacVMError.invalidDisplaySize(rawValue)
    }

    return (width, height)
}

public func parseDisplayPixelSizeAsEffectiveSize(_ rawValue: String) throws -> (width: Int, height: Int) {
    let pixels = try parseDisplaySize(rawValue)
    do {
        return try VMDisplayMetrics.effectiveSize(fromPixelWidth: pixels.width, height: pixels.height)
    } catch {
        throw MacVMError.invalidDisplaySize(rawValue)
    }
}
