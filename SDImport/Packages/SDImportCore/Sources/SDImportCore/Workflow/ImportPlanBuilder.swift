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

public struct ImportFilePlan: Sendable {
    public let update: JobFilePlanUpdate?
    public let willCopy: Bool
    public let status: String
    public let destinationPath: String?

    public init(
        update: JobFilePlanUpdate?,
        willCopy: Bool,
        status: String,
        destinationPath: String?
    ) {
        self.update = update
        self.willCopy = willCopy
        self.status = status
        self.destinationPath = destinationPath
    }
}

public struct ImportPlanBuilder: Sendable {
    public let sessions: [ImportPlanSession]
    public let organizationPreset: ImportOrganizationPreset
    public let roots: DestinationRoots
    public let fallbackLocation: String
    public let volumeName: String?

    public init(
        sessions: [ImportPlanSession],
        organizationPreset: ImportOrganizationPreset,
        roots: DestinationRoots,
        fallbackLocation: String,
        volumeName: String?
    ) {
        self.sessions = sessions
        self.organizationPreset = organizationPreset
        self.roots = roots
        self.fallbackLocation = fallbackLocation
        self.volumeName = volumeName
    }

    public func updates(files: [JobFileRecord]) -> [JobFilePlanUpdate] {
        files.compactMap { plan(file: $0).update }
    }

    public func plan(file: JobFileRecord) -> ImportFilePlan {
        guard let id = file.id else {
            return ImportFilePlan(
                update: nil,
                willCopy: false,
                status: "Not ready",
                destinationPath: file.finalDestinationPath ?? file.plannedDestinationPath
            )
        }

        if file.copyStatus == .copied {
            return ImportFilePlan(
                update: nil,
                willCopy: false,
                status: "Copied",
                destinationPath: file.finalDestinationPath ?? file.plannedDestinationPath
            )
        }

        let date = Self.sessionDate(for: file)
        let session = sessions.first { $0.date == date }
        let label = session?.label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? fallbackLocation.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Untitled"

        let isFootageSidecar = organizationPreset == .footageBackup
            && file.mediaKind == .unsupported
            && (session?.includeSidecars ?? true)

        if (file.mediaKind == .unsupported || file.decision == .unsupported) && !isFootageSidecar {
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
                status: "Unsupported",
                destinationPath: nil
            )
        }

        let included: Bool
        switch file.mediaKind {
        case .photo:
            included = session?.includePhotos ?? true
        case .video:
            included = session?.includeVideos ?? true
        case .unsupported:
            included = isFootageSidecar
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
                status: "Excluded",
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
                status: "Known",
                destinationPath: file.plannedDestinationPath
            )
        }

        let planner = DestinationPlanner()
        guard let destinationURL = planner.destinationURL(
            filename: file.filename,
            mediaKind: file.mediaKind,
            captureDate: date,
            sessionLabel: label,
            roots: roots,
            organizationPreset: organizationPreset,
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
                status: "No destination",
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
                status: "Already exists",
                destinationPath: destinationURL.path
            )
        case .copy(let resolvedURL):
            let isConflict = resolvedURL != destinationURL
            let copyStatus = file.mediaKind == .unsupported ? "Sidecar" : "Will copy"
            return ImportFilePlan(
                update: JobFilePlanUpdate(
                    id: id,
                    decision: isConflict ? .conflict : .new,
                    destinationDirectory: resolvedURL.deletingLastPathComponent().path,
                    plannedDestinationPath: resolvedURL.path,
                    copyStatus: .pending,
                    error: isConflict ? "destination file exists with different content" : nil
                ),
                willCopy: true,
                status: isConflict ? "Rename" : copyStatus,
                destinationPath: resolvedURL.path
            )
        }
    }

    public static func sessionDate(for file: JobFileRecord) -> String {
        if let captureDate = file.captureDate, !captureDate.isEmpty {
            return captureDate
        }
        return String(file.modificationDateString.prefix(10))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
