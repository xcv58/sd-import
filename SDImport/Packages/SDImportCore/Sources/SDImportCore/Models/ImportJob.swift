import Foundation

public struct ImportJob: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?
    public let mountPath: String
    public let volumeName: String?
    public let volumeUUID: String?
    public let location: String
    public let photosRoot: String
    public let videosRoot: String
    public var status: ImportJobStatus
    public var scannedFiles: Int
    public var newFiles: Int
    public var knownFiles: Int
    public var unsupportedFiles: Int
    public var conflictFiles: Int
    public var importedFiles: Int
    public var skippedFiles: Int
    public var failedFiles: Int
    public var summaryJSONPath: String?
    public var summaryMarkdownPath: String?
    public var appVersion: String?

    public init(
        id: String,
        createdAt: Date,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        mountPath: String,
        volumeName: String? = nil,
        volumeUUID: String? = nil,
        location: String,
        photosRoot: String,
        videosRoot: String,
        status: ImportJobStatus,
        scannedFiles: Int = 0,
        newFiles: Int = 0,
        knownFiles: Int = 0,
        unsupportedFiles: Int = 0,
        conflictFiles: Int = 0,
        importedFiles: Int = 0,
        skippedFiles: Int = 0,
        failedFiles: Int = 0,
        summaryJSONPath: String? = nil,
        summaryMarkdownPath: String? = nil,
        appVersion: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.mountPath = mountPath
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.location = location
        self.photosRoot = photosRoot
        self.videosRoot = videosRoot
        self.status = status
        self.scannedFiles = scannedFiles
        self.newFiles = newFiles
        self.knownFiles = knownFiles
        self.unsupportedFiles = unsupportedFiles
        self.conflictFiles = conflictFiles
        self.importedFiles = importedFiles
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
        self.summaryJSONPath = summaryJSONPath
        self.summaryMarkdownPath = summaryMarkdownPath
        self.appVersion = appVersion
    }
}
