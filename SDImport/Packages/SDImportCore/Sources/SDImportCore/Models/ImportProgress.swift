import Foundation

public struct ImportProgressFileEvent: Hashable, Codable, Identifiable, Sendable {
    public let id: String
    public let filename: String
    public let status: CopyStatus
    public let detail: String?
    public let destinationPath: String?
    public let size: Int64

    public init(
        id: String,
        filename: String,
        status: CopyStatus,
        detail: String?,
        destinationPath: String?,
        size: Int64
    ) {
        self.id = id
        self.filename = filename
        self.status = status
        self.detail = detail
        self.destinationPath = destinationPath
        self.size = size
    }
}

public struct ImportProgress: Hashable, Codable, Sendable {
    public let jobID: String
    public let volumeName: String?
    public let status: String
    public let startedAt: Date
    public let updatedAt: Date
    public let totalFiles: Int
    public let doneFiles: Int
    public let importedFiles: Int
    public let skippedFiles: Int
    public let failedFiles: Int
    public let totalBytes: Int64
    public let processedBytes: Int64
    public let copiedBytes: Int64
    public let throughputBytesPerSecond: Double
    public let etaSeconds: Double?
    public let percent: Double
    public let currentFilename: String?
    public let currentSourcePath: String?
    public let currentDestinationPath: String?
    public let recentFiles: [ImportProgressFileEvent]
    public let reportPath: String?

    public init(
        jobID: String,
        volumeName: String?,
        status: String,
        startedAt: Date,
        updatedAt: Date,
        totalFiles: Int,
        doneFiles: Int,
        importedFiles: Int,
        skippedFiles: Int,
        failedFiles: Int,
        totalBytes: Int64,
        processedBytes: Int64,
        copiedBytes: Int64,
        throughputBytesPerSecond: Double,
        etaSeconds: Double?,
        percent: Double,
        currentFilename: String?,
        currentSourcePath: String?,
        currentDestinationPath: String? = nil,
        recentFiles: [ImportProgressFileEvent] = [],
        reportPath: String?
    ) {
        self.jobID = jobID
        self.volumeName = volumeName
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.totalFiles = totalFiles
        self.doneFiles = doneFiles
        self.importedFiles = importedFiles
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
        self.totalBytes = totalBytes
        self.processedBytes = processedBytes
        self.copiedBytes = copiedBytes
        self.throughputBytesPerSecond = throughputBytesPerSecond
        self.etaSeconds = etaSeconds
        self.percent = percent
        self.currentFilename = currentFilename
        self.currentSourcePath = currentSourcePath
        self.currentDestinationPath = currentDestinationPath
        self.recentFiles = recentFiles
        self.reportPath = reportPath
    }
}
