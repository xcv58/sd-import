import Foundation
import Testing

@testable import SDImportCore

@Suite("ReportWriter")
struct ReportWriterTests {
    @Test("writes JSON and Markdown reports")
    func writesReports() throws {
        let directory = try temporaryDirectory()
        let baseURL = directory.appendingPathComponent("reports/job-1")
        let summary = ScanSummary(
            jobID: "job-1",
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            volumeUUID: nil,
            location: "TEST",
            scannedFiles: 1,
            newFiles: 1,
            knownFiles: 0,
            unsupportedFiles: 0,
            conflictFiles: 0
        )
        let file = JobFileRecord(
            jobID: "job-1",
            sourcePath: "/Volumes/CARD/DCIM/IMG_0001.JPG",
            relativePath: "DCIM/IMG_0001.JPG",
            filename: "IMG_0001.JPG",
            ext: ".jpg",
            size: 17,
            modificationDateString: "2023-11-14T22:13:20",
            mediaKind: .photo,
            fingerprint: "abc",
            captureDate: "2024-07-15",
            decision: .new,
            destinationDirectory: "/tmp/photos/2024-07-15 TEST",
            plannedDestinationPath: "/tmp/photos/2024-07-15 TEST/IMG_0001.JPG",
            copyStatus: .pending
        )

        let paths = try ReportWriter().writeReport(
            summary: summary,
            files: [file],
            baseURL: baseURL
        )

        #expect(FileManager.default.fileExists(atPath: paths.jsonURL.path))
        #expect(FileManager.default.fileExists(atPath: paths.markdownURL.path))

        let markdown = try String(contentsOf: paths.markdownURL)
        #expect(markdown.contains("# SD Import Report job-1"))
        #expect(markdown.contains("IMG_0001.JPG"))
    }
}
