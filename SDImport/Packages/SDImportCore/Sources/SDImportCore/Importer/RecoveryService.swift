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

    struct JobRecovery {
        var recovered = false
        var removedPartFiles = 0
        var unavailableFileID: Int64?
        var needsReview = false
        var resumedReviewedCopy = false
        var portableReceiptPending = false
        var copiedSourcePaths: [String] = []
    }

    func recoverJobWhileLocked(jobID: String) throws -> JobRecovery {
        var outcome = JobRecovery()
        guard let job = try jobRepository.fetchJob(id: jobID) else { return outcome }
        let attempts = try jobRepository.copyAttempts(jobID: jobID)
        guard job.status == .importing || !attempts.isEmpty else { return outcome }
        outcome.recovered = job.status == .importing || attempts.contains { !$0.localCopyCommitted }

        for attempt in attempts {
            if attempt.localCopyCommitted {
                if !replayPortableReceipt(attempt) { outcome.portableReceiptPending = true }
                continue
            }
            outcome.resumedReviewedCopy = outcome.resumedReviewedCopy || attempt.requiresDestinationReview
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
            case .unverifiedDestination:
                outcome.needsReview = outcome.needsReview || attempt.requiresDestinationReview
                try jobRepository.rejectUnverifiedCopy(attempt)
            case .published:
                try jobRepository.commitCopyAttempt(attempt)
                outcome.copiedSourcePaths.append(attempt.sourcePath)
                if !replayPortableReceipt(attempt) { outcome.portableReceiptPending = true }
            case .retry(let removedStaging, let needsReview):
                outcome.removedPartFiles += removedStaging ? 1 : 0
                let reviewRequired = needsReview && attempt.requiresDestinationReview
                outcome.needsReview = outcome.needsReview || reviewRequired
                try jobRepository.discardCopyAttempt(attempt, needsDestinationReview: reviewRequired)
            }
        }

        guard outcome.recovered else { return outcome }
        try jobRepository.resetPendingFilesAfterInterruption(jobID: jobID)
        let files = try jobRepository.fetchJobFiles(jobID: jobID)
        let fullyCopied = outcome.unavailableFileID == nil
            && !outcome.needsReview
            && files.contains { $0.copyStatus == .copied }
            && !files.contains(where: \.isPendingImport)
        try jobRepository.refreshImportTotals(
            jobID: jobID, finalStatus: fullyCopied ? .imported : .failed, completedAt: Date(),
            needsDestinationReview: outcome.needsReview ? true : nil
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
        case unverifiedDestination
        case published
        case retry(removedStaging: Bool, needsReview: Bool)
    }

    private func inspectInterruptedCopy(_ attempt: ImportCopyAttempt) throws -> CopyRecoveryDisposition {
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
                return .unverifiedDestination
            }
        }

        if let staging, let final, let verified = attempt.staged {
            guard attempt.stagingIdentity?.matches(staging) == true else { return .unverifiedDestination }
            if case .skip = ConflictResolver(fileManager: fileManager).resolveDestination(
                candidate: attempt.destination, expectedFingerprint: attempt.fingerprint, allowsRename: false
            ), try CopyEngine.readDigest(at: attempt.destination, identity: ImportCopyFileIdentity(final))
                != verified.digest {
                return .unverifiedDestination
            }
        }

        if let staging {
            // A journal can name a staging path before the file exists.
            // Leave a replaced entry alone if its identity no longer matches.
            guard attempt.stagingIdentity?.matches(staging) == true else {
                return .retry(removedStaging: false, needsReview: true)
            }
            try fileManager.removeItem(at: attempt.staging)
        }
        return .retry(removedStaging: staging != nil, needsReview: final != nil)
    }

}
