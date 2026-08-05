import Darwin
import Foundation

extension MacVMService {
    /// Grow a stopped installed macOS VM's boot disk without losing its RecoveryOS
    /// partition. The expensive regular-file and host-tool work intentionally runs
    /// away from the caller's actor; once the journal exists, recovery determines
    /// the safe outcome after cancellation or process interruption.
    public func resizeDisk(
        _ vm: ManagedVM,
        toSizeBytes targetSizeBytes: UInt64,
        progress: VMOperationHandler? = nil
    ) async throws -> ManagedVM {
        // Give equal/smaller requests the promised no-files-changed result before
        // taking a lock or creating a transaction. Recheck against fresh metadata
        // after the lock below.
        guard targetSizeBytes > vm.metadata.diskSizeBytes else {
            throw MacVMError.message(
                "Disk shrinking is unsupported. The requested size must be larger than the current \(VMText.gibLabel(for: vm.metadata.diskSizeBytes))."
            )
        }
        guard targetSizeBytes <= UInt64(Int64.max) else {
            throw MacVMError.message("The requested disk size exceeds the host file-size limit.")
        }
        guard targetSizeBytes % GUIDPartitionTable.alignmentBytes == 0 else {
            throw MacVMError.message("The requested disk size must be divisible by 4 KiB.")
        }

        let bundleURL = vm.bundleURL
        let expectedVMID = vm.metadata.id
        return try await Task.detached(priority: .utility) {
            let bundle = VMBundle(url: bundleURL)
            let lifecycleLock = try bundle.acquireDiskLifecycleLock(operation: "resize the disk")
            defer { withExtendedLifetime(lifecycleLock) {} }

            let transaction = DiskResizeTransaction()
            // Recovery is deliberately before metadata/runtime inspection: a
            // post-exchange crash may need to commit the already-verified target.
            let currentMetadata = try transaction.recoverIfNeeded(bundle: bundle)
            guard currentMetadata.id == expectedVMID else {
                throw MacVMError.message(
                    "The VM at \(bundle.url.path) no longer matches the disk resize request. Refresh and try again."
                )
            }
            guard targetSizeBytes > currentMetadata.diskSizeBytes else {
                throw MacVMError.message(
                    "Disk shrinking is unsupported. The requested size must be larger than the current \(VMText.gibLabel(for: currentMetadata.diskSizeBytes))."
                )
            }

            progress?(.status("Validating the stopped VM and its disk image…"))
            try Self.requireStoppedForDiskResize(bundle: bundle, name: currentMetadata.name)
            try Self.validateDiskResizeInput(
                bundle: bundle,
                metadata: currentMetadata,
                targetSizeBytes: targetSizeBytes
            )

            let committedMetadata = try transaction.execute(
                bundle: bundle,
                expectedVMID: expectedVMID,
                currentMetadata: currentMetadata,
                targetSizeBytes: targetSizeBytes
            ) { phase in
                progress?(.status(Self.diskResizeStatus(for: phase)))
            }
            progress?(.status(
                "Disk resize committed: \(VMText.gibLabel(for: currentMetadata.diskSizeBytes)) → \(VMText.gibLabel(for: committedMetadata.diskSizeBytes))."
            ))
            return ManagedVM(bundleURL: bundleURL, metadata: committedMetadata)
        }.value
    }

    /// Recovery/read paths acquire this same lock before invoking the transaction;
    /// callers that do not own it must use `tryAcquireDiskLifecycleLock` first.
    func recoverDiskResizeIfNeeded(for bundle: VMBundle) throws -> VMMetadata {
        let lifecycleLock = try bundle.acquireDiskLifecycleLock(operation: "recover a disk resize")
        defer { withExtendedLifetime(lifecycleLock) {} }
        return try DiskResizeTransaction().recoverIfNeeded(bundle: bundle)
    }

    private static func requireStoppedForDiskResize(bundle: VMBundle, name: String) throws {
        guard bundle.liveVMProcessRuntimeState() == nil,
              bundle.liveVNCSession() == nil,
              bundle.liveDisplayRuntimeState() == nil,
              bundle.liveSetupRuntimeState() == nil,
              bundle.liveDockerSidecarRuntimeDescriptor() == nil else {
            throw MacVMError.message("Stop '\(name)' before resizing its disk.")
        }
    }

    private static func validateDiskResizeInput(
        bundle: VMBundle,
        metadata: VMMetadata,
        targetSizeBytes: UInt64
    ) throws {
        guard targetSizeBytes > metadata.diskSizeBytes else {
            throw MacVMError.message("Disk shrinking is unsupported.")
        }
        guard targetSizeBytes <= UInt64(Int64.max) else {
            throw MacVMError.message("The requested disk size exceeds the host file-size limit.")
        }
        guard targetSizeBytes % GUIDPartitionTable.alignmentBytes == 0 else {
            throw MacVMError.message("The requested disk size must be divisible by 4 KiB.")
        }

        let imageURL = bundle.diskImageURL
        var imageStatus = stat()
        guard Darwin.lstat(imageURL.path, &imageStatus) == 0 else {
            throw MacVMError.message(
                "Couldn't inspect disk image at \(imageURL.path): \(String(cString: strerror(errno)))."
            )
        }
        guard (imageStatus.st_mode & S_IFMT) == S_IFREG else {
            throw MacVMError.message("Disk image at \(imageURL.path) must be a regular, non-symlinked file.")
        }
        guard imageStatus.st_size >= 0 else {
            throw MacVMError.message("Disk image at \(imageURL.path) has an invalid negative size.")
        }
        let actualSize = UInt64(imageStatus.st_size)
        guard actualSize == metadata.diskSizeBytes else {
            throw MacVMError.message(
                "Disk metadata says \(metadata.diskSizeBytes) bytes, but Disk.img at \(imageURL.path) is \(actualSize) bytes."
            )
        }
        _ = try GUIDPartitionTable(reading: imageURL, expectedSizeBytes: metadata.diskSizeBytes)

        // Refuse an externally attached canonical image before journal creation.
        let attachmentOperations = DiskResizeTransaction.Dependencies.live().attachments
        let devices = try attachmentOperations.attachedWholeDisks(imageURL)
        guard devices.isEmpty else {
            throw MacVMError.message(
                "Disk image \(imageURL.path) is attached as \(devices.joined(separator: ", ")); detach it before resizing."
            )
        }
    }

    private static func diskResizeStatus(for phase: DiskImageGrower.Phase) -> String {
        switch phase {
        case .validatingInput:
            return "Validating disk image…"
        case .stagingCandidate:
            return "Preparing a copy-on-write disk candidate…"
        case .relocatingRecovery:
            return "Relocating RecoveryOS…"
        case .writingPartitionTable:
            return "Writing the staged partition map…"
        case .attachingCandidate:
            return "Attaching the staged disk image…"
        case .verifyingBeforeResize:
            return "Verifying the staged partition map…"
        case .resizingContainer:
            return "Growing the APFS container…"
        case .verifyingAfterResize:
            return "Verifying APFS and RecoveryOS…"
        case .detachingCandidate:
            return "Detaching the staged disk image…"
        case .verifyingDetachedCandidate:
            return "Verifying the detached disk candidate…"
        case .complete:
            return "Committing the grown disk…"
        }
    }
}
