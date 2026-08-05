import CryptoKit
import Darwin
import Foundation

/// Builds and validates a larger disk-image candidate without ever attaching or
/// opening the canonical image for writing.
///
/// The caller owns publication of the returned candidate. This type deliberately
/// stops after producing a detached, fully verified file so a higher-level
/// transaction can atomically install it later.
struct DiskImageGrower {
    enum Phase: String, Equatable, Sendable {
        case validatingInput
        case stagingCandidate
        case relocatingRecovery
        case writingPartitionTable
        case attachingCandidate
        case verifyingBeforeResize
        case resizingContainer
        case verifyingAfterResize
        case detachingCandidate
        case verifyingDetachedCandidate
        case complete
    }

    struct RangeFingerprint: Equatable, Sendable {
        let byteRange: Range<UInt64>
        let sha256: String
    }

    struct RecoveryFingerprints: Equatable, Sendable {
        let source: RangeFingerprint
        let candidate: RangeFingerprint
    }

    struct Result: Equatable, Sendable {
        let sourceImageURL: URL
        let candidateImageURL: URL
        let sourceSizeBytes: UInt64
        let targetSizeBytes: UInt64
        let beforeHostCommands: RecoveryFingerprints
        let afterHostCommands: RecoveryFingerprints
        let wholeDiskIdentifier: String
        let mainPartitionIdentifier: String
        let apfsContainerIdentifier: String
        let finalMainPartitionSizeBytes: UInt64
    }

    typealias PhaseCallback = @Sendable (Phase) -> Void
    typealias FileStager = @Sendable (_ sourceURL: URL, _ candidateURL: URL) throws -> Void

    struct Attachment: Equatable, Sendable {
        let wholeDiskIdentifier: String
        let mainPartitionIdentifier: String
    }

    struct PartitionInfo: Equatable, Sendable {
        let parentWholeDiskIdentifier: String
        let sizeBytes: UInt64
    }

    private struct HostResizeResult {
        let attachment: Attachment
        let containerIdentifier: String
        let finalMainSizeBytes: UInt64
    }

    private struct FileSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private static let hdiutilURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    private static let diskutilURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    private static let copyBufferSize = 1024 * 1024

    private let processRunner: any DiskProcessRunning
    private let fileStager: FileStager

    init(
        processRunner: any DiskProcessRunning = DiskProcessRunner(),
        fileStager: @escaping FileStager = { sourceURL, candidateURL in
            try MacVMFileStager.copyCloneFirst(from: sourceURL, to: candidateURL)
        }
    ) {
        self.processRunner = processRunner
        self.fileStager = fileStager
    }

    /// Stages, grows, host-validates, and detaches a candidate disk image.
    ///
    /// `candidateImageURL` is the final path within the caller's private candidate
    /// directory. Existing content there may be replaced by `MacVMFileStager`.
    func grow(
        sourceImageURL: URL,
        candidateImageURL: URL,
        targetSizeBytes: UInt64,
        phase: PhaseCallback = { _ in }
    ) throws -> Result {
        phase(.validatingInput)
        let sourceURL = Self.normalizedFileURL(sourceImageURL)
        let requestedCandidateURL = Self.normalizedFileURL(candidateImageURL)
        guard sourceURL.path != requestedCandidateURL.path else {
            throw MacVMError.message("The disk growth source and candidate paths must be different.")
        }

        // Check before staging because replacing an attached pre-existing
        // candidate would be unsafe. Every comparison is an exact normalized path
        // comparison, never a basename or substring match.
        try requireUnattached([sourceURL, requestedCandidateURL])

        let sourceTable = try GUIDPartitionTable(reading: sourceURL)
        let intermediateTable = try sourceTable.intermediateLayout(growingTo: targetSizeBytes)
        let initialSourceSnapshot = try Self.snapshot(of: sourceURL)

        phase(.stagingCandidate)
        try fileStager(sourceURL, requestedCandidateURL)
        let candidateURL = Self.normalizedFileURL(requestedCandidateURL)
        guard sourceURL.path != candidateURL.path else {
            throw MacVMError.message("The staged disk candidate resolves to the canonical disk image.")
        }
        try requireUnattached([sourceURL, candidateURL])
        try Self.resizeExactly(
            candidateURL: candidateURL,
            sourceURL: sourceURL,
            targetSizeBytes: targetSizeBytes
        )

        phase(.relocatingRecovery)
        let beforeHostCommands = try Self.relocateRecovery(
            from: sourceURL,
            sourceRange: sourceTable.recoveryPartition.byteRange,
            to: candidateURL,
            candidateRange: intermediateTable.recoveryPartition.byteRange
        )

        phase(.writingPartitionTable)
        try intermediateTable.write(to: candidateURL)
        try Self.synchronize(candidateURL)
        let stagedTable = try GUIDPartitionTable(
            reading: candidateURL,
            expectedSizeBytes: targetSizeBytes,
            allowMainRecoveryGap: true
        )
        try Self.requireIntermediateTable(stagedTable, matches: intermediateTable)
        try requireUnattached([sourceURL, candidateURL])

        phase(.attachingCandidate)
        let hostResult = try withAttachedCandidate(
            candidateURL: candidateURL,
            sourceURL: sourceURL,
            table: stagedTable,
            targetSizeBytes: targetSizeBytes,
            phase: phase
        )

        phase(.verifyingDetachedCandidate)
        try Self.synchronize(candidateURL)
        let finalTable = try GUIDPartitionTable(
            reading: candidateURL,
            expectedSizeBytes: targetSizeBytes
        )
        try Self.requireFinalTable(
            finalTable,
            source: sourceTable,
            intermediate: intermediateTable,
            expectedMainSizeBytes: hostResult.finalMainSizeBytes
        )

        let afterHostCommands = try Self.fingerprints(
            sourceURL: sourceURL,
            sourceRange: sourceTable.recoveryPartition.byteRange,
            candidateURL: candidateURL,
            candidateRange: intermediateTable.recoveryPartition.byteRange
        )
        try Self.requireMatchingRecoveryFingerprints(afterHostCommands)
        guard afterHostCommands.source.sha256 == beforeHostCommands.source.sha256,
              afterHostCommands.candidate.sha256 == beforeHostCommands.candidate.sha256 else {
            throw MacVMError.message(
                "Recovery changed while host disk commands were operating on the candidate."
            )
        }

        let finalSourceSnapshot = try Self.snapshot(of: sourceURL)
        guard finalSourceSnapshot == initialSourceSnapshot else {
            throw MacVMError.message(
                "The canonical disk image changed while its growth candidate was being prepared."
            )
        }
        try requireUnattached([sourceURL, candidateURL])

        phase(.complete)
        return Result(
            sourceImageURL: sourceURL,
            candidateImageURL: candidateURL,
            sourceSizeBytes: sourceTable.diskSizeBytes,
            targetSizeBytes: targetSizeBytes,
            beforeHostCommands: beforeHostCommands,
            afterHostCommands: afterHostCommands,
            wholeDiskIdentifier: hostResult.attachment.wholeDiskIdentifier,
            mainPartitionIdentifier: hostResult.attachment.mainPartitionIdentifier,
            apfsContainerIdentifier: hostResult.containerIdentifier,
            finalMainPartitionSizeBytes: hostResult.finalMainSizeBytes
        )
    }
}

private extension DiskImageGrower {
    private func withAttachedCandidate(
        candidateURL: URL,
        sourceURL: URL,
        table: GUIDPartitionTable,
        targetSizeBytes: UInt64,
        phase: PhaseCallback
    ) throws -> HostResizeResult {
        let attachPropertyList = try processRunner.runPropertyList(
            executableURL: Self.hdiutilURL,
            arguments: ["attach", "-nomount", "-readwrite", "-plist", candidateURL.path]
        )
        let wholeDiskIdentifier: String
        do {
            wholeDiskIdentifier = try Self.wholeDiskIdentifier(from: attachPropertyList)
        } catch {
            let parseError = error
            do {
                try cleanupAttachmentAfterUnparseableAttach(
                    candidateURL: candidateURL,
                    sourceURL: sourceURL
                )
            } catch {
                throw MacVMError.message(
                    "The attached candidate could not be identified: \(Self.errorDescription(parseError)) "
                        + "Cleanup also failed: \(Self.errorDescription(error))"
                )
            }
            throw parseError
        }
        var detachNeeded = true
        // This is a last-resort cleanup for an unexpected exit from any path
        // below. Normal success and error paths detach explicitly so failures can
        // be surfaced rather than discarded.
        defer {
            if detachNeeded {
                _ = try? processRunner.run(
                    executableURL: Self.hdiutilURL,
                    arguments: ["detach", wholeDiskIdentifier]
                )
                try? requireUnattached([sourceURL, candidateURL])
            }
        }

        let attachment: Attachment
        do {
            attachment = try Self.attachment(
                from: attachPropertyList,
                mainPartitionSlot: table.mainPartition.slotIndex
            )
        } catch {
            let parseError = error
            do {
                _ = try processRunner.run(
                    executableURL: Self.hdiutilURL,
                    arguments: ["detach", wholeDiskIdentifier]
                )
                try requireUnattached([sourceURL, candidateURL])
                detachNeeded = false
            } catch {
                throw MacVMError.message(
                    "The attached candidate could not be identified: \(Self.errorDescription(parseError)) "
                        + "Detaching it also failed: \(Self.errorDescription(error))"
                )
            }
            throw parseError
        }

        do {
            phase(.verifyingBeforeResize)
            let initialInfoPropertyList = try processRunner.runPropertyList(
                executableURL: Self.diskutilURL,
                arguments: ["info", "-plist", attachment.mainPartitionIdentifier]
            )
            _ = try Self.validatePartitionInfo(
                initialInfoPropertyList,
                attachment: attachment,
                expectedPartition: table.mainPartition,
                expectedSizeBytes: table.mainPartition.lengthBytes
            )
            _ = try processRunner.run(
                executableURL: Self.diskutilURL,
                arguments: ["verifyDisk", attachment.wholeDiskIdentifier]
            )

            phase(.resizingContainer)
            _ = try processRunner.run(
                executableURL: Self.diskutilURL,
                arguments: [
                    "apfs", "resizeContainer", attachment.mainPartitionIdentifier, "0",
                ]
            )

            phase(.verifyingAfterResize)
            _ = try processRunner.run(
                executableURL: Self.diskutilURL,
                arguments: ["verifyDisk", attachment.wholeDiskIdentifier]
            )

            let finalTable = try GUIDPartitionTable(
                reading: candidateURL,
                expectedSizeBytes: targetSizeBytes
            )
            let expectedMainSize = finalTable.mainPartition.lengthBytes
            let finalInfoPropertyList = try processRunner.runPropertyList(
                executableURL: Self.diskutilURL,
                arguments: ["info", "-plist", attachment.mainPartitionIdentifier]
            )
            _ = try Self.validatePartitionInfo(
                finalInfoPropertyList,
                attachment: attachment,
                expectedPartition: finalTable.mainPartition,
                expectedSizeBytes: expectedMainSize
            )

            // `diskutil info -plist` does not expose the APFS container reference
            // for a physical store. Find it by exact physical-store identity in
            // the structured APFS list instead.
            let apfsPropertyList = try processRunner.runPropertyList(
                executableURL: Self.diskutilURL,
                arguments: ["apfs", "list", "-plist"]
            )
            let containerIdentifier = try Self.validateAPFSContainer(
                apfsPropertyList,
                physicalStoreIdentifier: attachment.mainPartitionIdentifier,
                physicalStoreUUID: finalTable.mainPartition.uniqueGUID,
                expectedCapacityBytes: expectedMainSize
            )

            phase(.detachingCandidate)
            try detach(
                attachment: attachment,
                sourceURL: sourceURL,
                candidateURL: candidateURL
            )
            detachNeeded = false
            return HostResizeResult(
                attachment: attachment,
                containerIdentifier: containerIdentifier,
                finalMainSizeBytes: expectedMainSize
            )
        } catch {
            let operationError = error
            do {
                phase(.detachingCandidate)
                try detach(
                    attachment: attachment,
                    sourceURL: sourceURL,
                    candidateURL: candidateURL
                )
                detachNeeded = false
            } catch {
                throw MacVMError.message(
                    "Disk growth failed: \(Self.errorDescription(operationError)) "
                        + "Detaching the candidate also failed: \(Self.errorDescription(error))"
                )
            }
            throw operationError
        }
    }

    func cleanupAttachmentAfterUnparseableAttach(
        candidateURL: URL,
        sourceURL: URL
    ) throws {
        let propertyList = try processRunner.runPropertyList(
            executableURL: Self.hdiutilURL,
            arguments: ["info", "-plist"]
        )
        let attachedDevices = try Self.attachedWholeDisks(
            for: candidateURL,
            hdiutilInfo: propertyList
        )
        guard attachedDevices.count <= 1 else {
            throw MacVMError.message(
                "The candidate unexpectedly has multiple attached whole disks."
            )
        }
        if let attachedDevice = attachedDevices.first {
            _ = try processRunner.run(
                executableURL: Self.hdiutilURL,
                arguments: ["detach", attachedDevice]
            )
        }
        try requireUnattached([sourceURL, candidateURL])
    }

    func detach(
        attachment: Attachment,
        sourceURL: URL,
        candidateURL: URL
    ) throws {
        _ = try processRunner.run(
            executableURL: Self.hdiutilURL,
            arguments: ["detach", attachment.wholeDiskIdentifier]
        )
        try requireUnattached([sourceURL, candidateURL])
    }

    func requireUnattached(_ imageURLs: [URL]) throws {
        let propertyList = try processRunner.runPropertyList(
            executableURL: Self.hdiutilURL,
            arguments: ["info", "-plist"]
        )
        try Self.requireUnattached(imageURLs, hdiutilInfo: propertyList)
    }

    static func requireUnattached(
        _ imageURLs: [URL],
        hdiutilInfo: [String: Any]
    ) throws {
        let prohibitedPaths = Set(imageURLs.map { normalizedFileURL($0).path })
        guard let images = hdiutilInfo["images"] as? [[String: Any]] else {
            throw MacVMError.message("hdiutil info did not return a valid images array.")
        }
        for image in images {
            guard let path = image["image-path"] as? String, path.hasPrefix("/") else {
                throw MacVMError.message("hdiutil info returned an image without an absolute path.")
            }
            let attachedPath = normalizedFileURL(URL(fileURLWithPath: path)).path
            guard prohibitedPaths.contains(attachedPath) else { continue }
            throw MacVMError.message(
                "Disk image \(attachedPath) is already attached; refusing to grow or modify it."
            )
        }
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
                throw MacVMError.message("The attached candidate has no system-entities array.")
            }
            let imageDevices = entities.compactMap { entity -> String? in
                guard entity["content-hint"] as? String == "GUID_partition_scheme",
                      let node = entity["dev-entry"] as? String,
                      isDeviceNode(node, allowSlice: false) else {
                    return nil
                }
                return String(node.dropFirst("/dev/".count))
            }
            guard imageDevices.count == 1 else {
                throw MacVMError.message(
                    "The attached candidate does not have exactly one GUID whole disk."
                )
            }
            devices.append(imageDevices[0])
        }
        return devices
    }

    static func wholeDiskIdentifier(from propertyList: [String: Any]) throws -> String {
        guard let entities = propertyList["system-entities"] as? [[String: Any]] else {
            throw MacVMError.message("hdiutil attach did not return a system-entities array.")
        }
        let wholeDevices = entities.compactMap { entity -> String? in
            guard entity["content-hint"] as? String == "GUID_partition_scheme",
                  let device = entity["dev-entry"] as? String,
                  isDeviceNode(device, allowSlice: false) else {
                return nil
            }
            return String(device.dropFirst("/dev/".count))
        }
        guard wholeDevices.count == 1, let wholeDevice = wholeDevices.first else {
            throw MacVMError.message(
                "hdiutil attach did not identify exactly one GUID_partition_scheme whole disk."
            )
        }
        return wholeDevice
    }

    static func attachment(
        from propertyList: [String: Any],
        mainPartitionSlot: Int
    ) throws -> Attachment {
        guard let entities = propertyList["system-entities"] as? [[String: Any]] else {
            throw MacVMError.message("hdiutil attach did not return a system-entities array.")
        }
        let wholeDevice = try wholeDiskIdentifier(from: propertyList)
        let mainDevice = "\(wholeDevice)s\(mainPartitionSlot + 1)"
        let expectedNode = "/dev/\(mainDevice)"
        guard entities.filter({ $0["dev-entry"] as? String == expectedNode }).count == 1 else {
            throw MacVMError.message(
                "hdiutil attach did not return the expected main partition device \(expectedNode)."
            )
        }
        return Attachment(
            wholeDiskIdentifier: wholeDevice,
            mainPartitionIdentifier: mainDevice
        )
    }

    static func validatePartitionInfo(
        _ propertyList: [String: Any],
        attachment: Attachment,
        expectedPartition: GUIDPartitionTable.Partition,
        expectedSizeBytes: UInt64
    ) throws -> PartitionInfo {
        guard propertyList["DeviceIdentifier"] as? String == attachment.mainPartitionIdentifier else {
            throw MacVMError.message("diskutil info returned a different partition device.")
        }
        let parent = (propertyList["ParentWholeDisk"] as? String)
            ?? (propertyList["PartOfWhole"] as? String)
        guard parent == attachment.wholeDiskIdentifier else {
            throw MacVMError.message("diskutil info returned a different parent whole disk.")
        }

        let expectedType = expectedPartition.typeGUID
        let content = propertyList["Content"] as? String
        if let rawPartitionType = propertyList["PartitionType"] {
            guard let partitionTypeString = rawPartitionType as? String,
                  UUID(uuidString: partitionTypeString) == expectedType else {
                throw MacVMError.message("diskutil info returned an unexpected GPT partition type.")
            }
        } else {
            guard content == "Apple_APFS"
                    || content?.caseInsensitiveCompare(expectedType.uuidString) == .orderedSame else {
                throw MacVMError.message("diskutil info did not identify the main slice as Apple APFS.")
            }
        }

        guard let diskUUIDString = propertyList["DiskUUID"] as? String,
              UUID(uuidString: diskUUIDString) == expectedPartition.uniqueGUID else {
            throw MacVMError.message("diskutil info returned an unexpected main partition UUID.")
        }
        guard let size = unsignedInteger(propertyList["Size"]), size == expectedSizeBytes else {
            throw MacVMError.message(
                "diskutil info returned an unexpected main partition size; expected \(expectedSizeBytes) bytes."
            )
        }

        return PartitionInfo(
            parentWholeDiskIdentifier: parent!,
            sizeBytes: size
        )
    }

    static func validateAPFSContainer(
        _ propertyList: [String: Any],
        physicalStoreIdentifier: String,
        physicalStoreUUID: UUID,
        expectedCapacityBytes: UInt64
    ) throws -> String {
        guard let containers = propertyList["Containers"] as? [[String: Any]] else {
            throw MacVMError.message("diskutil apfs list did not return a Containers array.")
        }
        let matchingContainers = containers.filter { container in
            guard let stores = container["PhysicalStores"] as? [[String: Any]] else {
                return false
            }
            return stores.contains {
                ($0["DeviceIdentifier"] as? String) == physicalStoreIdentifier
            }
        }
        guard matchingContainers.count == 1, let container = matchingContainers.first else {
            throw MacVMError.message("diskutil did not return exactly one associated APFS container.")
        }
        guard let containerIdentifier = container["ContainerReference"] as? String,
              isDiskIdentifier(containerIdentifier, allowSlice: false) else {
            throw MacVMError.message("The associated APFS container has an invalid identifier.")
        }
        guard unsignedInteger(container["CapacityCeiling"]) == expectedCapacityBytes else {
            throw MacVMError.message(
                "The APFS capacity ceiling is not exactly \(expectedCapacityBytes) bytes."
            )
        }
        guard let stores = container["PhysicalStores"] as? [[String: Any]] else {
            throw MacVMError.message("The APFS container did not report its physical stores.")
        }
        let matchingStores = stores.filter {
            ($0["DeviceIdentifier"] as? String) == physicalStoreIdentifier
        }
        guard matchingStores.count == 1, let store = matchingStores.first else {
            throw MacVMError.message(
                "The APFS container is not associated with the resized physical store."
            )
        }
        guard unsignedInteger(store["Size"]) == expectedCapacityBytes else {
            throw MacVMError.message("The APFS physical-store size does not match its partition.")
        }
        guard let uuidString = store["DiskUUID"] as? String,
              UUID(uuidString: uuidString) == physicalStoreUUID else {
            throw MacVMError.message("The APFS physical store has an unexpected partition UUID.")
        }
        return containerIdentifier
    }
}

private extension DiskImageGrower {
    static func requireIntermediateTable(
        _ actual: GUIDPartitionTable,
        matches expected: GUIDPartitionTable
    ) throws {
        guard actual.geometry == expected.geometry,
              actual.diskGUID == expected.diskGUID,
              actual.partitions == expected.partitions else {
            throw MacVMError.message(
                "The staged candidate does not contain the expected intermediate GUID partition table."
            )
        }
    }

    static func requireFinalTable(
        _ final: GUIDPartitionTable,
        source: GUIDPartitionTable,
        intermediate: GUIDPartitionTable,
        expectedMainSizeBytes: UInt64
    ) throws {
        guard final.geometry == intermediate.geometry,
              final.diskGUID == source.diskGUID,
              final.iscPartition == source.iscPartition,
              final.recoveryPartition == intermediate.recoveryPartition,
              final.mainPartition.rawEntryIdentity == source.mainPartition.rawEntryIdentity,
              final.mainPartition.firstLBA == source.mainPartition.firstLBA,
              final.mainPartition.lastLBA + 1 == final.recoveryPartition.firstLBA,
              final.mainPartition.lengthBytes == expectedMainSizeBytes else {
            throw MacVMError.message(
                "The resized candidate's final GUID partition table does not match the required adjacent layout."
            )
        }
    }

    static func resizeExactly(
        candidateURL: URL,
        sourceURL: URL,
        targetSizeBytes: UInt64
    ) throws {
        guard targetSizeBytes <= UInt64(Int64.max) else {
            throw MacVMError.message("The requested disk size exceeds Darwin file offsets.")
        }
        let sourceDescriptor = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw posixError("Couldn't open canonical disk image", path: sourceURL.path)
        }
        defer { Darwin.close(sourceDescriptor) }

        let candidateDescriptor = Darwin.open(candidateURL.path, O_RDWR | O_CLOEXEC)
        guard candidateDescriptor >= 0 else {
            throw posixError("Couldn't open staged disk candidate", path: candidateURL.path)
        }
        defer { Darwin.close(candidateDescriptor) }

        var sourceStatus = stat()
        var candidateStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0,
              Darwin.fstat(candidateDescriptor, &candidateStatus) == 0 else {
            throw posixError("Couldn't inspect staged disk files", path: candidateURL.path)
        }
        guard sourceStatus.st_dev != candidateStatus.st_dev
                || sourceStatus.st_ino != candidateStatus.st_ino else {
            throw MacVMError.message(
                "The staged disk candidate is the same file as the canonical disk image."
            )
        }
        guard Darwin.ftruncate(candidateDescriptor, off_t(targetSizeBytes)) == 0 else {
            throw posixError("Couldn't resize staged disk candidate", path: candidateURL.path)
        }
        guard Darwin.fstat(candidateDescriptor, &candidateStatus) == 0,
              candidateStatus.st_size >= 0,
              UInt64(candidateStatus.st_size) == targetSizeBytes else {
            throw MacVMError.message(
                "The staged disk candidate was not truncated to exactly \(targetSizeBytes) bytes."
            )
        }
    }

    static func relocateRecovery(
        from sourceURL: URL,
        sourceRange: Range<UInt64>,
        to candidateURL: URL,
        candidateRange: Range<UInt64>
    ) throws -> RecoveryFingerprints {
        guard sourceRange.count == candidateRange.count else {
            throw MacVMError.message("The relocated Recovery range changed byte length.")
        }
        let sourceDescriptor = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw posixError("Couldn't open canonical Recovery source", path: sourceURL.path)
        }
        defer { Darwin.close(sourceDescriptor) }

        let candidateDescriptor = Darwin.open(candidateURL.path, O_RDWR | O_CLOEXEC)
        guard candidateDescriptor >= 0 else {
            throw posixError("Couldn't open staged Recovery destination", path: candidateURL.path)
        }
        defer { Darwin.close(candidateDescriptor) }

        try punch(candidateRange, descriptor: candidateDescriptor, path: candidateURL.path)
        let copiedSparsely = try copySparseExtents(
            sourceDescriptor: sourceDescriptor,
            sourceRange: sourceRange,
            candidateDescriptor: candidateDescriptor,
            candidateRange: candidateRange,
            path: sourceURL.path
        )
        if !copiedSparsely {
            try copyExactly(
                sourceDescriptor: sourceDescriptor,
                sourceRange: sourceRange,
                candidateDescriptor: candidateDescriptor,
                candidateOffset: candidateRange.lowerBound,
                path: sourceURL.path
            )
        }

        let fingerprints = try fingerprints(
            sourceDescriptor: sourceDescriptor,
            sourceRange: sourceRange,
            candidateDescriptor: candidateDescriptor,
            candidateRange: candidateRange,
            sourcePath: sourceURL.path,
            candidatePath: candidateURL.path
        )
        try requireMatchingRecoveryFingerprints(fingerprints)

        // If the old and new ranges overlap, only the no-longer-used prefix may
        // be discarded. This happens strictly after a verified successful copy.
        let obsoleteEnd = min(sourceRange.upperBound, candidateRange.lowerBound)
        if sourceRange.lowerBound < obsoleteEnd {
            try punch(
                sourceRange.lowerBound..<obsoleteEnd,
                descriptor: candidateDescriptor,
                path: candidateURL.path
            )
        }
        return fingerprints
    }

    static func copySparseExtents(
        sourceDescriptor: Int32,
        sourceRange: Range<UInt64>,
        candidateDescriptor: Int32,
        candidateRange: Range<UInt64>,
        path: String
    ) throws -> Bool {
        var cursor = sourceRange.lowerBound
        while cursor < sourceRange.upperBound {
            errno = 0
            let dataOffset = Darwin.lseek(sourceDescriptor, off_t(cursor), SEEK_DATA)
            if dataOffset < 0 {
                if errno == ENXIO { return true }
                if sparseSeekingUnsupported(errno) { return false }
                throw posixError("Couldn't seek to Recovery data", path: path)
            }
            let dataStart = UInt64(dataOffset)
            if dataStart >= sourceRange.upperBound { return true }

            errno = 0
            let holeOffset = Darwin.lseek(sourceDescriptor, dataOffset, SEEK_HOLE)
            if holeOffset < 0 {
                if sparseSeekingUnsupported(errno) { return false }
                throw posixError("Couldn't seek to a Recovery hole", path: path)
            }
            let dataEnd = min(UInt64(holeOffset), sourceRange.upperBound)
            guard dataEnd > dataStart else {
                throw MacVMError.message("Sparse Recovery extent discovery did not make progress.")
            }
            let destinationOffset = candidateRange.lowerBound + (dataStart - sourceRange.lowerBound)
            try copyExactly(
                sourceDescriptor: sourceDescriptor,
                sourceRange: dataStart..<dataEnd,
                candidateDescriptor: candidateDescriptor,
                candidateOffset: destinationOffset,
                path: path
            )
            cursor = dataEnd
        }
        return true
    }

    static func copyExactly(
        sourceDescriptor: Int32,
        sourceRange: Range<UInt64>,
        candidateDescriptor: Int32,
        candidateOffset: UInt64,
        path: String
    ) throws {
        var buffer = [UInt8](repeating: 0, count: copyBufferSize)
        var sourceOffset = sourceRange.lowerBound
        var destinationOffset = candidateOffset
        while sourceOffset < sourceRange.upperBound {
            let requested = Int(min(UInt64(buffer.count), sourceRange.upperBound - sourceOffset))
            let bytesRead = try retryingIO {
                buffer.withUnsafeMutableBytes { bytes in
                    Darwin.pread(sourceDescriptor, bytes.baseAddress, requested, off_t(sourceOffset))
                }
            }
            guard bytesRead > 0 else {
                throw MacVMError.message("Canonical Recovery data ended before its GPT range.")
            }

            var written = 0
            while written < bytesRead {
                let writeCount = try retryingIO {
                    buffer.withUnsafeBytes { bytes in
                        Darwin.pwrite(
                            candidateDescriptor,
                            bytes.baseAddress!.advanced(by: written),
                            bytesRead - written,
                            off_t(destinationOffset + UInt64(written))
                        )
                    }
                }
                guard writeCount > 0 else {
                    throw MacVMError.message("Writing relocated Recovery data made no progress.")
                }
                written += writeCount
            }
            sourceOffset += UInt64(bytesRead)
            destinationOffset += UInt64(bytesRead)
        }
    }

    static func punch(_ range: Range<UInt64>, descriptor: Int32, path: String) throws {
        guard !range.isEmpty else { return }
        var hole = fpunchhole_t()
        hole.fp_offset = off_t(range.lowerBound)
        hole.fp_length = off_t(range.count)
        guard Darwin.fcntl(descriptor, F_PUNCHHOLE, &hole) == 0 else {
            throw posixError("Couldn't punch staged disk range", path: path)
        }
    }

    static func synchronize(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError("Couldn't open staged disk candidate for synchronization", path: url.path)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("Couldn't fsync staged disk candidate", path: url.path)
        }
        guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw posixError("Couldn't fully synchronize staged disk candidate", path: url.path)
        }
    }
}

private extension DiskImageGrower {
    static func fingerprints(
        sourceURL: URL,
        sourceRange: Range<UInt64>,
        candidateURL: URL,
        candidateRange: Range<UInt64>
    ) throws -> RecoveryFingerprints {
        let sourceDescriptor = Darwin.open(sourceURL.path, O_RDONLY | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw posixError("Couldn't open canonical Recovery source", path: sourceURL.path)
        }
        defer { Darwin.close(sourceDescriptor) }
        let candidateDescriptor = Darwin.open(candidateURL.path, O_RDONLY | O_CLOEXEC)
        guard candidateDescriptor >= 0 else {
            throw posixError("Couldn't open staged Recovery destination", path: candidateURL.path)
        }
        defer { Darwin.close(candidateDescriptor) }
        return try fingerprints(
            sourceDescriptor: sourceDescriptor,
            sourceRange: sourceRange,
            candidateDescriptor: candidateDescriptor,
            candidateRange: candidateRange,
            sourcePath: sourceURL.path,
            candidatePath: candidateURL.path
        )
    }

    static func fingerprints(
        sourceDescriptor: Int32,
        sourceRange: Range<UInt64>,
        candidateDescriptor: Int32,
        candidateRange: Range<UInt64>,
        sourcePath: String,
        candidatePath: String
    ) throws -> RecoveryFingerprints {
        RecoveryFingerprints(
            source: RangeFingerprint(
                byteRange: sourceRange,
                sha256: try sha256(
                    descriptor: sourceDescriptor,
                    range: sourceRange,
                    path: sourcePath
                )
            ),
            candidate: RangeFingerprint(
                byteRange: candidateRange,
                sha256: try sha256(
                    descriptor: candidateDescriptor,
                    range: candidateRange,
                    path: candidatePath
                )
            )
        )
    }

    static func sha256(descriptor: Int32, range: Range<UInt64>, path: String) throws -> String {
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: copyBufferSize)
        var offset = range.lowerBound
        while offset < range.upperBound {
            let requested = Int(min(UInt64(buffer.count), range.upperBound - offset))
            let bytesRead = try retryingIO {
                buffer.withUnsafeMutableBytes { bytes in
                    Darwin.pread(descriptor, bytes.baseAddress, requested, off_t(offset))
                }
            }
            guard bytesRead > 0 else {
                throw MacVMError.message("Couldn't hash the complete disk range in \(path).")
            }
            hasher.update(data: Data(buffer[0..<bytesRead]))
            offset += UInt64(bytesRead)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func requireMatchingRecoveryFingerprints(
        _ fingerprints: RecoveryFingerprints
    ) throws {
        guard fingerprints.source.sha256 == fingerprints.candidate.sha256 else {
            throw MacVMError.message(
                "The relocated Recovery partition failed SHA-256 verification."
            )
        }
    }

    private static func snapshot(of url: URL) throws -> FileSnapshot {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0, status.st_size >= 0 else {
            throw posixError("Couldn't inspect canonical disk image", path: url.path)
        }
        return FileSnapshot(
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            size: UInt64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec)
        )
    }

    static func normalizedFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let string = number.stringValue
        guard !string.hasPrefix("-") else { return nil }
        return UInt64(string)
    }

    static func isDeviceNode(_ value: String, allowSlice: Bool) -> Bool {
        guard value.hasPrefix("/dev/") else { return false }
        return isDiskIdentifier(String(value.dropFirst("/dev/".count)), allowSlice: allowSlice)
    }

    static func isDiskIdentifier(_ value: String, allowSlice: Bool) -> Bool {
        guard value.hasPrefix("disk") else { return false }
        let suffix = value.dropFirst(4)
        guard !suffix.isEmpty else { return false }
        if suffix.allSatisfy(\.isNumber) { return true }
        guard allowSlice,
              let separator = suffix.firstIndex(of: "s"),
              separator != suffix.startIndex else {
            return false
        }
        let diskNumber = suffix[..<separator]
        let sliceNumber = suffix[suffix.index(after: separator)...]
        return !sliceNumber.isEmpty
            && diskNumber.allSatisfy(\.isNumber)
            && sliceNumber.allSatisfy(\.isNumber)
    }

    static func sparseSeekingUnsupported(_ errorNumber: Int32) -> Bool {
        errorNumber == EINVAL || errorNumber == ENOTSUP || errorNumber == ENOSYS
    }

    static func retryingIO(_ operation: () -> Int) throws -> Int {
        while true {
            let result = operation()
            if result >= 0 { return result }
            if errno == EINTR { continue }
            throw MacVMError.message("Disk image I/O failed: \(String(cString: strerror(errno))).")
        }
    }

    static func posixError(_ action: String, path: String) -> MacVMError {
        .message("\(action) at \(path): \(String(cString: strerror(errno))).")
    }

    static func errorDescription(_ error: Error) -> String {
        let description = error.localizedDescription
        let limit = 4 * 1024
        guard description.utf8.count > limit else { return description }
        return String(description.prefix(limit)) + " [truncated]"
    }
}
