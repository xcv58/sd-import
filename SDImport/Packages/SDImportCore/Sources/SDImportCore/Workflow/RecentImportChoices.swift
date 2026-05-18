import Foundation

public struct RecentShootNameChoice: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let useCount: Int
    public let lastUsedAt: Date

    public init(name: String, useCount: Int, lastUsedAt: Date) {
        self.name = name
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}

public struct RecentPathChoice: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let displayName: String
    public let useCount: Int
    public let lastUsedAt: Date

    public init(path: String, displayName: String, useCount: Int, lastUsedAt: Date) {
        self.path = path
        self.displayName = displayName
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}

public enum RecentImportChoices {
    public static func shootNames(from jobs: [ImportJob], limit: Int = 6) -> [RecentShootNameChoice] {
        let ranked = rankedValues(
            from: jobs,
            key: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        ) { job in
            normalizedShootName(job.location)
        }

        return ranked
            .prefix(limit)
            .map {
                RecentShootNameChoice(
                    name: $0.value,
                    useCount: $0.useCount,
                    lastUsedAt: $0.lastUsedAt
                )
            }
    }

    public static func sourcePaths(from jobs: [ImportJob], limit: Int = 6) -> [RecentPathChoice] {
        pathChoices(from: jobs, limit: limit) { job in
            normalizedPath(job.mountPath)
        }
    }

    public static func photoRoots(from jobs: [ImportJob], limit: Int = 6) -> [RecentPathChoice] {
        pathChoices(from: jobs, limit: limit) { job in
            normalizedPath(job.photosRoot)
        }
    }

    public static func videoRoots(from jobs: [ImportJob], limit: Int = 6) -> [RecentPathChoice] {
        pathChoices(from: jobs, limit: limit) { job in
            normalizedPath(job.videosRoot)
        }
    }

    private static func pathChoices(
        from jobs: [ImportJob],
        limit: Int,
        value: (ImportJob) -> String?
    ) -> [RecentPathChoice] {
        rankedValues(from: jobs, value: value)
            .prefix(limit)
            .map {
                RecentPathChoice(
                    path: $0.value,
                    displayName: displayName(forPath: $0.value),
                    useCount: $0.useCount,
                    lastUsedAt: $0.lastUsedAt
                )
            }
    }

    private static func rankedValues(
        from jobs: [ImportJob],
        key: (String) -> String = { $0 },
        value: (ImportJob) -> String?
    ) -> [RankedValue] {
        var values: [String: RankedValue] = [:]

        for job in jobs where job.isImportHistoryEntry {
            guard let value = value(job) else {
                continue
            }

            let timestamp = job.completedAt ?? job.startedAt ?? job.createdAt
            let key = key(value)
            var ranked = values[key] ?? RankedValue(value: value, useCount: 0, lastUsedAt: timestamp)
            ranked.useCount += 1
            if timestamp > ranked.lastUsedAt {
                ranked.value = value
                ranked.lastUsedAt = timestamp
            }
            values[key] = ranked
        }

        return values.values.sorted { lhs, rhs in
            if lhs.useCount != rhs.useCount {
                return lhs.useCount > rhs.useCount
            }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
        }
    }

    private static func normalizedShootName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.localizedCaseInsensitiveCompare("Untitled") != .orderedSame else {
            return nil
        }
        return trimmed
    }

    private static func normalizedPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath
    }

    private static func displayName(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let lastComponent = url.lastPathComponent
        return lastComponent.isEmpty ? path : lastComponent
    }
}

private struct RankedValue {
    var value: String
    var useCount: Int
    var lastUsedAt: Date
}
