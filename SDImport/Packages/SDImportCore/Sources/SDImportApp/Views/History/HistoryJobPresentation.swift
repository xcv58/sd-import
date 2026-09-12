import Foundation
import SDImportCore

enum HistoryJobPresentation {
    static func title(for job: ImportJob) -> String {
        "\(displayName(for: job)) - \(timestamp(for: job))"
    }

    static func subtitle(for job: ImportJob) -> String {
        L10n.tr("\(statusTitle(for: job)) · \(job.importedFiles) copied · \(job.skippedFiles) skipped · \(job.failedFiles) failed")
    }

    static func timestamp(for job: ImportJob) -> String {
        let date = job.completedAt ?? job.startedAt ?? job.createdAt
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func displayName(for job: ImportJob) -> String {
        let location = job.location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isPlaceholderName(location) {
            return location
        }
        if let volumeName = job.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !isPlaceholderName(volumeName) {
            return volumeName
        }
        let mountName = URL(fileURLWithPath: job.mountPath).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !isPlaceholderName(mountName) {
            return mountName
        }
        return L10n.tr("Import Job")
    }

    private static func isPlaceholderName(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return normalized.isEmpty
            || normalized == "todo"
            || normalized == "untitled"
            || normalized == "no name"
    }

    private static func statusTitle(for job: ImportJob) -> String {
        switch job.status {
        case .scanned:
            return L10n.tr("Scanned")
        case .importing:
            return L10n.tr("Importing")
        case .imported:
            return L10n.tr("Imported")
        case .importedWithErrors:
            return L10n.tr("Imported with errors")
        case .skipped:
            return L10n.tr("Skipped")
        case .cancelled:
            return L10n.tr("Cancelled")
        case .failed:
            return L10n.tr("Failed")
        }
    }
}
