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
            finalDestinationPath: "/tmp/photos/2024-07-15 TEST/IMG_0001.JPG",
            copyStatus: .copied,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000)
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
        #expect(markdown.contains("- copied: `1`"))
        #expect(markdown.contains("## Copied Files"))
        #expect(markdown.contains("(Copied,"))

        let loadedReport = try ImportReportLoader().loadJSON(from: paths.jsonURL)
        #expect(loadedReport.summary.jobID == "job-1")
        #expect(loadedReport.files.map(\.filename) == ["IMG_0001.JPG"])

        let loadedMarkdown = try ImportReportLoader().loadMarkdown(from: paths.markdownURL)
        #expect(loadedMarkdown.contains("# SD Import Report job-1"))
    }

    @Test("groups Insta360 conflicts once and retains member filenames")
    func groupsInsta360Conflicts() throws {
        let directory = try temporaryDirectory()
        let baseURL = directory.appendingPathComponent("reports/job-conflict")
        let summary = ScanSummary(
            jobID: "job-conflict",
            mountPath: "/Volumes/CARD",
            volumeName: "CARD",
            volumeUUID: nil,
            location: "TEST",
            scannedFiles: 1,
            newFiles: 0,
            knownFiles: 0,
            unsupportedFiles: 0,
            conflictFiles: 1
        )
        let names = [
            "VID_20181001_210458_00_012.insv",
            "LRV_20181001_210458_01_012.lrv"
        ]
        let files = names.enumerated().map { offset, filename in
            JobFileRecord(
                id: Int64(offset + 1),
                jobID: "job-conflict",
                sourcePath: "/Volumes/CARD/DCIM/Camera01/\(filename)",
                relativePath: "DCIM/Camera01/\(filename)",
                filename: filename,
                ext: ".\(URL(fileURLWithPath: filename).pathExtension.lowercased())",
                size: 17,
                modificationDateString: "2023-11-14T22:13:20",
                mediaKind: offset == 0 ? .video : .unsupported,
                fingerprint: "v2:\(offset)",
                captureDate: "2024-07-15",
                decision: .conflict,
                destinationDirectory: "/tmp/videos",
                plannedDestinationPath: "/tmp/videos/\(filename)",
                copyStatus: .skipped,
                error: "destination_filename_conflict"
            )
        }

        let paths = try ReportWriter().writeReport(summary: summary, files: files, baseURL: baseURL)
        let markdown = try String(contentsOf: paths.markdownURL)

        #expect(markdown.components(separatedBy: "- Insta360 recording (Conflict)").count - 1 == 1)
        #expect(markdown.contains(names[0]))
        #expect(markdown.contains(names[1]))
    }
}
