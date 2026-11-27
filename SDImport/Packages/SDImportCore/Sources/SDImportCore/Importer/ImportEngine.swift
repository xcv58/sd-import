import Darwin
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
    private let reviewedInsta360RescanMembers: Set<Int64>
    private let reviewedDestinations: ReviewedImportDestinations?
    private let reviewedSourceFiles: [String: ReviewedFileIdentity]?
    private let preserveUntouchedScanOnCancellation: () -> Bool

    public init(
        fileManager: FileManager = .default,
        jobRepository: JobRepository,
        dedupeRepository: DedupeRepository,
        conflictResolver: ConflictResolver = ConflictResolver(),
        copyEngine: CopyEngine = CopyEngine(),
        destinationSpaceChecker: DestinationSpaceChecker = DestinationSpaceChecker(),
        reportWriter: ReportWriter = ReportWriter(),
        portableReceiptsEnabled: Bool = false,
        reviewedInsta360RescanMembers: Set<Int64> = [],
        reviewedDestinations: ReviewedImportDestinations? = nil,
        reviewedSourceFiles: [String: ReviewedFileIdentity]? = nil,
        preserveUntouchedScanOnCancellation: @escaping () -> Bool = { false }
    ) {
        self.fileManager = fileManager
        self.jobRepository = jobRepository
        self.dedupeRepository = dedupeRepository
        self.conflictResolver = conflictResolver
        self.copyEngine = copyEngine
        self.destinationSpaceChecker = destinationSpaceChecker
        self.reportWriter = reportWriter
        self.portableReceiptsEnabled = portableReceiptsEnabled
        self.reviewedInsta360RescanMembers = reviewedInsta360RescanMembers
        self.reviewedDestinations = reviewedDestinations
        self.reviewedSourceFiles = reviewedSourceFiles
        self.preserveUntouchedScanOnCancellation = preserveUntouchedScanOnCancellation
    }

    private func isHistoryExcluded(_ file: JobFileRecord) -> Bool {
        file.reimportRequested != true
            && file.decision == .known
            && (file.knownSource == .localLedger || file.knownSource == .portableLedger)
    }

    private func verifyReviewedHistorySkips(files: [JobFileRecord], sourcePath: String) throws {
        let excluded = files.filter {
            isHistoryExcluded($0) && $0.error != "excluded_by_import_selection"
        }
        guard !excluded.isEmpty else { return }
        guard excluded.allSatisfy({ validatedPortableIdentity(for: $0) != nil }) else {
            throw SDImportError.reviewedSourceChanged
        }
        let history = refreshedReviewHistory(files: excluded, sourcePath: sourcePath)
        guard excluded.allSatisfy({ file in
            guard let id = file.id, let source = file.knownSource else { return false }
            return history[id] == .known(source)
        }) else { throw SDImportError.reviewedDestinationChanged }
    }

    public func refreshedReviewHistory(files: [JobFileRecord], sourcePath: String) -> [Int64: ImportHistoryMatch] {
        let portableFingerprints = portableReceiptsEnabled
            ? (try? PortableImportReceiptLedger(sourceRootURL: URL(fileURLWithPath: sourcePath))
                .load().fingerprints) ?? []
            : []
        var matches: [Int64: ImportHistoryMatch] = [:]
        for file in files where file.reimportRequested != true && (file.isPendingImport || isHistoryExcluded(file)) {
            guard let id = file.id else { continue }
            if isHistoryExcluded(file) { matches[id] = .unmatched }
            let localMatch = (try? dedupeRepository.contains(fingerprint(for: file, currentIdentity: nil))) == true
            let portableMatchPossible = !portableFingerprints.isEmpty && file.portableReceiptOverride != true
            guard localMatch || portableMatchPossible, let identity = validatedPortableIdentity(for: file) else {
                continue
            }
            let localFingerprint = fingerprint(for: file, currentIdentity: portableReceiptsEnabled ? identity : nil)
            if (try? dedupeRepository.contains(localFingerprint)) == true {
                matches[id] = .known(.localLedger)
            } else if portableMatchPossible,
                      portableFingerprints.contains(PortableImportReceiptLedger.portableFingerprint(for: identity)) {
                matches[id] = .known(.portableLedger)
            }
        }
        return matches
    }

    @discardableResult
    public func importFiles(
        jobID: String,
        requiresReviewedDestinations: Bool = false,
        onProgress: ((ImportProgress) -> Void)? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> ImportResult {
        try importFiles(
            preparing: {}, jobID: jobID, requiresReviewedDestinations: requiresReviewedDestinations,
            onProgress: onProgress, shouldCancel: shouldCancel
        )
    }

    @discardableResult
    public func importFiles(
        preparing prepare: () throws -> Void,
        jobID: String,
        requiresReviewedDestinations: Bool,
        onProgress: ((ImportProgress) -> Void)? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> ImportResult {
        guard let result = try jobRepository.withImportLock(jobID: jobID, {
            try importFilesWhileLocked(
                jobID: jobID, requiresReviewedDestinations: requiresReviewedDestinations,
                prepare: prepare, onProgress: onProgress, shouldCancel: shouldCancel
            )
        }) else {
            throw SDImportError.invalidArgument(L10n.tr("Finish the current scan or import first"))
        }
        return result
    }

    private func importFilesWhileLocked(
        jobID: String,
        requiresReviewedDestinations userReviewedDestinations: Bool,
        prepare: () throws -> Void,
        onProgress: ((ImportProgress) -> Void)?,
        shouldCancel: () -> Bool
    ) throws -> ImportResult {
        let recovery = try RecoveryService(
            fileManager: fileManager, jobRepository: jobRepository, portableReceiptsEnabled: portableReceiptsEnabled
        ).recoverJobWhileLocked(jobID: jobID)
        if let unavailableFileID = recovery.unavailableFileID {
            throw SDImportError.missingDestinationDirectory(unavailableFileID)
        }
        if recovery.needsReview {
            throw SDImportError.reviewedDestinationChanged
        }
        guard let job = try jobRepository.fetchJob(id: jobID) else {
            throw SDImportError.jobNotFound(jobID)
        }

        if !userReviewedDestinations, try jobRepository.needsDestinationReview(jobID: jobID) {
            throw SDImportError.reviewedDestinationChanged
        }

        let requiresReviewedDestinations = userReviewedDestinations || recovery.resumedReviewedCopy
        if reviewedDestinations?.matches() == false { throw SDImportError.reviewedDestinationChanged }
        try prepare()
        let allFilesAtStart = try jobRepository.fetchJobFiles(jobID: jobID)
        let files = allFilesAtStart.filter(\.isPendingImport)
        if reviewedDestinations != nil {
            let reviewedSources = allFilesAtStart.filter {
                $0.isPendingImport || ($0.decision == .known && $0.knownSource == .destination
                    && $0.plannedDestinationPath != nil)
            }
            guard reviewedSources.allSatisfy({ validatedPortableIdentity(for: $0) != nil }) else {
                throw SDImportError.reviewedSourceChanged
            }
            try verifyReviewedHistorySkips(files: allFilesAtStart, sourcePath: job.mountPath)
        }
        let progressUnitIDBySourcePath = Insta360ClipDetector()
            .unitIDBySourcePath(files: allFilesAtStart)
        let progressUnitMembers = Dictionary(grouping: files) {
            progressUnitIDBySourcePath[$0.sourcePath] ?? "file:\($0.sourcePath)"
        }
        let totalFiles = progressUnitMembers.count
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.size }
        let startedAt = Date()
        var importedFiles = 0
        var skippedFiles = 0
        var failedFiles = 0
        var doneFiles = 0
        var completedStatusBySourcePath: [String: CopyStatus] = [:]
        var completedDetailBySourcePath: [String: String] = [:]
        var completedDestinationBySourcePath: [String: String] = [:]
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
        var portableReceiptWarning: String? = recovery.portableReceiptPending
            ? L10n.tr("Portable import history could not be updated: \(SDImportError.sourceFileMissing(URL(fileURLWithPath: job.mountPath)).localizedDescription)")
            : nil
        var portableReceiptSizeWarning: PortableReceiptSizeWarning?
        var portableWritesAvailable = portableReceiptsEnabled

        func markDone(_ file: JobFileRecord, status: CopyStatus) {
            completedStatusBySourcePath[file.sourcePath] = status
            let completedUnits = progressUnitMembers.values.compactMap { members -> CopyStatus? in
                let statuses = members.compactMap { completedStatusBySourcePath[$0.sourcePath] }
                guard statuses.count == members.count else { return nil }
                if statuses.contains(.failed) { return .failed }
                if statuses.contains(.copied) { return .copied }
                return .skipped
            }
            doneFiles = completedUnits.count
            importedFiles = completedUnits.filter { $0 == .copied }.count
            skippedFiles = completedUnits.filter { $0 == .skipped }.count
            failedFiles = completedUnits.filter { $0 == .failed }.count
        }

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
                    portableReceiptSizeWarning = nil
                }
            } catch {
                portableFingerprints.removeAll()
                portableWritesAvailable = false
                portableReceiptSizeWarning = PortableReceiptSizeWarning(error: error)
                portableReceiptWarning = L10n.tr("Portable import history is unavailable: \(error.localizedDescription)")
            }
        }

        func hasPortableReceipt(_ identity: PortableFileIdentity?, file: JobFileRecord) -> Bool {
            guard
                portableReceiptsEnabled,
                file.portableReceiptOverride != true,
                file.reimportRequested != true,
                let identity
            else {
                return false
            }
            let portableFingerprint = PortableImportReceiptLedger.portableFingerprint(for: identity)
            return portableFingerprints.contains(portableFingerprint)
        }

        func recordPortableReceipt(_ identity: PortableFileIdentity?, file: JobFileRecord) -> Bool {
            guard
                portableWritesAvailable,
                let identity
            else {
                return false
            }
            guard validatedPortableIdentity(for: file) == identity else {
                portableReceiptSizeWarning = nil
                portableReceiptWarning = L10n.tr("Portable import history was not updated because the source changed during import")
                return false
            }
            let portableFingerprint = PortableImportReceiptLedger.portableFingerprint(for: identity)
            guard
                !portableFingerprints.contains(portableFingerprint)
            else {
                return true
            }
            do {
                let appendResult = try portableLedger.appendReturningRevision(
                    identity: identity
                )
                if let warning = appendResult.warning {
                    portableReceiptWarning = warning
                    portableReceiptSizeWarning = nil
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
                        portableReceiptSizeWarning = nil
                    }
                }
                return true
            } catch {
                portableWritesAvailable = false
                portableReceiptSizeWarning = PortableReceiptSizeWarning(error: error)
                portableReceiptWarning = L10n.tr("Portable import history could not be updated: \(error.localizedDescription)")
                return false
            }
        }

        func stopForPlanChange(_ reason: SDImportError = .reviewedDestinationChanged) throws -> Never {
            let processedAnyFiles = !completedStatusBySourcePath.isEmpty
            try jobRepository.refreshImportTotals(
                jobID: jobID,
                finalStatus: processedAnyFiles ? .importedWithErrors : job.status,
                completedAt: processedAnyFiles ? Date() : job.completedAt,
                needsDestinationReview: true
            )
            throw reason
        }

        refreshPortableFingerprints()

        func isReviewedInsta360RescanMember(_ file: JobFileRecord) -> Bool {
            file.id.map { reviewedInsta360RescanMembers.contains($0) } == true
        }

        func verifyReviewedDestinationSkips() throws {
            for file in allFilesAtStart where file.decision == .known && file.knownSource == .destination {
                guard let path = file.plannedDestinationPath else { continue }
                if reviewedDestinations != nil, validatedPortableIdentity(for: file) == nil {
                    try stopForPlanChange(.reviewedSourceChanged)
                }
                if reviewedDestinations?.matchesSkippedFile(at: path) == false {
                    try stopForPlanChange()
                }
                let candidate = URL(fileURLWithPath: path, isDirectory: false)
                if isReviewedInsta360RescanMember(file) {
                    guard try !jobRepository.isUnverifiedDestination(candidate),
                          Insta360RescanRecovery.matchesSource(file, at: candidate, using: copyEngine)
                    else {
                        if shouldCancel() { throw SDImportError.cancelled }
                        throw SDImportError.insta360RescanCopyChanged
                    }
                    continue
                }
                let fingerprint = fingerprint(for: file, currentIdentity: nil)
                guard case .skip = try conflictResolver.resolveDestination(
                    candidate: candidate,
                    expectedFingerprint: fingerprint,
                    allowsRename: false,
                    rejectMatch: jobRepository.isUnverifiedDestination
                ) else {
                    try stopForPlanChange()
                }
            }
        }
        if requiresReviewedDestinations { try verifyReviewedDestinationSkips() }

        let pendingSourcePaths = Set(files.map(\.sourcePath))
        for group in Insta360ClipDetector().groups(files: allFilesAtStart) {
            let pendingMembers = group.files.filter { pendingSourcePaths.contains($0.sourcePath) }
            guard !pendingMembers.isEmpty else { continue }
            if pendingMembers.contains(where: isReviewedInsta360RescanMember) {
                let masterFolders = group.masterFiles.compactMap { member in
                    member.plannedDestinationPath.map {
                        URL(fileURLWithPath: $0).deletingLastPathComponent().resolvingSymlinksInPath()
                    }
                }
                guard masterFolders.count == group.masterFiles.count, Set(masterFolders).count == 1 else {
                    throw SDImportError.insta360RescanCopyChanged
                }
            }
            var destinationPaths: Set<String> = []
            for member in pendingMembers {
                guard let plannedDestinationPath = member.plannedDestinationPath else { continue }
                let candidate = URL(fileURLWithPath: plannedDestinationPath, isDirectory: false)
                let destinationKey = candidate.standardizedFileURL.path
                    .precomposedStringWithCanonicalMapping
                guard destinationPaths.insert(destinationKey).inserted else {
                    throw SDImportError.destinationFilenameConflict(candidate.path)
                }
                let portableIdentity = portableReceiptsEnabled
                    ? validatedPortableIdentity(for: member)
                    : nil
                let memberFingerprint = fingerprint(for: member, currentIdentity: portableIdentity)
                if case .blocked = try conflictResolver.resolveDestination(
                    candidate: candidate,
                    expectedFingerprint: memberFingerprint,
                    allowsRename: false,
                    rejectMatch: jobRepository.isUnverifiedDestination
                ) {
                    if requiresReviewedDestinations { try stopForPlanChange() }
                    throw SDImportError.destinationFilenameConflict(candidate.path)
                }
            }
        }

        let filesNeedingDestinationSpace = try files.filter { file in
            let portableIdentity: PortableFileIdentity?
            if portableReceiptsEnabled || reviewedDestinations != nil {
                guard let validatedIdentity = validatedPortableIdentity(for: file) else {
                    if reviewedDestinations != nil { try stopForPlanChange(.reviewedSourceChanged) }
                    return false
                }
                portableIdentity = portableReceiptsEnabled ? validatedIdentity : nil
            } else {
                portableIdentity = nil
            }
            let fingerprint = fingerprint(for: file, currentIdentity: portableIdentity)
            if !isReviewedInsta360RescanMember(file), file.reimportRequested != true,
               try dedupeRepository.contains(fingerprint) || hasPortableReceipt(portableIdentity, file: file)
            {
                if reviewedDestinations != nil { try stopForPlanChange() }
                return false
            }
            guard let plannedDestinationPath = file.plannedDestinationPath else {
                return true
            }
            let candidate = URL(fileURLWithPath: plannedDestinationPath, isDirectory: false)
            switch try conflictResolver.resolveDestination(
                candidate: candidate,
                expectedFingerprint: fingerprint,
                allowsRename: !requiresReviewedDestinations && !Insta360ClipDetector.isProprietaryRecordingFile(file),
                rejectMatch: jobRepository.isUnverifiedDestination
            ) {
            case .skip:
                if requiresReviewedDestinations { try stopForPlanChange() }
                return false
            case .copy:
                return true
            case .blocked:
                if requiresReviewedDestinations { try stopForPlanChange() }
                throw SDImportError.destinationFilenameConflict(candidate.path)
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

        try jobRepository.updateJobStatus(
            id: jobID, status: .importing, startedAt: startedAt,
            needsDestinationReview: requiresReviewedDestinations ? true : nil
        )

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
            let currentProgressFilename: String?
            if let currentFile,
               let unitID = progressUnitIDBySourcePath[currentFile.sourcePath],
               unitID.hasPrefix("insta360:") {
                let memberCount = progressUnitMembers[unitID]?.count ?? 1
                currentProgressFilename = "Insta360 · \(L10n.tr("\(memberCount) files"))"
            } else {
                currentProgressFilename = currentFile?.filename
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
                    currentFilename: currentProgressFilename,
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
            status _: CopyStatus,
            detail: String?,
            destinationPath: String?
        ) {
            if let detail {
                completedDetailBySourcePath[file.sourcePath] = detail
            }
            if let destinationPath {
                completedDestinationBySourcePath[file.sourcePath] = destinationPath
            }
            let unitID = progressUnitIDBySourcePath[file.sourcePath] ?? "file:\(file.sourcePath)"
            let members = progressUnitMembers[unitID] ?? [file]
            let completedStatuses = members.compactMap { completedStatusBySourcePath[$0.sourcePath] }
            guard completedStatuses.count == members.count else { return }
            let unitStatus: CopyStatus
            if completedStatuses.contains(.failed) {
                unitStatus = .failed
            } else if completedStatuses.contains(.copied) {
                unitStatus = .copied
            } else {
                unitStatus = .skipped
            }
            let representative = members.first {
                completedStatusBySourcePath[$0.sourcePath] == unitStatus
            } ?? file
            progressEventSequence += 1
            recentFiles.insert(
                ImportProgressFileEvent(
                    id: "\(unitID)-\(progressEventSequence)",
                    filename: unitID.hasPrefix("insta360:") ? "Insta360" : file.filename,
                    status: unitStatus,
                    detail: completedDetailBySourcePath[representative.sourcePath] ?? detail,
                    destinationPath: completedDestinationBySourcePath[representative.sourcePath]
                        ?? destinationPath,
                    size: members.reduce(Int64(0)) { $0 + $1.size },
                    memberCount: members.count
                ),
                at: 0
            )
            if recentFiles.count > 6 {
                recentFiles.removeLast(recentFiles.count - 6)
            }
        }

        emit(status: totalFiles == 0 ? "idle" : "copying")

        func cancelImport(
            currentFileID: Int64? = nil, reason: SDImportError = .cancelled
        ) throws -> Never {
            if let currentFileID {
                try jobRepository.updateFileCopyStatus(
                    id: currentFileID,
                    status: .pending,
                    error: "cancelled",
                    completedAt: nil
                )
            }
            let untouched = try reason == .cancelled && reviewedDestinations != nil && job.status == .scanned
                && completedStatusBySourcePath.isEmpty && !jobRepository.hasUnresolvedCopies(jobID: jobID)
                && preserveUntouchedScanOnCancellation()
            try jobRepository.refreshImportTotals(
                jobID: jobID,
                finalStatus: untouched ? .scanned : .cancelled,
                completedAt: untouched ? nil : Date()
            )
            emit(status: "aborted")
            throw reason
        }

        for file in files {
            guard let fileID = file.id else {
                throw SDImportError.invalidDatabaseValue(column: "job_files.id", value: "nil")
            }
            if shouldCancel() {
                try cancelImport()
            }
            do {
                try copyEngine.verifySourceDirectory()
            } catch SDImportError.sourceVolumeUnavailable {
                try cancelImport(reason: .sourceVolumeUnavailable)
            }

            currentFile = file
            currentDestinationPath = file.plannedDestinationPath
            activeFileBytes = 0
            emit(status: "copying")

            let sourceURL = URL(fileURLWithPath: file.sourcePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                if reviewedDestinations != nil { try stopForPlanChange(.reviewedSourceChanged) }
                markDone(file, status: .failed)
                processedBytes += file.size
                try jobRepository.updateFileCopyStatus(
                    id: fileID,
                    status: .failed,
                    error: "source file missing"
                )
                currentFile = nil
                currentDestinationPath = nil
                activeFileBytes = 0
                recordFileEvent(
                    file: file,
                    status: .failed,
                    detail: "source file missing",
                    destinationPath: file.plannedDestinationPath
                )
                emit(status: "copying")
                continue
            }

            let portableIdentity: PortableFileIdentity?
            if portableReceiptsEnabled || reviewedDestinations != nil {
                guard let validatedIdentity = validatedPortableIdentity(for: file) else {
                    if reviewedDestinations != nil { try stopForPlanChange(.reviewedSourceChanged) }
                    markDone(file, status: .failed)
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
                    recordFileEvent(
                        file: file,
                        status: .failed,
                        detail: detail,
                        destinationPath: file.plannedDestinationPath
                    )
                    emit(status: "copying")
                    continue
                }
                portableIdentity = portableReceiptsEnabled ? validatedIdentity : nil
            } else {
                portableIdentity = nil
            }
            let fingerprint = fingerprint(for: file, currentIdentity: portableIdentity)
            refreshPortableFingerprints()

            if !isReviewedInsta360RescanMember(file), file.reimportRequested != true,
               try dedupeRepository.contains(fingerprint) {
                if reviewedDestinations != nil { try stopForPlanChange() }
                markDone(file, status: .skipped)
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

            if !isReviewedInsta360RescanMember(file), hasPortableReceipt(portableIdentity, file: file) {
                if reviewedDestinations != nil { try stopForPlanChange() }
                markDone(file, status: .skipped)
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

            switch try conflictResolver.resolveDestination(
                candidate: candidate,
                expectedFingerprint: fingerprint,
                allowsRename: !requiresReviewedDestinations && !Insta360ClipDetector.isProprietaryRecordingFile(file),
                rejectMatch: jobRepository.isUnverifiedDestination
            ) {
            case .skip(let matchedURL, let reason):
                if requiresReviewedDestinations { try stopForPlanChange() }
                try jobRepository.recordDestinationSkip(
                    fileID: fileID, jobID: jobID, sourcePath: file.sourcePath,
                    fingerprint: fingerprint, destination: matchedURL, reason: reason
                )
                markDone(file, status: .skipped)
                processedBytes += file.size
                _ = recordPortableReceipt(portableIdentity, file: file)
                recordFileEvent(
                    file: file,
                    status: .skipped,
                    detail: reason,
                    destinationPath: matchedURL.path
                )
            case .blocked:
                if requiresReviewedDestinations { try stopForPlanChange() }
                throw SDImportError.destinationFilenameConflict(candidate.path)
            case .copy(let destinationURL):
                var attempt = ImportCopyAttempt(
                    id: UUID(), fileID: fileID, jobID: jobID, sourcePath: file.sourcePath,
                    destinationPath: destinationURL.path, fingerprint: fingerprint,
                    requiresDestinationReview: requiresReviewedDestinations
                )
                if let portableIdentity,
                   let rootIdentity = ImportCopyDirectoryIdentity(at: URL(fileURLWithPath: job.mountPath)) {
                    attempt.portableReceipt = CopyPortableReceipt(
                        rootPath: job.mountPath, rootIdentity: rootIdentity, fileIdentity: portableIdentity
                    )
                }
                currentDestinationPath = destinationURL.path
                emit(status: "copying")
                let published: ImportCopyAttempt
                let openDestination: OpenImportDestination?
                do {
                    (published, openDestination) = try copyToDestination(
                        attempt, from: sourceURL, modificationDate: modificationDate(from: file.modificationDateString),
                        expectedSourceEpoch: reviewedDestinations == nil ? nil : file.modificationTimeEpochSeconds,
                        reviewedSource: reviewedSourceFiles?[file.sourcePath],
                        onChunk: { chunkSize in
                            activeFileBytes = min(file.size, activeFileBytes + Int64(chunkSize))
                            emit(status: "copying")
                        },
                        shouldCancel: shouldCancel
                    )
                } catch SDImportError.cancelled {
                    try cancelImport(currentFileID: fileID)
                } catch SDImportError.sourceVolumeUnavailable {
                    try cancelImport(currentFileID: fileID, reason: .sourceVolumeUnavailable)
                } catch SDImportError.reviewedDestinationChanged where reviewedDestinations != nil {
                    try stopForPlanChange()
                } catch SDImportError.reviewedSourceChanged {
                    try stopForPlanChange(.reviewedSourceChanged)
                } catch CocoaError.fileWriteFileExists where requiresReviewedDestinations {
                    try stopForPlanChange()
                } catch {
                    if reviewedDestinations != nil, validatedPortableIdentity(for: file) == nil {
                        try stopForPlanChange(.reviewedSourceChanged)
                    }
                    // Cleanup errors may leave a journal entry. Recovery owns those attempts.
                    if try jobRepository.copyAttempts(jobID: jobID).contains(where: { $0.fileID == fileID }) {
                        try? jobRepository.refreshImportTotals(jobID: jobID, finalStatus: .failed)
                        throw error
                    }
                    let detail = L10n.errorMessage(for: error)
                    try jobRepository.updateFileCopyStatus(id: fileID, status: .failed, error: detail)
                    markDone(file, status: .failed)
                    processedBytes += file.size
                    recordFileEvent(file: file, status: .failed, detail: detail, destinationPath: destinationURL.path)
                    currentFile = nil
                    currentDestinationPath = nil
                    activeFileBytes = 0
                    emit(status: "copying")
                    continue
                }

                defer { withExtendedLifetime(openDestination) {} }
                let directoryFD = openDestination?.descriptor ?? AT_FDCWD
                var cancelledAfterPublishing = openDestination != nil && shouldCancel()
                var verified = false
                var rolledBack = false
                do {
                    if openDestination == nil, !published.destinationIsAccessible() {
                        throw SDImportError.missingDestinationDirectory(fileID)
                    }
                    if !cancelledAfterPublishing {
                        let info = try CopyEngine.fileInfo(at: published.destination, directoryFD: directoryFD)
                        let verifiedIdentity = info.map { published.staged?.matches($0) == true } == true
                        do {
                            let verifiedBytes = try published.reservedDestination == nil
                                || CopyEngine.publishedFileMatches(published, directoryFD: directoryFD, shouldCancel: {
                                    Task.isCancelled || (openDestination != nil && shouldCancel())
                                })
                            verified = verifiedIdentity && verifiedBytes
                        } catch SDImportError.cancelled where openDestination != nil {
                            cancelledAfterPublishing = true
                        }
                    }
                    if openDestination != nil {
                        cancelledAfterPublishing = cancelledAfterPublishing || shouldCancel()
                    }
                    if openDestination != nil, cancelledAfterPublishing || !published.destinationIsAccessible() {
                        try rollBackVisibleCopy(published, written: published.staged, directoryFD: directoryFD)
                        rolledBack = true
                    } else if verified {
                        try jobRepository.commitCopyAttempt(published)
                    } else {
                        try jobRepository.rejectUnverifiedCopy(published, needsDestinationReview: requiresReviewedDestinations)
                    }
                } catch {
                    // Keep the journal for recovery when verification or bookkeeping cannot finish.
                    try? jobRepository.refreshImportTotals(jobID: jobID, finalStatus: .failed)
                    throw error
                }
                if rolledBack {
                    if cancelledAfterPublishing { try cancelImport(currentFileID: fileID) }
                    try stopForPlanChange()
                }
                guard verified else {
                    if requiresReviewedDestinations { try stopForPlanChange() }
                    try jobRepository.refreshImportTotals(jobID: jobID, finalStatus: .failed)
                    throw SDImportError.destinationFilenameConflict(published.destinationPath)
                }
                markDone(file, status: .copied)
                processedBytes += file.size
                copiedBytes += file.size
                if recordPortableReceipt(portableIdentity, file: file), published.portableReceipt != nil {
                    try? jobRepository.discardCopyAttempt(published)
                }
                recordFileEvent(
                    file: file, status: .copied, detail: "Size checked", destinationPath: destinationURL.path
                )
            }

            currentFile = nil
            currentDestinationPath = nil
            activeFileBytes = 0
            emit(status: "copying")
        }

        if reviewedDestinations != nil, failedFiles == 0 {
            try verifyReviewedDestinationSkips()
            do {
                try verifyReviewedHistorySkips(files: allFilesAtStart, sourcePath: job.mountPath)
            } catch let error as SDImportError {
                try stopForPlanChange(error)
            }
            if reviewedDestinations?.matches() == false { try stopForPlanChange() }
        }
        let terminalStatus = failedFiles > 0 ? "completed_with_errors" : (totalFiles == 0 ? "idle" : "completed")
        let finalJobStatus: ImportJobStatus = failedFiles > 0 ? .importedWithErrors : .imported
        try jobRepository.refreshImportTotals(
            jobID: jobID,
            finalStatus: finalJobStatus,
            completedAt: Date(),
            needsDestinationReview: failedFiles == 0 ? false : nil
        )
        reportWriter.rewriteIfPossible(jobID: jobID, jobRepository: jobRepository)
        emit(status: terminalStatus, forceProcessedBytes: totalBytes)

        let finalFiles = try jobRepository.fetchJobFiles(jobID: jobID)
        let finalUnitIDBySourcePath = Insta360ClipDetector()
            .unitIDBySourcePath(files: finalFiles)
        let touchedSourcePaths = files.map(\.sourcePath) + recovery.copiedSourcePaths
        let touchedUnitIDs = Set(touchedSourcePaths.map { path in
            finalUnitIDBySourcePath[path] ?? "file:\(path)"
        })
        let processedContextFiles = finalFiles.filter { file in
            touchedUnitIDs.contains(
                finalUnitIDBySourcePath[file.sourcePath] ?? "file:\(file.sourcePath)"
            )
        }
        let presentationTotals = ImportReceiptTotals(files: processedContextFiles)
        return ImportResult(
            jobID: jobID,
            importedFiles: presentationTotals.copiedFiles,
            skippedFiles: presentationTotals.skippedFiles,
            failedFiles: presentationTotals.failedFiles,
            progressPath: nil,
            portableReceiptWarning: portableReceiptWarning,
            portableReceiptSizeWarning: portableReceiptSizeWarning
        )
    }

    private func copyToDestination(
        _ pending: ImportCopyAttempt,
        from source: URL,
        modificationDate: Date?,
        expectedSourceEpoch: Int64?,
        reviewedSource: ReviewedFileIdentity?,
        onChunk: @escaping (Int) -> Void,
        shouldCancel: () -> Bool
    ) throws -> (ImportCopyAttempt, OpenImportDestination?) {
        let directory = pending.destination.deletingLastPathComponent()
        if reviewedDestinations?.matches(directory) == false { throw SDImportError.reviewedDestinationChanged }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var attempt = pending
        guard let identity = ImportCopyDirectoryIdentity(at: directory) else {
            throw SDImportError.missingDestinationDirectory(attempt.fileID)
        }
        let openDestination: OpenImportDestination?
        if let reviewedDestinations {
            guard let opened = OpenImportDestination(at: directory, identity: identity),
                  reviewedDestinations.remember(identity, at: directory) else {
                throw SDImportError.reviewedDestinationChanged
            }
            openDestination = opened
        } else {
            openDestination = nil
        }
        defer { withExtendedLifetime(openDestination) {} }
        let directoryFD = openDestination?.descriptor ?? AT_FDCWD
        attempt.destinationDirectory = identity
        attempt.modificationDate = modificationDate
        try jobRepository.beginCopyAttempt(attempt)
        var interruptedDirectCopy: StagedImportCopy?
        do {
            if copyEngine.canRenameExclusively(directory) != false {
                attempt.staged = try copyEngine.stageFile(
                    from: source, to: attempt.staging, expectedSize: attempt.fingerprint.size,
                    modificationDate: modificationDate, expectedSourceEpoch: expectedSourceEpoch,
                    reviewedSource: reviewedSource, directoryFD: directoryFD,
                    onChunk: onChunk, shouldCancel: shouldCancel,
                    didCreate: { identity in
                        attempt.stagingIdentity = identity
                        try jobRepository.markCopyStaged(attempt)
                    }
                )
                attempt.stagingIdentity = attempt.staged?.identity
                try jobRepository.markCopyStaged(attempt)
                if shouldCancel() { throw SDImportError.cancelled }
                if directoryFD != AT_FDCWD, !attempt.destinationIsAccessible() {
                    throw SDImportError.reviewedDestinationChanged
                }
                do {
                    try copyEngine.publishFile(from: attempt.staging, to: attempt.destination, directoryFD: directoryFD)
                    return (attempt, openDestination)
                } catch SDImportError.fileSystemError(_, _, let code) where code == ENOTSUP || code == EOPNOTSUPP {
                    // Some volumes cannot rename without replacement. Use their exclusive create instead.
                    attempt.directCopyDigest = attempt.staged?.digest
                    try removeOwnedCopy(at: attempt.staging, identity: attempt.stagingIdentity, directoryFD: directoryFD)
                    attempt.stagingIdentity = nil
                    attempt.staged = nil
                    try jobRepository.markCopyStaged(attempt)
                }
            }
            if attempt.directCopyDigest == nil {
                attempt.directCopyDigest = try copyEngine.readSourceDigest(at: source)
                try jobRepository.markCopyStaged(attempt)
            }
            attempt.staged = try copyEngine.stageFile(
                from: source, to: attempt.destination, expectedSize: attempt.fingerprint.size,
                modificationDate: modificationDate, expectedSourceEpoch: expectedSourceEpoch,
                reviewedSource: reviewedSource, directoryFD: directoryFD,
                onChunk: onChunk, shouldCancel: shouldCancel,
                didCreate: { identity in
                    attempt.reservedDestination = identity
                    try jobRepository.markCopyStaged(attempt)
                },
                didInterrupt: directoryFD == AT_FDCWD ? nil : { interruptedDirectCopy = $0 }
            )
            attempt.reservedDestination = attempt.staged?.identity
            if directoryFD != AT_FDCWD, !attempt.destinationIsAccessible() {
                throw SDImportError.reviewedDestinationChanged
            }
            guard attempt.staged?.digest == attempt.directCopyDigest else {
                attempt.staged = nil
                throw SDImportError.invalidArgument(L10n.tr("Source changed since scan; scan again"))
            }
            try jobRepository.markCopyStaged(attempt)
        } catch {
            // A pinned directory also makes cleanup safe when its original path moves.
            let mayClean = directoryFD != AT_FDCWD || attempt.destinationIsAccessible()
            let reason = error as? SDImportError
            let invalidated = reason == .reviewedDestinationChanged || reason == .cancelled || reason == .sourceVolumeUnavailable
            if mayClean, let reservation = attempt.reservedDestination,
               reason == .reviewedSourceChanged || (directoryFD != AT_FDCWD && invalidated) {
                if directoryFD != AT_FDCWD {
                    try rollBackVisibleCopy(attempt, written: attempt.staged ?? interruptedDirectCopy, directoryFD: directoryFD)
                    throw error
                }
                try removeOwnedCopy(at: attempt.destination, identity: reservation, directoryFD: directoryFD)
                attempt.reservedDestination = nil
            }
            if mayClean, attempt.reservedDestination == nil {
                try removeOwnedCopy(at: attempt.staging, identity: attempt.stagingIdentity, directoryFD: directoryFD)
                try jobRepository.discardCopyAttempt(attempt)
            }
            throw error
        }
        return (attempt, openDestination)
    }

    private func rollBackVisibleCopy(_ attempt: ImportCopyAttempt, written: StagedImportCopy?, directoryFD: Int32) throws {
        let destination = attempt.destination
        if let info = try CopyEngine.fileInfo(at: destination, directoryFD: directoryFD) {
            let observed = ReviewedFileIdentity(info)
            guard let written, written.matches(info),
                  (try? CopyEngine.readDigest(
                    at: destination, identity: written.identity, directoryFD: directoryFD, shouldCancel: { false }
                  )) == written.digest,
                  let current = try CopyEngine.fileInfo(at: destination, directoryFD: directoryFD),
                  observed.matches(current) else {
                try jobRepository.rejectUnverifiedCopy(attempt, needsDestinationReview: true)
                return
            }
            try removeOwnedCopy(at: destination, identity: written.identity, directoryFD: directoryFD)
        }
        try jobRepository.discardCopyAttempt(attempt)
    }

    private func removeOwnedCopy(at url: URL, identity: ImportCopyFileIdentity?, directoryFD: Int32) throws {
        if let identity, let info = try CopyEngine.fileInfo(at: url, directoryFD: directoryFD), identity.matches(info) {
            if directoryFD == AT_FDCWD {
                try fileManager.removeItem(at: url)
            } else if unlinkat(directoryFD, url.lastPathComponent, 0) != 0, errno != ENOENT {
                throw SDImportError.fileSystemError(operation: "remove partial copy", path: url.path, code: errno)
            }
        }
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
            reviewedSourceFiles == nil || reviewedSourceFiles?[file.sourcePath]?.matches(path: file.sourcePath) == true,
            let attributes = try? fileManager.attributesOfItem(atPath: file.sourcePath),
            attributes[.type] as? FileAttributeType == .typeRegular,
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

}
