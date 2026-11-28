import Foundation
import SDImportCore

struct ScanBothReview {
    struct Source {
        let files: [JobFileRecord]
        let history: [Int64: ImportHistoryMatch]
    }

    struct VolumePlan {
        let rows: [ImportPreviewRow]
        let totals: ImportPreviewTotals
        let paths: [String]
        let confirmation: ScanBothSession.Confirmation?

        var hasConflict: Bool {
            rows.contains { $0.disposition.attention == .blocking }
        }

        func displayRows(isSkipped: Bool) -> [ImportPreviewRow] {
            guard isSkipped else { return rows }
            return rows.map { row in
                guard row.willCopy || row.disposition.attention >= .attention else { return row }
                return ImportPreviewRow(
                    id: row.id, filename: row.filename, date: row.date,
                    modificationDateString: row.modificationDateString, mediaKind: row.mediaKind,
                    sourcePath: row.sourcePath, destinationPath: nil, disposition: .excluded,
                    visualGroupID: row.visualGroupID, visualGroupKind: row.visualGroupKind,
                    willCopy: false, size: row.size, reimportRequested: false
                )
            }
        }
    }

    var shootName: String
    var mediaSelection: ImportMediaSelection
    var folderGrouping: ImportFolderGrouping
    var sources: [UUID: Source] = [:]
    var volumes: [UUID: VolumePlan] = [:]
    var sessions: [ImportPlanSession] = []
    var blockingMessage: String?

    func queuedEntries(in session: ScanBothSession) -> [ScanBothSession.Entry] {
        session.entries.filter { $0.awaitsImport && (volumes[$0.id]?.totals.copyFiles ?? 0) > 0 }
    }

    func totals(in session: ScanBothSession) -> ImportPreviewTotals {
        queuedEntries(in: session).compactMap { volumes[$0.id]?.totals }.reduce(.empty) { total, volume in
            ImportPreviewTotals(
                copyFiles: total.copyFiles + volume.copyFiles,
                skippedFiles: total.skippedFiles + volume.skippedFiles,
                copyBytes: total.copyBytes + volume.copyBytes
            )
        }
    }
}
