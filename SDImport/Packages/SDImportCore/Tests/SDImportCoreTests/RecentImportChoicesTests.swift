import Foundation
import Testing

@testable import SDImportCore

@Suite("RecentImportChoices")
struct RecentImportChoicesTests {
    @Test("ranks shoot names by frequency and latest use")
    func ranksShootNamesByFrequencyAndLatestUse() {
        let jobs = [
            job(id: "1", location: "Taipei", completedAt: Date(timeIntervalSince1970: 100)),
            job(id: "2", location: "Osaka", completedAt: Date(timeIntervalSince1970: 200)),
            job(id: "3", location: "Taipei", completedAt: Date(timeIntervalSince1970: 300)),
            job(id: "4", location: "Kyoto", completedAt: Date(timeIntervalSince1970: 400)),
            job(id: "5", location: "Osaka", completedAt: Date(timeIntervalSince1970: 500))
        ]

        let choices = RecentImportChoices.shootNames(from: jobs)

        #expect(choices.map(\.name) == ["Osaka", "Taipei", "Kyoto"])
        #expect(choices.first?.useCount == 2)
    }

    @Test("omits placeholder and blank shoot names")
    func omitsPlaceholderShootNames() {
        let jobs = [
            job(id: "1", location: " Untitled ", completedAt: Date(timeIntervalSince1970: 100)),
            job(id: "2", location: "  ", completedAt: Date(timeIntervalSince1970: 200)),
            job(id: "3", location: "Taipei", completedAt: Date(timeIntervalSince1970: 300))
        ]

        let choices = RecentImportChoices.shootNames(from: jobs)

        #expect(choices.map(\.name) == ["Taipei"])
    }

    @Test("deduplicates shoot names case-insensitively and preserves latest casing")
    func deduplicatesShootNamesCaseInsensitively() {
        let jobs = [
            job(id: "1", location: "taipei", completedAt: Date(timeIntervalSince1970: 100)),
            job(id: "2", location: "Taipei", completedAt: Date(timeIntervalSince1970: 200))
        ]

        let choices = RecentImportChoices.shootNames(from: jobs)

        #expect(choices.map(\.name) == ["Taipei"])
        #expect(choices.first?.useCount == 2)
    }

    @Test("deduplicates paths and ranks by frequency")
    func deduplicatesPaths() {
        let jobs = [
            job(id: "1", mountPath: "/Volumes/A", completedAt: Date(timeIntervalSince1970: 100)),
            job(id: "2", mountPath: "/Volumes/B", completedAt: Date(timeIntervalSince1970: 200)),
            job(id: "3", mountPath: "/Volumes/A", completedAt: Date(timeIntervalSince1970: 300))
        ]

        let choices = RecentImportChoices.sourcePaths(from: jobs)

        #expect(choices.map(\.path) == ["/Volumes/A", "/Volumes/B"])
        #expect(choices.first?.displayName == "A")
        #expect(choices.first?.useCount == 2)
    }

    @Test("ignores scan-only jobs")
    func ignoresScanOnlyJobs() {
        let jobs = [
            job(id: "1", location: "Scan", status: .scanned),
            job(id: "2", location: "Imported", status: .imported)
        ]

        let choices = RecentImportChoices.shootNames(from: jobs)

        #expect(choices.map(\.name) == ["Imported"])
    }

    private func job(
        id: String,
        mountPath: String = "/Volumes/CARD",
        location: String = "Taipei",
        status: ImportJobStatus = .imported,
        completedAt: Date? = nil
    ) -> ImportJob {
        ImportJob(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1),
            startedAt: nil,
            completedAt: completedAt,
            mountPath: mountPath,
            location: location,
            photosRoot: "/tmp/photos",
            videosRoot: "/tmp/videos",
            status: status
        )
    }
}
