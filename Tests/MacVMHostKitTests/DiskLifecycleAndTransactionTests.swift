import Foundation
import Testing
@testable import MacVMHostKit

@Test
func diskLifecycleLockRejectsContentionAndReleasesWithItsHandle() throws {
    let root = makeDiskTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleURL = root.appendingPathComponent("owner.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
    let bundle = VMBundle(url: bundleURL)

    var first: VMDiskLifecycleLock? = try bundle.acquireDiskLifecycleLock(operation: "resize the disk")
    #expect(first != nil)
    #expect(FileManager.default.fileExists(atPath: bundle.diskLifecycleLockURL.path))
    let contendedLock = try bundle.tryAcquireDiskLifecycleLock(operation: "clone the VM")
    #expect(contendedLock == nil)

    do {
        _ = try bundle.acquireDiskLifecycleLock(operation: "remove the VM")
        Issue.record("Expected the contending disk operation to be rejected")
    } catch {
        #expect(error.localizedDescription.contains("Another disk operation is already in progress"))
        #expect(error.localizedDescription.contains("remove the VM"))
    }

    first = nil
    let next = try #require(try bundle.tryAcquireDiskLifecycleLock(operation: "retry the resize"))
    withExtendedLifetime(next) {}
}

@Test
func diskLifecycleLockUsesResolvedBundleIdentityAcrossSymlinks() throws {
    let root = makeDiskTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleURL = root.appendingPathComponent("VMs/owner.macvm", isDirectory: true)
    let aliasURL = root.appendingPathComponent("Aliases/renamed.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: aliasURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: bundleURL)

    let bundle = VMBundle(url: bundleURL)
    let alias = VMBundle(url: aliasURL)
    #expect(bundle.diskLifecycleLockURL == alias.diskLifecycleLockURL)
    #expect(bundle.diskLifecycleLockURL.deletingLastPathComponent() == bundleURL.deletingLastPathComponent())

    let lock = try bundle.acquireDiskLifecycleLock(operation: "resize the original path")
    defer { withExtendedLifetime(lock) {} }
    #expect(try alias.tryAcquireDiskLifecycleLock(operation: "resize the alias") == nil)
}

@Test
func diskResizeTransactionPublishesThroughInjectedOperationsWithoutHostUtilities() throws {
    let root = makeDiskTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleURL = root.appendingPathComponent("owner.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
    let bundle = VMBundle(url: bundleURL)
    let sourceSize: UInt64 = 4_096
    let targetSize: UInt64 = 8_192
    let metadata = diskTransactionMetadata(diskSizeBytes: sourceSize)
    try bundle.writeMetadata(metadata)

    let sourceMarker = Data("source-image".utf8)
    let targetMarker = Data("target-image".utf8)
    try sourceMarker.write(to: bundle.diskImageURL)
    let sourceFingerprint = diskTransactionFingerprint(size: sourceSize, lastLBA: 4)
    let targetFingerprint = diskTransactionFingerprint(size: targetSize, lastLBA: 12)
    var didGrow = false
    var didExchange = false
    var attachmentChecks: [URL] = []

    let transaction = DiskResizeTransaction(dependencies: .init(
        grow: { sourceURL, candidateURL, requestedSize, _ in
            #expect(sourceURL == bundle.diskImageURL)
            #expect(requestedSize == targetSize)
            didGrow = true
            try targetMarker.write(to: candidateURL)
        },
        fingerprint: { imageURL in
            switch try Data(contentsOf: imageURL) {
            case sourceMarker:
                return sourceFingerprint
            case targetMarker:
                return targetFingerprint
            default:
                throw MacVMError.message("Unexpected test image marker")
            }
        },
        exchange: { canonicalURL, candidateURL in
            didExchange = true
            let canonicalData = try Data(contentsOf: canonicalURL)
            let candidateData = try Data(contentsOf: candidateURL)
            try candidateData.write(to: canonicalURL)
            try canonicalData.write(to: candidateURL)
        },
        attachments: .init(
            attachedWholeDisks: { imageURL in
                attachmentChecks.append(imageURL)
                return []
            },
            detachWholeDisk: { identifier in
                Issue.record("Unexpected detach request for \(identifier)")
            }
        )
    ))

    let result = try transaction.execute(
        bundle: bundle,
        expectedVMID: metadata.id,
        currentMetadata: metadata,
        targetSizeBytes: targetSize
    )

    #expect(didGrow)
    #expect(didExchange)
    #expect(result.diskSizeBytes == targetSize)
    #expect(try bundle.readMetadata().diskSizeBytes == targetSize)
    #expect(try Data(contentsOf: bundle.diskImageURL) == targetMarker)
    #expect(attachmentChecks.contains(bundle.diskImageURL))
    #expect(attachmentChecks.contains { $0.lastPathComponent == "Disk.img" && $0 != bundle.diskImageURL })
    #expect(!FileManager.default.fileExists(
        atPath: bundleURL.appendingPathComponent(DiskResizeTransaction.journalName).path
    ))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundleURL.path)
    #expect(!leftovers.contains { $0.hasPrefix(DiskResizeTransaction.stagePrefix) })
}

@Test
func diskResizeTransactionRollsBackJournalWhenInjectedGrowthFails() throws {
    let root = makeDiskTestDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleURL = root.appendingPathComponent("owner.macvm", isDirectory: true)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)
    let bundle = VMBundle(url: bundleURL)
    let sourceSize: UInt64 = 4_096
    let targetSize: UInt64 = 8_192
    let metadata = diskTransactionMetadata(diskSizeBytes: sourceSize)
    try bundle.writeMetadata(metadata)
    let sourceMarker = Data("source-image".utf8)
    try sourceMarker.write(to: bundle.diskImageURL)
    let sourceFingerprint = diskTransactionFingerprint(size: sourceSize, lastLBA: 4)

    let transaction = DiskResizeTransaction(dependencies: .init(
        grow: { _, _, _, _ in
            throw MacVMError.message("Injected growth failure")
        },
        fingerprint: { imageURL in
            guard try Data(contentsOf: imageURL) == sourceMarker else {
                throw MacVMError.message("Unexpected test image marker")
            }
            return sourceFingerprint
        },
        exchange: { _, _ in
            Issue.record("The transaction must not exchange images after growth fails")
        },
        attachments: .init(
            attachedWholeDisks: { _ in [] },
            detachWholeDisk: { identifier in
                Issue.record("Unexpected detach request for \(identifier)")
            }
        )
    ))

    do {
        _ = try transaction.execute(
            bundle: bundle,
            expectedVMID: metadata.id,
            currentMetadata: metadata,
            targetSizeBytes: targetSize
        )
        Issue.record("Expected the injected growth failure")
    } catch {
        #expect(error.localizedDescription.contains("Injected growth failure"))
    }

    #expect(try bundle.readMetadata() == metadata)
    #expect(try Data(contentsOf: bundle.diskImageURL) == sourceMarker)
    #expect(!FileManager.default.fileExists(
        atPath: bundleURL.appendingPathComponent(DiskResizeTransaction.journalName).path
    ))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: bundleURL.path)
    #expect(!leftovers.contains { $0.hasPrefix(DiskResizeTransaction.stagePrefix) })
}

private func makeDiskTestDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "macvm-disk-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func diskTransactionMetadata(diskSizeBytes: UInt64) -> VMMetadata {
    VMMetadata(
        name: "owner",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        cpuCount: 2,
        memorySizeBytes: 4 * 1_024 * 1_024 * 1_024,
        diskSizeBytes: diskSizeBytes,
        displayWidth: 1280,
        displayHeight: 720,
        bootstrapShareEnabled: false
    )
}

private func diskTransactionFingerprint(
    size: UInt64,
    lastLBA: UInt64
) -> DiskResizeTransaction.Fingerprint {
    DiskResizeTransaction.Fingerprint(
        logicalSizeBytes: size,
        geometry: .init(
            diskSizeBytes: size,
            sectorCount: size / GUIDPartitionTable.sectorSizeBytes,
            primaryHeaderLBA: 1,
            primaryEntriesLBA: 2,
            backupEntriesLBA: size / GUIDPartitionTable.sectorSizeBytes - 2,
            backupHeaderLBA: size / GUIDPartitionTable.sectorSizeBytes - 1,
            firstUsableLBA: 3,
            lastUsableLBA: size / GUIDPartitionTable.sectorSizeBytes - 3,
            partitionEntryCount: 1,
            partitionEntrySize: 128,
            partitionEntryArraySectorCount: 1
        ),
        diskGUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
        entries: [.init(
            slotIndex: 0,
            typeGUID: GUIDPartitionTable.mainPartitionType,
            uniqueGUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            firstLBA: 3,
            lastLBA: lastLBA,
            attributes: 0,
            name: "Macintosh HD",
            stableEntryDigest: String(repeating: "a", count: 64)
        )]
    )
}
