import Foundation
import Testing

@testable import SDImportCore

@Suite("Insta360ClipDetector")
struct Insta360ClipDetectorTests {
    @Test("groups current master and proxy filenames")
    func groupsCurrentMasterAndProxy() throws {
        let master = file(1, "VID_20181001_210458_00_002.insv", kind: .video)
        let proxy = file(2, "LRV_20181001_210458_01_002.lrv", kind: .unsupported)

        let group = try #require(Insta360ClipDetector().groups(files: [proxy, master]).first)

        #expect(group.masterFiles.map(\.filename) == [master.filename])
        #expect(group.proxyFiles.map(\.filename) == [proxy.filename])
    }

    @Test("keeps older dual masters and proxies in one recording")
    func groupsDualMasterRecording() throws {
        let files = [
            file(1, "VID_20181001_210458_00_007.insv", kind: .video),
            file(2, "VID_20181001_210458_10_007.insv", kind: .video),
            file(3, "LRV_20181001_210458_01_007.lrv", kind: .unsupported),
            file(4, "LRV_20181001_210458_11_007.lrv", kind: .unsupported)
        ]

        let group = try #require(Insta360ClipDetector().groups(files: files).first)

        #expect(group.masterFiles.count == 2)
        #expect(group.proxyFiles.count == 2)
    }

    @Test("does not attach orphan or mismatched proxies")
    func leavesOrphanProxyUngrouped() {
        let master = file(1, "VID_20181001_210458_00_007.insv", kind: .video)
        let mismatched = file(2, "LRV_20181001_210458_01_008.lrv", kind: .unsupported)
        let invalid = file(3, "preview.lrv", kind: .unsupported)

        let groups = Insta360ClipDetector().groups(files: [master, mismatched, invalid])

        #expect(groups.count == 1)
        #expect(groups.first?.masterFiles.count == 1)
        #expect(groups.first?.proxyFiles.isEmpty == true)
    }

    @Test("does not attach a proxy from a channel whose master is absent")
    func requiresMatchingChannelMaster() {
        let master = file(1, "VID_20181001_210458_00_007.insv", kind: .video)
        let otherChannelProxy = file(2, "LRV_20181001_210458_11_007.lrv", kind: .unsupported)

        let group = Insta360ClipDetector().groups(files: [master, otherChannelProxy]).first

        #expect(group?.masterFiles.map(\.filename) == [master.filename])
        #expect(group?.proxyFiles.isEmpty == true)
    }

    @Test("rejects missing or nonconsecutive sequence tokens")
    func rejectsMalformedRecordingNames() {
        let validMaster = file(1, "VID_20181001_210458_00_002.insv", kind: .video)
        let missingSequence = file(2, "LRV_20181001_210458_01.lrv", kind: .unsupported)
        let insertedToken = file(3, "LRV_20181001_210458_01_extra_002.lrv", kind: .unsupported)

        let group = Insta360ClipDetector()
            .groups(files: [validMaster, missingSequence, insertedToken])
            .first

        #expect(group?.masterFiles.map(\.filename) == [validMaster.filename])
        #expect(group?.proxyFiles.isEmpty == true)
    }

    @Test("accepts a valid trailing tuple after an earlier numeric token")
    func acceptsTrailingTupleAfterNumericPrefix() throws {
        let master = file(1, "12345678_VID_20181001_210458_00_002.insv", kind: .video)
        let proxy = file(2, "12345678_LRV_20181001_210458_01_002.lrv", kind: .unsupported)

        let group = try #require(Insta360ClipDetector().groups(files: [master, proxy]).first)

        #expect(group.masterFiles.map(\.filename) == [master.filename])
        #expect(group.proxyFiles.map(\.filename) == [proxy.filename])
    }

    @Test("does not merge recordings in case-distinct directories")
    func preservesDirectoryCase() throws {
        let master = file(
            1,
            "VID_20181001_210458_00_002.insv",
            kind: .video,
            directory: "DCIM/Camera"
        )
        let proxy = file(
            2,
            "LRV_20181001_210458_01_002.lrv",
            kind: .unsupported,
            directory: "DCIM/camera"
        )

        let group = try #require(Insta360ClipDetector().groups(files: [master, proxy]).first)

        #expect(group.masterFiles.map(\.filename) == [master.filename])
        #expect(group.proxyFiles.isEmpty)
    }

    @Test("scan totals count a matched recording once")
    func recordingAwareCountsMatchedRecording() {
        let files = [
            file(1, "VID_20181001_210458_00_007.insv", kind: .video),
            file(2, "VID_20181001_210458_10_007.insv", kind: .video),
            file(3, "LRV_20181001_210458_01_007.lrv", kind: .unsupported),
            file(4, "LRV_20181001_210458_11_007.lrv", kind: .unsupported)
        ]

        let counts = RecordingAwareScanSummary.counts(files: files)

        #expect(counts.scannedFiles == 1)
        #expect(counts.newFiles == 1)
        #expect(counts.knownFiles == 0)
        #expect(counts.unsupportedFiles == 0)
    }

    @Test("partly known recordings remain one new recording")
    func recordingAwareCountsPartialKnownRecording() {
        let master = file(
            1,
            "VID_20181001_210458_00_007.insv",
            kind: .video,
            decision: .known,
            knownSource: .localLedger
        )
        let proxy = file(2, "LRV_20181001_210458_01_007.lrv", kind: .unsupported)

        let counts = RecordingAwareScanSummary.counts(files: [master, proxy])

        #expect(counts.newFiles == 1)
        #expect(counts.knownFiles == 0)
        #expect(counts.unsupportedFiles == 0)
    }

    @Test("fully known portable recordings count once")
    func recordingAwareCountsKnownPortableRecording() {
        let master = file(
            1,
            "VID_20181001_210458_00_007.insv",
            kind: .video,
            decision: .known,
            knownSource: .portableLedger
        )
        let proxy = file(
            2,
            "LRV_20181001_210458_01_007.lrv",
            kind: .unsupported,
            decision: .known,
            knownSource: .portableLedger
        )

        let counts = RecordingAwareScanSummary.counts(files: [master, proxy])

        #expect(counts.newFiles == 0)
        #expect(counts.knownFiles == 1)
        #expect(counts.portableKnownFiles == 1)
    }

    @Test("orphan proxies remain unsupported in scan totals")
    func recordingAwareCountsOrphanProxy() {
        let proxy = file(1, "LRV_20181001_210458_11_007.lrv", kind: .unsupported)

        let counts = RecordingAwareScanSummary.counts(files: [proxy])

        #expect(counts.scannedFiles == 1)
        #expect(counts.newFiles == 0)
        #expect(counts.unsupportedFiles == 1)
    }

    @Test("presentation exposes one recording unit with every exact member")
    func presentationGroupsRecordingMembers() throws {
        let files = [
            file(1, "VID_20181001_210458_00_007.insv", kind: .video),
            file(2, "VID_20181001_210458_10_007.insv", kind: .video),
            file(3, "LRV_20181001_210458_01_007.lrv", kind: .unsupported),
            file(4, "LRV_20181001_210458_11_007.lrv", kind: .unsupported),
            file(5, "IMG_0001.JPG", kind: .photo)
        ]

        let units = RecordingPresentation.units(files: files)
        let recording = try #require(units.first)

        #expect(units.count == 2)
        #expect(recording.isInsta360Recording)
        #expect(recording.files.map(\.filename) == [
            "VID_20181001_210458_00_007.insv",
            "VID_20181001_210458_10_007.insv",
            "LRV_20181001_210458_01_007.lrv",
            "LRV_20181001_210458_11_007.lrv"
        ])
        #expect(units[1].primaryFile.filename == "IMG_0001.JPG")
    }

    private func file(
        _ id: Int64,
        _ filename: String,
        kind: MediaKind,
        decision: FileDecision? = nil,
        knownSource: KnownFileSource? = nil,
        directory: String = "DCIM/Camera01"
    ) -> JobFileRecord {
        JobFileRecord(
            id: id,
            jobID: "job-1",
            sourcePath: "/Volumes/CARD/\(directory)/\(filename)",
            relativePath: "\(directory)/\(filename)",
            filename: filename,
            ext: ".\(URL(fileURLWithPath: filename).pathExtension.lowercased())",
            size: 1024,
            modificationDateString: "2018-10-01T21:04:58",
            mediaKind: kind,
            fingerprint: "v2:\(id)",
            captureDate: "2018-10-01",
            decision: decision ?? (kind == .unsupported ? .unsupported : .new),
            knownSource: knownSource,
            destinationDirectory: nil,
            plannedDestinationPath: nil,
            copyStatus: .pending
        )
    }
}
