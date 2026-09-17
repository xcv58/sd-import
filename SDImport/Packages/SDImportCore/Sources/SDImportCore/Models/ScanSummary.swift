import Foundation

public struct ScanSummary: Hashable, Codable, Sendable {
    public let jobID: String
    public let mountPath: String
    public let volumeName: String?
    public let volumeUUID: String?
    public let location: String
    public let scannedFiles: Int
    public let newFiles: Int
    public let knownFiles: Int
    public let unsupportedFiles: Int
    public let conflictFiles: Int
    public let portableKnownFiles: Int?
    public let portableReceiptWarning: String?
    public var portableReceiptSizeWarning: PortableReceiptSizeWarning? = nil

    // Keep the existing scan-summary encoding unchanged. This extra value is
    // only needed while the current process presents a completed scan.
    private enum CodingKeys: String, CodingKey {
        case jobID, mountPath, volumeName, volumeUUID, location, scannedFiles
        case newFiles, knownFiles, unsupportedFiles, conflictFiles
        case portableKnownFiles, portableReceiptWarning
    }

    public init(
        jobID: String,
        mountPath: String,
        volumeName: String?,
        volumeUUID: String?,
        location: String,
        scannedFiles: Int,
        newFiles: Int,
        knownFiles: Int,
        unsupportedFiles: Int,
        conflictFiles: Int,
        portableKnownFiles: Int? = nil,
        portableReceiptWarning: String? = nil,
        portableReceiptSizeWarning: PortableReceiptSizeWarning? = nil
    ) {
        self.jobID = jobID
        self.mountPath = mountPath
        self.volumeName = volumeName
        self.volumeUUID = volumeUUID
        self.location = location
        self.scannedFiles = scannedFiles
        self.newFiles = newFiles
        self.knownFiles = knownFiles
        self.unsupportedFiles = unsupportedFiles
        self.conflictFiles = conflictFiles
        self.portableKnownFiles = portableKnownFiles
        self.portableReceiptWarning = portableReceiptWarning
        self.portableReceiptSizeWarning = portableReceiptSizeWarning
    }
}
