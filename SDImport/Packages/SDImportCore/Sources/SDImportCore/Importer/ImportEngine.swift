import Foundation

public struct ImportEngine {
    private static let modificationDateFormatterKey = "SDImport.ImportEngine.modificationDateFormatter"

    private let fileManager: FileManager
    private let jobRepository: JobRepository
    private let dedupeRepository: DedupeRepository
    private let conflictResolver: ConflictResolver
    private let copyEngine: CopyEngine
    private let destinationSpaceChecker: DestinationSpaceChecker
    private let reportWriter: ReportWriter
    private let portableReceiptsEnabled: Bool

    public init(
        fileManager: FileManager = .default,
        jobRepository: JobRepository,
        dedupeRepository: DedupeRepository,
        conflictResolver: ConflictResolver = ConflictResolver(),
        copyEngine: CopyEngine = CopyEngine(),
        destinationSpaceChecker: DestinationSpaceChecker = DestinationSpaceChecker(),
        reportWriter: ReportWriter = ReportWriter(),
        portableReceiptsEnabled: Bool = false
    ) {
        self.fileManager = fileManager
        self.jobRepository = jobRepository
        self.dedupeRepository = dedupeRepository
        self.conflictResolver = conflictResolver
        self.copyEngine = copyEngine
        self.destinationSpaceChecker = destinationSpaceChecker
        self.reportWriter = reportWriter
        self.portableReceiptsEnabled = portableReceiptsEnabled
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
        var currentDestinationPath: String?
        var recentFiles: [ImportProgressFileEvent] = []
        var progressEventSequence = 0
        let destinationDirectories = Self.destinationDirectories(for: files)
        let portableLedger = PortableImportReceiptLedger(
            sourceRootURL: URL(fileURLWithPath: job.mountPath, isDirectory: true)
        )
        var portableFingerprints: Set<String> = []
        var portableLedgerRevision: PortableImportReceiptLedgerRevision?
        var portableReceiptWarning: String?
        var portableWritesAvailable = portableReceiptsEnabled

        func refreshPortableFingerprints() {
            guard portableReceiptsEnabled else {
                return
            }
            do {
                guard let snapshot = try portableLedger.load(
                    ifChangedSince: portableLedgerRevision
                ) else {
                    return
                }
                portableFingerprints = snapshot.fingerprints
                portableLedgerRevision = snapshot.revision
                if let warning = snapshot.warning {
                    portableReceiptWarning = warning
                }
            } catch {
                portableFingerprints.removeAll()
                portableWritesAvailable = false
                portableReceiptWarning = L10n.tr("Portable import history is unavailable: \(error.localizedDescription)")
            }
        }

        func hasPortableReceipt(_ identity: PortableFileIdentity?, file: JobFileRecord) -> Bool {
            guard
                portableReceiptsEnabled,
                file.portableReceiptOverride != true,
                let identity
            else {
                return false
            }
            let portableFingerprint = PortableImportReceiptLedger.portableFingerprint(for: identity)
            return portableFingerprints.contains(portableFingerprint)
        }

        func recordPortableReceipt(_ identity: PortableFileIdentity?, file: JobFileRecord) {
            guard
                portableWritesAvailable,
                let identity
            else {
                return
            }
            guard validatedPortableIdentity(for: file) == identity else {
                portableReceiptWarning = L10n.tr("Portable import history was not updated because the source changed during import")
                return
            }
            let portableFingerprint = PortableImportReceiptLedger.portableFingerprint(for: identity)
            guard
                !portableFingerprints.contains(portableFingerprint)
            else {
                return
            }
            do {
                let appendResult = try portableLedger.appendReturningRevision(
                    identity: identity
                )
                if let warning = appendResult.warning {
                    portableReceiptWarning = warning
                }
                if appendResult.previousRevision == portableLedgerRevision {
                    portableLedgerRevision = appendResult.revision
                    portableFingerprints.insert(portableFingerprint)
                } else {
                    let snapshot = try portableLedger.load()
                    portableFingerprints = snapshot.fingerprints
                    portableLedgerRevision = snapshot.revision
                    if let warning = snapshot.warning {
                        portableReceiptWarning = warning
                    }
                }
            } catch {
                portableWritesAvailable = false
                portableReceiptWarning = L10n.tr("Portable import history could not be updated: \(error.localizedDescription)")
            }
        }

        refreshPortableFingerprints()

        let filesNeedingDestinationSpace = try files.filter { file in
            let portableIdentity: PortableFileIdentity?
            if portableReceiptsEnabled {
                guard let validatedIdentity = validatedPortableIdentity(for: file) else {
                    return false
                }
                portableIdentity = validatedIdentity
            } else {
                portableIdentity = nil
            }
            let fingerprint = fingerprint(for: file, currentIdentity: portableIdentity)
            if try dedupeRepository.contains(fingerprint)
                || hasPortableReceipt(portableIdentity, file: file)
            {
                return false
            }
            guard let plannedDestinationPath = file.plannedDestinationPath else {
                return true
            }
            let candidate = URL(fileURLWithPath: plannedDestinationPath, isDirectory: false)
            switch conflictResolver.resolveDestination(candidate: candidate, expectedFingerprint: fingerprint) {
            case .skip:
                return false
            case .copy:
                return true
            }
        }

        let spaceCheck = try destinationSpaceChecker.check(files: filesNeedingDestinationSpace)
        if let failure = spaceCheck.failures.first {
            throw SDImportError.insufficientDestinationSpace(
                path: failure.displayPath,
                requiredBytes: failure.requiredBytes,
                availableBytes: failure.availableBytes
            )
        }

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
                    currentDestinationPath: currentDestinationPath,
                    destinationDirectories: destinationDirectories,
                    recentFiles: recentFiles,
                    reportPath: job.summaryMarkdownPath
                )
            )
        }

        func recordFileEvent(
            file: JobFileRecord,
            status: CopyStatus,
            detail: String?,
            destinationPath: String?
        ) {
            progressEventSequence += 1
            recentFiles.insert(
                ImportProgressFileEvent(
                    id: "\(file.id ?? -1)-\(progressEventSequence)",
                    filename: file.filename,
                    status: status,
                    detail: detail,
                    destinationPath: destinationPath,
                    size: file.size
                ),
                at: 0
            )
            if recentFiles.count > 6 {
                recentFiles.removeLast(recentFiles.count - 6)
            }
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
            currentDestinationPath = file.plannedDestinationPath
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
                currentDestinationPath = nil
                activeFileBytes = 0
                recordFileEvent(file: file, status: .failed, detail: "source file missing", destinationPath: nil)
                emit(status: "copying")
                continue
            }

            let portableIdentity: PortableFileIdentity?
            if portableReceiptsEnabled {
                guard let validatedIdentity = validatedPortableIdentity(for: file) else {
                    failedFiles += 1
                    doneFiles += 1
                    processedBytes += file.size
                    let detail = "source changed since scan; rescan required"
                    try jobRepository.updateFileCopyStatus(
                        id: fileID,
                        status: .failed,
                        error: detail
                    )
                    currentFile = nil
                    currentDestinationPath = nil
                    activeFileBytes = 0
                    recordFileEvent(file: file, status: .failed, detail: detail, destinationPath: nil)
                    emit(status: "copying")
                    continue
                }
                portableIdentity = validatedIdentity
            } else {
                portableIdentity = nil
            }
            let fingerprint = fingerprint(for: file, currentIdentity: portableIdentity)
            refreshPortableFingerprints()

            if try dedupeRepository.contains(fingerprint) {
                skippedFiles += 1
                doneFiles += 1
                processedBytes += file.size
                try jobRepository.updateFileCopyStatus(
                    id: fileID,
                    status: .skipped,
                    error: "already_imported_fingerprint",
                    decision: .known,
                    knownSource: .localLedger
                )
                currentFile = nil
                currentDestinationPath = nil
                activeFileBytes = 0
                recordFileEvent(
                    file: file,
                    status: .skipped,
                    detail: "Already imported",
                    destinationPath: file.plannedDestinationPath
                )
                emit(status: "copying")
                continue
            }

            if hasPortableReceipt(portableIdentity, file: file) {
                skippedFiles += 1
                doneFiles += 1
                processedBytes += file.size
                try jobRepository.updateFileCopyStatus(
                    id: fileID,
                    status: .skipped,
                    error: "already_imported_portable_receipt",
                    decision: .known,
                    knownSource: .portableLedger
                )
                currentFile = nil
                currentDestinationPath = nil
                activeFileBytes = 0
                recordFileEvent(
                    file: file,
                    status: .skipped,
                    detail: "Imported on another Mac",
                    destinationPath: file.plannedDestinationPath
                )
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
                    error: reason,
                    decision: .known,
                    knownSource: .destination
                )
                try dedupeRepository.recordImported(
                    fingerprint,
                    jobID: jobID,
                    sourcePath: file.sourcePath
                )
                recordPortableReceipt(portableIdentity, file: file)
                recordFileEvent(
                    file: file,
                    status: .skipped,
                    detail: reason,
                    destinationPath: candidate.path
                )
            case .copy(let destinationURL):
                do {
                    currentDestinationPath = destinationURL.path
                    emit(status: "copying")
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
                    recordPortableReceipt(portableIdentity, file: file)
                    recordFileEvent(
                        file: file,
                        status: .copied,
                        detail: "Size checked",
                        destinationPath: destinationURL.path
                    )
                } catch SDImportError.cancelled {
                    try cancelImport(currentFileID: fileID)
                } catch {
                    failedFiles += 1
                    doneFiles += 1
                    processedBytes += file.size
                    let detail = L10n.errorMessage(for: error)
                    try jobRepository.updateFileCopyStatus(
                        id: fileID,
                        status: .failed,
                        error: detail
                    )
                    recordFileEvent(
                        file: file,
                        status: .failed,
                        detail: detail,
                        destinationPath: destinationURL.path
                    )
                }
            }

            currentFile = nil
            currentDestinationPath = nil
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
        rewriteReportIfPossible(jobID: jobID)
        emit(status: terminalStatus, forceProcessedBytes: totalBytes)

        return ImportResult(
            jobID: jobID,
            importedFiles: importedFiles,
            skippedFiles: skippedFiles,
            failedFiles: failedFiles,
            progressPath: nil,
            portableReceiptWarning: portableReceiptWarning
        )
    }

    private func modificationDate(from string: String) -> Date? {
        if let formatter = Thread.current.threadDictionary[Self.modificationDateFormatterKey] as? DateFormatter {
            return formatter.date(from: string)
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        Thread.current.threadDictionary[Self.modificationDateFormatterKey] = formatter
        return formatter.date(from: string)
    }

    private static func destinationDirectories(for files: [JobFileRecord]) -> [String] {
        let directories = files.compactMap { file -> String? in
            if let destinationPath = file.plannedDestinationPath {
                return URL(fileURLWithPath: destinationPath, isDirectory: false)
                    .deletingLastPathComponent()
                    .path
            }
            return file.destinationDirectory
        }
        return Array(Set(directories))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func fingerprint(
        for file: JobFileRecord,
        currentIdentity: PortableFileIdentity?
    ) -> FileFingerprint {
        if file.modificationTimeEpochSeconds == nil, let currentIdentity {
            return FileFingerprint.compute(
                size: currentIdentity.size,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(
                    currentIdentity.modificationTimeEpochSeconds
                )),
                identityHint: currentIdentity.relativePath
            )
        }

        return FileFingerprint(
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
    }

    private func validatedPortableIdentity(for file: JobFileRecord) -> PortableFileIdentity? {
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: file.sourcePath),
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            size == file.size,
            let modificationDate = attributes[.modificationDate] as? Date
        else {
            return nil
        }
        let identity = PortableFileIdentity(
            size: size,
            modificationDate: modificationDate,
            relativePath: file.relativePath ?? file.filename
        )
        guard
            file.modificationTimeEpochSeconds == nil
                || file.modificationTimeEpochSeconds == identity.modificationTimeEpochSeconds
        else {
            return nil
        }
        return identity
    }

    private func rewriteReportIfPossible(jobID: String) {
        guard
            let job = try? jobRepository.fetchJob(id: jobID),
            let reportPath = job.summaryMarkdownPath ?? job.summaryJSONPath
        else {
            return
        }

        let files = (try? jobRepository.fetchJobFiles(jobID: jobID)) ?? []
        let summary = ScanSummary(
            jobID: job.id,
            mountPath: job.mountPath,
            volumeName: job.volumeName,
            volumeUUID: job.volumeUUID,
            location: job.location,
            scannedFiles: job.scannedFiles,
            newFiles: job.newFiles,
            knownFiles: job.knownFiles,
            unsupportedFiles: job.unsupportedFiles,
            conflictFiles: job.conflictFiles
        )
        let baseURL = URL(fileURLWithPath: reportPath, isDirectory: false).deletingPathExtension()
        _ = try? reportWriter.writeReport(summary: summary, files: files, baseURL: baseURL)
    }
}
