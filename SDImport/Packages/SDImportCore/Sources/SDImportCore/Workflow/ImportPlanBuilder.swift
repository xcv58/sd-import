import Foundation

public struct ImportPlanSession: Identifiable, Hashable, Sendable {
    public var id: String { date }
    public let date: String
    public var label: String
    public let photoCount: Int
    public let videoCount: Int
    public let unsupportedCount: Int
    public var includePhotos: Bool
    public var includeVideos: Bool
    public var includeSidecars: Bool

    public init(
        date: String,
        label: String,
        photoCount: Int,
        videoCount: Int,
        unsupportedCount: Int,
        includePhotos: Bool,
        includeVideos: Bool,
        includeSidecars: Bool
    ) {
        self.date = date
        self.label = label
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.unsupportedCount = unsupportedCount
        self.includePhotos = includePhotos
        self.includeVideos = includeVideos
        self.includeSidecars = includeSidecars
    }
}

public enum ImportPlanAttention: Int, Comparable, Hashable, Sendable {
    case normal
    case informational
    case attention
    case blocking

    public static func < (lhs: ImportPlanAttention, rhs: ImportPlanAttention) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ImportPlanDisposition: Hashable, Sendable {
    case notReady
    case copied
    case unsupported
    case excluded
    case known(KnownFileSource?)
    case noDestination
    case alreadyExists
    case rename(originalPath: String, destinationPath: String, reason: String?)
    case supportFile
    case copy

    public var title: String {
        switch self {
        case .notReady:
            return L10n.tr("Not ready")
        case .copied:
            return L10n.tr("Copied")
        case .unsupported:
            return L10n.tr("Unsupported")
        case .excluded:
            return L10n.tr("Excluded")
        case .known(let source):
            return source == .portableLedger ? L10n.tr("Other Mac") : L10n.tr("Known")
        case .noDestination:
            return L10n.tr("No destination")
        case .alreadyExists:
            return L10n.tr("Already exists")
        case .rename:
            return L10n.tr("Rename")
        case .supportFile:
            return L10n.tr("Support file")
        case .copy:
            return L10n.tr("Will copy")
        }
    }

    public var attention: ImportPlanAttention {
        switch self {
        case .notReady, .noDestination:
            return .blocking
        case .rename, .known(.portableLedger):
            return .attention
        case .unsupported, .excluded, .known, .alreadyExists:
            return .informational
        case .copied, .supportFile, .copy:
            return .normal
        }
    }
}

public struct ImportFilePlan: Sendable {
    public let update: JobFilePlanUpdate?
    public let willCopy: Bool
    public let disposition: ImportPlanDisposition
    public let destinationPath: String?

    public var status: String { disposition.title }

    public init(
        update: JobFilePlanUpdate?,
        willCopy: Bool,
        disposition: ImportPlanDisposition,
        destinationPath: String?
    ) {
        self.update = update
        self.willCopy = willCopy
        self.disposition = disposition
        self.destinationPath = destinationPath
    }
}

public struct ImportPlanBuilder: Sendable {
    public let sessions: [ImportPlanSession]
    public let mediaSelection: ImportMediaSelection
    public let organizationPreset: ImportOrganizationPreset
    public let folderGrouping: ImportFolderGrouping
    public let roots: DestinationRoots
    public let fallbackLocation: String
    public let volumeName: String?

    public init(
        sessions: [ImportPlanSession],
        mediaSelection: ImportMediaSelection = .photosAndVideos,
        organizationPreset: ImportOrganizationPreset,
        folderGrouping: ImportFolderGrouping = .byDay,
        roots: DestinationRoots,
        fallbackLocation: String,
        volumeName: String?
    ) {
        self.sessions = sessions
        self.mediaSelection = mediaSelection
        self.organizationPreset = organizationPreset
        self.folderGrouping = folderGrouping
        self.roots = roots
        self.fallbackLocation = fallbackLocation
        self.volumeName = volumeName
    }

    public func updates(files: [JobFileRecord]) -> [JobFilePlanUpdate] {
        plans(files: files).compactMap(\.update)
    }

    public func plans(files: [JobFileRecord]) -> [ImportFilePlan] {
        var reservedDestinationPaths: Set<String> = []
        return files.map {
            plan(file: $0, reservedDestinationPaths: &reservedDestinationPaths)
        }
    }

    public func plan(file: JobFileRecord) -> ImportFilePlan {
        var reservedDestinationPaths: Set<String> = []
        return plan(file: file, reservedDestinationPaths: &reservedDestinationPaths)
    }

    private func plan(
        file: JobFileRecord,
        reservedDestinationPaths: inout Set<String>
    ) -> ImportFilePlan {
        guard let id = file.id else {
            return ImportFilePlan(
                update: nil,
                willCopy: false,
                disposition: .notReady,
                destinationPath: file.finalDestinationPath ?? file.plannedDestinationPath
            )
        }

        if file.copyStatus == .copied {
            return ImportFilePlan(
                update: nil,
                willCopy: false,
                disposition: .copied,
                destinationPath: file.finalDestinationPath ?? file.plannedDestinationPath
            )
        }

        let date = Self.sessionDate(for: file)
        let session = sessions.first { $0.date == date }
        let label = folderLabel(for: session)
        let folderDate = folderDate(for: date)

        let isFootageSupportFile = organizationPreset == .footageBackup
            && (file.mediaKind == .unsupported || MediaFileHeuristics.isLikelyVideoPreviewJPEG(file))
            && mediaSelection.includes(.video)
            && (session?.includeSidecars ?? false)
        let shouldTreatAsUnsupported = file.mediaKind == .unsupported
            || file.decision == .unsupported
            || (organizationPreset == .footageBackup && MediaFileHeuristics.isLikelyVideoPreviewJPEG(file))

        if shouldTreatAsUnsupported && !isFootageSupportFile {
            return ImportFilePlan(
                update: JobFilePlanUpdate(
                    id: id,
                    decision: .unsupported,
                    destinationDirectory: nil,
                    plannedDestinationPath: nil,
                    copyStatus: .skipped,
                    error: "unsupported"
                ),
                willCopy: false,
                disposition: .unsupported,
                destinationPath: nil
            )
        }

        let included: Bool
        if isFootageSupportFile {
            included = true
        } else {
            switch file.mediaKind {
            case .photo:
                included = mediaSelection.includes(.photo) && (session?.includePhotos ?? true)
            case .video:
                included = mediaSelection.includes(.video) && (session?.includeVideos ?? true)
            case .unsupported:
                included = false
            }
        }

        guard included else {
            return ImportFilePlan(
                update: JobFilePlanUpdate(
                    id: id,
                    decision: file.decision,
                    destinationDirectory: nil,
                    plannedDestinationPath: nil,
                    copyStatus: .skipped,
                    error: "excluded_by_import_selection"
                ),
                willCopy: false,
                disposition: .excluded,
                destinationPath: nil
            )
        }

        if file.decision == .known {
            return ImportFilePlan(
                update: JobFilePlanUpdate(
                    id: id,
                    decision: .known,
                    destinationDirectory: file.destinationDirectory,
                    plannedDestinationPath: file.plannedDestinationPath,
                    copyStatus: .skipped,
                    error: nil
                ),
                willCopy: false,
                disposition: .known(file.knownSource),
                destinationPath: file.plannedDestinationPath
            )
        }

        let planner = DestinationPlanner()
        let destinationMediaKind: MediaKind = isFootageSupportFile ? .unsupported : file.mediaKind
        guard let destinationURL = planner.destinationURL(
            filename: file.filename,
            mediaKind: destinationMediaKind,
            captureDate: folderDate,
            sessionLabel: label,
            roots: roots,
            organizationPreset: organizationPreset,
            folderGrouping: folderGrouping,
            relativePath: file.relativePath,
            volumeName: volumeName
        ) else {
            return ImportFilePlan(
                update: JobFilePlanUpdate(
                    id: id,
                    decision: file.decision,
                    destinationDirectory: nil,
                    plannedDestinationPath: nil,
                    copyStatus: .skipped,
                    error: "no_destination"
                ),
                willCopy: false,
                disposition: .noDestination,
                destinationPath: nil
            )
        }

        let fingerprint = FileFingerprint.compute(
            size: file.size,
            modificationDateString: file.modificationDateString,
            identityHint: file.relativePath ?? file.filename
        )
        let resolver = ConflictResolver()
        switch resolver.resolveDestination(candidate: destinationURL, expectedFingerprint: fingerprint) {
        case .skip(let reason):
            return ImportFilePlan(
                update: JobFilePlanUpdate(
                    id: id,
                    decision: .known,
                    destinationDirectory: destinationURL.deletingLastPathComponent().path,
                    plannedDestinationPath: destinationURL.path,
                    copyStatus: .skipped,
                    error: reason
                ),
                willCopy: false,
                disposition: .alreadyExists,
                destinationPath: destinationURL.path
            )
        case .copy(let resolvedURL):
            let batchResolution = reserveUniqueBatchDestination(
                resolvedURL,
                reservedDestinationPaths: &reservedDestinationPaths
            )
            let resolvedURL = batchResolution.url
            let isConflict = resolvedURL != destinationURL
            let disposition: ImportPlanDisposition
            if isConflict {
                disposition = .rename(
                    originalPath: destinationURL.path,
                    destinationPath: resolvedURL.path,
                    reason: batchResolution.reason ?? "destination file exists with different content"
                )
            } else if isFootageSupportFile {
                disposition = .supportFile
            } else {
                disposition = .copy
            }
            return ImportFilePlan(
                update: JobFilePlanUpdate(
                    id: id,
                    decision: isConflict ? .conflict : .new,
                    destinationDirectory: resolvedURL.deletingLastPathComponent().path,
                    plannedDestinationPath: resolvedURL.path,
                    copyStatus: .pending,
                    error: batchResolution.reason ?? (isConflict ? "destination file exists with different content" : nil)
                ),
                willCopy: true,
                disposition: disposition,
                destinationPath: resolvedURL.path
            )
        }
    }

    private func folderLabel(for session: ImportPlanSession?) -> String {
        if folderGrouping == .oneShootFolder {
            return fallbackLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? sessions.first?.label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "Untitled"
        }

        return session?.label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallbackLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Untitled"
    }

    private func folderDate(for date: String) -> String {
        switch folderGrouping {
        case .byDay:
            return date
        case .oneShootFolder:
            let dateRange = Self.dateRangeTitle(for: sessions.map(\.date))
            return dateRange == "Undated" ? date : dateRange
        }
    }

    private func reserveUniqueBatchDestination(
        _ url: URL,
        reservedDestinationPaths: inout Set<String>
    ) -> (url: URL, reason: String?) {
        let key = reservedKey(for: url)
        if !reservedDestinationPaths.contains(key) {
            reservedDestinationPaths.insert(key)
            return (url, nil)
        }

        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 1

        while true {
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let next = directory.appendingPathComponent("\(stem)-copy-\(counter)\(suffix)", isDirectory: false)
            let nextKey = reservedKey(for: next)
            if !reservedDestinationPaths.contains(nextKey)
                && !FileManager.default.fileExists(atPath: next.path) {
                reservedDestinationPaths.insert(nextKey)
                return (next, "destination file name repeats in this import")
            }
            counter += 1
        }
    }

    private func reservedKey(for url: URL) -> String {
        url.standardizedFileURL.path.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    public static func sessionDate(for file: JobFileRecord) -> String {
        if let captureDate = file.captureDate, !captureDate.isEmpty {
            return captureDate
        }
        return String(file.modificationDateString.prefix(10))
    }

    public static func dateRangeTitle(for dates: [String]) -> String {
        let sortedDates = Array(Set(dates.filter { !$0.isEmpty })).sorted()
        guard let first = sortedDates.first else {
            return "Undated"
        }
        guard let last = sortedDates.last, last != first else {
            return first
        }
        return "\(first) to \(last)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
