import CoreGraphics
import CoreText
import Darwin
import Foundation
import Testing
import Virtualization
@testable import MacVMHostKit

@Test
func sanitizedBundleNameDropsInvalidCharacters() {
    #expect(sanitizedBundleName(" dev vm / 01 ") == "dev-vm-01")
    #expect(sanitizedBundleName("...") == "vm")
}

@Test
func displayParserAcceptsWidthByHeight() throws {
    let size = try parseDisplaySize("2560x1440")
    #expect(size.width == 2560)
    #expect(size.height == 1440)

    let effectiveSize = try parseDisplayPixelSizeAsEffectiveSize("2560x1440")
    #expect(effectiveSize.width == 1280)
    #expect(effectiveSize.height == 720)
    #expect(throws: MacVMError.self) {
        _ = try parseDisplayPixelSizeAsEffectiveSize("2559x1440")
    }
}

@Test
func versionDisplayUsesBundleMarketingVersionAndBuild() throws {
    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("bundle")
    let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let infoURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let info = [
        "CFBundleIdentifier": "dev.macvm.macvm.version-test",
        "CFBundleName": "VersionTest",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": "2.3.4",
        "CFBundleVersion": "56",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: infoURL, options: .atomic)

    let bundle = try #require(Bundle(url: bundleURL))
    #expect(MacVMVersion.shortVersion(bundle: bundle) == "2.3.4")
    #expect(MacVMVersion.displayVersion(bundle: bundle) == "Version 2.3.4 (56)")
}

@Test
func metadataRoundTripsThroughJSON() throws {
    let metadata = VMMetadata(
        name: "dev-01",
        cpuCount: 6,
        memorySizeBytes: 12 * oneGiB,
        diskSizeBytes: 200 * oneGiB,
        displayWidth: 1920,
        displayHeight: 1200,
        bootstrapShareEnabled: true,
        installedRestoreImageName: "UniversalMac_26.3_Restore.ipsw"
    )

    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("macvm")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(metadata)

    let decoded = try bundle.readMetadata()
    #expect(decoded.id == metadata.id)
    #expect(decoded.name == metadata.name)
    #expect(decoded.cpuCount == metadata.cpuCount)
    #expect(decoded.memorySizeBytes == metadata.memorySizeBytes)
    #expect(decoded.diskSizeBytes == metadata.diskSizeBytes)
    #expect(decoded.displayWidth == metadata.displayWidth)
    #expect(decoded.displayHeight == metadata.displayHeight)
    #expect(decoded.displayPixelDescription == "3840x2400")
    #expect(decoded.bootstrapShareEnabled == metadata.bootstrapShareEnabled)
    #expect(decoded.installedRestoreImageName == metadata.installedRestoreImageName)
    #expect(abs(decoded.createdAt.timeIntervalSince(metadata.createdAt)) < 1)
}

@Test
func bootstrapScriptIncludesXcodeAutomationHooks() throws {
    let script = try BootstrapAssets.loadBootstrapScript()
    #expect(script.contains("--install-xcode"))
    #expect(script.contains("xcodebuild -runFirstLaunch"))
    #expect(script.contains("xcodebuild -downloadPlatform iOS"))
    #expect(script.contains("Xcode*.xip"))
    #expect(!script.contains("\"$TRANSFERS_DIR\"/Xcode*.app"))
    #expect(!script.contains("Path to Xcode.app"))
    #expect(!script.contains("mkdir -p \"$HOME/Developer\""))
    #expect(!script.contains("~/Developer"))
}

@Test
func fileStagerCopiesWithoutChangingSource() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = root.appendingPathComponent("Source.xip")
    let destination = root
        .appendingPathComponent("Shared", isDirectory: true)
        .appendingPathComponent("Transfers", isDirectory: true)
        .appendingPathComponent("Source.xip")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = Data("xcode-archive".utf8)
    try payload.write(to: source)
    try MacVMFileStager.copyCloneFirst(from: source, to: destination)

    #expect(try Data(contentsOf: source) == payload)
    #expect(try Data(contentsOf: destination) == payload)
}

@Test
func defaultDraftUsesExpectedSizingDefaults() {
    let service = MacVMService()
    let draft = service.defaultDraft(named: "defaults")
    let expectedCPUCount = MacVMService.recommendedCPUCount(
        hostCPUCount: ProcessInfo.processInfo.processorCount,
        minimumAllowedCPUCount: Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount),
        maximumAllowedCPUCount: Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
    )

    #expect(draft.cpuCount == expectedCPUCount)
    #expect(draft.memoryGiB == 8)
    #expect(draft.diskGiB == 80)
    // Retina default: 1280x720 points = 2560x1440 pixels in the 2x guest.
    #expect(draft.displayWidth == 1280)
    #expect(draft.displayHeight == 720)
    #expect(draft.displayPixelWidth == 2560)
    #expect(draft.displayPixelHeight == 1440)
}

@Test
func recommendedCPUCountUsesHalfTheHostCores() {
    #expect(
        MacVMService.recommendedCPUCount(
            hostCPUCount: 12,
            minimumAllowedCPUCount: 1,
            maximumAllowedCPUCount: 12
        ) == 6
    )
    #expect(
        MacVMService.recommendedCPUCount(
            hostCPUCount: 9,
            minimumAllowedCPUCount: 1,
            maximumAllowedCPUCount: 12
        ) == 4
    )
}

@Test
func recommendedCPUCountRespectsVirtualizationBounds() {
    #expect(
        MacVMService.recommendedCPUCount(
            hostCPUCount: 2,
            minimumAllowedCPUCount: 2,
            maximumAllowedCPUCount: 12
        ) == 2
    )
    #expect(
        MacVMService.recommendedCPUCount(
            hostCPUCount: 32,
            minimumAllowedCPUCount: 1,
            maximumAllowedCPUCount: 6
        ) == 6
    )
}

@Test
func removeVMDeletesResolvedBundle() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let bundleURL = rootURL
        .appendingPathComponent("remove-me", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let metadata = VMMetadata(
        name: "remove-me",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    try VMBundle(url: bundleURL).writeMetadata(metadata)

    let service = MacVMService(rootDirectory: rootURL)
    let removed = try service.removeVM(identifier: "remove-me")

    #expect(removed.name == "remove-me")
    #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
}

@Test
func removeVMDeletesBundleMissingMetadataByBasename() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let bundleURL = rootURL
        .appendingPathComponent("remove-orphan", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

    let service = MacVMService(rootDirectory: rootURL)
    let removed = try service.removeVM(identifier: "remove-orphan")

    #expect(removed.name == "remove-orphan")
    #expect(removed.metadata == nil)
    #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
}

@Test
func removeVMDeletesBundleWithUnreadableSharedTrashDirectory() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let bundleURL = rootURL
        .appendingPathComponent("remove-trash", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    let sharedURL = bundleURL.appendingPathComponent("Shared", isDirectory: true)
    let trashURL = sharedURL.appendingPathComponent(".Trashes", isDirectory: true)

    try FileManager.default.createDirectory(at: trashURL, withIntermediateDirectories: true)
    defer {
        _ = chmod(trashURL.path, 0o700)
    }

    let metadata = VMMetadata(
        name: "remove-trash",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: true
    )
    try VMBundle(url: bundleURL).writeMetadata(metadata)

    // Regression: macOS can create this in the shared directory without owner
    // read permission, which made recursive FileManager deletion fail.
    #expect(chmod(trashURL.path, 0o1311) == 0)

    let service = MacVMService(rootDirectory: rootURL)
    let removed = try service.removeVM(identifier: "remove-trash")

    #expect(removed.name == "remove-trash")
    #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
}

@Test
func listFormatterPrintsFullBundlePath() {
    let bundleURL = URL(fileURLWithPath: "/tmp/macvm-list-test/dev.macvm", isDirectory: true)
    let metadata = VMMetadata(
        name: "dev",
        cpuCount: 4,
        memorySizeBytes: 8 * oneGiB,
        diskSizeBytes: 80 * oneGiB,
        displayWidth: 1920,
        displayHeight: 1080,
        bootstrapShareEnabled: false
    )
    let virtualMachine = ManagedVM(bundleURL: bundleURL, metadata: metadata)

    let lines = VMListFormatter.table(for: [virtualMachine]).split(separator: "\n")

    #expect(lines.first?.contains("BUNDLE PATH") == true)
    #expect(lines.last?.hasSuffix(bundleURL.path) == true)
}

@Test
func metadataRoundTripsNetworkAndSetupFields() throws {
    let metadata = VMMetadata(
        name: "dev-02",
        cpuCount: 4,
        memorySizeBytes: 8 * oneGiB,
        diskSizeBytes: 80 * oneGiB,
        displayWidth: 1920,
        displayHeight: 1080,
        bootstrapShareEnabled: false,
        installedRestoreImageName: nil,
        macAddress: "52:55:55:14:02:36",
        setupUsername: "admin",
        setupFullName: "Managed via macvm",
        setupCompletedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("macvm")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(metadata)

    let decoded = try bundle.readMetadata()
    #expect(decoded.macAddress == "52:55:55:14:02:36")
    #expect(decoded.setupUsername == "admin")
    #expect(decoded.setupFullName == "Managed via macvm")
    #expect(abs((decoded.setupCompletedAt ?? .distantPast).timeIntervalSince1970 - 1_700_000_000) < 1)
}

// Regression: the guest MAC was previously regenerated on every boot and never
// persisted, so DHCP-lease lookups were unstable. Identity must be assigned once
// and stay identical across repeated calls.
@Test
func ensureNetworkIdentityBackfillsAndStaysStable() throws {
    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("macvm")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let bundle = VMBundle(url: bundleURL)
    let metadata = VMMetadata(
        name: "no-mac",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    #expect(metadata.macAddress == nil)

    let first = try bundle.ensureNetworkIdentity(metadata)
    #expect(first.macAddress != nil)
    #expect(MACAddress.octets(first.macAddress ?? "") != nil)

    // Idempotent: a second call returns the same address, and it was persisted.
    let second = try bundle.ensureNetworkIdentity(first)
    #expect(second.macAddress == first.macAddress)
    #expect(try bundle.readMetadata().macAddress == first.macAddress)
}

@Test
func rfbMessageEncodersProduceCorrectBytes() {
    #expect(RFBMessage.keyEvent(keysym: 0xff0d, down: true) == [4, 1, 0, 0, 0x00, 0x00, 0xff, 0x0d])
    #expect(RFBMessage.pointerEvent(buttonMask: 1, x: 0x0102, y: 0x0304) == [5, 1, 0x01, 0x02, 0x03, 0x04])
    #expect(RFBMessage.clientCutText("hello") == [6, 0, 0, 0, 0, 0, 0, 5, 0x68, 0x65, 0x6c, 0x6c, 0x6f])
    #expect(RFBMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 0x0500, height: 0x02d0)
        == [3, 0, 0, 0, 0, 0, 0x05, 0x00, 0x02, 0xd0])
    #expect(RFBMessage.setEncodings([RFB.rawEncoding]) == [2, 0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
    // Raw(0), DesktopSize(-223), Cursor(-239), LastRect(-224) as big-endian Int32.
    #expect(RFBMessage.setEncodings(RFB.clientEncodings) == [
        2, 0, 0x00, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0x21,
        0xff, 0xff, 0xff, 0x11,
        0xff, 0xff, 0xff, 0x20,
    ])
    #expect(RFBMessage.clientInit(shared: true) == [1])
}

@Test
func rfbPixelFormatRoundTrips() {
    let encoded = RFBPixelFormat.bgra32.encoded
    #expect(encoded == [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
    #expect(RFBPixelFormat(bytes: encoded) == RFBPixelFormat.bgra32)
}

@Test
func rfbRectangleHeaderParses() {
    let bytes: [UInt8] = [0, 1, 0, 2, 0, 3, 0, 4, 0, 0, 0, 0]
    let header = RFBRectangleHeader(bytes: bytes)
    #expect(header == RFBRectangleHeader(x: 1, y: 2, width: 3, height: 4, encoding: 0))
    #expect(RFBRectangleHeader(bytes: [0, 1]) == nil)
}

@Test
func framebufferBlitAndEncode() {
    var framebuffer = Framebuffer(width: 2, height: 2)
    // One red pixel (B=0, G=0, R=255, X=0) blitted at (1, 0).
    framebuffer.blit([0, 0, 255, 0], x: 1, y: 0, width: 1, height: 1)
    #expect(framebuffer.pixels[4 * 1 + 2] == 255) // red channel of pixel (1,0)
    #expect(framebuffer.cgImage()?.width == 2)
    #expect(framebuffer.cgImage()?.height == 2)
    #expect(framebuffer.pngData() != nil)
}

@Test
func keysymNamingAndShift() {
    #expect(Keysym.named("return") == 0xff0d)
    #expect(Keysym.named("a") == 0x61)
    #expect(Keysym.named("Z") == 0x5a)
    #expect(Keysym.named("space") == 0x20)
    #expect(Keysym.named("nope") == nil)
    #expect(Keysym.modifier(named: "cmd") == Keysym.command)

    #expect(Keysym.needsShift("A"))
    #expect(!Keysym.needsShift("a"))
    #expect(Keysym.needsShift("!"))
    #expect(!Keysym.needsShift("1"))
}

@Test
func keysymTypingExpandsShiftedCharacters() {
    let strokes = Keysym.keystrokes(forTyping: "aA")
    #expect(strokes == [
        KeyStroke(keysym: 0x61, down: true),
        KeyStroke(keysym: 0x61, down: false),
        KeyStroke(keysym: Keysym.shift, down: true),
        KeyStroke(keysym: 0x41, down: true),
        KeyStroke(keysym: 0x41, down: false),
        KeyStroke(keysym: Keysym.shift, down: false),
    ])
}

@Test
func keysymParsesChords() {
    let chord = Keysym.parseChord("cmd+space")
    #expect(chord?.modifiers == [Keysym.command])
    #expect(chord?.key == Keysym.space)

    let plain = Keysym.parseChord("return")
    #expect(plain?.modifiers.isEmpty == true)
    #expect(plain?.key == 0xff0d)

    #expect(Keysym.parseChord("ctrl+c")?.modifiers == [Keysym.control])
    #expect(Keysym.parseChord("bogus") == nil)
}

@Test
func rfbAuthMirrorsBitsAndMatchesDESVector() {
    #expect(RFBAuth.mirrorBits(0x01) == 0x80)
    #expect(RFBAuth.mirrorBits(0x80) == 0x01)
    #expect(RFBAuth.mirrorBits(0xf0) == 0x0f)
    #expect(RFBAuth.mirrorBits(0xaa) == 0x55)

    // 'p'=0x70 -> 0x0e, 'a'=0x61 -> 0x86, 's'=0x73 -> 0xce
    #expect(RFBAuth.desKey(from: "pass") == [0x0e, 0x86, 0xce, 0xce, 0, 0, 0, 0])

    // FIPS single-DES ECB known-answer vector.
    let key: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]
    let plaintext: [UInt8] = [0x4e, 0x6f, 0x77, 0x20, 0x69, 0x73, 0x20, 0x74]
    let expected: [UInt8] = [0x3f, 0xa4, 0x0e, 0x8a, 0x98, 0x4d, 0x48, 0x15]
    #expect(RFBAuth.desEncryptECB(data: plaintext, key: key) == expected)

    // A 16-byte challenge yields a 16-byte response, deterministically.
    let challenge = [UInt8](repeating: 0x5a, count: 16)
    let response = RFBAuth.response(challenge: challenge, password: "secret")
    #expect(response.count == 16)
    #expect(response == RFBAuth.response(challenge: challenge, password: "secret"))
}

@Test
func setupStepsRoundTripThroughJSON() throws {
    let steps: [SetupStep] = [
        .waitText("Language", timeout: 300),
        .clickText("English", timeout: 60),
        .clickText("^Continue$", whenText: "FileVault", timeout: 30, optional: true),
        .advanceUntilText("Finder|Enter Password", timeout: 120),
        .clickText("Not Now", timeout: 20, optional: true),
        .type("United States"),
        .type("admin", whenText: "Enter Password", timeout: 5, optional: true),
        .keys(["tab", "return"]),
        .keys(["return"], whenText: "Enter Password", timeout: 5, optional: true),
        .delay(2),
        .screenshot("desktop"),
        .wake,
    ]

    let data = try JSONEncoder().encode(steps)
    let decoded = try JSONDecoder().decode([SetupStep].self, from: data)
    #expect(decoded == steps)
}

@Test
func setupFlowLoadsOverrideFromJSON() throws {
    let steps: [SetupStep] = [.waitText("Custom"), .clickText("Go")]
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
    try JSONEncoder().encode(steps).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try SetupFlows.load(from: url) == steps)
}

@Test
func setupFlowAnchorsEarlyOnboardingPanesBeforeAccountCreation() throws {
    let steps = SetupFlows.builtIn(forMacOSMajor: 26, options: SetupOptions())

    let country = try #require(steps.firstIndex { $0.action == .waitText && ($0.text ?? "").contains("Country") })
    let transfer = try #require(steps.firstIndex { $0.action == .waitText && ($0.text ?? "").contains("Transfer Your Data") })
    let languages = try #require(steps.firstIndex { $0.action == .waitText && ($0.text ?? "").contains("Written and Spoken Languages") })
    let account = try #require(steps.firstIndex { $0.action == .waitText && ($0.text ?? "").contains("Create a.*Account") })

    #expect(country < transfer)
    #expect(transfer < languages)
    #expect(languages < account)
    #expect(steps[country].optional != true)
    #expect(steps[transfer].optional != true)
    #expect(steps[languages].optional != true)
}

@Test
func setupPlanExposesPhasesWithAnchors() {
    let plan = SetupFlows.plan(forMacOSMajor: 26, options: SetupOptions())

    #expect(plan.phases.count == 11)
    #expect(plan.phases.map(\.id) == Array(0..<11))
    #expect(plan.phases.map(\.title) == [
        "Boot headless, connect RFB client",
        "Language selection",
        "Country or Region",
        "Transfer Your Data",
        "Create admin account",
        "Handle FileVault prompt",
        "Finish Setup Assistant panes",
        "Log in if required",
        "Reach the desktop",
        "Enable SSH, install per-VM key",
        "Wait for IP and SSH",
    ])
    #expect(plan.phases[5].anchor == #"FileVault → "Not Now""#)
    #expect(plan.phases[6].anchor == #"advanceUntilText "Finder|Enter Password""#)
    #expect(plan.phases[10].anchor == "dhcpd_leases")

    // Pipeline-owned phases carry no step index; OCR phases point into the flow
    // in step order.
    #expect(plan.phases[0].firstStepIndex == nil)
    #expect(plan.phases[9].firstStepIndex == nil)
    #expect(plan.phases[10].firstStepIndex == nil)
    let stepIndexes = plan.phases.compactMap(\.firstStepIndex)
    #expect(stepIndexes.count == 8)
    #expect(stepIndexes == stepIndexes.sorted())
    #expect(stepIndexes.allSatisfy { $0 >= 0 && $0 < plan.steps.count })
}

@Test
func setupPhasesForCustomFlowLeaveUnmatchedMarkersWithoutStepIndexes() {
    let phases = SetupFlows.phases(for: [.waitText("Custom"), .clickText("Go")])

    #expect(phases.count == 11)
    #expect(phases[1].firstStepIndex == 0)
    #expect(phases[2].firstStepIndex == nil)
    #expect(phases[4].firstStepIndex == nil)
}

@Test
func ocrQueryMatchesUsesExactSubstringAndRegexSemantics() {
    #expect(OCRService.queryMatches("Not Now", candidate: "not now"))
    #expect(OCRService.queryMatches("Continue", candidate: "Click Continue to proceed"))
    #expect(OCRService.queryMatches("^Skip$", candidate: "Skip"))
    #expect(!OCRService.queryMatches("^Skip$", candidate: "Skip this step"))
    #expect(OCRService.queryMatches("Other Sign-In Options|Set Up Later", candidate: "Set Up Later"))
    #expect(!OCRService.queryMatches("Full Name", candidate: "Password"))
}

@Test
func setupRescueTriesDismissiveButtonsBeforeGenericAdvancement() throws {
    let queries = SetupStepRunner.rescueQueries
    let notNow = try #require(queries.firstIndex(of: "Not Now"))
    let otherSignIn = try #require(queries.firstIndex(of: "Other Sign-In Options"))
    let setUpLater = try #require(queries.firstIndex(of: "Set Up Later"))
    let dontUse = try #require(queries.firstIndex(of: "Don.t Use"))
    let adult = try #require(queries.firstIndex(of: "Adult|Acult"))
    let agree = try #require(queries.firstIndex(of: "Agree"))
    let cont = try #require(queries.firstIndex(of: "Continue"))
    #expect(notNow < cont)
    #expect(otherSignIn < cont)
    #expect(setUpLater < cont)
    #expect(dontUse < cont)
    #expect(adult < cont)
    #expect(agree < cont)

    // "Don.t Use" must match both apostrophe variants OCR produces.
    #expect(OCRService.queryMatches("Don.t Use", candidate: "Don't Use"))
    #expect(OCRService.queryMatches("Don.t Use", candidate: "Don’t Use"))
}

@Test
func setupRescuePrefersFileVaultModalContinueOverBackgroundButtons() throws {
    let observations = [
        TextObservation(
            string: "Not Now",
            rectInPixels: CGRect(x: 740, y: 930, width: 80, height: 24),
            confidence: 0.96
        ),
        TextObservation(
            string: "Mac Data Will Not Be Securely Encrypted",
            rectInPixels: CGRect(x: 820, y: 610, width: 260, height: 34),
            confidence: 0.98
        ),
        TextObservation(
            string: "Continue",
            rectInPixels: CGRect(x: 1040, y: 730, width: 86, height: 28),
            confidence: 0.98
        ),
    ]

    let match = try #require(SetupStepRunner.rescueMatch(in: observations))
    #expect(match.text == "Continue")
    #expect(match.x == 1083)
    #expect(match.y == 744)
}

/// Regression for the flow ending mid-Setup-Assistant: late panes should be
/// driven from current screenshots, not by paying one timeout for every possible
/// pane in a linear list. The login screen is optional because some builds land
/// directly on Finder after Setup Assistant completes.
@Test
func setupFlowAdvancesLatePanesAndLogsInOnlyWhenNeeded() throws {
    let options = SetupOptions()
    let steps = SetupFlows.tahoe(options: options)
    let waits = steps.filter { $0.action == .waitText }
    let advances = steps.filter { $0.action == .advanceUntilText }

    let firstFinishGate = try #require(advances.first)
    #expect((firstFinishGate.text ?? "").contains("Finder"))
    #expect((firstFinishGate.text ?? "").contains("Enter Password"))
    #expect(firstFinishGate.optional != true)

    let conditionalPassword = try #require(steps.first {
        $0.action == .type
            && $0.text == options.password
            && ($0.whenText ?? "").contains("Enter Password")
    })
    let loginFocus = try #require(steps.first {
        $0.action == .clickTextWhenText
            && ($0.text ?? "").contains("Password")
            && $0.whenText == conditionalPassword.whenText
    })
    let conditionalReturn = try #require(steps.first {
        $0.action == .keys
            && $0.keys == ["return"]
            && ($0.whenText ?? "").contains("Enter Password")
    })
    #expect(loginFocus.optional == true)
    #expect(conditionalPassword.optional == true)
    #expect(conditionalReturn.optional == true)

    let desktopGate = try #require(advances.last)
    #expect(desktopGate.text == "Finder")
    #expect(desktopGate.optional != true)

    let account = try #require(steps.firstIndex { $0.action == .waitText && ($0.text ?? "").contains("Create a.*Account") })
    let focusIndex = try #require(steps.firstIndex { $0 == loginFocus })
    let loginIndex = try #require(steps.firstIndex { $0 == conditionalPassword })
    let desktopIndex = try #require(steps.firstIndex { $0 == desktopGate })
    #expect(account < loginIndex)
    #expect(focusIndex < loginIndex)
    #expect(loginIndex < desktopIndex)
    #expect(desktopIndex == steps.count - 3) // followed only by a settle delay + screenshot

    #expect(waits.allSatisfy { !($0.text ?? "").contains("|:") })
}

@Test
func setupFlowHandlesFileVaultBeforeScreenshotDrivenTail() throws {
    let steps = SetupFlows.tahoe(options: SetupOptions())

    let account = try #require(steps.firstIndex {
        $0.action == .waitText && ($0.text ?? "").contains("Create a.*Account")
    })
    let fileVaultChoice = try #require(steps.firstIndex {
        $0.action == .clickTextWhenText
            && $0.text == "Not Now"
            && ($0.whenText ?? "").contains("FileVault")
    })
    let fileVaultConfirmation = try #require(steps.firstIndex {
        $0.action == .clickTextWhenText
            && $0.text == "^Continue$"
            && ($0.whenText ?? "").contains("Securely Encrypted")
    })
    let tail = try #require(steps.firstIndex {
        $0.action == .advanceUntilText
            && ($0.text ?? "").contains("Enter Password")
            && ($0.text ?? "").contains("Finder")
    })

    #expect(account < fileVaultChoice)
    #expect(fileVaultChoice < fileVaultConfirmation)
    #expect(fileVaultConfirmation < tail)
    #expect(steps[fileVaultChoice].optional == true)
    #expect(steps[fileVaultConfirmation].optional == true)
}

/// Regression: small framebuffers are upscaled 2x before Vision recognition, and
/// matches must map back to NATIVE framebuffer pixels (an unmapped match would
/// land at ~2x the true coordinates and clicks would miss).
@Test
func ocrUpscalesSmallFramebuffersAndMapsMatchesToNativePixels() throws {
    let width = 640
    let height = 360
    let textOrigin = CGPoint(x: 200, y: 100) // CG bottom-left origin

    var framebuffer = Framebuffer(width: width, height: height)
    try framebuffer.pixels.withUnsafeMutableBytes { buffer in
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let context = try #require(CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let attributed = NSAttributedString(string: "Not Now", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = textOrigin
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }

    let match = try #require(OCRService.match("Not Now", in: framebuffer))

    // Center must be near the drawn text in NATIVE coordinates: x around
    // 200..260, y around (360 - 100 - glyph height) ≈ 250. Doubled (unmapped)
    // coordinates would land far outside these bounds.
    #expect(match.x >= 190 && match.x <= 300)
    #expect(match.y >= 230 && match.y <= 270)
}

@Test
func setupFlowAcceptsObservedAgeRangeOCRVariant() throws {
    let query = try #require(SetupStepRunner.rescueQueries.first { $0.contains("Acult") })

    #expect(query.contains("Adult"))
    #expect(OCRService.queryMatches(query, candidate: "Acult"))
}

@Test
func provisioningScriptContainsExpectedCommands() {
    let script = GuestProvisioningScript.build(GuestProvisioningInputs(
        username: "admin",
        password: "admin",
        authorizedKey: "ssh-ed25519 AAAATESTKEY macvm-test",
        extraAuthorizedKey: nil,
        enableAutoLogin: true,
        passwordFilePath: "/Volumes/My Shared Files/Transfers/.macvm-pw"
    ))

    #expect(script.contains("launchctl load -w /System/Library/LaunchDaemons/ssh.plist"))
    #expect(script.contains("ssh-ed25519 AAAATESTKEY macvm-test"))
    #expect(script.contains("NOPASSWD: ALL"))
    #expect(script.contains("visudo -cf")) // sudoers validated before install
    #expect(script.contains("sysadminctl -autologin set"))
    #expect(script.contains("pmset -a sleep 0"))
    #expect(script.contains(GuestProvisioningScript.doneMarker))

    // Auto-login off removes the sysadminctl line.
    let noAutoLogin = GuestProvisioningScript.build(GuestProvisioningInputs(
        username: "admin", password: "admin", authorizedKey: "k",
        extraAuthorizedKey: nil, enableAutoLogin: false,
        passwordFilePath: "/tmp/pw"
    ))
    #expect(!noAutoLogin.contains("sysadminctl -autologin set"))
}

@Test
func guestHardenerUsesExpectedDockTargets() {
    #expect(GuestHardener.finderDockPoint(width: 2560, height: 1440) == (x: 151, y: 1392))
    #expect(GuestHardener.launchpadDockPoint(width: 2560, height: 1440) == (x: 445, y: 1392))
    #expect(GuestHardener.finderDockPoint(width: 1, height: 1) == (x: 0, y: 0))
    #expect(GuestHardener.launchpadDockPoint(width: 1, height: 1) == (x: 0, y: 0))
}

@Test
func usernameValidationRejectsShellMetacharacters() {
    #expect(GuestProvisioningScript.isValidUsername("admin"))
    #expect(GuestProvisioningScript.isValidUsername("dev_user_01"))
    #expect(!GuestProvisioningScript.isValidUsername(""))
    #expect(!GuestProvisioningScript.isValidUsername("a; rm -rf /"))
    #expect(!GuestProvisioningScript.isValidUsername("a/b"))
    #expect(!GuestProvisioningScript.isValidUsername("a b"))
    #expect(!GuestProvisioningScript.isValidUsername("$(whoami)"))
}

@Test
func ocrPixelRectFlipsFromNormalized() {
    // Vision boxes are normalized with a bottom-left origin; we want top-left pixels.
    let rect = OCRService.pixelRect(
        fromNormalized: CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25),
        width: 1000,
        height: 1000
    )
    #expect(rect == CGRect(x: 250, y: 250, width: 500, height: 250))
}

@Test
func ocrFindPrefersExactThenSubstringTopToBottom() {
    let observations = [
        TextObservation(string: "Continue anyway", rectInPixels: CGRect(x: 0, y: 300, width: 100, height: 20), confidence: 0.9),
        TextObservation(string: "Continue", rectInPixels: CGRect(x: 0, y: 500, width: 80, height: 20), confidence: 0.9),
        TextObservation(string: "Continue", rectInPixels: CGRect(x: 0, y: 100, width: 80, height: 20), confidence: 0.9),
    ]

    // Exact match wins over the substring "Continue anyway", and the topmost exact
    // (y=100) is returned first.
    let exact = OCRService.find("Continue", in: observations)
    #expect(exact?.rectInPixels.minY == 100)

    // Second occurrence of the exact match is the lower one (y=500).
    let second = OCRService.find("Continue", in: observations, occurrence: 1)
    #expect(second?.rectInPixels.minY == 500)

    // A substring-only query still resolves.
    #expect(OCRService.find("anyway", in: observations)?.string == "Continue anyway")

    // Center is the pixel midpoint (used as the click target).
    #expect(exact?.center == CGPoint(x: 40, y: 110))

    #expect(OCRService.find("Nonexistent", in: observations) == nil)
}

@Test
func vncSessionRoundTripsAndReportsLiveness() throws {
    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("macvm")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let bundle = VMBundle(url: bundleURL)
    #expect(bundle.readVNCSession() == nil)
    #expect(bundle.liveVNCSession() == nil)

    // Our own pid is live; a session pointing at it must be reported live.
    let live = VNCSession(port: 5900, password: "secret42", pid: getpid(), startedAt: Date())
    try bundle.writeVNCSession(live)

    // iso8601 encoding drops sub-second precision, so compare fields with a date
    // tolerance rather than whole-struct equality.
    let decoded = try #require(bundle.readVNCSession())
    #expect(decoded.port == live.port)
    #expect(decoded.password == live.password)
    #expect(decoded.pid == live.pid)
    #expect(abs(decoded.startedAt.timeIntervalSince(live.startedAt)) < 1)
    #expect(bundle.liveVNCSession()?.pid == live.pid)

    // A session for pid 1 (launchd, not us) is not "our" live session; still, the
    // point of interest is that a definitely-dead pid reads back as not live.
    let dead = VNCSession(port: 5900, password: nil, pid: Int32.max, startedAt: Date())
    #expect(dead.isLive == false)

    bundle.clearVNCSession()
    #expect(bundle.readVNCSession() == nil)
}

@Test
func vncSessionRendersLoopbackURL() {
    let secured = VNCSession(port: 5901, password: "secret42", pid: getpid(), startedAt: Date())
    let unauthenticated = VNCSession(port: 5902, password: nil, pid: getpid(), startedAt: Date())

    #expect(secured.vncURLString == "vnc://:secret42@127.0.0.1:5901")
    #expect(unauthenticated.vncURLString == "vnc://127.0.0.1:5902")
    #expect(URL(string: secured.vncURLString)?.scheme == "vnc")
}

@Test
func displayRuntimeStateRoundTripsAndReportsLiveness() throws {
    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("macvm")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let bundle = VMBundle(url: bundleURL)
    #expect(bundle.readDisplayRuntimeState() == nil)
    #expect(bundle.liveDisplayRuntimeState() == nil)

    let live = VMDisplayRuntimeState(
        width: 1280,
        height: 720,
        pixelWidth: 2560,
        pixelHeight: 1440,
        source: .viewer,
        pid: getpid(),
        updatedAt: Date()
    )
    try bundle.writeDisplayRuntimeState(live)

    let decoded = try #require(bundle.readDisplayRuntimeState())
    #expect(decoded.width == live.width)
    #expect(decoded.height == live.height)
    #expect(decoded.source == live.source)
    #expect(decoded.pid == live.pid)
    #expect(decoded.pixelDescription == "2560x1440")
    #expect(abs(decoded.updatedAt.timeIntervalSince(live.updatedAt)) < 1)
    #expect(bundle.liveDisplayRuntimeState()?.displayDescription == "1280x720")

    let dead = VMDisplayRuntimeState(
        width: 1280,
        height: 720,
        pixelWidth: 2560,
        pixelHeight: 1440,
        source: .headless,
        pid: Int32.max,
        updatedAt: Date()
    )
    try bundle.writeDisplayRuntimeState(dead)
    #expect(bundle.readDisplayRuntimeState()?.displayDescription == "1280x720")
    #expect(bundle.liveDisplayRuntimeState() == nil)

    bundle.clearDisplayRuntimeState()
    #expect(bundle.readDisplayRuntimeState() == nil)
}

@Test
func vmProcessRuntimeStateRoundTripsAndReportsLiveness() throws {
    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("macvm")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let bundle = VMBundle(url: bundleURL)
    #expect(bundle.readVMProcessRuntimeState() == nil)
    #expect(bundle.liveVMProcessRuntimeState() == nil)

    let live = VMProcessRuntimeState(
        role: .viewer,
        pid: getpid(),
        startedAt: Date(),
        logPath: "/tmp/macvm-viewer.log"
    )
    try bundle.writeVMProcessRuntimeState(live)

    let decoded = try #require(bundle.readVMProcessRuntimeState())
    #expect(decoded.role == live.role)
    #expect(decoded.pid == live.pid)
    #expect(decoded.logPath == live.logPath)
    #expect(abs(decoded.startedAt.timeIntervalSince(live.startedAt)) < 1)
    #expect(bundle.liveVMProcessRuntimeState()?.pid == live.pid)

    let dead = VMProcessRuntimeState(role: .headless, pid: Int32.max, startedAt: Date())
    try bundle.writeVMProcessRuntimeState(dead)
    #expect(bundle.readVMProcessRuntimeState()?.role == .headless)
    #expect(bundle.liveVMProcessRuntimeState() == nil)

    bundle.clearVMProcessRuntimeState()
    #expect(bundle.readVMProcessRuntimeState() == nil)
}

@Test
func stopVMUsesLiveVNCSessionOwnerWhenProcessStateIsMissing() throws {
    let rootURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bundleURL = rootURL
        .appendingPathComponent("dev-01", isDirectory: true)
        .appendingPathExtension(VMStorage.bundleExtension)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let metadata = VMMetadata(
        name: "dev-01",
        cpuCount: 2,
        memorySizeBytes: 4 * oneGiB,
        diskSizeBytes: 40 * oneGiB,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
    let bundle = VMBundle(url: bundleURL)
    try bundle.writeMetadata(metadata)
    try bundle.writeVNCSession(VNCSession(port: 5901, password: "secret42", pid: getpid(), startedAt: Date()))

    let service = MacVMService(rootDirectory: rootURL)
    let vm = ManagedVM(bundleURL: bundleURL, metadata: metadata)

    var didThrow = false
    do {
        _ = try service.stopVM(vm)
    } catch {
        didThrow = true
        #expect(error.localizedDescription.contains("Refusing to stop the current process"))
    }

    #expect(didThrow)
}

@Test
func setupRuntimeStateRoundTripsAndReportsLiveness() throws {
    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("macvm")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let bundle = VMBundle(url: bundleURL)
    #expect(bundle.readSetupRuntimeState() == nil)
    #expect(bundle.liveSetupRuntimeState() == nil)

    let live = VMSetupRuntimeState(
        username: "admin",
        fullName: "Administrator",
        phaseIndex: 6,
        phaseCount: 11,
        pid: getpid(),
        startedAt: Date(),
        updatedAt: Date()
    )
    try bundle.writeSetupRuntimeState(live)

    let decoded = try #require(bundle.readSetupRuntimeState())
    #expect(decoded.username == live.username)
    #expect(decoded.fullName == live.fullName)
    #expect(decoded.phaseIndex == live.phaseIndex)
    #expect(decoded.phaseCount == live.phaseCount)
    #expect(decoded.pid == live.pid)
    #expect(abs(decoded.startedAt.timeIntervalSince(live.startedAt)) < 1)
    #expect(abs(decoded.updatedAt.timeIntervalSince(live.updatedAt)) < 1)
    #expect(bundle.liveSetupRuntimeState()?.phaseIndex == live.phaseIndex)

    let failed = VMSetupRuntimeState(
        username: "admin",
        fullName: "Administrator",
        phaseCount: 11,
        failureMessage: "Timed out",
        pid: Int32.max,
        startedAt: Date(),
        updatedAt: Date()
    )
    try bundle.writeSetupRuntimeState(failed)
    #expect(bundle.readSetupRuntimeState()?.failureMessage == "Timed out")
    #expect(bundle.liveSetupRuntimeState() == nil)

    bundle.clearSetupRuntimeState()
    #expect(bundle.readSetupRuntimeState() == nil)
}

@Test
func viewerWindowStateRoundTrips() throws {
    let bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathExtension("macvm")
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let bundle = VMBundle(url: bundleURL)
    #expect(bundle.readViewerWindowState() == nil)

    let state = VMViewerWindowState(
        x: 100,
        y: 200,
        width: 1440,
        height: 900,
        updatedAt: Date()
    )
    try bundle.writeViewerWindowState(state)

    let decoded = try #require(bundle.readViewerWindowState())
    #expect(decoded.x == state.x)
    #expect(decoded.y == state.y)
    #expect(decoded.width == state.width)
    #expect(decoded.height == state.height)
    #expect(abs(decoded.updatedAt.timeIntervalSince(state.updatedAt)) < 1)
}

@Test
func macAddressComparisonIgnoresZeroPadding() {
    #expect(MACAddress.octets("52:55:55:14:2:36") == [0x52, 0x55, 0x55, 0x14, 0x02, 0x36])
    #expect(MACAddress.canonical("52:55:55:14:2:36") == "52:55:55:14:02:36")
    #expect(MACAddress.equal("52:55:55:14:2:36", "52:55:55:14:02:36"))
    #expect(MACAddress.equal("AA:BB:CC:00:11:22", "aa:bb:cc:0:11:22"))
    #expect(MACAddress.octets("52:55:55:14:36") == nil)   // only five octets
    #expect(MACAddress.octets("52:55:55:14:2:zz") == nil) // non-hex
}

@Test
func dhcpLeaseParserMatchesNonPaddedMAC() {
    let contents = """
    {
    \tname=guest-a
    \tip_address=192.168.64.10
    \thw_address=1,52:55:55:14:2:36
    \tidentifier=1,52:55:55:14:2:36
    \tlease=0x60000000
    }
    {
    \tname=guest-b
    \tip_address=192.168.64.11
    \thw_address=1,52:55:55:aa:bb:c
    \tidentifier=1,52:55:55:aa:bb:c
    \tlease=0x70000000
    }
    """

    let leases = DHCPLeaseParser.parse(contents)
    #expect(leases.count == 2)

    // now is between the two expiry timestamps (0x60000000 past, 0x70000000 future).
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    // Zero-padded query matches the non-padded stored octets.
    let live = DHCPLeaseParser.bestLease(in: leases, macAddress: "52:55:55:aa:bb:0c", now: now)
    #expect(live?.ipAddress == "192.168.64.11")

    // The only match is expired, so we still fall back to its last-known IP.
    let stale = DHCPLeaseParser.bestLease(in: leases, macAddress: "52:55:55:14:02:36", now: now)
    #expect(stale?.ipAddress == "192.168.64.10")
}

@Test
func arpParserExtractsIPAndMAC() {
    let output = """
    ? (192.168.64.10) at 52:55:55:14:2:36 on bridge100 ifscope [ethernet]
    ? (192.168.64.1) at 0:1c:42:0:0:8 on bridge100 ifscope permanent [ethernet]
    ? (224.0.0.251) at (incomplete) on en0 [ethernet]
    """

    let entries = GuestNetwork.parseARP(output)
    #expect(entries.count == 2)   // the (incomplete) entry is skipped
    #expect(entries.first { MACAddress.equal($0.mac, "52:55:55:14:02:36") }?.ip == "192.168.64.10")
}

@Test
func guestSSHArgumentsAreWellFormed() {
    let interactive = GuestSSH.arguments(
        host: "192.168.64.10",
        user: "admin",
        identityFile: URL(fileURLWithPath: "/keys/id_ed25519"),
        allocateTTY: true
    )
    #expect(interactive.contains("-t"))
    #expect(interactive.contains("StrictHostKeyChecking=accept-new"))
    #expect(interactive.contains("IdentitiesOnly=yes"))
    #expect(interactive.last == "admin@192.168.64.10")

    let command = GuestSSH.arguments(
        host: "host",
        user: "admin",
        identityFile: nil,
        remoteCommand: ["uptime"]
    )
    #expect(!command.contains("-i"))   // no identity file supplied
    #expect(command.suffix(2) == ["admin@host", "uptime"])
}

@Test
func ansibleInventoryRendersConnectionVars() {
    let withKey = AnsibleInventory.render(
        name: "myvm",
        host: "192.168.64.10",
        user: "admin",
        identityFile: URL(fileURLWithPath: "/keys/id_ed25519")
    )
    #expect(withKey.hasPrefix("myvm "))
    #expect(withKey.contains("ansible_host=192.168.64.10"))
    #expect(withKey.contains("ansible_user=admin"))
    #expect(withKey.contains("ansible_ssh_private_key_file=/keys/id_ed25519"))

    let withoutKey = AnsibleInventory.render(name: "myvm", host: "h", user: "admin", identityFile: nil)
    #expect(!withoutKey.contains("ansible_ssh_private_key_file"))
}

@Test
func rfbCaptureOnceUsesANewConnectionForEachCapture() async throws {
    let server = try MinimalRFBServer(maxConnections: 2)
    server.start()
    defer { server.stop() }

    let first = try await RFBClient.captureOnce(port: server.port, password: nil)
    let second = try await RFBClient.captureOnce(port: server.port, password: nil)

    #expect(first.width == 1)
    #expect(first.height == 1)
    #expect(first.pixels == [0, 0, 255, 0])
    #expect(second.pixels == [0, 255, 0, 0])
    #expect(server.connectionCount == 2)
    #expect(server.waitUntilStopped(timeout: 2))
}

@Test
func rfbClientSendsClipboardText() async throws {
    let server = try MinimalRFBServer(maxConnections: 1, mode: .captureClientCutText)
    server.start()
    defer { server.stop() }

    try await RFBClient.withConnection(port: server.port, password: nil) { client in
        try await client.setClipboardText("host text")
    }

    #expect(server.waitUntilStopped(timeout: 2))
    #expect(server.receivedClientCutTexts == ["host text"])
}

@Test
func rfbClientReceivesClipboardText() async throws {
    let server = try MinimalRFBServer(maxConnections: 1, mode: .sendServerCutText("guest text"))
    server.start()
    defer { server.stop() }

    let text = try await RFBClient.withConnection(port: server.port, password: nil) { client in
        try await client.waitForClipboardText(timeout: 1)
    }

    #expect(text == "guest text")
    #expect(server.waitUntilStopped(timeout: 2))
}

@Test
func rfbClientClipboardWaitTimesOut() async throws {
    let server = try MinimalRFBServer(maxConnections: 1, mode: .idleAfterHandshake)
    server.start()
    defer { server.stop() }

    var didThrow = false
    do {
        _ = try await RFBClient.withConnection(port: server.port, password: nil) { client in
            try await client.waitForClipboardText(timeout: 0.1)
        }
    } catch {
        didThrow = true
        #expect(error.localizedDescription.contains("Timed out"))
    }

    #expect(didThrow)
}

private enum MinimalRFBServerMode {
    case framebufferCaptures
    case captureClientCutText
    case sendServerCutText(String)
    case idleAfterHandshake
}

private final class MinimalRFBServer: @unchecked Sendable {
    let port: Int

    private let socketFD: Int32
    private let maxConnections: Int
    private let mode: MinimalRFBServerMode
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var closed = false
    private var handledConnections = 0
    private var capturedClientCutTexts: [String] = []

    var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handledConnections
    }

    var receivedClientCutTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedClientCutTexts
    }

    init(maxConnections: Int, mode: MinimalRFBServerMode = .framebufferCaptures) throws {
        self.maxConnections = maxConnections
        self.mode = mode

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TestSocketError.operationFailed("socket")
        }
        socketFD = fd

        var reuse = 1
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw TestSocketError.operationFailed("setsockopt")
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw TestSocketError.operationFailed("bind")
        }

        guard listen(fd, Int32(maxConnections)) == 0 else {
            throw TestSocketError.operationFailed("listen")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(fd, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else {
            throw TestSocketError.operationFailed("getsockname")
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }

            for _ in 0..<maxConnections {
                let clientFD = Darwin.accept(socketFD, nil, nil)
                guard clientFD >= 0 else {
                    return
                }

                let connectionIndex = nextConnectionIndex()
                do {
                    try serve(clientFD: clientFD, connectionIndex: connectionIndex)
                } catch {
                    // The client side will surface protocol failures; the server
                    // just needs to close the accepted socket.
                }
                Darwin.close(clientFD)
            }
        }
    }

    func stop() {
        lock.lock()
        let shouldClose = !closed
        closed = true
        lock.unlock()

        if shouldClose {
            Darwin.close(socketFD)
        }
        _ = waitUntilStopped(timeout: 2)
    }

    func waitUntilStopped(timeout: TimeInterval) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }

    private func nextConnectionIndex() -> Int {
        lock.lock()
        defer { lock.unlock() }
        handledConnections += 1
        return handledConnections
    }

    private func serve(clientFD: Int32, connectionIndex: Int) throws {
        try writeAll([UInt8]("RFB 003.008\n".utf8), to: clientFD)
        _ = try readExactly(12, from: clientFD)

        try writeAll([1, RFB.securityNone], to: clientFD)
        _ = try readExactly(1, from: clientFD)
        try writeAll([0, 0, 0, 0], to: clientFD)
        _ = try readExactly(1, from: clientFD)

        var serverInit: [UInt8] = []
        serverInit.appendBigEndian(UInt16(1))
        serverInit.appendBigEndian(UInt16(1))
        serverInit.append(contentsOf: RFBPixelFormat.bgra32.encoded)
        serverInit.appendBigEndian(UInt32(0))
        try writeAll(serverInit, to: clientFD)

        _ = try readExactly(20, from: clientFD) // SetPixelFormat.
        let encodingsHeader = try readExactly(4, from: clientFD)
        let encodingCount = Int(UInt16(encodingsHeader[2]) << 8 | UInt16(encodingsHeader[3]))
        _ = try readExactly(encodingCount * 4, from: clientFD)

        switch mode {
        case .framebufferCaptures:
            try serveFramebufferCapture(clientFD: clientFD, connectionIndex: connectionIndex)
        case .captureClientCutText:
            try captureClientCutText(clientFD: clientFD)
        case .sendServerCutText(let text):
            try sendServerCutText(text, to: clientFD)
        case .idleAfterHandshake:
            usleep(300 * 1000)
        }
    }

    private func serveFramebufferCapture(clientFD: Int32, connectionIndex: Int) throws {
        _ = try readExactly(10, from: clientFD) // FramebufferUpdateRequest.
        let pixel: [UInt8] = connectionIndex == 1 ? [0, 0, 255, 0] : [0, 255, 0, 0]
        var update: [UInt8] = [RFB.framebufferUpdateType, 0]
        update.appendBigEndian(UInt16(1))
        update.appendBigEndian(UInt16(0))
        update.appendBigEndian(UInt16(0))
        update.appendBigEndian(UInt16(1))
        update.appendBigEndian(UInt16(1))
        update.appendBigEndian(UInt32(bitPattern: RFB.rawEncoding))
        update.append(contentsOf: pixel)
        try writeAll(update, to: clientFD)
    }

    private func captureClientCutText(clientFD: Int32) throws {
        let messageType = try readExactly(1, from: clientFD)[0]
        guard messageType == RFB.clientCutTextType else {
            throw TestSocketError.operationFailed("clientCutText")
        }
        _ = try readExactly(3, from: clientFD)
        let lengthBytes = try readExactly(4, from: clientFD)
        let length = Int(
            UInt32(lengthBytes[0]) << 24 |
            UInt32(lengthBytes[1]) << 16 |
            UInt32(lengthBytes[2]) << 8 |
            UInt32(lengthBytes[3])
        )
        let bytes = try readExactly(length, from: clientFD)
        guard let text = String(data: Data(bytes), encoding: .utf8) else {
            throw TestSocketError.operationFailed("decode clientCutText")
        }

        lock.lock()
        capturedClientCutTexts.append(text)
        lock.unlock()
    }

    private func sendServerCutText(_ text: String, to clientFD: Int32) throws {
        let textBytes = [UInt8](text.utf8)
        var message: [UInt8] = [RFB.serverCutTextType, 0, 0, 0]
        message.appendBigEndian(UInt32(textBytes.count))
        message.append(contentsOf: textBytes)
        try writeAll(message, to: clientFD)
    }
}

private enum TestSocketError: Error {
    case operationFailed(String)
    case connectionClosed
}

private func readExactly(_ count: Int, from fd: Int32) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0

    while offset < count {
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), count - offset)
        }
        if readCount == 0 {
            throw TestSocketError.connectionClosed
        }
        if readCount < 0 {
            if errno == EINTR {
                continue
            }
            throw TestSocketError.operationFailed("read")
        }
        offset += readCount
    }

    return bytes
}

private func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
    var offset = 0

    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
        }
        if written < 0 {
            if errno == EINTR {
                continue
            }
            throw TestSocketError.operationFailed("write")
        }
        offset += written
    }
}
