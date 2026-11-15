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

    public init(fileManager: FileManager = .default, jobRepository: JobRepository) {
        self.fileManager = fileManager
        self.jobRepository = jobRepository
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
        var copiedSourcePaths: [String] = []
    }

    func recoverJobWhileLocked(jobID: String) throws -> JobRecovery {
        var outcome = JobRecovery()
        guard let job = try jobRepository.fetchJob(id: jobID) else { return outcome }
        let attempts = try jobRepository.copyAttempts(jobID: jobID)
        guard job.status == .importing || !attempts.isEmpty else { return outcome }
        outcome.recovered = true

        if attempts.isEmpty {
            // Rows from before the journal only recorded candidate and final paths.
            for file in try jobRepository.fetchJobFiles(jobID: jobID) {
                outcome.removedPartFiles += removePartFileIfPresent(for: file.plannedDestinationPath)
                outcome.removedPartFiles += removePartFileIfPresent(for: file.finalDestinationPath)
            }
        }
        for attempt in attempts {
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
            case .published:
                try jobRepository.commitCopyAttempt(attempt)
                outcome.copiedSourcePaths.append(attempt.sourcePath)
            case .retry(let removedStaging, let needsReview):
                outcome.removedPartFiles += removedStaging ? 1 : 0
                outcome.needsReview = outcome.needsReview || needsReview
                try jobRepository.discardCopyAttempt(attempt, needsDestinationReview: needsReview)
            }
        }

        try jobRepository.resetPendingFilesAfterInterruption(jobID: jobID)
        let files = try jobRepository.fetchJobFiles(jobID: jobID)
        let fullyCopied = outcome.unavailableFileID == nil
            && !outcome.needsReview
            && files.contains { $0.copyStatus == .copied }
            && !files.contains(where: \.isPendingImport)
        try jobRepository.refreshImportTotals(
            jobID: jobID, finalStatus: fullyCopied ? .imported : .failed, completedAt: Date()
        )
        return outcome
    }

    private enum CopyRecoveryDisposition {
        case unavailable
        case published
        case retry(removedStaging: Bool, needsReview: Bool)
    }

    private func inspectInterruptedCopy(_ attempt: ImportCopyAttempt) throws -> CopyRecoveryDisposition {
        guard attempt.destinationIsAccessible() else { return .unavailable }

        let staging = try CopyEngine.fileInfo(at: attempt.staging)
        let final = try CopyEngine.fileInfo(at: attempt.destination)
        if staging == nil, final != nil, try CopyEngine.publishedFileMatches(attempt) {
            return .published
        }

        if let reservation = attempt.reservedDestination, let final, reservation.matches(final) {
            // Exclusive creation claims the final name before bytes are written on volumes
            // that lack exclusive rename. Only remove a partial file this attempt owns.
            try fileManager.removeItem(at: attempt.destination)
            return .retry(removedStaging: false, needsReview: false)
        }

        if let staging {
            // A journal can name a staging path before the file exists.
            // Leave a replaced entry alone if its identity no longer matches.
            guard staging.st_mode & S_IFMT == S_IFREG,
                  attempt.staged?.matches(staging) != false else {
                return .retry(removedStaging: false, needsReview: true)
            }
            try fileManager.removeItem(at: attempt.staging)
        }
        return .retry(removedStaging: staging != nil, needsReview: final != nil)
    }

    private func removePartFileIfPresent(for path: String?) -> Int {
        guard let path else {
            return 0
        }

        let partURL = URL(fileURLWithPath: path + ".part", isDirectory: false)
        guard fileManager.fileExists(atPath: partURL.path) else {
            return 0
        }

        do {
            try fileManager.removeItem(at: partURL)
            return 1
        } catch {
            return 0
        }
    }
}
