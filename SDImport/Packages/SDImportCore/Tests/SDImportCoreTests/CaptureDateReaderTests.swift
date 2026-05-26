import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import SDImportCore

@Suite("CaptureDateReader")
struct CaptureDateReaderTests {
    @Test("parses common metadata date strings")
    func parsesCommonMetadataDateStrings() throws {
        let exifDate = try #require(CaptureDateParser.date(from: "2022:05:06 07:08:09"))
        let isoDate = try #require(CaptureDateParser.date(from: "2023-04-05T06:07:08Z"))
        let quickTimeDate = try #require(CaptureDateParser.date(from: "2024-03-02T01:00:00+0000"))
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        #expect(CaptureDateParser.captureDateString(from: exifDate) == "2022-05-06")
        #expect(CaptureDateParser.captureDateString(from: isoDate, calendar: utcCalendar) == "2023-04-05")
        #expect(CaptureDateParser.captureDateString(from: quickTimeDate, calendar: utcCalendar) == "2024-03-02")
    }

    @Test("scanner uses JPEG EXIF date before filesystem fallback")
    func scannerUsesJPEGExifDate() throws {
        let rootURL = try temporaryDirectory()
        let mountURL = rootURL.appendingPathComponent("mount", isDirectory: true)
        let photosURL = rootURL.appendingPathComponent("photos", isDirectory: true)
        let videosURL = rootURL.appendingPathComponent("videos", isDirectory: true)
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photosURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videosURL, withIntermediateDirectories: true)

        let sourceURL = mountURL.appendingPathComponent("IMG_EXIF.JPG")
        try writeJPEGWithEXIFDate("2022:05:06 07:08:09", to: sourceURL)
        let fallbackDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.creationDate: fallbackDate, .modificationDate: fallbackDate],
            ofItemAtPath: sourceURL.path
        )

        let pool = try migratedPool()
        let jobRepository = JobRepository(pool: pool)
        let scanner = MediaScanner(
            jobRepository: jobRepository,
            dedupeRepository: DedupeRepository(pool: pool)
        )

        let summary = try scanner.scan(
            ScanRequest(
                mountURL: mountURL,
                volumeName: "CARD",
                location: "TEST",
                roots: DestinationRoots(photosURL: photosURL, videosURL: videosURL),
                jobID: "job-exif"
            )
        )
        let files = try jobRepository.fetchJobFiles(jobID: "job-exif")
        let file = try #require(files.first)

        #expect(summary.newFiles == 1)
        #expect(file.captureDate == "2022-05-06")
        #expect(file.plannedDestinationPath == photosURL
            .appendingPathComponent("2022-05-06 TEST", isDirectory: true)
            .appendingPathComponent("IMG_EXIF.JPG")
            .path)
    }

    private func writeJPEGWithEXIFDate(_ date: String, to url: URL) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw TestImageError.couldNotCreateContext
        }

        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))

        guard let image = context.makeImage() else {
            throw TestImageError.couldNotCreateImage
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw TestImageError.couldNotCreateDestination
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: date
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw TestImageError.couldNotWriteImage
        }
    }
}

private enum TestImageError: Error {
    case couldNotCreateContext
    case couldNotCreateImage
    case couldNotCreateDestination
    case couldNotWriteImage
}
