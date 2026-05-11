import Foundation
import Testing

@testable import SDImportCore

@Suite("DiagnosticsReportBuilder")
struct DiagnosticsReportBuilderTests {
    @Test("redacts home and volume paths")
    func redactsHomeAndVolumePaths() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        #expect(
            DiagnosticsReportBuilder.redactedPath(
                "/Users/tester/Pictures/Photos",
                homeDirectory: home
            ) == "~/Pictures/Photos"
        )
        #expect(
            DiagnosticsReportBuilder.redactedPath(
                "/Volumes/SONY_CARD/DCIM/100MSDCF",
                homeDirectory: home
            ) == "/Volumes/SONY_CARD/..."
        )
    }

    @Test("diagnostics report excludes file names and source paths")
    func diagnosticsReportExcludesFileNamesAndSourcePaths() {
        let snapshot = DiagnosticsReportSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.16",
            appBuild: "16",
            osVersion: "macOS 14.6",
            architecture: "arm64",
            updateFeedConfigured: true,
            sourcePath: "/Volumes/CARD/DCIM/100MEDIA",
            photosPath: "/Users/tester/Pictures/Photos",
            videosPath: "/Users/tester/Movies/Footage",
            sourceStatus: "Ready",
            photosStatus: "Ready",
            videosStatus: "Ready",
            autoPromptEnabled: true,
            historyRetention: "90 days",
            statusMessage: "Import failed",
            setupError: nil,
            crashReportDirectory: "/Users/tester/Library/Logs/DiagnosticReports",
            recentCrashReports: [
                DiagnosticsCrashReportSummary(
                    fileExtension: "ips",
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_100),
                    byteCount: 4096
                )
            ],
            recentJobs: [],
            selectedFiles: [
                DiagnosticsFileSummary(
                    file: JobFileRecord(
                        id: 1,
                        jobID: "job-1",
                        sourcePath: "/Volumes/CARD/DCIM/100MEDIA/PRIVATE_NAME.CR3",
                        relativePath: "DCIM/100MEDIA/PRIVATE_NAME.CR3",
                        filename: "PRIVATE_NAME.CR3",
                        ext: ".CR3",
                        size: 2048,
                        modificationDateString: "2024-07-15T10:00:00",
                        mediaKind: .photo,
                        fingerprint: "fingerprint",
                        captureDate: "2024-07-15",
                        decision: .new,
                        destinationDirectory: "/Users/tester/Pictures/Photos",
                        plannedDestinationPath: "/Users/tester/Pictures/Photos/PRIVATE_NAME.CR3",
                        copyStatus: .failed,
                        error: "source file missing"
                    )
                )
            ]
        )

        let report = DiagnosticsReportBuilder.markdown(
            snapshot: snapshot,
            homeDirectory: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )

        #expect(report.contains(".CR3"))
        #expect(report.contains("source file missing"))
        #expect(report.contains("## Crash Reports"))
        #expect(report.contains("~/Library/Logs/DiagnosticReports"))
        #expect(report.contains("IPS"))
        #expect(!report.contains("PRIVATE_NAME"))
        #expect(!report.contains("/Users/tester"))
        #expect(!report.contains("/Volumes/CARD/DCIM"))
    }
}
