public struct ImportPreviewGroupDispositionSummary: Equatable, Sendable {
    public let copyCount: Int
    public let skippedCount: Int

    public init(copyCount: Int, skippedCount: Int) {
        self.copyCount = copyCount
        self.skippedCount = skippedCount
    }

    public var mixedStatusTitle: String? {
        guard copyCount > 0, skippedCount > 0 else {
            return nil
        }
        let copiedTitle = copyCount == 1 ? L10n.tr("1 copy") : L10n.tr("\(copyCount) copies")
        return L10n.tr("\(copiedTitle) · \(skippedCount) skipped")
    }
}
