import Foundation
import Testing

@testable import SDImportCore

@Suite("DestinationSpaceChecker")
struct DestinationSpaceCheckerTests {
    @Test("groups required bytes by destination volume")
    func groupsRequiredBytesByVolume() throws {
        let checker = DestinationSpaceChecker { path in
            let id = path.hasPrefix("/Volumes/A") ? "volume-a" : "volume-b"
            return VolumeCapacity(
                volumeID: id,
                displayPath: id,
                availableBytes: 1_000,
                totalBytes: 2_000
            )
        }

        let result = try checker.check(files: [
            file(size: 300, destinationDirectory: "/Volumes/A/Photos"),
            file(size: 400, destinationDirectory: "/Volumes/A/Photos"),
            file(size: 250, destinationDirectory: "/Volumes/B/Video")
        ])

        #expect(result.hasEnoughSpace)
        #expect(result.requirements.count == 2)
        #expect(result.requirements.first { $0.volumeID == "volume-a" }?.requiredBytes == 700)
        #expect(result.requirements.first { $0.volumeID == "volume-b" }?.requiredBytes == 250)
    }

    @Test("reports insufficient destination space")
    func reportsInsufficientDestinationSpace() throws {
        let checker = DestinationSpaceChecker { _ in
            VolumeCapacity(
                volumeID: "volume",
                displayPath: "/Volumes/Card",
                availableBytes: 500,
                totalBytes: 1_000
            )
        }

        let result = try checker.check(files: [
            file(size: 300, destinationDirectory: "/Volumes/Card/Photos"),
            file(size: 250, destinationDirectory: "/Volumes/Card/Video")
        ])

        #expect(result.hasEnoughSpace == false)
        #expect(result.failures.first?.requiredBytes == 550)
        #expect(result.failures.first?.availableBytes == 500)
    }

    private func file(size: Int64, destinationDirectory: String?) -> JobFileRecord {
        JobFileRecord(
            jobID: "job",
            sourcePath: "/Volumes/Card/DCIM/IMG.JPG",
            relativePath: "DCIM/IMG.JPG",
            filename: "IMG.JPG",
            ext: ".jpg",
            size: size,
            modificationDateString: "2026-05-03T12:00:00",
            mediaKind: .photo,
            fingerprint: "fingerprint-\(size)",
            captureDate: "2026-05-03",
            decision: .new,
            destinationDirectory: destinationDirectory,
            plannedDestinationPath: destinationDirectory.map { "\($0)/IMG.JPG" },
            copyStatus: .pending
        )
    }
}
