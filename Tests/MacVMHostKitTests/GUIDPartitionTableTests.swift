import Foundation
import Testing
@testable import MacVMHostKit

private let syntheticDiskGUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

private struct SyntheticGPTPartition {
    let slot: Int
    let typeGUID: UUID
    let uniqueGUID: UUID
    let range: ClosedRange<UInt64>
    let attributes: UInt64
    let name: String
}

private struct SyntheticGPTImage {
    static let sectorSize = 512
    static let sectorCount: UInt64 = 128
    static let entryCount: UInt32 = 8
    static let entrySize: UInt32 = 128
    static let entrySectorCount: UInt64 = 2
    static let primaryEntriesLBA: UInt64 = 2
    static let backupHeaderLBA = sectorCount - 1
    static let backupEntriesLBA = backupHeaderLBA - entrySectorCount
    static let firstUsableLBA: UInt64 = 8
    static let lastUsableLBA = backupEntriesLBA - 1

    static let normalPartitions = [
        SyntheticGPTPartition(
            slot: 0,
            typeGUID: GUIDPartitionTable.iscPartitionType,
            uniqueGUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            range: 8...15,
            attributes: 0x10,
            name: "iSCPreboot"
        ),
        SyntheticGPTPartition(
            slot: 1,
            typeGUID: GUIDPartitionTable.mainPartitionType,
            uniqueGUID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
            range: 16...79,
            attributes: 0x20,
            name: "Macintosh HD"
        ),
        SyntheticGPTPartition(
            slot: 2,
            typeGUID: GUIDPartitionTable.recoveryPartitionType,
            uniqueGUID: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
            range: 80...119,
            attributes: 0x40,
            name: "Recovery"
        ),
    ]

    static func data(partitions: [SyntheticGPTPartition] = normalPartitions) -> Data {
        var entries = Data(count: Int(entryCount * entrySize))
        for partition in partitions {
            let offset = partition.slot * Int(entrySize)
            entries.replaceSubrange(
                offset..<(offset + 16),
                with: encodeGPTGUID(partition.typeGUID)
            )
            entries.replaceSubrange(
                (offset + 16)..<(offset + 32),
                with: encodeGPTGUID(partition.uniqueGUID)
            )
            entries.setTestUInt64LE(partition.range.lowerBound, at: offset + 32)
            entries.setTestUInt64LE(partition.range.upperBound, at: offset + 40)
            entries.setTestUInt64LE(partition.attributes, at: offset + 48)
            for (index, codeUnit) in partition.name.utf16.prefix(36).enumerated() {
                entries.setTestUInt16LE(codeUnit, at: offset + 56 + index * 2)
            }
            // Exercise preservation of implementation-specific bytes beyond the
            // standard 128-byte GPT entry when entry sizes grow in future fixtures.
        }

        let entriesCRC = IEEECRC32.checksum(entries)
        let primaryHeader = header(
            currentLBA: 1,
            backupLBA: backupHeaderLBA,
            entriesLBA: primaryEntriesLBA,
            entriesCRC: entriesCRC
        )
        let backupHeader = header(
            currentLBA: backupHeaderLBA,
            backupLBA: 1,
            entriesLBA: backupEntriesLBA,
            entriesCRC: entriesCRC
        )

        var image = Data(count: Int(sectorCount) * sectorSize)
        var protectiveMBR = Data(count: sectorSize)
        protectiveMBR[446 + 4] = 0xEE
        protectiveMBR.setTestUInt32LE(1, at: 446 + 8)
        protectiveMBR.setTestUInt32LE(UInt32(sectorCount - 1), at: 446 + 12)
        protectiveMBR[510] = 0x55
        protectiveMBR[511] = 0xAA
        image.replaceTestSector(0, with: protectiveMBR)
        image.replaceTestSector(1, with: primaryHeader)
        image.replaceTestSectors(primaryEntriesLBA, with: entries)
        image.replaceTestSectors(backupEntriesLBA, with: entries)
        image.replaceTestSector(backupHeaderLBA, with: backupHeader)
        return image
    }

    private static func header(
        currentLBA: UInt64,
        backupLBA: UInt64,
        entriesLBA: UInt64,
        entriesCRC: UInt32
    ) -> Data {
        var result = Data(count: sectorSize)
        result.replaceSubrange(0..<8, with: Data("EFI PART".utf8))
        result.setTestUInt32LE(0x0001_0000, at: 8)
        result.setTestUInt32LE(92, at: 12)
        result.setTestUInt64LE(currentLBA, at: 24)
        result.setTestUInt64LE(backupLBA, at: 32)
        result.setTestUInt64LE(firstUsableLBA, at: 40)
        result.setTestUInt64LE(lastUsableLBA, at: 48)
        result.replaceSubrange(56..<72, with: encodeGPTGUID(syntheticDiskGUID))
        result.setTestUInt64LE(entriesLBA, at: 72)
        result.setTestUInt32LE(entryCount, at: 80)
        result.setTestUInt32LE(entrySize, at: 84)
        result.setTestUInt32LE(entriesCRC, at: 88)
        result.setTestUInt32LE(IEEECRC32.checksum(result.subdata(in: 0..<92)), at: 16)
        return result
    }
}

@Test
func guidPartitionTableParsesSyntheticAppleLayout() throws {
    try withSyntheticGPT { url in
        let table = try GUIDPartitionTable(
            reading: url,
            expectedSizeBytes: SyntheticGPTImage.sectorCount * 512
        )

        #expect(table.diskGUID == syntheticDiskGUID)
        #expect(table.geometry == GUIDPartitionTable.Geometry(
            diskSizeBytes: SyntheticGPTImage.sectorCount * 512,
            sectorCount: SyntheticGPTImage.sectorCount,
            primaryHeaderLBA: 1,
            primaryEntriesLBA: SyntheticGPTImage.primaryEntriesLBA,
            backupEntriesLBA: SyntheticGPTImage.backupEntriesLBA,
            backupHeaderLBA: SyntheticGPTImage.backupHeaderLBA,
            firstUsableLBA: SyntheticGPTImage.firstUsableLBA,
            lastUsableLBA: SyntheticGPTImage.lastUsableLBA,
            partitionEntryCount: SyntheticGPTImage.entryCount,
            partitionEntrySize: SyntheticGPTImage.entrySize,
            partitionEntryArraySectorCount: SyntheticGPTImage.entrySectorCount
        ))
        #expect(table.partitions.map(\.slotIndex) == [0, 1, 2])
        #expect(table.iscPartition.name == "iSCPreboot")
        #expect(table.mainPartition.byteRange == (16 * 512)..<(80 * 512))
        #expect(table.mainPartition.attributes == 0x20)
        #expect(table.recoveryPartition.sectorCount == 40)
        #expect(table.trailingUsableSectorCount == 5)
    }
}

@Test
func guidPartitionTableRelocatesRecoveryAndWritesValidGPTCopies() throws {
    try withSyntheticGPT { sourceURL in
        let source = try GUIDPartitionTable(reading: sourceURL)
        let targetSectorCount: UInt64 = 192
        let targetSize = targetSectorCount * GUIDPartitionTable.sectorSizeBytes
        let relocated = try source.intermediateLayout(growingTo: targetSize)
        let targetURL = sourceURL.deletingLastPathComponent().appendingPathComponent("grown.img")
        var targetData = try Data(contentsOf: sourceURL)
        targetData.append(Data(count: Int(targetSize) - targetData.count))
        try targetData.write(to: targetURL)

        try relocated.write(to: targetURL)

        let reparsed = try GUIDPartitionTable(
            reading: targetURL,
            expectedSizeBytes: targetSize,
            allowMainRecoveryGap: true
        )
        #expect(reparsed.mainPartition == source.mainPartition)
        #expect(reparsed.recoveryPartition.firstLBA == 144)
        #expect(reparsed.recoveryPartition.lastLBA == 183)
        #expect(reparsed.recoveryPartition.sectorCount == source.recoveryPartition.sectorCount)
        #expect(reparsed.recoveryPartition.rawEntryIdentity == source.recoveryPartition.rawEntryIdentity)
        #expect(reparsed.geometry.backupEntriesLBA == 189)
        #expect(reparsed.geometry.backupHeaderLBA == 191)

        let written = try Data(contentsOf: targetURL)
        assertValidHeaderAndEntryCRC(in: written, headerLBA: 1, entriesLBA: 2)
        assertValidHeaderAndEntryCRC(in: written, headerLBA: 191, entriesLBA: 189)
        #expect(written.testUInt32LE(at: 446 + 12) == UInt32(targetSectorCount - 1))

        let obsoleteBackup = written.subdata(
            in: Int(SyntheticGPTImage.backupEntriesLBA * 512)..<Int(SyntheticGPTImage.sectorCount * 512)
        )
        #expect(obsoleteBackup.allSatisfy { $0 == 0 })
        expectGPTFailure(at: targetURL, containing: "main APFS and Recovery partitions are not adjacent")
    }
}

@Test
func guidPartitionTableRejectsCorruptHeaderAndEntryCRCs() throws {
    try withSyntheticGPT { validURL in
        let directory = validURL.deletingLastPathComponent()

        var badHeader = try Data(contentsOf: validURL)
        badHeader[SyntheticGPTImage.sectorSize + 48] ^= 0x01
        let badHeaderURL = directory.appendingPathComponent("bad-header.img")
        try badHeader.write(to: badHeaderURL)
        expectGPTFailure(at: badHeaderURL, containing: "primary GPT header CRC does not match")

        var badEntries = try Data(contentsOf: validURL)
        badEntries[Int(SyntheticGPTImage.primaryEntriesLBA * 512) + 56] ^= 0x01
        let badEntriesURL = directory.appendingPathComponent("bad-entries.img")
        try badEntries.write(to: badEntriesURL)
        expectGPTFailure(at: badEntriesURL, containing: "primary partition-entry array CRC does not match")
    }
}

@Test
func guidPartitionTableRejectsChecksummedInvalidAppleLayouts() throws {
    let normal = SyntheticGPTImage.normalPartitions
    let cases: [(String, [SyntheticGPTPartition], String)] = [
        (
            "gap",
            [normal[0], SyntheticGPTPartition(
                slot: 1,
                typeGUID: normal[1].typeGUID,
                uniqueGUID: normal[1].uniqueGUID,
                range: 24...79,
                attributes: normal[1].attributes,
                name: normal[1].name
            ), normal[2]],
            "ISC and main APFS partitions are not adjacent"
        ),
        (
            "overlap",
            [normal[0], SyntheticGPTPartition(
                slot: 1,
                typeGUID: normal[1].typeGUID,
                uniqueGUID: normal[1].uniqueGUID,
                range: 16...87,
                attributes: normal[1].attributes,
                name: normal[1].name
            ), normal[2]],
            "partition slots 2 and 3 overlap"
        ),
        (
            "wrong-type",
            [normal[0], normal[1], SyntheticGPTPartition(
                slot: 2,
                typeGUID: GUIDPartitionTable.mainPartitionType,
                uniqueGUID: normal[2].uniqueGUID,
                range: normal[2].range,
                attributes: normal[2].attributes,
                name: normal[2].name
            )],
            "expected one ISC"
        ),
    ]

    let directory = makeGPTTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, partitions, expectedMessage) in cases {
        let url = directory.appendingPathComponent("\(name).img")
        try SyntheticGPTImage.data(partitions: partitions).write(to: url)
        expectGPTFailure(at: url, containing: expectedMessage)
    }
}

@Test
func ieeeCRC32MatchesGPTStandardPolynomialKnownVector() {
    #expect(IEEECRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
}

private func withSyntheticGPT(_ body: (URL) throws -> Void) throws {
    let directory = makeGPTTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Disk.img")
    try SyntheticGPTImage.data().write(to: url)
    try body(url)
}

private func makeGPTTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "macvm-gpt-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func expectGPTFailure(at url: URL, containing expectedMessage: String) {
    do {
        _ = try GUIDPartitionTable(reading: url)
        Issue.record("Expected GPT parsing to fail for \(url.lastPathComponent)")
    } catch {
        #expect(error.localizedDescription.contains(expectedMessage))
    }
}

private func assertValidHeaderAndEntryCRC(in image: Data, headerLBA: UInt64, entriesLBA: UInt64) {
    let headerOffset = Int(headerLBA * 512)
    let header = image.subdata(in: headerOffset..<(headerOffset + 512))
    let storedHeaderCRC = header.testUInt32LE(at: 16)
    var headerCRCData = header.subdata(in: 0..<92)
    headerCRCData.setTestUInt32LE(0, at: 16)
    #expect(IEEECRC32.checksum(headerCRCData) == storedHeaderCRC)

    let entriesOffset = Int(entriesLBA * 512)
    let entries = image.subdata(in: entriesOffset..<(entriesOffset + 1_024))
    #expect(IEEECRC32.checksum(entries) == header.testUInt32LE(at: 88))
}

private func encodeGPTGUID(_ uuid: UUID) -> Data {
    let bytes = uuid.uuid
    return Data([
        bytes.3, bytes.2, bytes.1, bytes.0,
        bytes.5, bytes.4,
        bytes.7, bytes.6,
        bytes.8, bytes.9, bytes.10, bytes.11,
        bytes.12, bytes.13, bytes.14, bytes.15,
    ])
}

private extension Data {
    mutating func replaceTestSector(_ lba: UInt64, with sector: Data) {
        replaceTestSectors(lba, with: sector)
    }

    mutating func replaceTestSectors(_ lba: UInt64, with data: Data) {
        let offset = Int(lba) * SyntheticGPTImage.sectorSize
        replaceSubrange(offset..<(offset + data.count), with: data)
    }

    func testUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    mutating func setTestUInt16LE(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func setTestUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    mutating func setTestUInt64LE(_ value: UInt64, at offset: Int) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
        self[offset + 4] = UInt8(truncatingIfNeeded: value >> 32)
        self[offset + 5] = UInt8(truncatingIfNeeded: value >> 40)
        self[offset + 6] = UInt8(truncatingIfNeeded: value >> 48)
        self[offset + 7] = UInt8(truncatingIfNeeded: value >> 56)
    }
}
