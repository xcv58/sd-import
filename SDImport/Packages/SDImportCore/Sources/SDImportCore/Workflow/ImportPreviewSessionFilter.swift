import Foundation

public struct ImportPreviewSessionFilter: Sendable {
    public init() {}

    public func visibleSessions(
        files: [JobFileRecord],
        plans: [ImportFilePlan],
        sessions: [ImportPlanSession],
        importMediaSelection: ImportMediaSelection,
        organizationPreset: ImportOrganizationPreset
    ) -> [ImportPlanSession] {
        let countsByDate = sessionCounts(
            files: files,
            plans: plans,
            importMediaSelection: importMediaSelection,
            organizationPreset: organizationPreset
        )

        return sessions.compactMap { session in
            guard let counts = countsByDate[session.date], counts.total > 0 else {
                return nil
            }

            return ImportPlanSession(
                date: session.date,
                label: session.label,
                photoCount: counts.photoCount,
                videoCount: counts.videoCount,
                unsupportedCount: counts.unsupportedCount,
                includePhotos: session.includePhotos,
                includeVideos: session.includeVideos,
                includeSidecars: session.includeSidecars
            )
        }
    }

    private func sessionCounts(
        files: [JobFileRecord],
        plans: [ImportFilePlan],
        importMediaSelection: ImportMediaSelection,
        organizationPreset: ImportOrganizationPreset
    ) -> [String: SessionCounts] {
        var countsByDate: [String: SessionCounts] = [:]
        let plansBySourcePath = Dictionary(
            uniqueKeysWithValues: zip(files, plans).map { ($0.sourcePath, $1) }
        )
        let insta360Groups = Insta360ClipDetector().groups(files: files)
        let groupedSourcePaths = Set(insta360Groups.flatMap { $0.files.map(\.sourcePath) })

        for group in insta360Groups {
            guard let master = group.masterFiles.first,
                  group.files.contains(where: { file in
                      guard let plan = plansBySourcePath[file.sourcePath] else {
                          return false
                      }
                      return isVisibleInSessionEditor(
                          file: file,
                          plan: plan,
                          importMediaSelection: importMediaSelection,
                          organizationPreset: organizationPreset
                      )
                  }) else {
                continue
            }
            let date = ImportPlanBuilder.sessionDate(for: master)
            countsByDate[date, default: SessionCounts()].videoCount += 1
        }

        for (file, plan) in zip(files, plans) {
            guard !groupedSourcePaths.contains(file.sourcePath) else {
                continue
            }
            guard isVisibleInSessionEditor(
                file: file,
                plan: plan,
                importMediaSelection: importMediaSelection,
                organizationPreset: organizationPreset
            ) else {
                continue
            }

            let date = ImportPlanBuilder.sessionDate(for: file)
            var counts = countsByDate[date, default: SessionCounts()]
            if organizationPreset == .footageBackup && MediaFileHeuristics.isLikelyVideoPreviewJPEG(file) {
                counts.unsupportedCount += 1
            } else {
                switch file.mediaKind {
                case .photo:
                    counts.photoCount += 1
                case .video:
                    counts.videoCount += 1
                case .unsupported:
                    counts.unsupportedCount += 1
                }
            }
            countsByDate[date] = counts
        }

        return countsByDate
    }

    private func isVisibleInSessionEditor(
        file: JobFileRecord,
        plan: ImportFilePlan,
        importMediaSelection: ImportMediaSelection,
        organizationPreset: ImportOrganizationPreset
    ) -> Bool {
        if plan.willCopy {
            return true
        }

        guard plan.disposition == .excluded else {
            return false
        }

        switch file.mediaKind {
        case .photo:
            guard organizationPreset != .footageBackup else {
                return false
            }
            return importMediaSelection.includes(.photo)
        case .video:
            return importMediaSelection.includes(.video)
        case .unsupported:
            return organizationPreset == .footageBackup
        }
    }
}

private struct SessionCounts {
    var photoCount = 0
    var videoCount = 0
    var unsupportedCount = 0

    var total: Int {
        photoCount + videoCount + unsupportedCount
    }
}
