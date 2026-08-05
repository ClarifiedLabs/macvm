import CryptoKit
import Darwin
import Foundation

/// Crash-recoverable publication of a verified, larger disk image.
///
/// Callers must hold the bundle's `VMDiskLifecycleLock` for every operation on
/// this type. The journal is intentionally created before its stage directory,
/// so an unjournaled `.DiskResize.*` directory is never part of a valid plan.
struct DiskResizeTransaction {
    static let journalName = ".DiskResizeTransaction.json"
    static let stagePrefix = ".DiskResize."

    enum JournalPhase: String, Codable, Equatable, Sendable {
        case planned
        case candidateReady
        case exchanged
        case metadataCommitted
    }

    struct GeometryFingerprint: Codable, Equatable, Sendable {
        let diskSizeBytes: UInt64
        let sectorCount: UInt64
        let primaryHeaderLBA: UInt64
        let primaryEntriesLBA: UInt64
        let backupEntriesLBA: UInt64
        let backupHeaderLBA: UInt64
        let firstUsableLBA: UInt64
        let lastUsableLBA: UInt64
        let partitionEntryCount: UInt32
        let partitionEntrySize: UInt32
        let partitionEntryArraySectorCount: UInt64
    }

    struct EntryFingerprint: Codable, Equatable, Sendable {
        let slotIndex: Int
        let typeGUID: UUID
        let uniqueGUID: UUID
        let firstLBA: UInt64
        let lastLBA: UInt64
        let attributes: UInt64
        let name: String
        /// SHA-256 of the raw entry with its first/last-LBA fields omitted.
        /// It consequently remains stable when a partition is moved or grown.
        let stableEntryDigest: String
    }

    struct Fingerprint: Codable, Equatable, Sendable {
        let logicalSizeBytes: UInt64
        let geometry: GeometryFingerprint
        let diskGUID: UUID
        let entries: [EntryFingerprint]
    }

    struct Journal: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        var schemaVersion = currentSchemaVersion
        let transactionID: UUID
        let stageDirectoryName: String
        let expectedVMID: UUID
        let targetSizeBytes: UInt64
        let sourceFingerprint: Fingerprint
        var targetFingerprint: Fingerprint?
        var phase: JournalPhase
    }

    enum ImageClassification: String, Equatable, Sendable {
        case source
        case target
        case incomplete
        case missing
    }

    typealias ProgressCallback = DiskImageGrower.PhaseCallback
    typealias GrowOperation = (
        _ sourceImageURL: URL,
        _ candidateImageURL: URL,
        _ targetSizeBytes: UInt64,
        _ phase: DiskImageGrower.PhaseCallback
    ) throws -> Void
    typealias FingerprintOperation = (_ imageURL: URL) throws -> Fingerprint
    typealias ExchangeOperation = (_ canonicalImageURL: URL, _ candidateImageURL: URL) throws -> Void

    struct AttachmentOperations {
        let attachedWholeDisks: (_ imageURL: URL) throws -> [String]
        let detachWholeDisk: (_ identifier: String) throws -> Void
    }

    struct Dependencies {
        let grow: GrowOperation
        let fingerprint: FingerprintOperation
        let exchange: ExchangeOperation
        let attachments: AttachmentOperations

        static func live(
            processRunner: any DiskProcessRunning = DiskProcessRunner()
        ) -> Dependencies {
            Dependencies(
                grow: { sourceURL, candidateURL, targetSizeBytes, phase in
                    let result = try DiskImageGrower(processRunner: processRunner).grow(
                        sourceImageURL: sourceURL,
                        candidateImageURL: candidateURL,
                        targetSizeBytes: targetSizeBytes,
                        phase: phase
                    )
                    guard result.sourceImageURL.path == DiskResizeTransaction.normalizedFileURL(sourceURL).path,
                          result.candidateImageURL.path == DiskResizeTransaction.normalizedFileURL(candidateURL).path,
                          result.sourceSizeBytes < result.targetSizeBytes,
                          result.targetSizeBytes == targetSizeBytes else {
                        throw MacVMError.message(
                            "The disk grower returned a candidate for a different resize plan."
                        )
                    }
                },
                fingerprint: { try DiskResizeTransaction.makeFingerprint(imageURL: $0) },
                exchange: { try DiskResizeTransaction.exchangeImages($0, $1) },
                attachments: AttachmentOperations(
                    attachedWholeDisks: { imageURL in
                        let propertyList = try processRunner.runPropertyList(
                            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                            arguments: ["info", "-plist"]
                        )
                        return try DiskResizeTransaction.attachedWholeDisks(
                            for: imageURL,
                            hdiutilInfo: propertyList
                        )
                    },
                    detachWholeDisk: { identifier in
                        guard DiskResizeTransaction.isWholeDiskIdentifier(identifier) else {
                            throw MacVMError.message(
                                "Refusing to detach an invalid disk identifier while cleaning up a resize."
                            )
                        }
                        _ = try processRunner.run(
                            executableURL: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                            arguments: ["detach", identifier]
                        )
                    }
                )
            )
        }
    }

    fileprivate enum FileKind {
        case missing
        case regular
        case directory
        case other
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
    }

    /// Grows and publishes a disk while the caller retains the disk lifecycle lock.
    /// The expected ID and complete metadata snapshot prevent a stale service request
    /// from starting a transaction for a replaced or concurrently edited VM.
    func execute(
        bundle: VMBundle,
        expectedVMID: UUID,
        currentMetadata: VMMetadata,
        targetSizeBytes: UInt64,
        progress: @escaping ProgressCallback = { _ in }
    ) throws -> VMMetadata {
        let recoveredMetadata = try recoverIfNeeded(bundle: bundle)
        guard expectedVMID == currentMetadata.id,
              recoveredMetadata.id == expectedVMID,
              recoveredMetadata == currentMetadata else {
            throw MacVMError.message(
                "The VM metadata changed before its disk resize could begin. Refresh the VM and try again."
            )
        }
        guard targetSizeBytes > currentMetadata.diskSizeBytes,
              targetSizeBytes <= UInt64(Int64.max),
              targetSizeBytes % GUIDPartitionTable.alignmentBytes == 0 else {
            throw MacVMError.message(
                "The requested disk size must be a larger 4 KiB-aligned size supported by this host."
            )
        }

        let canonicalURL = bundle.diskImageURL
        guard try fileKind(at: canonicalURL) == .regular else {
            throw MacVMError.message("The canonical disk image is missing or is not a regular file.")
        }
        let sourceFingerprint = try dependencies.fingerprint(canonicalURL)
        try validateFingerprint(sourceFingerprint, description: "source")
        guard sourceFingerprint.logicalSizeBytes == currentMetadata.diskSizeBytes else {
            throw MacVMError.message(
                "The disk image is \(sourceFingerprint.logicalSizeBytes) bytes, but VM metadata records \(currentMetadata.diskSizeBytes) bytes."
            )
        }

        let transactionID = UUID()
        let stageName = Self.stagePrefix + transactionID.uuidString
        let stageURL = bundle.url.appendingPathComponent(stageName, isDirectory: true)
        let candidateURL = stageURL.appendingPathComponent("Disk.img", isDirectory: false)
        var journal = Journal(
            transactionID: transactionID,
            stageDirectoryName: stageName,
            expectedVMID: expectedVMID,
            targetSizeBytes: targetSizeBytes,
            sourceFingerprint: sourceFingerprint,
            targetFingerprint: nil,
            phase: .planned
        )

        do {
            // This must be durable before the first creation of the stage path.
            try writeJournal(journal, bundle: bundle)
            try FileManager.default.createDirectory(
                at: stageURL,
                withIntermediateDirectories: false
            )
            try synchronizeDirectory(stageURL)
            try synchronizeDirectory(bundle.url)

            try dependencies.grow(
                canonicalURL,
                candidateURL,
                targetSizeBytes,
                progress
            )
            guard try fileKind(at: candidateURL) == .regular else {
                throw MacVMError.message("The disk grower did not produce a regular candidate image.")
            }
            try synchronizeFile(candidateURL)
            try synchronizeDirectory(stageURL)

            let targetFingerprint = try dependencies.fingerprint(candidateURL)
            try validateFingerprint(targetFingerprint, description: "target")
            try validateResizePlan(
                source: sourceFingerprint,
                target: targetFingerprint,
                targetSizeBytes: targetSizeBytes
            )
            guard try dependencies.fingerprint(canonicalURL) == sourceFingerprint else {
                throw MacVMError.message(
                    "The canonical disk image changed while its resize candidate was being prepared."
                )
            }

            // Fingerprint and phase become durable in the same journal replacement.
            journal.targetFingerprint = targetFingerprint
            journal.phase = .candidateReady
            try writeJournal(journal, bundle: bundle)

            try requireRegularDistinctImages(canonicalURL, candidateURL)
            try requireUnattached([canonicalURL, candidateURL])
            try dependencies.exchange(canonicalURL, candidateURL)
            try synchronizeDirectory(stageURL)
            try synchronizeDirectory(bundle.url)

            let canonicalClass = try classify(
                canonicalURL,
                source: sourceFingerprint,
                target: targetFingerprint
            )
            let stageClass = try classify(
                candidateURL,
                source: sourceFingerprint,
                target: targetFingerprint
            )
            guard canonicalClass == .target, stageClass == .source else {
                throw ambiguousStateError(
                    canonical: canonicalClass,
                    stage: stageClass,
                    journalURL: journalURL(for: bundle)
                )
            }

            journal.phase = .exchanged
            try writeJournal(journal, bundle: bundle)
            return try recoverIfNeeded(bundle: bundle)
        } catch {
            let operationError = error
            guard FileManager.default.fileExists(atPath: journalURL(for: bundle).path) else {
                throw operationError
            }
            do {
                let recovered = try recoverIfNeeded(bundle: bundle)
                if recovered.id == expectedVMID,
                   recovered.diskSizeBytes == targetSizeBytes {
                    return recovered
                }
            } catch {
                throw MacVMError.message(
                    "Disk resize failed: \(operationError.localizedDescription) "
                        + "Recovery also failed: \(error.localizedDescription)"
                )
            }
            throw operationError
        }
    }

    /// Resolves a journal by fingerprinting both image locations. Journal phase is
    /// never used to choose roll-forward versus rollback.
    @discardableResult
    func recoverIfNeeded(bundle: VMBundle) throws -> VMMetadata {
        let journalURL = journalURL(for: bundle)
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            return try bundle.readMetadata()
        }

        var journal = try readJournal(bundle: bundle)
        try validateJournal(journal)
        let stageURL = bundle.url.appendingPathComponent(
            journal.stageDirectoryName,
            isDirectory: true
        )
        let candidateURL = stageURL.appendingPathComponent("Disk.img", isDirectory: false)
        try validateStageDirectory(stageURL)

        let canonicalClass = try classify(
            bundle.diskImageURL,
            source: journal.sourceFingerprint,
            target: journal.targetFingerprint
        )
        let stageClass = try classify(
            candidateURL,
            source: journal.sourceFingerprint,
            target: journal.targetFingerprint
        )

        switch canonicalClass {
        case .source:
            // Regardless of how far candidate preparation got, the exchange did
            // not install the target. A known-good source is deterministic rollback.
            let metadata = try persistDiskSize(
                journal.sourceFingerprint.logicalSizeBytes,
                expectedVMID: journal.expectedVMID,
                allowedCurrentSizes: [
                    journal.sourceFingerprint.logicalSizeBytes,
                    journal.targetSizeBytes,
                ],
                bundle: bundle
            )
            do {
                try cleanupStageAndJournal(
                    stageURL: stageURL,
                    journal: journal,
                    bundle: bundle
                )
            } catch {
                // The source metadata is durable. Retain the journal so cleanup is
                // retried, but do not make an otherwise usable VM unavailable.
                return metadata
            }
            return metadata

        case .target:
            guard stageClass == .source || stageClass == .missing else {
                throw ambiguousStateError(
                    canonical: canonicalClass,
                    stage: stageClass,
                    journalURL: journalURL
                )
            }
            let metadata = try persistDiskSize(
                journal.targetSizeBytes,
                expectedVMID: journal.expectedVMID,
                allowedCurrentSizes: [
                    journal.sourceFingerprint.logicalSizeBytes,
                    journal.targetSizeBytes,
                ],
                bundle: bundle
            )

            // From this point onward the target image and metadata are durable.
            // Any journal/stage cleanup error must preserve recovery evidence and
            // still return the committed metadata.
            do {
                journal.phase = .metadataCommitted
                try writeJournal(journal, bundle: bundle)
                try cleanupStageAndJournal(
                    stageURL: stageURL,
                    journal: journal,
                    bundle: bundle
                )
            } catch {
                return metadata
            }
            return metadata

        case .incomplete, .missing:
            throw ambiguousStateError(
                canonical: canonicalClass,
                stage: stageClass,
                journalURL: journalURL
            )
        }
    }

    /// Explicitly discards resize state before the owning bundle is removed.
    /// Every regular image is detached by exact hdiutil plist path matching first.
    func discardForRemoval(bundle: VMBundle) throws {
        let fileManager = FileManager.default
        let journalURL = journalURL(for: bundle)
        if fileManager.fileExists(atPath: journalURL.path) {
            try validateJournal(readJournal(bundle: bundle))
        }

        guard try fileKind(at: bundle.url) == .directory else { return }
        let entries = try fileManager.contentsOfDirectory(
            at: bundle.url,
            includingPropertiesForKeys: nil,
            options: []
        )
        let stageURLs = try entries.filter { entry in
            guard entry.lastPathComponent.hasPrefix(Self.stagePrefix) else { return false }
            guard Self.transactionID(fromStageName: entry.lastPathComponent) != nil else {
                throw MacVMError.message(
                    "Invalid disk resize staging path at \(entry.path); preserving it for inspection."
                )
            }
            try validateStageDirectory(entry)
            return true
        }

        switch try fileKind(at: bundle.diskImageURL) {
        case .regular:
            try detachExactImageIfNeeded(bundle.diskImageURL)
        case .missing:
            break
        case .directory, .other:
            throw MacVMError.message(
                "The canonical disk path is not a regular file; preserving the bundle for inspection."
            )
        }

        for stageURL in stageURLs {
            let imageURL = stageURL.appendingPathComponent("Disk.img", isDirectory: false)
            if try fileKind(at: imageURL) == .regular {
                try detachExactImageIfNeeded(imageURL)
            }
        }
        for stageURL in stageURLs {
            try fileManager.removeItem(at: stageURL)
        }
        try synchronizeDirectory(bundle.url)
        if fileManager.fileExists(atPath: journalURL.path) {
            try fileManager.removeItem(at: journalURL)
            try synchronizeDirectory(bundle.url)
        }
    }
}

private extension DiskResizeTransaction {
    func journalURL(for bundle: VMBundle) -> URL {
        bundle.url.appendingPathComponent(Self.journalName, isDirectory: false)
    }

    static func transactionID(fromStageName name: String) -> UUID? {
        guard name.hasPrefix(stagePrefix) else { return nil }
        let suffix = String(name.dropFirst(stagePrefix.count))
        guard !suffix.isEmpty, !suffix.contains("/") else { return nil }
        return UUID(uuidString: suffix)
    }

    func validateJournal(_ journal: Journal) throws {
        guard journal.schemaVersion == Journal.currentSchemaVersion,
              journal.stageDirectoryName == Self.stagePrefix + journal.transactionID.uuidString,
              Self.transactionID(fromStageName: journal.stageDirectoryName) == journal.transactionID,
              journal.targetSizeBytes > journal.sourceFingerprint.logicalSizeBytes,
              journal.targetSizeBytes <= UInt64(Int64.max),
              journal.targetSizeBytes % GUIDPartitionTable.alignmentBytes == 0 else {
            throw MacVMError.message("The disk resize journal is invalid; preserving it for inspection.")
        }
        try validateFingerprint(journal.sourceFingerprint, description: "journal source")
        if let target = journal.targetFingerprint {
            try validateFingerprint(target, description: "journal target")
            try validateResizePlan(
                source: journal.sourceFingerprint,
                target: target,
                targetSizeBytes: journal.targetSizeBytes
            )
        } else if journal.phase != .planned {
            throw MacVMError.message(
                "The disk resize journal has no target fingerprint; preserving it for inspection."
            )
        }
    }

    func validateFingerprint(_ fingerprint: Fingerprint, description: String) throws {
        let geometry = fingerprint.geometry
        let sizeProduct = geometry.sectorCount.multipliedReportingOverflow(
            by: GUIDPartitionTable.sectorSizeBytes
        )
        let slots = Set(fingerprint.entries.map(\.slotIndex))
        guard !sizeProduct.overflow,
              sizeProduct.partialValue == fingerprint.logicalSizeBytes,
              geometry.diskSizeBytes == fingerprint.logicalSizeBytes,
              geometry.partitionEntryCount > 0,
              geometry.partitionEntrySize >= 128,
              geometry.partitionEntryArraySectorCount > 0,
              slots.count == fingerprint.entries.count,
              !fingerprint.entries.isEmpty,
              fingerprint.entries.allSatisfy({ entry in
                  entry.slotIndex >= 0
                      && entry.firstLBA <= entry.lastLBA
                      && Self.isSHA256(entry.stableEntryDigest)
              }) else {
            throw MacVMError.message(
                "The \(description) disk fingerprint is invalid; preserving transaction evidence."
            )
        }
    }

    func validateResizePlan(
        source: Fingerprint,
        target: Fingerprint,
        targetSizeBytes: UInt64
    ) throws {
        let sourceEntries = Dictionary(uniqueKeysWithValues: source.entries.map { ($0.slotIndex, $0) })
        let targetEntries = Dictionary(uniqueKeysWithValues: target.entries.map { ($0.slotIndex, $0) })
        guard target.logicalSizeBytes == targetSizeBytes,
              target.logicalSizeBytes > source.logicalSizeBytes,
              target.diskGUID == source.diskGUID,
              sourceEntries.count == targetEntries.count,
              sourceEntries.allSatisfy({ slot, sourceEntry in
                  guard let targetEntry = targetEntries[slot] else { return false }
                  return sourceEntry.slotIndex == targetEntry.slotIndex
                      && sourceEntry.typeGUID == targetEntry.typeGUID
                      && sourceEntry.uniqueGUID == targetEntry.uniqueGUID
                      && sourceEntry.attributes == targetEntry.attributes
                      && sourceEntry.name == targetEntry.name
                      && sourceEntry.stableEntryDigest == targetEntry.stableEntryDigest
              }) else {
            throw MacVMError.message(
                "The staged disk fingerprint does not match the recorded source resize plan."
            )
        }
    }

    func classify(
        _ imageURL: URL,
        source: Fingerprint,
        target: Fingerprint?
    ) throws -> ImageClassification {
        switch try fileKind(at: imageURL) {
        case .missing:
            return .missing
        case .directory, .other:
            return .incomplete
        case .regular:
            do {
                let actual = try dependencies.fingerprint(imageURL)
                if actual == source { return .source }
                if let target, actual == target { return .target }
                return .incomplete
            } catch {
                return .incomplete
            }
        }
    }

    func validateStageDirectory(_ stageURL: URL) throws {
        switch try fileKind(at: stageURL) {
        case .missing:
            return
        case .regular, .other:
            throw MacVMError.message(
                "The disk resize stage is not a directory; preserving transaction evidence."
            )
        case .directory:
            break
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: stageURL,
            includingPropertiesForKeys: nil,
            options: []
        )
        guard contents.count <= 1,
              contents.allSatisfy({ $0.lastPathComponent == "Disk.img" }) else {
            throw MacVMError.message(
                "The disk resize stage contains unexpected data; preserving transaction evidence."
            )
        }
        let candidateURL = stageURL.appendingPathComponent("Disk.img", isDirectory: false)
        switch try fileKind(at: candidateURL) {
        case .missing, .regular:
            return
        case .directory, .other:
            throw MacVMError.message(
                "The staged disk candidate is not a regular file; preserving transaction evidence."
            )
        }
    }

    func requireRegularDistinctImages(_ firstURL: URL, _ secondURL: URL) throws {
        var firstStatus = stat()
        var secondStatus = stat()
        guard Darwin.lstat(firstURL.path, &firstStatus) == 0,
              (firstStatus.st_mode & S_IFMT) == S_IFREG,
              Darwin.lstat(secondURL.path, &secondStatus) == 0,
              (secondStatus.st_mode & S_IFMT) == S_IFREG else {
            throw MacVMError.message("Disk resize publication requires two regular image files.")
        }
        guard firstStatus.st_dev != secondStatus.st_dev || firstStatus.st_ino != secondStatus.st_ino else {
            throw MacVMError.message(
                "The staged disk candidate is the same file as the canonical disk image."
            )
        }
    }

    func requireUnattached(_ imageURLs: [URL]) throws {
        for imageURL in imageURLs {
            let devices = try dependencies.attachments.attachedWholeDisks(imageURL)
            guard devices.isEmpty else {
                throw MacVMError.message(
                    "Disk image \(imageURL.path) is attached; refusing to publish the resize candidate."
                )
            }
        }
    }

    func detachExactImageIfNeeded(_ imageURL: URL) throws {
        let devices = try dependencies.attachments.attachedWholeDisks(imageURL)
        guard Set(devices).count == devices.count else {
            throw MacVMError.message(
                "hdiutil reported duplicate attachments for \(imageURL.path); preserving the image."
            )
        }
        for device in devices.sorted() {
            guard Self.isWholeDiskIdentifier(device) else {
                throw MacVMError.message(
                    "hdiutil reported an invalid attachment for \(imageURL.path); preserving the image."
                )
            }
            try dependencies.attachments.detachWholeDisk(device)
        }
        guard try dependencies.attachments.attachedWholeDisks(imageURL).isEmpty else {
            throw MacVMError.message(
                "Disk image \(imageURL.path) remains attached; preserving transaction evidence."
            )
        }
    }

    func persistDiskSize(
        _ desiredSize: UInt64,
        expectedVMID: UUID,
        allowedCurrentSizes: Set<UInt64>,
        bundle: VMBundle
    ) throws -> VMMetadata {
        let current = try bundle.readMetadata()
        guard current.id == expectedVMID,
              allowedCurrentSizes.contains(current.diskSizeBytes) else {
            throw MacVMError.message(
                "VM metadata no longer matches the recorded disk resize plan; preserving transaction evidence."
            )
        }

        if current.diskSizeBytes != desiredSize {
            _ = try bundle.updateMetadata { metadata in
                guard metadata.id == expectedVMID,
                      allowedCurrentSizes.contains(metadata.diskSizeBytes) else {
                    throw MacVMError.message(
                        "VM metadata changed while committing its disk resize."
                    )
                }
                // No other metadata field is part of this transaction.
                metadata.diskSizeBytes = desiredSize
            }
        }
        try synchronizeFile(bundle.metadataURL)
        try synchronizeDirectory(bundle.url)

        let durableMetadata = try bundle.readMetadata()
        guard durableMetadata.id == expectedVMID,
              durableMetadata.diskSizeBytes == desiredSize else {
            throw MacVMError.message("The committed disk metadata could not be verified.")
        }
        return durableMetadata
    }

    func cleanupStageAndJournal(
        stageURL: URL,
        journal: Journal,
        bundle: VMBundle
    ) throws {
        try validateStageDirectory(stageURL)
        let candidateURL = stageURL.appendingPathComponent("Disk.img", isDirectory: false)
        if try fileKind(at: candidateURL) == .regular {
            try detachExactImageIfNeeded(candidateURL)
        }
        // Recheck after host commands so newly introduced data is never discarded.
        try validateStageDirectory(stageURL)
        if try fileKind(at: stageURL) == .directory {
            try FileManager.default.removeItem(at: stageURL)
            try synchronizeDirectory(bundle.url)
        }

        let journalURL = journalURL(for: bundle)
        do {
            try FileManager.default.removeItem(at: journalURL)
            try synchronizeDirectory(bundle.url)
        } catch {
            // If unlink succeeded but directory synchronization failed, recreate a
            // durable journal rather than reporting successful cleanup without it.
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                try? writeJournal(journal, bundle: bundle)
            }
            throw error
        }
    }

    func readJournal(bundle: VMBundle) throws -> Journal {
        let url = journalURL(for: bundle)
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= 1024 * 1024 else {
            throw MacVMError.message(
                "The disk resize journal is missing, unsafe, or too large; preserving it for inspection."
            )
        }
        do {
            return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        } catch {
            throw MacVMError.message(
                "The disk resize journal is malformed; preserving it for inspection."
            )
        }
    }

    func writeJournal(_ journal: Journal, bundle: VMBundle) throws {
        try validateJournal(journal)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        let finalURL = journalURL(for: bundle)
        let temporaryURL = bundle.url.appendingPathComponent(
            ".\(Self.journalName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw Self.posixError("Couldn't create disk resize journal", path: temporaryURL.path)
        }

        var writeError: Error?
        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw Self.posixError(
                            "Couldn't write disk resize journal",
                            path: temporaryURL.path
                        )
                    }
                    offset += count
                }
            }
            try Self.synchronizeDescriptor(
                descriptor,
                path: temporaryURL.path,
                full: true
            )
        } catch {
            writeError = error
        }
        if Darwin.close(descriptor) != 0, writeError == nil {
            writeError = Self.posixError(
                "Couldn't close disk resize journal",
                path: temporaryURL.path
            )
        }
        if let writeError {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw writeError
        }

        let renameResult = temporaryURL.path.withCString { temporaryPath in
            finalURL.path.withCString { finalPath in
                Darwin.rename(temporaryPath, finalPath)
            }
        }
        guard renameResult == 0 else {
            let error = Self.posixError(
                "Couldn't publish disk resize journal",
                path: finalURL.path
            )
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        try synchronizeDirectory(bundle.url)
    }

    func fileKind(at url: URL) throws -> FileKind {
        var status = stat()
        if Darwin.lstat(url.path, &status) != 0 {
            if errno == ENOENT { return .missing }
            throw Self.posixError("Couldn't inspect disk resize path", path: url.path)
        }
        switch status.st_mode & S_IFMT {
        case S_IFREG:
            return .regular
        case S_IFDIR:
            return .directory
        default:
            return .other
        }
    }

    func synchronizeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.posixError("Couldn't open file for disk resize synchronization", path: url.path)
        }
        defer { _ = Darwin.close(descriptor) }
        try Self.synchronizeDescriptor(descriptor, path: url.path, full: true)
    }

    func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.posixError("Couldn't open directory for disk resize synchronization", path: url.path)
        }
        defer { _ = Darwin.close(descriptor) }
        try Self.synchronizeDescriptor(descriptor, path: url.path, full: false)
    }

    static func synchronizeDescriptor(_ descriptor: Int32, path: String, full: Bool) throws {
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("Couldn't fsync disk resize data", path: path)
        }
        if full, Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            throw posixError("Couldn't fully synchronize disk resize data", path: path)
        }
    }

    static func makeFingerprint(imageURL: URL) throws -> Fingerprint {
        let table = try GUIDPartitionTable(reading: imageURL)
        let geometry = table.geometry
        return Fingerprint(
            logicalSizeBytes: table.diskSizeBytes,
            geometry: GeometryFingerprint(
                diskSizeBytes: geometry.diskSizeBytes,
                sectorCount: geometry.sectorCount,
                primaryHeaderLBA: geometry.primaryHeaderLBA,
                primaryEntriesLBA: geometry.primaryEntriesLBA,
                backupEntriesLBA: geometry.backupEntriesLBA,
                backupHeaderLBA: geometry.backupHeaderLBA,
                firstUsableLBA: geometry.firstUsableLBA,
                lastUsableLBA: geometry.lastUsableLBA,
                partitionEntryCount: geometry.partitionEntryCount,
                partitionEntrySize: geometry.partitionEntrySize,
                partitionEntryArraySectorCount: geometry.partitionEntryArraySectorCount
            ),
            diskGUID: table.diskGUID,
            entries: table.partitions
                .sorted { $0.slotIndex < $1.slotIndex }
                .map { partition in
                    EntryFingerprint(
                        slotIndex: partition.slotIndex,
                        typeGUID: partition.typeGUID,
                        uniqueGUID: partition.uniqueGUID,
                        firstLBA: partition.firstLBA,
                        lastLBA: partition.lastLBA,
                        attributes: partition.attributes,
                        name: partition.name,
                        stableEntryDigest: SHA256.hash(
                            data: partition.rawEntryIdentity.nonLBABytes
                        ).map { String(format: "%02x", $0) }.joined()
                    )
                }
        )
    }

    static func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func attachedWholeDisks(
        for imageURL: URL,
        hdiutilInfo: [String: Any]
    ) throws -> [String] {
        guard let images = hdiutilInfo["images"] as? [[String: Any]] else {
            throw MacVMError.message("hdiutil info did not return a valid images array.")
        }
        let expectedPath = normalizedFileURL(imageURL).path
        var devices: [String] = []
        for image in images {
            guard let path = image["image-path"] as? String, path.hasPrefix("/") else {
                throw MacVMError.message("hdiutil info returned an image without an absolute path.")
            }
            guard normalizedFileURL(URL(fileURLWithPath: path)).path == expectedPath else {
                continue
            }
            guard let entities = image["system-entities"] as? [[String: Any]] else {
                throw MacVMError.message("The attached disk image has no system-entities array.")
            }
            let imageDevices = entities.compactMap { entity -> String? in
                guard entity["content-hint"] as? String == "GUID_partition_scheme",
                      let node = entity["dev-entry"] as? String,
                      node.hasPrefix("/dev/") else {
                    return nil
                }
                let identifier = String(node.dropFirst("/dev/".count))
                return isWholeDiskIdentifier(identifier) ? identifier : nil
            }
            guard imageDevices.count == 1 else {
                throw MacVMError.message(
                    "The attached disk image does not have exactly one GUID whole disk."
                )
            }
            devices.append(imageDevices[0])
        }
        return devices
    }

    static func exchangeImages(_ firstURL: URL, _ secondURL: URL) throws {
        let result = firstURL.path.withCString { firstPath in
            secondURL.path.withCString { secondPath in
                renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw posixError(
                "Couldn't atomically exchange disk resize images",
                path: "\(firstURL.path) and \(secondURL.path)"
            )
        }
    }

    static func isWholeDiskIdentifier(_ value: String) -> Bool {
        guard value.hasPrefix("disk") else { return false }
        let suffix = value.dropFirst(4)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= Character("0").asciiValue! && byte <= Character("9").asciiValue!)
                || (byte >= Character("a").asciiValue! && byte <= Character("f").asciiValue!)
        }
    }

    static func posixError(_ operation: String, path: String) -> MacVMError {
        MacVMError.message("\(operation) at \(path): \(String(cString: strerror(errno)))")
    }

    func ambiguousStateError(
        canonical: ImageClassification,
        stage: ImageClassification,
        journalURL: URL
    ) -> MacVMError {
        MacVMError.message(
            "Disk resize state is ambiguous or was modified (canonical: \(canonical.rawValue), "
                + "stage: \(stage.rawValue)). Preserving images and journal at \(journalURL.path)."
        )
    }
}
