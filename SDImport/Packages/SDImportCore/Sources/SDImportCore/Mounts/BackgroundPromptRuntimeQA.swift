import Foundation

#if DEBUG
public enum BackgroundPromptRuntimeQA {
    private struct LifecycleMarker: Codable {
        let targetApplicationPath: String
        let createdAt: Date
    }

    public static let prepareApplicationArgument = "--sdimport-helper-runtime-qa-prepare"
    public static let consumeHandoffArgument = "--sdimport-helper-runtime-qa-consume-handoff"
    public static let unregisterHelperArgument = "--sdimport-helper-runtime-qa-unregister"
    public static let injectedMountArgument = "--sdimport-helper-runtime-qa-mount"
    public static let lifecycleMarkerMaximumAge: TimeInterval = 5 * 60

    public static func preparesApplication(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        distribution: AppDistribution = .current
    ) -> Bool {
        distribution == .macAppStore && arguments.contains(prepareApplicationArgument)
    }

    public static func preparedApplicationConfiguration(
        _ configuration: AppConfiguration,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        distribution: AppDistribution = .current
    ) -> AppConfiguration? {
        guard preparesApplication(arguments: arguments, distribution: distribution) else {
            return nil
        }
        var preparedConfiguration = configuration
        preparedConfiguration.autoPromptEnabled = true
        preparedConfiguration.hasCompletedOnboarding = true
        return preparedConfiguration
    }

    public static func unregistersHelper(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        distribution: AppDistribution = .current
    ) -> Bool {
        distribution == .macAppStore && arguments.contains(unregisterHelperArgument)
    }

    public static func consumesInjectedHandoff(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        distribution: AppDistribution = .current
    ) -> Bool {
        distribution == .macAppStore && arguments.contains(consumeHandoffArgument)
    }

    public static func permitsRegistrationReconciliation(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        distribution: AppDistribution = .current,
        helperLifecycleIsActive: Bool = false
    ) -> Bool {
        !preparesApplication(arguments: arguments, distribution: distribution)
            && !consumesInjectedHandoff(arguments: arguments, distribution: distribution)
            && !unregistersHelper(arguments: arguments, distribution: distribution)
            && !(distribution == .macAppStore && helperLifecycleIsActive)
    }

    public static func markHelperLifecycleActive(
        targetApplicationURL: URL,
        markerURL: URL? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws {
        let resolvedMarkerURL = try markerURL ?? defaultLifecycleMarkerURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: resolvedMarkerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let marker = LifecycleMarker(
            targetApplicationPath: normalizedPath(targetApplicationURL),
            createdAt: now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: resolvedMarkerURL, options: [.atomic])
    }

    public static func helperLifecycleIsActive(
        targetApplicationURL: URL = Bundle.main.bundleURL,
        markerURL: URL? = nil,
        now: Date = Date(),
        maximumAge: TimeInterval = lifecycleMarkerMaximumAge,
        fileManager: FileManager = .default
    ) -> Bool {
        guard
            maximumAge >= 0,
            let resolvedMarkerURL = try? markerURL ?? defaultLifecycleMarkerURL(fileManager: fileManager),
            let data = try? Data(contentsOf: resolvedMarkerURL)
        else {
            return false
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard
            let marker = try? decoder.decode(LifecycleMarker.self, from: data),
            marker.targetApplicationPath == normalizedPath(targetApplicationURL),
            now.timeIntervalSince(marker.createdAt) >= 0,
            now.timeIntervalSince(marker.createdAt) <= maximumAge
        else {
            return false
        }
        return true
    }

    public static func clearHelperLifecycleMarker(
        markerURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let resolvedMarkerURL = try markerURL ?? defaultLifecycleMarkerURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: resolvedMarkerURL.path) else {
            return
        }
        try fileManager.removeItem(at: resolvedMarkerURL)
    }

    public static func injectedMountURL(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        distribution: AppDistribution = .current
    ) -> URL? {
        guard distribution == .macAppStore else {
            return nil
        }
        guard
            let argumentIndex = arguments.firstIndex(of: injectedMountArgument),
            arguments.indices.contains(argumentIndex + 1)
        else {
            return nil
        }
        let url = URL(
            fileURLWithPath: arguments[argumentIndex + 1],
            isDirectory: true
        ).standardizedFileURL
        guard url.path.hasPrefix("/Volumes/") else {
            return nil
        }
        return url
    }

    public static func injectedPostDetectionVolume(at mountURL: URL) -> MountedVolume {
        let url = mountURL.standardizedFileURL
        return MountedVolume(
            id: "runtime-qa:\(url.path)",
            name: url.lastPathComponent,
            mountURL: url,
            volumeUUID: nil,
            isRemovable: true,
            isInternal: false,
            isDiskImage: false,
            totalCapacityBytes: nil,
            availableCapacityBytes: nil
        )
    }

    public static func retainingLivePromptVolume(
        _ fixture: MountedVolume?,
        in volumes: [MountedVolume],
        isCurrent: (MountedVolume) -> Bool
    ) -> [MountedVolume] {
        guard let fixture,
              !volumes.contains(where: { $0.mountPath == fixture.mountPath }),
              isCurrent(fixture) else {
            return volumes
        }
        return volumes + [fixture]
    }

    private static func defaultLifecycleMarkerURL(fileManager: FileManager) throws -> URL {
        try AppGroupContainer.sharedSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("Background Prompt", isDirectory: true)
            .appendingPathComponent("runtime-qa-active.json", isDirectory: false)
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
#endif
