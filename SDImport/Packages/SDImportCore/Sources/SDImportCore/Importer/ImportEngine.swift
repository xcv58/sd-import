import Foundation

public struct ImportEngine {
    private let fileManager: FileManager
    private let jobRepository: JobRepository
    private let dedupeRepository: DedupeRepository
    private let conflictResolver: ConflictResolver
    private let copyEngine: CopyEngine

    public init(
        fileManager: FileManager = .default,
        jobRepository: JobRepository,
        dedupeRepository: DedupeRepository,
        conflictResolver: ConflictResolver = ConflictResolver(),
        copyEngine: CopyEngine = CopyEngine()
    ) {
        self.fileManager = fileManager
        self.jobRepository = jobRepository
        self.dedupeRepository = dedupeRepository
        self.conflictResolver = conflictResolver
        self.copyEngine = copyEngine
    }

    @discardableResult
    public func importFiles(
        jobID: String,
        onProgress: ((ImportProgress) -> Void)? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> ImportResult {
        guard let job = try jobRepository.fetchJob(id: jobID) else {
            throw SDImportError.jobNotFound(jobID)
        }

        let files = try jobRepository.pendingFilesForImport(jobID: jobID)
        let totalFiles = files.count
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let startedAt = Date()
        var importedFiles = 0
        var skippedFiles = 0
        var failedFiles = 0
        var doneFiles = 0
        var processedBytes: Int64 = 0
        var copiedBytes: Int64 = 0
        var activeFileBytes: Int64 = 0
        var currentFile: JobFileRecord?

        try jobRepository.updateJobStatus(id: jobID, status: .importing, startedAt: startedAt)

        func emit(status: String, forceProcessedBytes: Int64? = nil) {
            let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
            let displayedProcessed = forceProcessedBytes ?? min(totalBytes, processedBytes + activeFileBytes)
            let throughput = Double(displayedProcessed) / elapsed
            let remainingBytes = max(0, totalBytes - displayedProcessed)
            let eta = throughput > 1 ? Double(remainingBytes) / throughput : nil
            let percent: Double
            if totalBytes > 0 {
                percent = (Double(displayedProcessed) / Double(totalBytes)) * 100.0
            } else if totalFiles > 0 {
                percent = (Double(doneFiles) / Double(totalFiles)) * 100.0
            } else {
                percent = 100.0
            }

            onProgress?(
                ImportProgress(
                    jobID: jobID,
                    volumeName: job.volumeName,
                    status: status,
                    startedAt: startedAt,
                    updatedAt: Date(),
                    totalFiles: totalFiles,
                    doneFiles: doneFiles,
                    importedFiles: importedFiles,
                    skippedFiles: skippedFiles,
                    failedFiles: failedFiles,
                    totalBytes: totalBytes,
                    processedBytes: displayedProcessed,
                    copiedBytes: copiedBytes + activeFileBytes,
                    throughputBytesPerSecond: throughput,
                    etaSeconds: eta,
                    percent: percent,
                    currentFilename: currentFile?.filename,
                    currentSourcePath: currentFile?.sourcePath,
                    reportPath: job.summaryMarkdownPath
                )
            )
        }

        emit(status: totalFiles == 0 ? "idle" : "copying")

        func cancelImport(currentFileID: Int64? = nil) throws -> Never {
            if let currentFileID {
                try jobRepository.updateFileCopyStatus(
                    id: currentFileID,
                    status: .pending,
                    error: "cancelled",
                    completedAt: nil
                )
            }
            try jobRepository.refreshImportTotals(
                jobID: jobID,
                finalStatus: .cancelled,
                completedAt: Date()
            )
            emit(status: "aborted")
            throw SDImportError.cancelled
        }

        for file in files {
            guard let fileID = file.id else {
                throw SDImportError.invalidDatabaseValue(column: "job_files.id", value: "nil")
            }
            if shouldCancel() {
                try cancelImport()
            }

            currentFile = file
            activeFileBytes = 0
            emit(status: "copying")

            let sourceURL = URL(fileURLWithPath: file.sourcePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                failedFiles += 1
                doneFiles += 1
                processedBytes += file.size
                try jobRepository.updateFileCopyStatus(
                    id: fileID,
                    status: .failed,
                    error: "source file missing"
                )
                currentFile = nil
                activeFileBytes = 0
                emit(status: "copying")
                continue
            }

            let fingerprint = FileFingerprint(
                size: file.size,
                modificationDate: modificationDate(from: file.modificationDateString) ?? Date(timeIntervalSince1970: 0),
                modificationDateString: file.modificationDateString,
                identityHint: file.relativePath ?? file.filename,
                value: FileFingerprint.compute(
                    size: file.size,
                    modificationDateString: file.modificationDateString,
                    identityHint: file.relativePath ?? file.filename
                ).value
            )

            if try dedupeRepository.contains(fingerprint) {
                skippedFiles += 1
                doneFiles += 1
                processedBytes += file.size
                try jobRepository.updateFileCopyStatus(
                    id: fileID,
                    status: .skipped,
                    error: "already_imported_fingerprint"
                )
                currentFile = nil
                activeFileBytes = 0
                emit(status: "copying")
                continue
            }

            guard let destinationDirectory = file.destinationDirectory else {
                throw SDImportError.missingDestinationDirectory(file.id)
            }

            let candidate = file.plannedDestinationPath.map {
                URL(fileURLWithPath: $0, isDirectory: false)
            } ?? URL(fileURLWithPath: destinationDirectory, isDirectory: true)
                .appendingPathComponent(file.filename, isDirectory: false)

            switch conflictResolver.resolveDestination(candidate: candidate, expectedFingerprint: fingerprint) {
            case .skip(let reason):
                skippedFiles += 1
                doneFiles += 1
                processedBytes += file.size
                try jobRepository.updateFileCopyStatus(
                    id: fileID,
                    status: .skipped,
                    error: reason
                )
                try dedupeRepository.recordImported(
                    fingerprint,
                    jobID: jobID,
                    sourcePath: file.sourcePath
                )
            case .copy(let destinationURL):
                do {
                    try copyEngine.copyFile(
                        from: sourceURL,
                        to: destinationURL,
                        expectedSize: file.size,
                        modificationDate: modificationDate(from: file.modificationDateString),
                        onChunk: { chunkSize in
                            activeFileBytes = min(file.size, activeFileBytes + Int64(chunkSize))
                            emit(status: "copying")
                        },
                        shouldCancel: shouldCancel
                    )
                    importedFiles += 1
                    doneFiles += 1
                    processedBytes += file.size
                    copiedBytes += file.size
                    try jobRepository.updateFileCopyStatus(
                        id: fileID,
                        status: .copied,
                        finalDestinationPath: destinationURL.path,
                        error: nil
                    )
                    try dedupeRepository.recordImported(
                        fingerprint,
                        jobID: jobID,
                        sourcePath: file.sourcePath
                    )
                } catch SDImportError.cancelled {
                    try cancelImport(currentFileID: fileID)
                } catch {
                    failedFiles += 1
                    doneFiles += 1
                    processedBytes += file.size
                    try jobRepository.updateFileCopyStatus(
                        id: fileID,
                        status: .failed,
                        error: String(describing: error)
                    )
                }
            }

            currentFile = nil
            activeFileBytes = 0
            emit(status: "copying")
        }

        let terminalStatus = failedFiles > 0 ? "completed_with_errors" : (totalFiles == 0 ? "idle" : "completed")
        let finalJobStatus: ImportJobStatus = failedFiles > 0 ? .importedWithErrors : .imported
        try jobRepository.refreshImportTotals(
            jobID: jobID,
            finalStatus: finalJobStatus,
            completedAt: Date()
        )
        emit(status: terminalStatus, forceProcessedBytes: totalBytes)

        return ImportResult(
            jobID: jobID,
            importedFiles: importedFiles,
            skippedFiles: skippedFiles,
            failedFiles: failedFiles,
            progressPath: nil
        )
    }

    private func modificationDate(from string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: string)
    }
}
