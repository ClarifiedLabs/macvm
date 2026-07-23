import Darwin
import Foundation

enum DockerSidecarReplacementRecoveryDecision: Equatable {
    case rollForward
    case rollBack
    case ambiguous
}

struct DockerSidecarReplacementJournal: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var transactionID: UUID
    var stageDirectoryName: String
    var candidateID: UUID
    var previousSettings: DockerSidecarSettings?
    var intendedSettings: DockerSidecarSettings
}

enum DockerSidecarReplacement {
    static let journalName = ".DockerSidecar-replacement.json"
    static let stagePrefix = ".DockerSidecar-"

    static func recoveryDecision(
        canonicalCandidateID: UUID?,
        stageCandidateID: UUID?,
        expectedCandidateID: UUID
    ) -> DockerSidecarReplacementRecoveryDecision {
        if canonicalCandidateID == expectedCandidateID {
            return .rollForward
        }
        if stageCandidateID == expectedCandidateID {
            return .rollBack
        }
        return .ambiguous
    }

    static func exchangeDirectoriesAtomically(_ firstURL: URL, _ secondURL: URL) throws {
        let result = firstURL.path.withCString { firstPath in
            secondURL.path.withCString { secondPath in
                renameatx_np(AT_FDCWD, firstPath, AT_FDCWD, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            let code = errno
            throw MacVMError.message(
                "Couldn't atomically exchange Docker sidecar directories: \(String(cString: strerror(code)))."
            )
        }
    }

    static func commit(
        ownerBundle: VMBundle,
        stageSidecar: DockerSidecarBundle,
        candidateID: UUID,
        previousSettings: DockerSidecarSettings?,
        intendedSettings: DockerSidecarSettings
    ) throws -> VMMetadata {
        let stageName = stageSidecar.url.lastPathComponent
        guard isValidStageDirectoryName(stageName),
              stageSidecar.url.deletingLastPathComponent().standardizedFileURL == ownerBundle.url.standardizedFileURL else {
            throw MacVMError.message("Invalid Docker sidecar staging directory.")
        }
        let stagedMetadata = try stageSidecar.validateIntegrity()
        guard stagedMetadata.replacementCandidateID == candidateID else {
            throw MacVMError.message("Docker sidecar staging identity does not match its replacement transaction.")
        }

        let journal = DockerSidecarReplacementJournal(
            transactionID: UUID(),
            stageDirectoryName: stageName,
            candidateID: candidateID,
            previousSettings: previousSettings,
            intendedSettings: intendedSettings
        )
        try writeJournal(journal, ownerBundle: ownerBundle)

        do {
            if ownerBundle.dockerSidecarBundle.isPresent {
                try exchangeDirectoriesAtomically(stageSidecar.url, ownerBundle.dockerSidecarBundle.url)
            } else {
                try FileManager.default.moveItem(
                    at: stageSidecar.url,
                    to: ownerBundle.dockerSidecarBundle.url
                )
            }
        } catch {
            // A failed exchange leaves the old appliance canonical. Recovery
            // recognizes the candidate in staging and removes the transaction.
            _ = try? recoverIfNeeded(ownerBundle: ownerBundle)
            throw error
        }

        return try recoverIfNeeded(ownerBundle: ownerBundle)
    }

    @discardableResult
    static func recoverIfNeeded(ownerBundle: VMBundle) throws -> VMMetadata {
        guard FileManager.default.fileExists(atPath: ownerBundle.dockerSidecarReplacementJournalURL.path) else {
            // Preparation happens under the same operation lock but precedes the
            // journal. Remove candidates left by process termination before they
            // can be started or copied into a clone.
            try cleanupStaleStages(ownerBundle: ownerBundle)
            return try ownerBundle.readMetadata()
        }
        let journal = try readJournal(ownerBundle: ownerBundle)
        guard journal.schemaVersion == DockerSidecarReplacementJournal.currentSchemaVersion,
              isValidStageDirectoryName(journal.stageDirectoryName) else {
            throw MacVMError.message(
                "Docker sidecar replacement journal is invalid at \(ownerBundle.dockerSidecarReplacementJournalURL.path)."
            )
        }

        let stageURL = ownerBundle.url.appendingPathComponent(
            journal.stageDirectoryName,
            isDirectory: true
        )
        let stageSidecar = DockerSidecarBundle(url: stageURL)
        let finalSidecar = ownerBundle.dockerSidecarBundle
        let decision = recoveryDecision(
            canonicalCandidateID: replacementCandidateID(in: finalSidecar),
            stageCandidateID: replacementCandidateID(in: stageSidecar),
            expectedCandidateID: journal.candidateID
        )

        switch decision {
        case .rollForward:
            do {
                _ = try finalSidecar.validateIntegrity()
            } catch {
                guard stageSidecar.isPresent,
                      (try? stageSidecar.validateIntegrity()) != nil else {
                    throw MacVMError.message(
                        "The committed Docker sidecar replacement is corrupt and no valid previous appliance is available: \(error.localizedDescription)"
                    )
                }
                try exchangeDirectoriesAtomically(stageURL, finalSidecar.url)
                let metadata = try ownerBundle.updateMetadata { metadata in
                    metadata.dockerSidecar = journal.previousSettings
                }
                // The old appliance is canonical again. Remove the journal first
                // so interruption during best-effort candidate cleanup cannot be
                // mistaken for an ambiguous in-flight exchange.
                try FileManager.default.removeItem(at: ownerBundle.dockerSidecarReplacementJournalURL)
                try? FileManager.default.removeItem(at: stageURL)
                return metadata
            }

            let metadata = try ownerBundle.updateMetadata { metadata in
                metadata.dockerSidecar = journal.intendedSettings
            }
            if stageSidecar.isPresent {
                try FileManager.default.removeItem(at: stageURL)
            }
            try FileManager.default.removeItem(at: ownerBundle.dockerSidecarReplacementJournalURL)
            return metadata

        case .rollBack:
            let metadata = try ownerBundle.updateMetadata { metadata in
                metadata.dockerSidecar = journal.previousSettings
            }
            // The exchange never committed. Finalize the rollback before
            // deleting its disposable candidate; stale-stage cleanup can finish
            // that deletion after an interruption.
            try FileManager.default.removeItem(at: ownerBundle.dockerSidecarReplacementJournalURL)
            try? FileManager.default.removeItem(at: stageURL)
            return metadata

        case .ambiguous:
            throw MacVMError.message(
                "Docker sidecar replacement state is ambiguous. Preserving the appliance and journal for recovery."
            )
        }
    }

    static func writeJournal(
        _ journal: DockerSidecarReplacementJournal,
        ownerBundle: VMBundle
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(journal).write(
            to: ownerBundle.dockerSidecarReplacementJournalURL,
            options: .atomic
        )
    }

    static func cleanupStaleStages(ownerBundle: VMBundle) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: ownerBundle.url.path) else { return }
        for entry in try fileManager.contentsOfDirectory(
            at: ownerBundle.url,
            includingPropertiesForKeys: nil,
            options: []
        ) where isValidStageDirectoryName(entry.lastPathComponent) {
            try fileManager.removeItem(at: entry)
        }
    }

    private static func readJournal(ownerBundle: VMBundle) throws -> DockerSidecarReplacementJournal {
        try JSONDecoder().decode(
            DockerSidecarReplacementJournal.self,
            from: Data(contentsOf: ownerBundle.dockerSidecarReplacementJournalURL)
        )
    }

    private static func replacementCandidateID(in sidecar: DockerSidecarBundle) -> UUID? {
        guard sidecar.isPresent else { return nil }
        return try? sidecar.readMetadata().replacementCandidateID
    }

    private static func isValidStageDirectoryName(_ name: String) -> Bool {
        name.hasPrefix(stagePrefix)
            && !name.hasPrefix(".DockerSidecar-backup-")
            && !name.contains("/")
            && name != stagePrefix
    }
}

extension VMBundle {
    var dockerSidecarReplacementJournalURL: URL {
        url.appendingPathComponent(DockerSidecarReplacement.journalName, isDirectory: false)
    }

    var hasDockerSidecarReplacementJournal: Bool {
        FileManager.default.fileExists(atPath: dockerSidecarReplacementJournalURL.path)
    }

    @discardableResult
    func recoverDockerSidecarReplacementIfNeeded() throws -> VMMetadata {
        try DockerSidecarReplacement.recoverIfNeeded(ownerBundle: self)
    }
}
