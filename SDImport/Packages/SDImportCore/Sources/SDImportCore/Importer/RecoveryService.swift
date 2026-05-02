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

        for job in interruptedJobs {
            let files = try jobRepository.fetchJobFiles(jobID: job.id)
            for file in files {
                removedPartFiles += removePartFileIfPresent(for: file.plannedDestinationPath)
                removedPartFiles += removePartFileIfPresent(for: file.finalDestinationPath)
            }

            try jobRepository.resetPendingFilesAfterInterruption(jobID: job.id)
            try jobRepository.refreshImportTotals(
                jobID: job.id,
                finalStatus: .failed,
                completedAt: Date()
            )
        }

        return RecoverySummary(
            recoveredJobs: interruptedJobs.count,
            removedPartFiles: removedPartFiles
        )
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
