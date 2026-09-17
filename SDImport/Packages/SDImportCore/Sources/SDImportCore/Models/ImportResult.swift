import Foundation

public struct ImportResult: Hashable, Codable, Sendable {
    public let jobID: String
    public let importedFiles: Int
    public let skippedFiles: Int
    public let failedFiles: Int
    public let progressPath: String?
    public let portableReceiptWarning: String?
    public var portableReceiptSizeWarning: PortableReceiptSizeWarning? = nil

    // Preserve the existing import-result encoding; the byte count is a
    // transient display aid for the current process only.
    private enum CodingKeys: String, CodingKey {
        case jobID, importedFiles, skippedFiles, failedFiles, progressPath
        case portableReceiptWarning
    }

    public init(
        jobID: String,
        importedFiles: Int,
        skippedFiles: Int,
        failedFiles: Int,
        progressPath: String?,
        portableReceiptWarning: String? = nil,
        portableReceiptSizeWarning: PortableReceiptSizeWarning? = nil
    ) {
        self.jobID = jobID
        self.importedFiles = importedFiles
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
        self.progressPath = progressPath
        self.portableReceiptWarning = portableReceiptWarning
        self.portableReceiptSizeWarning = portableReceiptSizeWarning
    }
}
