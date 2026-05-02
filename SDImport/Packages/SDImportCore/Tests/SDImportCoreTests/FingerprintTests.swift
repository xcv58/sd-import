import Foundation
import Testing

@testable import SDImportCore

@Suite("FileFingerprint")
struct FingerprintTests {
    @Test("matches Python metadata_fingerprint payload hashing")
    func matchesPythonPayloadHashing() {
        let fingerprint = FileFingerprint.compute(
            size: 17,
            modificationDateString: "2023-11-14T22:13:20"
        )

        #expect(fingerprint.value == "98e81b08042d5ff983c28e093608b4318641da53")
    }

    @Test("formats modification dates with second precision and no timezone suffix")
    func formatsModificationDateLikePythonIsoSeconds() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let utc = TimeZone(secondsFromGMT: 0)!

        let formatted = FileFingerprint.pythonCompatibleModificationDateString(
            date,
            timeZone: utc
        )

        #expect(formatted == "2023-11-14T22:13:20")
    }

    @Test("identity-scoped fingerprints distinguish same-size same-mtime files")
    func identityScopedFingerprintsDistinguishCameraNeighbors() {
        let first = FileFingerprint.compute(
            size: 64_794_624,
            modificationDateString: "2026-04-28T12:59:42",
            identityHint: "DCIM/100MSDCF/DSC03912.ARW"
        )
        let second = FileFingerprint.compute(
            size: 64_794_624,
            modificationDateString: "2026-04-28T12:59:42",
            identityHint: "DCIM/100MSDCF/DSC03913.ARW"
        )

        #expect(first.value.hasPrefix("v2:"))
        #expect(first.value != second.value)
    }
}
