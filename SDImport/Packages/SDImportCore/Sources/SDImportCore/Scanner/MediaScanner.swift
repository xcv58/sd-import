import Foundation

public struct ScanRequest {
    public let mountURL: URL
    public let volumeName: String?
    public let volumeUUID: String?
    public let location: String
    public let roots: DestinationRoots
    public let reportsDirectoryURL: URL?
    public let jobID: String

    public init(
        mountURL: URL,
        volumeName: String? = nil,
        volumeUUID: String? = nil,
        location: String,
        roots: DestinationRoots,
        reportsDirectoryURL: URL? = nil,
        jobID: String = JobID.make()
    ) {
        self.mountURL = mountURL
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.location = location
        self.roots = roots
        self.reportsDirectoryURL = reportsDirectoryURL
        self.jobID = jobID
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
    public func scan(_ request: ScanRequest) throws -> ScanSummary {
        var files: [JobFileRecord] = []
        var scannedFiles = 0
        var newFiles = 0
        var knownFiles = 0
        var unsupportedFiles = 0
        var conflictFiles = 0

        for fileURL in fileEnumerator.mediaCandidateFiles(in: request.mountURL) {
            scannedFiles += 1
            let attributes = try attributes(for: fileURL)
            let ext = fileURL.pathExtension.isEmpty ? "" : ".\(fileURL.pathExtension.lowercased())"
            let mediaKind = classifier.classify(extension: ext)
            let relativePath = relativePath(for: fileURL, rootURL: request.mountURL)
            let modificationDateString = FileFingerprint.pythonCompatibleModificationDateString(attributes.modificationDate)

            guard mediaKind != .unsupported else {
                unsupportedFiles += 1
                files.append(
                    JobFileRecord(
                        jobID: request.jobID,
                        sourcePath: fileURL.path,
                        relativePath: relativePath,
                        filename: fileURL.lastPathComponent,
                        ext: ext,
                        size: attributes.size,
                        modificationDateString: modificationDateString,
                        mediaKind: .unsupported,
                        fingerprint: nil,
                        captureDate: nil,
                        decision: .unsupported,
                        destinationDirectory: nil,
                        plannedDestinationPath: nil,
                        copyStatus: .skipped
                    )
                )
                continue
            }

            let fingerprint = FileFingerprint.compute(
                size: attributes.size,
                modificationDate: attributes.modificationDate,
                modificationDateString: modificationDateString,
                identityHint: relativePath
            )
            let alreadyImported = try dedupeRepository.contains(fingerprint)
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
                    expectedFingerprint: fingerprint
                ) {
                case .skip:
                    decision = .known
                    copyStatus = .skipped
                case .copy(let resolvedURL):
                    if resolvedURL != destinationURL {
                        decision = .conflict
                        copyStatus = .pending
                        error = "destination file exists with different content"
                    }
                }
            }

            switch decision {
            case .new:
                newFiles += 1
            case .known:
                knownFiles += 1
            case .conflict:
                conflictFiles += 1
            case .unsupported:
                unsupportedFiles += 1
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
                    mediaKind: mediaKind,
                    fingerprint: fingerprint.value,
                    captureDate: captureDate,
                    decision: decision,
                    destinationDirectory: destinationDirectory?.path,
                    plannedDestinationPath: destinationURL?.path,
                    copyStatus: copyStatus,
                    error: error
                )
            )
        }

        let summary = ScanSummary(
            jobID: request.jobID,
            mountPath: request.mountURL.path,
            volumeName: request.volumeName ?? request.mountURL.lastPathComponent,
            volumeUUID: request.volumeUUID,
            location: request.location,
            scannedFiles: scannedFiles,
            newFiles: newFiles,
            knownFiles: knownFiles,
            unsupportedFiles: unsupportedFiles,
            conflictFiles: conflictFiles
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
            scannedFiles: scannedFiles,
            newFiles: newFiles,
            knownFiles: knownFiles,
            unsupportedFiles: unsupportedFiles,
            conflictFiles: conflictFiles,
            summaryJSONPath: reportBaseURL?.appendingPathExtension("json").path,
            summaryMarkdownPath: reportBaseURL?.appendingPathExtension("md").path
        )

        try jobRepository.insertScannedJob(job, files: files)

        if let reportBaseURL {
            _ = try reportWriter.writeReport(summary: summary, files: files, baseURL: reportBaseURL)
        }

        return summary
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
