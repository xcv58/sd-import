import Foundation
import SDImportCore

enum HistoryJobPresentation {
    static func title(for job: ImportJob) -> String {
        "\(displayName(for: job)) - \(timestamp(for: job))"
    }

    static func subtitle(for job: ImportJob) -> String {
        "\(statusTitle(for: job)) · \(job.importedFiles) copied · \(job.skippedFiles) skipped · \(job.failedFiles) failed"
    }

    static func timestamp(for job: ImportJob) -> String {
        let date = job.completedAt ?? job.startedAt ?? job.createdAt
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func displayName(for job: ImportJob) -> String {
        if let volumeName = job.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines), !volumeName.isEmpty {
            return volumeName
        }
        let location = job.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !location.isEmpty, location != "TODO" {
            return location
        }
        let mountName = URL(fileURLWithPath: job.mountPath).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !mountName.isEmpty {
            return mountName
        }
        return "Import Job"
    }

    private static func statusTitle(for job: ImportJob) -> String {
        switch job.status {
        case .scanned:
            return "Scanned"
        case .importing:
            return "Importing"
        case .imported:
            return "Imported"
        case .importedWithErrors:
            return "Imported with errors"
        case .skipped:
            return "Skipped"
        case .cancelled:
            return "Cancelled"
        case .failed:
            return "Failed"
        }
    }
}
