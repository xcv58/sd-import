import AVFoundation
import Foundation
import ImageIO

public protocol CaptureDateReading {
    func captureDate(
        for fileURL: URL,
        mediaKind: MediaKind,
        attributes: FileAttributes
    ) -> String
}

public struct FileAttributes: Hashable, Sendable {
    public let size: Int64
    public let modificationDate: Date
    public let creationDate: Date?

    public init(size: Int64, modificationDate: Date, creationDate: Date?) {
        self.size = size
        self.modificationDate = modificationDate
        self.creationDate = creationDate
    }
}

public struct NativeCaptureDateReader: CaptureDateReading {
    private let imageReader: ImageCaptureDateReader
    private let videoReader: VideoCaptureDateReader
    private let fallbackReader: FileDateFallbackReader

    public init(
        imageReader: ImageCaptureDateReader = ImageCaptureDateReader(),
        videoReader: VideoCaptureDateReader = VideoCaptureDateReader(),
        fallbackReader: FileDateFallbackReader = FileDateFallbackReader()
    ) {
        self.imageReader = imageReader
        self.videoReader = videoReader
        self.fallbackReader = fallbackReader
    }

    public func captureDate(
        for fileURL: URL,
        mediaKind: MediaKind,
        attributes: FileAttributes
    ) -> String {
        let metadataDate: Date?
        switch mediaKind {
        case .photo:
            metadataDate = imageReader.metadataDate(for: fileURL)
        case .video:
            metadataDate = videoReader.metadataDate(for: fileURL)
        case .unsupported:
            metadataDate = nil
        }

        guard let metadataDate else {
            return fallbackReader.captureDate(
                for: fileURL,
                mediaKind: mediaKind,
                attributes: attributes
            )
        }

        return CaptureDateParser.captureDateString(from: metadataDate)
    }
}

public struct ImageCaptureDateReader {
    public init() {}

    public func metadataDate(for fileURL: URL) -> Date? {
        guard
            let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let candidates: [Any?] = [
            exif?[kCGImagePropertyExifDateTimeOriginal as String],
            exif?[kCGImagePropertyExifDateTimeDigitized as String],
            tiff?[kCGImagePropertyTIFFDateTime as String]
        ]

        for value in candidates {
            if let string = value as? String, let date = CaptureDateParser.date(from: string) {
                return date
            }
        }

        return nil
    }
}

public struct VideoCaptureDateReader {
    public init() {}

    public func metadataDate(for fileURL: URL) -> Date? {
        let asset = AVURLAsset(url: fileURL)
        let allMetadata = asset.commonMetadata + asset.metadata + asset.availableMetadataFormats.flatMap {
            asset.metadata(forFormat: $0)
        }

        for item in allMetadata where isCreationMetadata(item) {
            if let date = date(from: item) {
                return date
            }
        }

        return allMetadata.compactMap(date(from:)).first
    }

    private func isCreationMetadata(_ item: AVMetadataItem) -> Bool {
        let keyParts = [
            item.identifier?.rawValue,
            item.commonKey?.rawValue,
            item.key as? String
        ]
        .compactMap { $0?.lowercased() }

        return keyParts.contains { part in
            part.contains("creation") || part.contains("created") || part.contains("date")
        }
    }

    private func date(from item: AVMetadataItem) -> Date? {
        if let date = item.dateValue {
            return date
        }
        if let string = item.stringValue {
            return CaptureDateParser.date(from: string)
        }
        return nil
    }
}

public struct FileDateFallbackReader: CaptureDateReading {
    private let calendar: Calendar

    public init(calendar: Calendar = Calendar(identifier: .gregorian)) {
        self.calendar = calendar
    }

    public func captureDate(
        for fileURL: URL,
        mediaKind: MediaKind,
        attributes: FileAttributes
    ) -> String {
        let date = attributes.creationDate ?? attributes.modificationDate
        return CaptureDateParser.captureDateString(from: date, calendar: calendar)
    }
}

enum CaptureDateParser {
    static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let date = iso8601Formatter.date(from: trimmed) {
            return date
        }

        if let date = iso8601Formatter.date(from: normalizedISO8601(trimmed)) {
            return date
        }

        return dateFormats.compactMap { format in
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter.date(from: trimmed)
        }.first
    }

    static func captureDateString(
        from date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static let dateFormats = [
        "yyyy:MM:dd HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
        "yyyy-MM-dd"
    ]

    private static var iso8601Formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }

    private static func normalizedISO8601(_ string: String) -> String {
        if string.hasSuffix("Z") || string.contains("+") {
            return string
        }
        return string + "Z"
    }
}
