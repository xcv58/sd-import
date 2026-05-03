import Foundation

public struct VolumeCapacity: Equatable, Sendable {
    public let volumeID: String
    public let displayPath: String
    public let availableBytes: Int64
    public let totalBytes: Int64?

    public init(
        volumeID: String,
        displayPath: String,
        availableBytes: Int64,
        totalBytes: Int64?
    ) {
        self.volumeID = volumeID
        self.displayPath = displayPath
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }
}

public struct DestinationSpaceRequirement: Equatable, Sendable {
    public let volumeID: String
    public let displayPath: String
    public let requiredBytes: Int64
    public let availableBytes: Int64
    public let totalBytes: Int64?

    public var isSatisfied: Bool {
        requiredBytes <= availableBytes
    }
}

public struct DestinationSpaceCheckResult: Equatable, Sendable {
    public let requirements: [DestinationSpaceRequirement]

    public var failures: [DestinationSpaceRequirement] {
        requirements.filter { !$0.isSatisfied }
    }

    public var hasEnoughSpace: Bool {
        failures.isEmpty
    }
}

public struct DestinationSpaceChecker: Sendable {
    public typealias CapacityProvider = @Sendable (_ destinationDirectory: String) throws -> VolumeCapacity?

    private let capacityProvider: CapacityProvider

    public init(capacityProvider: @escaping CapacityProvider = DestinationSpaceChecker.fileSystemCapacity) {
        self.capacityProvider = capacityProvider
    }

    public func check(files: [JobFileRecord]) throws -> DestinationSpaceCheckResult {
        var grouped: [String: (capacity: VolumeCapacity, requiredBytes: Int64)] = [:]

        for file in files where file.size > 0 {
            guard let destinationDirectory = file.destinationDirectory else {
                continue
            }
            guard let capacity = try capacityProvider(destinationDirectory) else {
                continue
            }

            let existing = grouped[capacity.volumeID]
            grouped[capacity.volumeID] = (
                capacity: existing?.capacity ?? capacity,
                requiredBytes: (existing?.requiredBytes ?? 0) + file.size
            )
        }

        let requirements = grouped.values
            .map { item in
                DestinationSpaceRequirement(
                    volumeID: item.capacity.volumeID,
                    displayPath: item.capacity.displayPath,
                    requiredBytes: item.requiredBytes,
                    availableBytes: item.capacity.availableBytes,
                    totalBytes: item.capacity.totalBytes
                )
            }
            .sorted { $0.displayPath.localizedStandardCompare($1.displayPath) == .orderedAscending }

        return DestinationSpaceCheckResult(requirements: requirements)
    }

    public static func fileSystemCapacity(for destinationDirectory: String) throws -> VolumeCapacity? {
        guard let existingURL = nearestExistingDirectory(for: destinationDirectory) else {
            return nil
        }

        let attributes = try FileManager.default.attributesOfFileSystem(forPath: existingURL.path)
        guard let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value else {
            return nil
        }

        let total = (attributes[.systemSize] as? NSNumber)?.int64Value
        let volumeID = (attributes[.systemNumber] as? NSNumber)?.stringValue ?? existingURL.path

        return VolumeCapacity(
            volumeID: volumeID,
            displayPath: existingURL.path,
            availableBytes: available,
            totalBytes: total
        )
    }

    private static func nearestExistingDirectory(for path: String) -> URL? {
        var url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false

        while true {
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }

            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else {
                return nil
            }
            url = parent
        }
    }
}
