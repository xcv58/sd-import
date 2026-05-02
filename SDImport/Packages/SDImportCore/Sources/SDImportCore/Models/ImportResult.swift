import Foundation

public struct ImportResult: Hashable, Codable, Sendable {
    public let jobID: String
    public let importedFiles: Int
    public let skippedFiles: Int
    public let failedFiles: Int
    public let progressPath: String?

    public init(
        jobID: String,
        importedFiles: Int,
        skippedFiles: Int,
        failedFiles: Int,
        progressPath: String?
    ) {
        self.jobID = jobID
        self.importedFiles = importedFiles
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
        self.progressPath = progressPath
    }
}
