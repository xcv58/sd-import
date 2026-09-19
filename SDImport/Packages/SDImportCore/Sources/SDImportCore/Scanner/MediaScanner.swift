import Foundation

public struct ScanRequest {
    public let mountURL: URL
    public let volumeName: String?
    public let volumeUUID: String?
    public let location: String
    public let roots: DestinationRoots
    public let reportsDirectoryURL: URL?
    public let jobID: String
    public let portableReceiptsEnabled: Bool

    public init(
        mountURL: URL,
        volumeName: String? = nil,
        volumeUUID: String? = nil,
        location: String,
        roots: DestinationRoots,
        reportsDirectoryURL: URL? = nil,
        jobID: String = JobID.make(),
        portableReceiptsEnabled: Bool = false
    ) {
        self.mountURL = mountURL
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.location = location
        self.roots = roots
        self.reportsDirectoryURL = reportsDirectoryURL
        self.jobID = jobID
        self.portableReceiptsEnabled = portableReceiptsEnabled
    }
}

public struct MediaScanner {
    private let fileManager: FileManager
    private let fileEnumerator: FileEnumerator
    private let classifier: MediaClassifier
    private let destinationPlanner: DestinationPlanner
    private let captureDateReader: any CaptureDateReading
    private let jobRepository: JobRepository
    private let dedupeRepository: DedupeRepository
    private let conflictResolver: ConflictResolver
    private let reportWriter: ReportWriter

    public init(
        fileManager: FileManager = .default,
        fileEnumerator: FileEnumerator = FileEnumerator(),
        classifier: MediaClassifier = MediaClassifier(),
        destinationPlanner: DestinationPlanner = DestinationPlanner(),
        captureDateReader: any CaptureDateReading = NativeCaptureDateReader(),
        jobRepository: JobRepository,
        dedupeRepository: DedupeRepository,
        conflictResolver: ConflictResolver = ConflictResolver(),
        reportWriter: ReportWriter = ReportWriter()
    ) {
        self.fileManager = fileManager
        self.fileEnumerator = fileEnumerator
        self.classifier = classifier
        self.destinationPlanner = destinationPlanner
        self.captureDateReader = captureDateReader
        self.jobRepository = jobRepository
        self.dedupeRepository = dedupeRepository
        self.conflictResolver = conflictResolver
        self.reportWriter = reportWriter
    }

    @discardableResult
    public func scan(
        _ request: ScanRequest,
        shouldCancel: () -> Bool = { false }
    ) throws -> ScanSummary {
        var files: [JobFileRecord] = []
        var portableFingerprints: Set<String> = []
        var portableIdentitiesToBackfill: [(sourcePath: String, identity: PortableFileIdentity)] = []
        var portableReceiptWarning: String?
        var portableReceiptSizeWarning: PortableReceiptSizeWarning?
        var portableWritesAvailable = request.portableReceiptsEnabled
        let portableLedger = PortableImportReceiptLedger(sourceRootURL: request.mountURL)

        if request.portableReceiptsEnabled {
            do {
                let snapshot = try portableLedger.load()
                portableFingerprints = snapshot.fingerprints
                portableReceiptWarning = snapshot.warning
            } catch {
                portableWritesAvailable = false
                portableReceiptSizeWarning = PortableReceiptSizeWarning(error: error)
                portableReceiptWarning = L10n.tr("Portable import history is unavailable: \(error.localizedDescription)")
            }
        }

        for fileURL in try fileEnumerator.mediaCandidateFiles(in: request.mountURL, shouldCancel: shouldCancel) {
            if shouldCancel() {
                throw SDImportError.cancelled
            }
            if classifier.shouldIgnore(filename: fileURL.lastPathComponent) {
                continue
            }
            let attributes = try attributes(for: fileURL)
            let ext = fileURL.pathExtension.isEmpty ? "" : ".\(fileURL.pathExtension.lowercased())"
            let mediaKind = classifier.classify(extension: ext)
            let relativePath = relativePath(for: fileURL, rootURL: request.mountURL)
            let modificationDateString = FileFingerprint.pythonCompatibleModificationDateString(attributes.modificationDate)
            let fingerprint = FileFingerprint.compute(
                size: attributes.size,
                modificationDate: attributes.modificationDate,
                modificationDateString: modificationDateString,
                identityHint: relativePath
            )
            let portableIdentity = PortableFileIdentity(
                size: attributes.size,
                modificationDate: attributes.modificationDate,
                relativePath: relativePath
            )
            let locallyImported = try dedupeRepository.contains(fingerprint)
            let portableFingerprint = PortableImportReceiptLedger.portableFingerprint(for: portableIdentity)
            let portablyImported = request.portableReceiptsEnabled
                && portableFingerprints.contains(portableFingerprint)
            let shouldBackfillPortableReceipt = request.portableReceiptsEnabled
                && portableWritesAvailable
                && locallyImported
                && !portablyImported
            let exactlyImportedFromThisSource: Bool
            if shouldBackfillPortableReceipt {
                exactlyImportedFromThisSource = try dedupeRepository.containsExactSource(
                    fingerprint,
                    sourcePath: fileURL.path
                )
            } else {
                exactlyImportedFromThisSource = false
            }
            let alreadyImported = locallyImported || portablyImported
            var knownSource: KnownFileSource?
            if locallyImported {
                knownSource = .localLedger
            } else if portablyImported {
                knownSource = .portableLedger
            }

            if exactlyImportedFromThisSource {
                portableIdentitiesToBackfill.append((fileURL.path, portableIdentity))
                portableFingerprints.insert(portableFingerprint)
            }

            guard mediaKind != .unsupported else {
                files.append(
                    JobFileRecord(
                        jobID: request.jobID,
                        sourcePath: fileURL.path,
                        relativePath: relativePath,
                        filename: fileURL.lastPathComponent,
                        ext: ext,
                        size: attributes.size,
                        modificationDateString: modificationDateString,
                        modificationTimeEpochSeconds: portableIdentity.modificationTimeEpochSeconds,
                        mediaKind: .unsupported,
                        fingerprint: fingerprint.value,
                        captureDate: nil,
                        decision: alreadyImported ? .known : .unsupported,
                        knownSource: knownSource,
                        destinationDirectory: nil,
                        plannedDestinationPath: nil,
                        copyStatus: .skipped
                    )
                )
                continue
            }

            let captureDate = captureDateReader.captureDate(
                for: fileURL,
                mediaKind: mediaKind,
                attributes: attributes
            )
            let destinationURL = destinationPlanner.destinationURL(
                filename: fileURL.lastPathComponent,
                mediaKind: mediaKind,
                captureDate: captureDate,
                location: request.location,
                roots: request.roots
            )
            let destinationDirectory = destinationURL?.deletingLastPathComponent()

            var decision: FileDecision = alreadyImported ? .known : .new
            var copyStatus: CopyStatus = alreadyImported ? .skipped : .pending
            var error: String?

            if decision == .new, let destinationURL, fileManager.fileExists(atPath: destinationURL.path) {
                switch conflictResolver.resolveDestination(
                    candidate: destinationURL,
                    expectedFingerprint: fingerprint,
                    allowsRename: ![".insv", ".lrv"].contains(ext.lowercased())
                ) {
                case .skip:
                    decision = .known
                    copyStatus = .skipped
                    knownSource = .destination
                case .copy(let resolvedURL):
                    if resolvedURL != destinationURL {
                        decision = .conflict
                        copyStatus = .pending
                        error = "destination file exists with different content"
                    }
                case .blocked(let reason):
                    decision = .conflict
                    copyStatus = .skipped
                    error = reason
                }
            }

            files.append(
                JobFileRecord(
                    jobID: request.jobID,
                    sourcePath: fileURL.path,
                    relativePath: relativePath,
                    filename: fileURL.lastPathComponent,
                    ext: ext,
                    size: attributes.size,
                    modificationDateString: modificationDateString,
                    modificationTimeEpochSeconds: portableIdentity.modificationTimeEpochSeconds,
                    mediaKind: mediaKind,
                    fingerprint: fingerprint.value,
                    captureDate: captureDate,
                    decision: decision,
                    knownSource: knownSource,
                    destinationDirectory: destinationDirectory?.path,
                    plannedDestinationPath: destinationURL?.path,
                    copyStatus: copyStatus,
                    error: error
                )
            )
        }

        if shouldCancel() {
            throw SDImportError.cancelled
        }

        let matchedProxyPaths = Set(
            Insta360ClipDetector().groups(files: files)
                .flatMap(\.proxyFiles)
                .map(\.sourcePath)
        )
        let unmatchedProxyPaths = Set(
            files.lazy
                .filter { Self.isInsta360ProxyFile($0) && !matchedProxyPaths.contains($0.sourcePath) }
                .map(\.sourcePath)
        )
        files = files.map { file in
            guard unmatchedProxyPaths.contains(file.sourcePath) else { return file }
            return JobFileRecord(
                id: file.id,
                jobID: file.jobID,
                sourcePath: file.sourcePath,
                relativePath: file.relativePath,
                filename: file.filename,
                ext: file.ext,
                size: file.size,
                modificationDateString: file.modificationDateString,
                modificationTimeEpochSeconds: file.modificationTimeEpochSeconds,
                mediaKind: .unsupported,
                fingerprint: file.fingerprint,
                captureDate: file.captureDate,
                decision: .unsupported,
                knownSource: nil,
                destinationDirectory: nil,
                plannedDestinationPath: nil,
                finalDestinationPath: nil,
                copyStatus: .skipped,
                error: nil,
                portableReceiptOverride: file.portableReceiptOverride,
                completedAt: file.completedAt
            )
        }

        if portableWritesAvailable, !portableIdentitiesToBackfill.isEmpty {
            do {
                let identities = portableIdentitiesToBackfill
                    .filter { !unmatchedProxyPaths.contains($0.sourcePath) }
                    .map(\.identity)
                if !identities.isEmpty {
                    let appendResult = try portableLedger.appendReturningRevision(
                        identities: identities
                    )
                    if let warning = appendResult.warning, portableReceiptWarning != warning {
                        portableReceiptWarning = [portableReceiptWarning, warning]
                            .compactMap { $0 }
                            .joined(separator: ". ")
                    }
                }
            } catch {
                portableReceiptSizeWarning = PortableReceiptSizeWarning(error: error)
                portableReceiptWarning = L10n.tr("Portable import history could not be updated: \(error.localizedDescription)")
            }
        }

        return try persist(
            request: request,
            files: files,
            portableReceiptWarning: portableReceiptWarning,
            portableReceiptSizeWarning: portableReceiptSizeWarning
        )
    }

    private func persist(
        request: ScanRequest,
        files: [JobFileRecord],
        portableReceiptWarning: String?,
        portableReceiptSizeWarning: PortableReceiptSizeWarning?
    ) throws -> ScanSummary {
        let recordingCounts = RecordingAwareScanSummary.counts(files: files)
        let summary = ScanSummary(
            jobID: request.jobID,
            mountPath: request.mountURL.path,
            volumeName: request.volumeName ?? request.mountURL.lastPathComponent,
            volumeUUID: request.volumeUUID,
            location: request.location,
            scannedFiles: recordingCounts.scannedFiles,
            newFiles: recordingCounts.newFiles,
            knownFiles: recordingCounts.knownFiles,
            unsupportedFiles: recordingCounts.unsupportedFiles,
            conflictFiles: recordingCounts.conflictFiles,
            portableKnownFiles: recordingCounts.portableKnownFiles,
            portableReceiptWarning: portableReceiptWarning,
            portableReceiptSizeWarning: portableReceiptSizeWarning
        )

        let reportBaseURL = request.reportsDirectoryURL?.appendingPathComponent(request.jobID, isDirectory: false)
        let job = ImportJob(
            id: request.jobID,
            createdAt: Date(),
            mountPath: request.mountURL.path,
            volumeName: summary.volumeName,
            volumeUUID: request.volumeUUID,
            location: request.location,
            photosRoot: request.roots.photosURL.path,
            videosRoot: request.roots.videosURL.path,
            status: .scanned,
            scannedFiles: recordingCounts.scannedFiles,
            newFiles: recordingCounts.newFiles,
            knownFiles: recordingCounts.knownFiles,
            unsupportedFiles: recordingCounts.unsupportedFiles,
            conflictFiles: recordingCounts.conflictFiles,
            summaryJSONPath: reportBaseURL?.appendingPathExtension("json").path,
            summaryMarkdownPath: reportBaseURL?.appendingPathExtension("md").path
        )

        try jobRepository.insertScannedJob(job, files: files)

        if let reportBaseURL {
            _ = try reportWriter.writeReport(summary: summary, files: files, baseURL: reportBaseURL)
        }

        return summary
    }

    private static func isInsta360ProxyFile(_ file: JobFileRecord) -> Bool {
        file.ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased(with: Locale(identifier: "en_US_POSIX")) == "lrv"
    }

    private func attributes(for fileURL: URL) throws -> FileAttributes {
        let raw = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard
            let size = raw[.size] as? NSNumber,
            let modificationDate = raw[.modificationDate] as? Date
        else {
            throw SDImportError.missingFileAttributes(fileURL)
        }
        return FileAttributes(
            size: size.int64Value,
            modificationDate: modificationDate,
            creationDate: raw[.creationDate] as? Date
        )
    }

    private func relativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            return fileURL.lastPathComponent
        }
        let relative = filePath.dropFirst(rootPath.count).drop { $0 == "/" }
        return String(relative)
    }
}
