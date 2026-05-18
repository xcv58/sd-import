import Foundation

public struct ImportReport: Hashable, Codable, Sendable {
    public let summary: ScanSummary
    public let files: [JobFileRecord]

    public init(summary: ScanSummary, files: [JobFileRecord]) {
        self.summary = summary
        self.files = files
    }
}

public struct ImportReportLoader {
    private let decoder: JSONDecoder

    public init() {
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loadJSON(from url: URL) throws -> ImportReport {
        let data = try Data(contentsOf: url)
        return try decoder.decode(ImportReport.self, from: data)
    }

    public func loadMarkdown(from url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
