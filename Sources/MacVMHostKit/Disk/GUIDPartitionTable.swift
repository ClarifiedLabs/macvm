import Darwin
import Foundation

/// IEEE 802.3 CRC-32, as used by GPT headers and partition-entry arrays.
enum IEEECRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return crc ^ UInt32.max
    }
}

/// A validated Apple VM GUID partition table and its two on-disk copies.
///
/// Parsing is intentionally strict. Disk-image growth relies on the normal Apple
/// ISC, system, Recovery ordering rather than attempting to repair an arbitrary
/// GPT. `intermediateLayout(growingTo:)` moves only the Recovery entry; a caller
/// must move the Recovery partition's bytes before writing the returned layout.
struct GUIDPartitionTable {
    static let sectorSizeBytes: UInt64 = 512
    static let alignmentBytes: UInt64 = 4_096

    static let iscPartitionType = UUID(uuidString: "69646961-6700-11AA-AA11-00306543ECAC")!
    static let mainPartitionType = UUID(uuidString: "7C3457EF-0000-11AA-AA11-00306543ECAC")!
    static let recoveryPartitionType = UUID(uuidString: "52637672-7900-11AA-AA11-00306543ECAC")!

    struct Geometry: Equatable {
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

    struct RawEntryIdentity: Equatable {
        /// The zero-based partition-entry slot is part of an entry's identity.
        let slotIndex: Int
        /// The complete raw entry except for first/last LBA (bytes 32..<48).
        let nonLBABytes: Data
    }

    struct Partition: Equatable {
        let slotIndex: Int
        let typeGUID: UUID
        let uniqueGUID: UUID
        let firstLBA: UInt64
        let lastLBA: UInt64
        let attributes: UInt64
        let name: String
        let rawEntryData: Data

        var sectorCount: UInt64 {
            lastLBA - firstLBA + 1
        }

        var byteOffset: UInt64 {
            firstLBA * GUIDPartitionTable.sectorSizeBytes
        }

        var lengthBytes: UInt64 {
            sectorCount * GUIDPartitionTable.sectorSizeBytes
        }

        var byteRange: Range<UInt64> {
            byteOffset..<(byteOffset + lengthBytes)
        }

        var rawEntryIdentity: RawEntryIdentity {
            var nonLBABytes = Data()
            nonLBABytes.append(rawEntryData.subdata(in: 0..<32))
            nonLBABytes.append(rawEntryData.subdata(in: 48..<rawEntryData.count))
            return RawEntryIdentity(slotIndex: slotIndex, nonLBABytes: nonLBABytes)
        }
    }

    let sourceURL: URL
    let geometry: Geometry
    let diskGUID: UUID
    let partitions: [Partition]
    let iscPartition: Partition
    let mainPartition: Partition
    let recoveryPartition: Partition
    let trailingUsableSectorCount: UInt64

    var diskSizeBytes: UInt64 { geometry.diskSizeBytes }
    var sectorCount: UInt64 { geometry.sectorCount }

    private static let gptSignature = Data("EFI PART".utf8)
    private static let gptRevision1: UInt32 = 0x0001_0000
    private static let minimumHeaderSize: UInt32 = 92
    private static let minimumPartitionEntrySize: UInt32 = 128
    private static let maximumPartitionEntryArrayBytes: UInt64 = 64 * 1_024 * 1_024
    private static let alignmentSectors = alignmentBytes / sectorSizeBytes

    private let protectiveMBR: Data
    private let protectiveMBRSlot: Int
    private let primaryHeaderSector: Data
    private let backupHeaderSector: Data
    private let headerSize: UInt32
    private let partitionEntryStorage: Data
    private let obsoleteBackupSectorRanges: [Range<UInt64>]

    /// `allowMainRecoveryGap` is used only while a staged candidate waits for
    /// `diskutil apfs resizeContainer` to extend the main APFS partition. The
    /// canonical installed layout always uses the default strict adjacency.
    init(
        reading url: URL,
        expectedSizeBytes: UInt64? = nil,
        allowMainRecoveryGap: Bool = false
    ) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.ioError(action: "open", url: url, errorNumber: errno)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw Self.ioError(action: "inspect", url: url, errorNumber: errno)
        }
        guard status.st_size >= 0 else {
            throw Self.invalid(url, "the source has a negative byte size")
        }

        let fileSize = UInt64(status.st_size)
        if let expectedSizeBytes, expectedSizeBytes != fileSize {
            throw Self.invalid(
                url,
                "metadata says the disk is \(expectedSizeBytes) bytes, but the file is \(fileSize) bytes"
            )
        }
        guard fileSize % Self.sectorSizeBytes == 0 else {
            throw Self.invalid(
                url,
                "the file size \(fileSize) is not a multiple of the required 512-byte sector size"
            )
        }
        guard fileSize % Self.alignmentBytes == 0 else {
            throw Self.invalid(url, "the file size \(fileSize) is not 4 KiB aligned")
        }

        let sectorCount = fileSize / Self.sectorSizeBytes
        guard sectorCount >= 6 else {
            throw Self.invalid(url, "the disk is too small to contain primary and backup GPT structures")
        }

        let protectiveMBR = try Self.readExactly(
            descriptor: descriptor,
            offset: 0,
            count: Int(Self.sectorSizeBytes),
            url: url
        )
        let protectiveSlot = try Self.validateProtectiveMBR(
            protectiveMBR,
            sectorCount: sectorCount,
            url: url
        )

        let primaryHeaderSector = try Self.readSector(
            descriptor: descriptor,
            lba: 1,
            url: url
        )
        let backupHeaderLBA = sectorCount - 1
        let backupHeaderSector = try Self.readSector(
            descriptor: descriptor,
            lba: backupHeaderLBA,
            url: url
        )
        let primaryHeader = try Self.parseHeader(
            primaryHeaderSector,
            copyName: "primary",
            url: url
        )
        let backupHeader = try Self.parseHeader(
            backupHeaderSector,
            copyName: "backup",
            url: url
        )

        try Self.validateHeaders(
            primary: primaryHeader,
            backup: backupHeader,
            sectorCount: sectorCount,
            url: url
        )

        let entryArrayByteCount = try Self.multiplied(
            UInt64(primaryHeader.partitionEntryCount),
            UInt64(primaryHeader.partitionEntrySize),
            url: url,
            description: "partition-entry array byte count"
        )
        guard entryArrayByteCount > 0 else {
            throw Self.invalid(url, "the GPT declares an empty partition-entry array")
        }
        guard entryArrayByteCount <= Self.maximumPartitionEntryArrayBytes else {
            throw Self.invalid(
                url,
                "the partition-entry array is \(entryArrayByteCount) bytes; the supported maximum is \(Self.maximumPartitionEntryArrayBytes) bytes"
            )
        }
        let roundedEntryBytes = try Self.added(
            entryArrayByteCount,
            Self.sectorSizeBytes - 1,
            url: url,
            description: "rounded partition-entry array byte count"
        )
        let entryArraySectorCount = roundedEntryBytes / Self.sectorSizeBytes

        try Self.validateTableExtents(
            primary: primaryHeader,
            backup: backupHeader,
            entryArraySectorCount: entryArraySectorCount,
            sectorCount: sectorCount,
            url: url
        )

        let storageByteCount = try Self.multiplied(
            entryArraySectorCount,
            Self.sectorSizeBytes,
            url: url,
            description: "partition-entry storage byte count"
        )
        guard storageByteCount <= UInt64(Int.max) else {
            throw Self.invalid(url, "the partition-entry array is too large for this host")
        }

        let primaryEntryStorage = try Self.readSectors(
            descriptor: descriptor,
            firstLBA: primaryHeader.partitionEntriesLBA,
            sectorCount: entryArraySectorCount,
            byteCount: Int(storageByteCount),
            url: url
        )
        let backupEntryStorage = try Self.readSectors(
            descriptor: descriptor,
            firstLBA: backupHeader.partitionEntriesLBA,
            sectorCount: entryArraySectorCount,
            byteCount: Int(storageByteCount),
            url: url
        )
        let entryByteCount = Int(entryArrayByteCount)
        let primaryEntryData = primaryEntryStorage.subdata(in: 0..<entryByteCount)
        let backupEntryData = backupEntryStorage.subdata(in: 0..<entryByteCount)

        guard IEEECRC32.checksum(primaryEntryData) == primaryHeader.partitionEntryArrayCRC32 else {
            throw Self.invalid(url, "the primary partition-entry array CRC does not match its header")
        }
        guard IEEECRC32.checksum(backupEntryData) == backupHeader.partitionEntryArrayCRC32 else {
            throw Self.invalid(url, "the backup partition-entry array CRC does not match its header")
        }

        let primaryEntries = try Self.parseEntries(
            primaryEntryData,
            count: primaryHeader.partitionEntryCount,
            size: primaryHeader.partitionEntrySize,
            copyName: "primary",
            url: url
        )
        let backupEntries = try Self.parseEntries(
            backupEntryData,
            count: backupHeader.partitionEntryCount,
            size: backupHeader.partitionEntrySize,
            copyName: "backup",
            url: url
        )
        try Self.validateSemanticEntryEquality(
            primary: primaryEntries,
            backup: backupEntries,
            url: url
        )

        let usedPartitions = primaryEntries.compactMap(\.partition)
        let validated = try Self.validateAppleLayout(
            usedPartitions,
            firstUsableLBA: primaryHeader.firstUsableLBA,
            lastUsableLBA: primaryHeader.lastUsableLBA,
            allowMainRecoveryGap: allowMainRecoveryGap,
            url: url
        )

        let geometry = Geometry(
            diskSizeBytes: fileSize,
            sectorCount: sectorCount,
            primaryHeaderLBA: primaryHeader.currentLBA,
            primaryEntriesLBA: primaryHeader.partitionEntriesLBA,
            backupEntriesLBA: backupHeader.partitionEntriesLBA,
            backupHeaderLBA: backupHeader.currentLBA,
            firstUsableLBA: primaryHeader.firstUsableLBA,
            lastUsableLBA: primaryHeader.lastUsableLBA,
            partitionEntryCount: primaryHeader.partitionEntryCount,
            partitionEntrySize: primaryHeader.partitionEntrySize,
            partitionEntryArraySectorCount: entryArraySectorCount
        )

        self.init(
            sourceURL: url,
            geometry: geometry,
            diskGUID: primaryHeader.diskGUID,
            partitions: usedPartitions.sorted { $0.firstLBA < $1.firstLBA },
            iscPartition: validated.isc,
            mainPartition: validated.main,
            recoveryPartition: validated.recovery,
            trailingUsableSectorCount: validated.trailingSlack,
            protectiveMBR: protectiveMBR,
            protectiveMBRSlot: protectiveSlot,
            primaryHeaderSector: primaryHeaderSector,
            backupHeaderSector: backupHeaderSector,
            headerSize: primaryHeader.headerSize,
            partitionEntryStorage: primaryEntryStorage,
            obsoleteBackupSectorRanges: []
        )
    }

    /// Returns the GPT layout used while growing the main APFS partition.
    ///
    /// The Recovery partition keeps its length, entry slot, GUIDs, attributes,
    /// name, and any implementation-specific entry bytes. Its LBA range moves to
    /// the end of the enlarged usable range. ISC and the main partition remain
    /// byte-for-byte unchanged, leaving free space between main and Recovery for
    /// the later APFS resize step.
    func intermediateLayout(growingTo newSizeBytes: UInt64) throws -> GUIDPartitionTable {
        guard newSizeBytes > geometry.diskSizeBytes else {
            throw Self.invalid(
                sourceURL,
                "GPT growth requires a size greater than \(geometry.diskSizeBytes) bytes; received \(newSizeBytes)"
            )
        }
        guard newSizeBytes % Self.alignmentBytes == 0 else {
            throw Self.invalid(sourceURL, "the requested size \(newSizeBytes) is not 4 KiB aligned")
        }
        guard newSizeBytes <= UInt64(Int64.max) else {
            throw Self.invalid(sourceURL, "the requested size is too large for Darwin file offsets")
        }

        let newSectorCount = newSizeBytes / Self.sectorSizeBytes
        let newBackupHeaderLBA = newSectorCount - 1
        guard newBackupHeaderLBA > geometry.partitionEntryArraySectorCount else {
            throw Self.invalid(sourceURL, "the requested size cannot contain a backup GPT")
        }
        let newBackupEntriesLBA = newBackupHeaderLBA - geometry.partitionEntryArraySectorCount
        guard newBackupEntriesLBA > geometry.firstUsableLBA else {
            throw Self.invalid(sourceURL, "the requested size leaves no usable partition space")
        }
        let newLastUsableLBA = newBackupEntriesLBA - 1
        guard newLastUsableLBA > trailingUsableSectorCount else {
            throw Self.invalid(sourceURL, "the requested size cannot preserve GPT trailing slack")
        }

        let recoveryLastLBA = newLastUsableLBA - trailingUsableSectorCount
        let recoveryLength = recoveryPartition.sectorCount
        guard recoveryLastLBA >= recoveryLength - 1 else {
            throw Self.invalid(sourceURL, "the requested size cannot contain the Recovery partition")
        }
        let recoveryFirstLBA = recoveryLastLBA - (recoveryLength - 1)
        guard recoveryFirstLBA > mainPartition.lastLBA else {
            throw Self.invalid(sourceURL, "the relocated Recovery partition would overlap the main partition")
        }
        guard recoveryFirstLBA % Self.alignmentSectors == 0 else {
            throw Self.invalid(sourceURL, "the relocated Recovery partition start would not be 4 KiB aligned")
        }
        let recoveryEndLBA = try Self.added(
            recoveryLastLBA,
            1,
            url: sourceURL,
            description: "relocated Recovery end LBA"
        )
        guard recoveryEndLBA % Self.alignmentSectors == 0 else {
            throw Self.invalid(sourceURL, "the relocated Recovery partition end would not be 4 KiB aligned")
        }

        let entrySize = Int(geometry.partitionEntrySize)
        let entryOffset = recoveryPartition.slotIndex * entrySize
        var newEntryStorage = partitionEntryStorage
        newEntryStorage.setUInt64LE(recoveryFirstLBA, at: entryOffset + 32)
        newEntryStorage.setUInt64LE(recoveryLastLBA, at: entryOffset + 40)
        let newRawRecoveryEntry = newEntryStorage.subdata(in: entryOffset..<(entryOffset + entrySize))
        let newRecovery = Partition(
            slotIndex: recoveryPartition.slotIndex,
            typeGUID: recoveryPartition.typeGUID,
            uniqueGUID: recoveryPartition.uniqueGUID,
            firstLBA: recoveryFirstLBA,
            lastLBA: recoveryLastLBA,
            attributes: recoveryPartition.attributes,
            name: recoveryPartition.name,
            rawEntryData: newRawRecoveryEntry
        )
        guard newRecovery.rawEntryIdentity == recoveryPartition.rawEntryIdentity else {
            throw Self.invalid(sourceURL, "relocating Recovery unexpectedly changed its raw entry identity")
        }

        let newPartitions = partitions.map { partition in
            partition.slotIndex == recoveryPartition.slotIndex ? newRecovery : partition
        }.sorted { $0.firstLBA < $1.firstLBA }
        let newGeometry = Geometry(
            diskSizeBytes: newSizeBytes,
            sectorCount: newSectorCount,
            primaryHeaderLBA: geometry.primaryHeaderLBA,
            primaryEntriesLBA: geometry.primaryEntriesLBA,
            backupEntriesLBA: newBackupEntriesLBA,
            backupHeaderLBA: newBackupHeaderLBA,
            firstUsableLBA: geometry.firstUsableLBA,
            lastUsableLBA: newLastUsableLBA,
            partitionEntryCount: geometry.partitionEntryCount,
            partitionEntrySize: geometry.partitionEntrySize,
            partitionEntryArraySectorCount: geometry.partitionEntryArraySectorCount
        )
        let oldBackupEnd = try Self.added(
            geometry.backupHeaderLBA,
            1,
            url: sourceURL,
            description: "old backup GPT end LBA"
        )

        return GUIDPartitionTable(
            sourceURL: sourceURL,
            geometry: newGeometry,
            diskGUID: diskGUID,
            partitions: newPartitions,
            iscPartition: iscPartition,
            mainPartition: mainPartition,
            recoveryPartition: newRecovery,
            trailingUsableSectorCount: trailingUsableSectorCount,
            protectiveMBR: protectiveMBR,
            protectiveMBRSlot: protectiveMBRSlot,
            primaryHeaderSector: primaryHeaderSector,
            backupHeaderSector: backupHeaderSector,
            headerSize: headerSize,
            partitionEntryStorage: newEntryStorage,
            obsoleteBackupSectorRanges: obsoleteBackupSectorRanges
                + [geometry.backupEntriesLBA..<oldBackupEnd]
        )
    }

    /// Writes the represented PMBR and both GPT copies to an already-sized file.
    /// Recovery partition contents are not copied by this method.
    func write(to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw Self.ioError(action: "open for GPT writing", url: url, errorNumber: errno)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw Self.ioError(action: "inspect before GPT writing", url: url, errorNumber: errno)
        }
        guard status.st_size >= 0, UInt64(status.st_size) == geometry.diskSizeBytes else {
            let actualSize = status.st_size < 0 ? "an invalid size" : "\(UInt64(status.st_size)) bytes"
            throw MacVMError.message(
                "Couldn't write the GUID partition table to \(url.path): the destination is \(actualSize), expected exactly \(geometry.diskSizeBytes) bytes."
            )
        }

        let entryByteCount = try Self.multiplied(
            UInt64(geometry.partitionEntryCount),
            UInt64(geometry.partitionEntrySize),
            url: url,
            description: "partition-entry array byte count"
        )
        guard entryByteCount <= UInt64(partitionEntryStorage.count) else {
            throw Self.invalid(url, "the in-memory partition-entry array is truncated")
        }
        let entryData = partitionEntryStorage.subdata(in: 0..<Int(entryByteCount))
        let entryCRC = IEEECRC32.checksum(entryData)

        let primaryHeader = Self.updatedHeader(
            primaryHeaderSector,
            currentLBA: geometry.primaryHeaderLBA,
            backupLBA: geometry.backupHeaderLBA,
            firstUsableLBA: geometry.firstUsableLBA,
            lastUsableLBA: geometry.lastUsableLBA,
            partitionEntriesLBA: geometry.primaryEntriesLBA,
            entryCRC: entryCRC,
            headerSize: headerSize
        )
        let backupHeader = Self.updatedHeader(
            backupHeaderSector,
            currentLBA: geometry.backupHeaderLBA,
            backupLBA: geometry.primaryHeaderLBA,
            firstUsableLBA: geometry.firstUsableLBA,
            lastUsableLBA: geometry.lastUsableLBA,
            partitionEntriesLBA: geometry.backupEntriesLBA,
            entryCRC: entryCRC,
            headerSize: headerSize
        )
        let updatedPMBR = Self.updatedProtectiveMBR(
            protectiveMBR,
            slot: protectiveMBRSlot,
            sectorCount: geometry.sectorCount
        )

        try zeroObsoleteBackupStructures(descriptor: descriptor, url: url)

        // Commit the backup first so a failure before the primary update leaves
        // the old primary as the authoritative copy.
        try Self.writeExactly(
            partitionEntryStorage,
            descriptor: descriptor,
            offset: try Self.byteOffset(forLBA: geometry.backupEntriesLBA, url: url),
            url: url
        )
        try Self.writeExactly(
            backupHeader,
            descriptor: descriptor,
            offset: try Self.byteOffset(forLBA: geometry.backupHeaderLBA, url: url),
            url: url
        )
        try Self.writeExactly(
            partitionEntryStorage,
            descriptor: descriptor,
            offset: try Self.byteOffset(forLBA: geometry.primaryEntriesLBA, url: url),
            url: url
        )
        try Self.writeExactly(
            primaryHeader,
            descriptor: descriptor,
            offset: try Self.byteOffset(forLBA: geometry.primaryHeaderLBA, url: url),
            url: url
        )
        try Self.writeExactly(updatedPMBR, descriptor: descriptor, offset: 0, url: url)

        guard Darwin.fsync(descriptor) == 0 else {
            throw Self.ioError(action: "flush GPT changes to", url: url, errorNumber: errno)
        }
    }

    private init(
        sourceURL: URL,
        geometry: Geometry,
        diskGUID: UUID,
        partitions: [Partition],
        iscPartition: Partition,
        mainPartition: Partition,
        recoveryPartition: Partition,
        trailingUsableSectorCount: UInt64,
        protectiveMBR: Data,
        protectiveMBRSlot: Int,
        primaryHeaderSector: Data,
        backupHeaderSector: Data,
        headerSize: UInt32,
        partitionEntryStorage: Data,
        obsoleteBackupSectorRanges: [Range<UInt64>]
    ) {
        self.sourceURL = sourceURL
        self.geometry = geometry
        self.diskGUID = diskGUID
        self.partitions = partitions
        self.iscPartition = iscPartition
        self.mainPartition = mainPartition
        self.recoveryPartition = recoveryPartition
        self.trailingUsableSectorCount = trailingUsableSectorCount
        self.protectiveMBR = protectiveMBR
        self.protectiveMBRSlot = protectiveMBRSlot
        self.primaryHeaderSector = primaryHeaderSector
        self.backupHeaderSector = backupHeaderSector
        self.headerSize = headerSize
        self.partitionEntryStorage = partitionEntryStorage
        self.obsoleteBackupSectorRanges = obsoleteBackupSectorRanges
    }
}

private extension GUIDPartitionTable {
    struct Header {
        let revision: UInt32
        let headerSize: UInt32
        let currentLBA: UInt64
        let backupLBA: UInt64
        let firstUsableLBA: UInt64
        let lastUsableLBA: UInt64
        let diskGUID: UUID
        let partitionEntriesLBA: UInt64
        let partitionEntryCount: UInt32
        let partitionEntrySize: UInt32
        let partitionEntryArrayCRC32: UInt32
    }

    struct ParsedEntry {
        let isUsed: Bool
        let semanticBytes: Data?
        let partition: Partition?
    }

    static func parseHeader(_ sector: Data, copyName: String, url: URL) throws -> Header {
        guard sector.count == Int(sectorSizeBytes) else {
            throw invalid(url, "the \(copyName) GPT header sector is truncated")
        }
        guard sector.subdata(in: 0..<8) == gptSignature else {
            throw invalid(url, "the \(copyName) GPT signature is missing")
        }

        let revision = sector.uint32LE(at: 8)
        guard revision == gptRevision1 else {
            throw invalid(
                url,
                "the \(copyName) GPT revision is 0x\(String(revision, radix: 16)); only revision 1.0 is supported"
            )
        }
        let headerSize = sector.uint32LE(at: 12)
        guard headerSize >= minimumHeaderSize, headerSize <= UInt32(sectorSizeBytes) else {
            throw invalid(
                url,
                "the \(copyName) GPT header size \(headerSize) is outside \(minimumHeaderSize)...\(sectorSizeBytes) bytes"
            )
        }
        guard sector.uint32LE(at: 20) == 0 else {
            throw invalid(url, "the \(copyName) GPT reserved header field is nonzero")
        }

        let storedCRC = sector.uint32LE(at: 16)
        var crcData = sector.subdata(in: 0..<Int(headerSize))
        crcData.setUInt32LE(0, at: 16)
        guard IEEECRC32.checksum(crcData) == storedCRC else {
            throw invalid(url, "the \(copyName) GPT header CRC does not match")
        }

        let entrySize = sector.uint32LE(at: 84)
        guard entrySize >= minimumPartitionEntrySize, entrySize % 8 == 0 else {
            throw invalid(
                url,
                "the \(copyName) GPT partition-entry size \(entrySize) is smaller than 128 bytes or not a multiple of 8"
            )
        }

        return Header(
            revision: revision,
            headerSize: headerSize,
            currentLBA: sector.uint64LE(at: 24),
            backupLBA: sector.uint64LE(at: 32),
            firstUsableLBA: sector.uint64LE(at: 40),
            lastUsableLBA: sector.uint64LE(at: 48),
            diskGUID: GPTGUID.decode(sector.subdata(in: 56..<72)),
            partitionEntriesLBA: sector.uint64LE(at: 72),
            partitionEntryCount: sector.uint32LE(at: 80),
            partitionEntrySize: entrySize,
            partitionEntryArrayCRC32: sector.uint32LE(at: 88)
        )
    }

    static func validateHeaders(
        primary: Header,
        backup: Header,
        sectorCount: UInt64,
        url: URL
    ) throws {
        let finalLBA = sectorCount - 1
        guard primary.currentLBA == 1 else {
            throw invalid(url, "the primary GPT header claims LBA \(primary.currentLBA), expected LBA 1")
        }
        guard backup.currentLBA == finalLBA else {
            throw invalid(
                url,
                "the backup GPT header claims LBA \(backup.currentLBA), expected the final LBA \(finalLBA)"
            )
        }
        guard primary.backupLBA == backup.currentLBA, backup.backupLBA == primary.currentLBA else {
            throw invalid(url, "the primary and backup GPT headers do not point to each other")
        }
        guard primary.revision == backup.revision,
              primary.headerSize == backup.headerSize,
              primary.firstUsableLBA == backup.firstUsableLBA,
              primary.lastUsableLBA == backup.lastUsableLBA,
              primary.diskGUID == backup.diskGUID,
              primary.partitionEntryCount == backup.partitionEntryCount,
              primary.partitionEntrySize == backup.partitionEntrySize else {
            throw invalid(url, "the primary and backup GPT headers disagree on disk geometry")
        }
        guard primary.firstUsableLBA <= primary.lastUsableLBA else {
            throw invalid(url, "the GPT usable LBA range is reversed")
        }
        guard primary.lastUsableLBA < sectorCount else {
            throw invalid(url, "the GPT usable LBA range extends beyond the disk")
        }
    }

    static func validateTableExtents(
        primary: Header,
        backup: Header,
        entryArraySectorCount: UInt64,
        sectorCount: UInt64,
        url: URL
    ) throws {
        guard primary.partitionEntriesLBA == primary.currentLBA + 1 else {
            throw invalid(url, "the primary partition-entry array does not immediately follow its header")
        }
        let primaryEntryEnd = try added(
            primary.partitionEntriesLBA,
            entryArraySectorCount,
            url: url,
            description: "primary partition-entry array end LBA"
        )
        guard primaryEntryEnd <= primary.firstUsableLBA else {
            throw invalid(url, "the primary partition-entry array overlaps the usable disk range")
        }

        guard backup.currentLBA >= entryArraySectorCount else {
            throw invalid(url, "the backup GPT has no room for its partition-entry array")
        }
        let expectedBackupEntriesLBA = backup.currentLBA - entryArraySectorCount
        guard backup.partitionEntriesLBA == expectedBackupEntriesLBA else {
            throw invalid(url, "the backup partition-entry array does not immediately precede its header")
        }
        guard backup.partitionEntriesLBA > backup.lastUsableLBA else {
            throw invalid(url, "the backup partition-entry array overlaps the usable disk range")
        }
        guard backup.currentLBA < sectorCount else {
            throw invalid(url, "the backup GPT header extends beyond the disk")
        }
    }

    static func parseEntries(
        _ data: Data,
        count: UInt32,
        size: UInt32,
        copyName: String,
        url: URL
    ) throws -> [ParsedEntry] {
        let entrySize = Int(size)
        var result: [ParsedEntry] = []
        result.reserveCapacity(Int(count))

        for slot in 0..<Int(count) {
            let start = slot * entrySize
            let end = start + entrySize
            guard end <= data.count else {
                throw invalid(url, "the \(copyName) partition entry in slot \(slot + 1) is truncated")
            }
            let rawEntry = data.subdata(in: start..<end)
            let rawTypeGUID = rawEntry.subdata(in: 0..<16)
            let isUsed = rawTypeGUID.contains { $0 != 0 }
            guard isUsed else {
                result.append(ParsedEntry(isUsed: false, semanticBytes: nil, partition: nil))
                continue
            }

            let rawUniqueGUID = rawEntry.subdata(in: 16..<32)
            guard rawUniqueGUID.contains(where: { $0 != 0 }) else {
                throw invalid(url, "the \(copyName) partition entry in slot \(slot + 1) has a zero unique GUID")
            }
            let firstLBA = rawEntry.uint64LE(at: 32)
            let lastLBA = rawEntry.uint64LE(at: 40)
            guard firstLBA <= lastLBA else {
                throw invalid(url, "the \(copyName) partition entry in slot \(slot + 1) has a reversed LBA range")
            }

            let nameData = rawEntry.subdata(in: 56..<128)
            var nameCodeUnits: [UInt16] = []
            nameCodeUnits.reserveCapacity(36)
            for offset in stride(from: 0, to: nameData.count, by: 2) {
                let codeUnit = nameData.uint16LE(at: offset)
                if codeUnit == 0 { break }
                nameCodeUnits.append(codeUnit)
            }
            let name = String(decoding: nameCodeUnits, as: UTF16.self)
            let partition = Partition(
                slotIndex: slot,
                typeGUID: GPTGUID.decode(rawTypeGUID),
                uniqueGUID: GPTGUID.decode(rawUniqueGUID),
                firstLBA: firstLBA,
                lastLBA: lastLBA,
                attributes: rawEntry.uint64LE(at: 48),
                name: name,
                rawEntryData: rawEntry
            )
            result.append(
                ParsedEntry(
                    isUsed: true,
                    semanticBytes: rawEntry,
                    partition: partition
                )
            )
        }
        return result
    }

    static func validateSemanticEntryEquality(
        primary: [ParsedEntry],
        backup: [ParsedEntry],
        url: URL
    ) throws {
        guard primary.count == backup.count else {
            throw invalid(url, "the primary and backup partition-entry arrays have different lengths")
        }
        for slot in primary.indices {
            guard primary[slot].isUsed == backup[slot].isUsed else {
                throw invalid(
                    url,
                    "the primary and backup GPT copies disagree whether partition slot \(slot + 1) is used"
                )
            }
            if primary[slot].isUsed, primary[slot].semanticBytes != backup[slot].semanticBytes {
                throw invalid(
                    url,
                    "the primary and backup GPT copies disagree on partition slot \(slot + 1)"
                )
            }
        }
    }

    static func validateAppleLayout(
        _ partitions: [Partition],
        firstUsableLBA: UInt64,
        lastUsableLBA: UInt64,
        allowMainRecoveryGap: Bool,
        url: URL
    ) throws -> (isc: Partition, main: Partition, recovery: Partition, trailingSlack: UInt64) {
        guard partitions.count == 3 else {
            throw invalid(
                url,
                "expected exactly ISC, main APFS, and Recovery partitions; found \(partitions.count) used entries"
            )
        }

        for partition in partitions {
            guard partition.firstLBA >= firstUsableLBA, partition.lastLBA <= lastUsableLBA else {
                throw invalid(
                    url,
                    "partition slot \(partition.slotIndex + 1) lies outside the GPT usable LBA range"
                )
            }
            guard partition.firstLBA % alignmentSectors == 0 else {
                throw invalid(url, "partition slot \(partition.slotIndex + 1) is not 4 KiB start-aligned")
            }
            let endLBA = try added(
                partition.lastLBA,
                1,
                url: url,
                description: "partition slot \(partition.slotIndex + 1) end LBA"
            )
            guard endLBA % alignmentSectors == 0 else {
                throw invalid(url, "partition slot \(partition.slotIndex + 1) is not 4 KiB end-aligned")
            }
        }

        let sorted = partitions.sorted { lhs, rhs in
            lhs.firstLBA == rhs.firstLBA ? lhs.lastLBA < rhs.lastLBA : lhs.firstLBA < rhs.firstLBA
        }
        for pairIndex in 1..<sorted.count {
            guard sorted[pairIndex - 1].lastLBA < sorted[pairIndex].firstLBA else {
                throw invalid(
                    url,
                    "partition slots \(sorted[pairIndex - 1].slotIndex + 1) and \(sorted[pairIndex].slotIndex + 1) overlap"
                )
            }
        }

        let iscMatches = partitions.filter { $0.typeGUID == iscPartitionType }
        let mainMatches = partitions.filter { $0.typeGUID == mainPartitionType }
        let recoveryMatches = partitions.filter { $0.typeGUID == recoveryPartitionType }
        guard iscMatches.count == 1, mainMatches.count == 1, recoveryMatches.count == 1 else {
            throw invalid(
                url,
                "expected one ISC (\(iscPartitionType.uuidString)), one main APFS (\(mainPartitionType.uuidString)), and one Recovery (\(recoveryPartitionType.uuidString)) partition"
            )
        }

        let isc = iscMatches[0]
        let main = mainMatches[0]
        let recovery = recoveryMatches[0]
        guard isc.slotIndex < main.slotIndex, main.slotIndex < recovery.slotIndex else {
            throw invalid(url, "ISC, main APFS, and Recovery entries are not in partition-slot order")
        }
        guard sorted.map(\.slotIndex) == [isc.slotIndex, main.slotIndex, recovery.slotIndex] else {
            throw invalid(url, "ISC, main APFS, and Recovery partitions are not in physical disk order")
        }
        let iscEnd = try added(isc.lastLBA, 1, url: url, description: "ISC end LBA")
        let mainEnd = try added(main.lastLBA, 1, url: url, description: "main APFS end LBA")
        guard iscEnd == main.firstLBA else {
            throw invalid(url, "ISC and main APFS partitions are not adjacent")
        }
        if allowMainRecoveryGap {
            guard mainEnd <= recovery.firstLBA else {
                throw invalid(url, "the staged main APFS and Recovery partitions overlap")
            }
        } else {
            guard mainEnd == recovery.firstLBA else {
                throw invalid(url, "main APFS and Recovery partitions are not adjacent")
            }
        }
        guard recovery.lastLBA < lastUsableLBA else {
            throw invalid(url, "the Recovery partition does not leave required trailing usable-sector slack")
        }
        let trailingSlack = lastUsableLBA - recovery.lastLBA
        guard trailingSlack < alignmentSectors else {
            throw invalid(
                url,
                "the Recovery partition leaves \(trailingSlack) trailing usable sectors; expected only 4 KiB alignment slack"
            )
        }

        return (isc, main, recovery, trailingSlack)
    }

    static func validateProtectiveMBR(_ sector: Data, sectorCount: UInt64, url: URL) throws -> Int {
        guard sector.count == Int(sectorSizeBytes) else {
            throw invalid(url, "the protective MBR sector is truncated")
        }
        guard sector[510] == 0x55, sector[511] == 0xAA else {
            throw invalid(url, "the protective MBR is missing its 0x55AA signature")
        }

        var protectiveSlots: [Int] = []
        for slot in 0..<4 {
            let start = 446 + slot * 16
            let record = sector.subdata(in: start..<(start + 16))
            if record.allSatisfy({ $0 == 0 }) { continue }
            guard record[4] == 0xEE else {
                throw invalid(url, "the MBR is hybrid; partition slot \(slot + 1) is not protective type 0xEE")
            }
            guard record[0] == 0 else {
                throw invalid(url, "the protective MBR partition is unexpectedly marked bootable")
            }
            protectiveSlots.append(slot)
        }
        guard protectiveSlots.count == 1, let slot = protectiveSlots.first else {
            throw invalid(url, "the MBR must contain exactly one nonhybrid protective 0xEE partition")
        }

        let start = 446 + slot * 16
        guard sector.uint32LE(at: start + 8) == 1 else {
            throw invalid(url, "the protective MBR partition does not begin at LBA 1")
        }
        let expectedSectorCount = UInt32(min(sectorCount - 1, UInt64(UInt32.max)))
        guard sector.uint32LE(at: start + 12) == expectedSectorCount else {
            throw invalid(
                url,
                "the protective MBR covers \(sector.uint32LE(at: start + 12)) sectors, expected \(expectedSectorCount)"
            )
        }
        return slot
    }

    static func updatedProtectiveMBR(_ source: Data, slot: Int, sectorCount: UInt64) -> Data {
        var result = source
        let start = 446 + slot * 16
        result[start] = 0
        result[start + 4] = 0xEE
        result.setUInt32LE(1, at: start + 8)
        result.setUInt32LE(UInt32(min(sectorCount - 1, UInt64(UInt32.max))), at: start + 12)
        result[510] = 0x55
        result[511] = 0xAA
        return result
    }

    static func updatedHeader(
        _ source: Data,
        currentLBA: UInt64,
        backupLBA: UInt64,
        firstUsableLBA: UInt64,
        lastUsableLBA: UInt64,
        partitionEntriesLBA: UInt64,
        entryCRC: UInt32,
        headerSize: UInt32
    ) -> Data {
        var result = source
        result.setUInt64LE(currentLBA, at: 24)
        result.setUInt64LE(backupLBA, at: 32)
        result.setUInt64LE(firstUsableLBA, at: 40)
        result.setUInt64LE(lastUsableLBA, at: 48)
        result.setUInt64LE(partitionEntriesLBA, at: 72)
        result.setUInt32LE(entryCRC, at: 88)
        result.setUInt32LE(0, at: 16)
        let crc = IEEECRC32.checksum(result.subdata(in: 0..<Int(headerSize)))
        result.setUInt32LE(crc, at: 16)
        return result
    }

    func zeroObsoleteBackupStructures(descriptor: Int32, url: URL) throws {
        guard !obsoleteBackupSectorRanges.isEmpty else { return }

        let primaryEntriesEnd = try Self.added(
            geometry.primaryEntriesLBA,
            geometry.partitionEntryArraySectorCount,
            url: url,
            description: "primary partition-entry array end LBA"
        )
        let backupEntriesEnd = try Self.added(
            geometry.backupEntriesLBA,
            geometry.partitionEntryArraySectorCount,
            url: url,
            description: "backup partition-entry array end LBA"
        )
        let backupHeaderEnd = try Self.added(
            geometry.backupHeaderLBA,
            1,
            url: url,
            description: "backup header end LBA"
        )
        var protectedRanges: [Range<UInt64>] = [
            0..<2,
            geometry.primaryEntriesLBA..<primaryEntriesEnd,
            geometry.backupEntriesLBA..<backupEntriesEnd,
            geometry.backupHeaderLBA..<backupHeaderEnd,
        ]
        for partition in partitions {
            let end = try Self.added(
                partition.lastLBA,
                1,
                url: url,
                description: "partition slot \(partition.slotIndex + 1) end LBA"
            )
            protectedRanges.append(partition.firstLBA..<end)
        }

        var safeRanges = obsoleteBackupSectorRanges
        for protectedRange in protectedRanges {
            safeRanges = safeRanges.flatMap { Self.subtract(protectedRange, from: $0) }
        }

        let maximumZeroSectors: UInt64 = 2_048
        let maximumZeroBytes = Int(maximumZeroSectors * Self.sectorSizeBytes)
        let zeros = Data(count: maximumZeroBytes)
        for range in safeRanges where !range.isEmpty {
            var lba = range.lowerBound
            while lba < range.upperBound {
                let sectorCount = min(maximumZeroSectors, range.upperBound - lba)
                let byteCount = Int(sectorCount * Self.sectorSizeBytes)
                try Self.writeExactly(
                    zeros.prefixData(byteCount),
                    descriptor: descriptor,
                    offset: try Self.byteOffset(forLBA: lba, url: url),
                    url: url
                )
                lba += sectorCount
            }
        }
    }

    static func subtract(_ removed: Range<UInt64>, from source: Range<UInt64>) -> [Range<UInt64>] {
        guard removed.lowerBound < source.upperBound, removed.upperBound > source.lowerBound else {
            return [source]
        }
        var result: [Range<UInt64>] = []
        if removed.lowerBound > source.lowerBound {
            result.append(source.lowerBound..<min(removed.lowerBound, source.upperBound))
        }
        if removed.upperBound < source.upperBound {
            result.append(max(removed.upperBound, source.lowerBound)..<source.upperBound)
        }
        return result
    }

    static func readSector(descriptor: Int32, lba: UInt64, url: URL) throws -> Data {
        try readExactly(
            descriptor: descriptor,
            offset: try byteOffset(forLBA: lba, url: url),
            count: Int(sectorSizeBytes),
            url: url
        )
    }

    static func readSectors(
        descriptor: Int32,
        firstLBA: UInt64,
        sectorCount: UInt64,
        byteCount: Int,
        url: URL
    ) throws -> Data {
        let computedByteCount = try multiplied(
            sectorCount,
            sectorSizeBytes,
            url: url,
            description: "sector read byte count"
        )
        guard computedByteCount == UInt64(byteCount) else {
            throw invalid(url, "an internal GPT sector-read size check failed")
        }
        return try readExactly(
            descriptor: descriptor,
            offset: try byteOffset(forLBA: firstLBA, url: url),
            count: byteCount,
            url: url
        )
    }

    static func readExactly(descriptor: Int32, offset: UInt64, count: Int, url: URL) throws -> Data {
        guard offset <= UInt64(Int64.max) else {
            throw invalid(url, "a GPT read offset exceeds Darwin's file-offset range")
        }
        var data = Data(count: count)
        var readCount = 0
        while readCount < count {
            let result: Int = data.withUnsafeMutableBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: readCount),
                    count - readCount,
                    off_t(offset + UInt64(readCount))
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw ioError(action: "read GPT data from", url: url, errorNumber: errno)
            }
            guard result > 0 else {
                throw MacVMError.message(
                    "Couldn't read the GUID partition table from \(url.path): reached end of file at byte \(offset + UInt64(readCount))."
                )
            }
            readCount += result
        }
        return data
    }

    static func writeExactly(_ data: Data, descriptor: Int32, offset: UInt64, url: URL) throws {
        guard offset <= UInt64(Int64.max) else {
            throw invalid(url, "a GPT write offset exceeds Darwin's file-offset range")
        }
        let finalOffset = try added(
            offset,
            UInt64(data.count),
            url: url,
            description: "GPT write end offset"
        )
        guard finalOffset <= UInt64(Int64.max) else {
            throw invalid(url, "a GPT write extends beyond Darwin's file-offset range")
        }

        var writtenCount = 0
        while writtenCount < data.count {
            let result: Int = data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.pwrite(
                    descriptor,
                    baseAddress.advanced(by: writtenCount),
                    data.count - writtenCount,
                    off_t(offset + UInt64(writtenCount))
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw ioError(action: "write GPT data to", url: url, errorNumber: errno)
            }
            guard result > 0 else {
                throw MacVMError.message(
                    "Couldn't write the GUID partition table to \(url.path): a positional write made no progress at byte \(offset + UInt64(writtenCount))."
                )
            }
            writtenCount += result
        }
    }

    static func byteOffset(forLBA lba: UInt64, url: URL) throws -> UInt64 {
        let result = try multiplied(
            lba,
            sectorSizeBytes,
            url: url,
            description: "LBA byte offset"
        )
        guard result <= UInt64(Int64.max) else {
            throw invalid(url, "LBA \(lba) exceeds Darwin's file-offset range")
        }
        return result
    }

    static func added(_ lhs: UInt64, _ rhs: UInt64, url: URL, description: String) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw invalid(url, "integer overflow while calculating \(description)")
        }
        return result
    }

    static func multiplied(_ lhs: UInt64, _ rhs: UInt64, url: URL, description: String) throws -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw invalid(url, "integer overflow while calculating \(description)")
        }
        return result
    }

    static func invalid(_ url: URL, _ reason: String) -> MacVMError {
        MacVMError.message("Couldn't use the disk image at \(url.path): invalid GUID partition table: \(reason).")
    }

    static func ioError(action: String, url: URL, errorNumber: Int32) -> MacVMError {
        let reason = String(cString: strerror(errorNumber))
        return MacVMError.message("Couldn't \(action) \(url.path): \(reason).")
    }
}

/// GPT stores the first three UUID components little-endian, unlike UUID's
/// canonical byte order. Keeping this conversion explicit avoids relying on
/// host endianness or unaligned typed loads.
private enum GPTGUID {
    static func decode(_ bytes: Data) -> UUID {
        precondition(bytes.count == 16)
        let canonical: [UInt8] = [
            bytes[3], bytes[2], bytes[1], bytes[0],
            bytes[5], bytes[4],
            bytes[7], bytes[6],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        ]
        return UUID(uuid: (
            canonical[0], canonical[1], canonical[2], canonical[3],
            canonical[4], canonical[5], canonical[6], canonical[7],
            canonical[8], canonical[9], canonical[10], canonical[11],
            canonical[12], canonical[13], canonical[14], canonical[15]
        ))
    }

    static func encode(_ uuid: UUID) -> Data {
        let bytes = uuid.uuid
        return Data([
            bytes.3, bytes.2, bytes.1, bytes.0,
            bytes.5, bytes.4,
            bytes.7, bytes.6,
            bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15,
        ])
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset])
            | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func uint64LE(at offset: Int) -> UInt64 {
        UInt64(self[offset])
            | (UInt64(self[offset + 1]) << 8)
            | (UInt64(self[offset + 2]) << 16)
            | (UInt64(self[offset + 3]) << 24)
            | (UInt64(self[offset + 4]) << 32)
            | (UInt64(self[offset + 5]) << 40)
            | (UInt64(self[offset + 6]) << 48)
            | (UInt64(self[offset + 7]) << 56)
    }

    mutating func setUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func setUInt64LE(_ value: UInt64, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 4] = UInt8(truncatingIfNeeded: value >> 32)
        self[offset + 5] = UInt8(truncatingIfNeeded: value >> 40)
        self[offset + 6] = UInt8(truncatingIfNeeded: value >> 48)
        self[offset + 7] = UInt8(truncatingIfNeeded: value >> 56)
    }

    func prefixData(_ count: Int) -> Data {
        count == self.count ? self : subdata(in: 0..<count)
    }
}
