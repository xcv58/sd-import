import Testing

@testable import SDImportCore

@Suite("Photo pair detector")
struct PhotoPairDetectorTests {
    @Test("summarizes RAW and JPEG pairs by folder and filename stem")
    func summarizesRawAndJPEGPairsByFolderAndStem() {
        let files = [
            jobFile(relativePath: "DCIM/100MEDIA/IMG_0001.ARW", ext: ".ARW", mediaKind: .photo),
            jobFile(relativePath: "DCIM/100MEDIA/IMG_0001.JPG", ext: ".JPG", mediaKind: .photo),
            jobFile(relativePath: "DCIM/100MEDIA/IMG_0002.ARW", ext: ".ARW", mediaKind: .photo),
            jobFile(relativePath: "DCIM/100MEDIA/IMG_0003.JPG", ext: ".JPG", mediaKind: .photo),
            jobFile(relativePath: "DCIM/100MEDIA/IMG_0004.MOV", ext: ".MOV", mediaKind: .video)
        ]

        let summary = PhotoPairDetector().summarize(files: files)

        #expect(summary.rawJPEGPairCount == 1)
        #expect(summary.rawOnlyCount == 1)
        #expect(summary.jpegOnlyCount == 1)
    }

    @Test("does not pair files from different folders")
    func doesNotPairFilesFromDifferentFolders() {
        let files = [
            jobFile(relativePath: "DCIM/100MEDIA/IMG_0001.ARW", ext: ".ARW", mediaKind: .photo),
            jobFile(relativePath: "DCIM/101MEDIA/IMG_0001.JPG", ext: ".JPG", mediaKind: .photo)
        ]

        let summary = PhotoPairDetector().summarize(files: files)

        #expect(summary.rawJPEGPairCount == 0)
        #expect(summary.rawOnlyCount == 1)
        #expect(summary.jpegOnlyCount == 1)
    }
}

private func jobFile(
    relativePath: String,
    ext: String,
    mediaKind: MediaKind
) -> JobFileRecord {
    JobFileRecord(
        id: 1,
        jobID: "job-1",
        sourcePath: "/Volumes/CARD/\(relativePath)",
        relativePath: relativePath,
        filename: String(relativePath.split(separator: "/").last ?? ""),
        ext: ext,
        size: 10,
        modificationDateString: "2026-04-29T12:00:00Z",
        mediaKind: mediaKind,
        fingerprint: nil,
        captureDate: "2026-04-29",
        decision: .new,
        destinationDirectory: nil,
        plannedDestinationPath: nil,
        copyStatus: .pending
    )
}
