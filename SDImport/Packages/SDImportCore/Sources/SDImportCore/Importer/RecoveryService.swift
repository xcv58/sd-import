import Darwin
import Foundation

public struct RecoverySummary: Hashable, Codable, Sendable {
    public let recoveredJobs: Int
    public let removedPartFiles: Int

    public init(recoveredJobs: Int, removedPartFiles: Int) {
        self.recoveredJobs = recoveredJobs
        self.removedPartFiles = removedPartFiles
    }
}

public struct RecoveryService {
    private let fileManager: FileManager
    private let jobRepository: JobRepository
    private let portableReceiptsEnabled: Bool

    public init(
        fileManager: FileManager = .default, jobRepository: JobRepository, portableReceiptsEnabled: Bool = false
    ) {
        self.fileManager = fileManager
        self.jobRepository = jobRepository
        self.portableReceiptsEnabled = portableReceiptsEnabled
    }

    @discardableResult
    public func recoverInterruptedImports() throws -> RecoverySummary {
        let interruptedJobs = try jobRepository.interruptedImportJobs()
        var removedPartFiles = 0

        var recoveredJobs = 0
        for job in interruptedJobs {
            guard let outcome = try jobRepository.withImportLock(jobID: job.id, {
                try recoverJobWhileLocked(jobID: job.id)
            }), outcome.recovered else {
                continue
            }
            recoveredJobs += 1
            removedPartFiles += outcome.removedPartFiles
        }

        return RecoverySummary(recoveredJobs: recoveredJobs, removedPartFiles: removedPartFiles)
    }

    public func recoverInterruptedImport(
        jobID: String, preparation: Insta360RescanRecovery.Preparation? = nil
    ) throws {
        guard try jobRepository.withImportLock(jobID: jobID, {
            try recoverJobWhileLocked(jobID: jobID)
        }) != nil else {
            throw SDImportError.invalidArgument(L10n.tr("Finish the current scan or import first"))
        }
        // Older attempts are supplemental. A busy job keeps its journal for later recovery.
        for previous in preparation?.earlierAttempts ?? [] {
            try Task.checkCancellation()
            _ = try jobRepository.withImportLock(jobID: previous.jobID) {
                try recoverJobWhileLocked(jobID: previous.jobID, attemptIDs: previous.attemptIDs)
            }
        }
    }

    struct JobRecovery {
        var recovered = false
        var removedPartFiles = 0
        var unavailableFileID: Int64?
        var needsReview = false
        var resumedReviewedCopy = false
        var portableReceiptPending = false
        var copiedSourcePaths: [String] = []
    }

    func recoverJobWhileLocked(jobID: String, attemptIDs: Set<UUID>? = nil) throws -> JobRecovery {
        var outcome = JobRecovery()
        guard let job = try jobRepository.fetchJob(id: jobID) else { return outcome }
        let allAttempts = try jobRepository.copyAttempts(jobID: jobID)
        let attempts = attemptIDs.map { ids in allAttempts.filter { ids.contains($0.id) } } ?? allAttempts
        guard !attempts.isEmpty || (attemptIDs == nil && job.status == .importing) else { return outcome }
        outcome.recovered = job.status == .importing || attempts.contains { $0.localCopyCommitted != true }

        for attempt in attempts {
            if attempt.localCopyCommitted == true {
                if !replayPortableReceipt(attempt) { outcome.portableReceiptPending = true }
                continue
            }
            outcome.resumedReviewedCopy = outcome.resumedReviewedCopy || attempt.requiresDestinationReview == true
            let disposition: CopyRecoveryDisposition
            do {
                disposition = try inspectInterruptedCopy(attempt)
            } catch {
                outcome.unavailableFileID = attempt.fileID
                continue
            }
            switch disposition {
            case .unavailable:
                outcome.unavailableFileID = attempt.fileID
            case .unverifiedDestination(let removedStaging):
                outcome.removedPartFiles += removedStaging ? 1 : 0
                let needsReview = attempt.destinationDirectory == nil || attempt.requiresDestinationReview == true
                outcome.needsReview = outcome.needsReview || needsReview
                try jobRepository.rejectUnverifiedCopy(attempt, needsDestinationReview: needsReview)
            case .published:
                try jobRepository.commitCopyAttempt(
                    attempt, requireReviewForRemainingFiles: attempt.requiresDestinationReview == true
                )
                outcome.copiedSourcePaths.append(attempt.sourcePath)
                if !replayPortableReceipt(attempt) { outcome.portableReceiptPending = true }
            case .retry(let removedStaging):
                outcome.removedPartFiles += removedStaging ? 1 : 0
                let reviewRequired = attempt.requiresDestinationReview == true
                outcome.needsReview = outcome.needsReview || reviewRequired
                try jobRepository.discardCopyAttempt(attempt, needsDestinationReview: reviewRequired)
            }
        }

        guard outcome.recovered else { return outcome }
        try jobRepository.resetPendingFilesAfterInterruption(jobID: jobID)
        let files = try jobRepository.fetchJobFiles(jobID: jobID)
        let hasOtherPendingCopies = attemptIDs.map { ids in
            allAttempts.contains { $0.localCopyCommitted != true && !ids.contains($0.id) }
        } ?? false
        let fullyCopied = outcome.unavailableFileID == nil
            && !outcome.needsReview
            && !hasOtherPendingCopies
            && files.contains { $0.copyStatus == .copied }
            && !files.contains(where: \.isPendingImport)
        try jobRepository.refreshImportTotals(
            jobID: jobID, finalStatus: fullyCopied ? .imported : .failed, completedAt: Date(),
            needsDestinationReview: fullyCopied ? false : (outcome.needsReview ? true : nil)
        )
        ReportWriter(fileManager: fileManager).rewriteIfPossible(jobID: jobID, jobRepository: jobRepository)
        return outcome
    }

    private func replayPortableReceipt(_ attempt: ImportCopyAttempt) -> Bool {
        guard portableReceiptsEnabled, let receipt = attempt.portableReceipt else { return true }
        do {
            guard try receipt.replay(
                sourcePath: attempt.sourcePath, copiedDigest: attempt.staged?.digest ?? attempt.directCopyDigest
            ) else { return false }
            try jobRepository.discardCopyAttempt(attempt)
            return true
        } catch {
            return false
        }
    }

    private enum CopyRecoveryDisposition {
        case unavailable
        case unverifiedDestination(removedStaging: Bool)
        case published
        case retry(removedStaging: Bool)
    }

    private func inspectInterruptedCopy(_ attempt: ImportCopyAttempt) throws -> CopyRecoveryDisposition {
        // Early journal entries lack the parent identity needed for safe file operations.
        guard attempt.destinationDirectory != nil else { return .unverifiedDestination(removedStaging: false) }
        guard attempt.destinationIsAccessible() else { return .unavailable }

        let staging = try CopyEngine.fileInfo(at: attempt.staging)
        let final = try CopyEngine.fileInfo(at: attempt.destination)
        if staging == nil, let final {
            if try CopyEngine.publishedFileMatches(attempt) {
                if attempt.staged == nil, let date = attempt.modificationDate {
                    try CopyEngine.restoreCopyDate(date, at: attempt.destination, identity: ImportCopyFileIdentity(final))
                }
                return .published
            }

            // Retain negative verification so a later metadata-only check cannot accept this file.
            if attempt.staged != nil || attempt.reservedDestination != nil {
                return .unverifiedDestination(removedStaging: false)
            }
        }

        if let staging, let final, let verified = attempt.staged {
            guard attempt.stagingIdentity?.matches(staging) == true else {
                return .unverifiedDestination(removedStaging: false)
            }
            if case .skip = ConflictResolver(fileManager: fileManager).resolveDestination(
                candidate: attempt.destination, expectedFingerprint: attempt.fingerprint, allowsRename: false
            ), try CopyEngine.readDigest(at: attempt.destination, identity: ImportCopyFileIdentity(final))
                != verified.digest {
                return .unverifiedDestination(removedStaging: try removeOwnedStaging(attempt))
            }
        }

        return .retry(removedStaging: try removeOwnedStaging(attempt))
    }

    private func removeOwnedStaging(_ attempt: ImportCopyAttempt) throws -> Bool {
        guard attempt.destinationIsAccessible() else {
            throw SDImportError.missingDestinationDirectory(attempt.fileID)
        }
        guard let identity = attempt.stagingIdentity,
              let current = try CopyEngine.fileInfo(at: attempt.staging),
              identity.matches(current) else {
            return false
        }
        try fileManager.removeItem(at: attempt.staging)
        return true
    }
}
