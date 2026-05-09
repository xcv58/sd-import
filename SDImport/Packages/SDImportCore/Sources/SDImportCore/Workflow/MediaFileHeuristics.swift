import Foundation

public enum MediaFileHeuristics {
    public static let videoPreviewJPEGThresholdBytes: Int64 = 1_000_000

    public static func isLikelyVideoPreviewJPEG(_ file: JobFileRecord) -> Bool {
        guard file.mediaKind == .photo, file.size < videoPreviewJPEGThresholdBytes else {
            return false
        }
        let ext = file.ext.lowercased(with: Locale(identifier: "en_US_POSIX"))
        return ext == ".jpg" || ext == ".jpeg"
    }
}
