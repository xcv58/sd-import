import Foundation
import Testing

@testable import SDImportCore

@Suite("ConflictResolver")
struct ConflictResolverTests {
    @Test("returns candidate when destination is missing")
    func returnsCandidateWhenMissing() throws {
        let directory = try temporaryDirectory()
        let candidate = directory.appendingPathComponent("IMG_0001.JPG")
        let fingerprint = FileFingerprint.compute(
            size: 17,
            modificationDateString: "2023-11-14T22:13:20"
        )

        let resolution = ConflictResolver().resolveDestination(
            candidate: candidate,
            expectedFingerprint: fingerprint
        )

        #expect(resolution == .copy(to: candidate))
    }

    @Test("allocates copy suffix for different existing destination")
    func allocatesCopySuffix() throws {
        let directory = try temporaryDirectory()
        let candidate = directory.appendingPathComponent("IMG_0001.JPG")
        let copy1 = directory.appendingPathComponent("IMG_0001-copy-1.JPG")
        try Data("old".utf8).write(to: candidate)
        try Data("older".utf8).write(to: copy1)
        let fingerprint = FileFingerprint.compute(
            size: 17,
            modificationDateString: "2023-11-14T22:13:20"
        )

        let resolution = ConflictResolver().resolveDestination(
            candidate: candidate,
            expectedFingerprint: fingerprint
        )

        #expect(resolution == .copy(to: directory.appendingPathComponent("IMG_0001-copy-2.JPG")))
    }
}
