import Foundation

public struct ImportReceiptTotals: Equatable, Sendable {
    public let copiedFiles: Int
    public let copiedBytes: Int64
    public let skippedFiles: Int
    public let failedFiles: Int

    public init(files: [JobFileRecord]) {
        let recordingCounts = RecordingAwareScanSummary.counts(files: files)
        copiedFiles = recordingCounts.importedFiles
        copiedBytes = files.reduce(Int64(0)) { total, file in
            file.copyStatus == .copied ? total + file.size : total
        }
        skippedFiles = recordingCounts.skippedFiles
        failedFiles = recordingCounts.failedFiles
    }
}
