import DiskArbitration
import Foundation
import IOKit

public struct VolumeDetector: Sendable {
    private let ignoredNameFragments: [String]
    private let classifier = MediaClassifier()

    public init(ignoredNameFragments: [String] = ["time machine", "backup", "recovery", "preboot", "macintosh hd"]) {
        self.ignoredNameFragments = ignoredNameFragments.map { $0.lowercased() }
    }

    public func removableSourceVolume(containing sourceURL: URL) -> MountedVolume? {
        guard let root = try? sourceURL.resourceValues(forKeys: [.volumeURLKey]).volume,
              let volume = currentMountedVolume(from: root, includeCapacity: false),
              isRemovableSourceVolume(volume) else { return nil }
        return volume
    }

    public func currentMountedVolume(from mountURL: URL, includeCapacity: Bool = true) -> MountedVolume? {
        let freshURL = URL(fileURLWithPath: mountURL.path, isDirectory: true).standardizedFileURL
        guard let root = (try? freshURL.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              root.standardizedFileURL.path == freshURL.path else {
            return nil
        }
        return mountedVolume(from: freshURL, includeCapacity: includeCapacity)
    }

    public func mountedVolume(
        from mountURL: URL,
        includeCapacity: Bool = true
    ) -> MountedVolume {
        var resourceKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey
        ]
        if includeCapacity {
            resourceKeys.formUnion([
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
        }
        let values = try? mountURL.resourceValues(forKeys: resourceKeys)
        let name = values?.volumeName ?? mountURL.lastPathComponent
        let diskTraits = Self.diskTraits(for: mountURL)
        let isRemovable = (values?.volumeIsRemovable ?? false)
            || (values?.volumeIsEjectable ?? false)
            || diskTraits.isRemovable
            || diskTraits.isEjectable
        let totalCapacity = includeCapacity
            ? values?.volumeTotalCapacity.map(Int64.init)
            : nil
        let availableCapacity = includeCapacity
            ? Self.sourceAvailableCapacity(
                available: values?.volumeAvailableCapacity.map(Int64.init),
                importantUsage: values?.volumeAvailableCapacityForImportantUsage
            )
            : nil

        return MountedVolume(
            id: values?.volumeUUIDString ?? mountURL.standardizedFileURL.path,
            name: name,
            mountURL: mountURL,
            volumeUUID: values?.volumeUUIDString,
            isRemovable: isRemovable,
            isInternal: values?.volumeIsInternal ?? false,
            isDiskImage: diskTraits.isDiskImage || Self.hasDiskImageNameOrPath(name: name, path: mountURL.path),
            totalCapacityBytes: totalCapacity,
            availableCapacityBytes: availableCapacity,
            wholeDiskIdentifier: diskTraits.wholeDiskIdentifier,
            deviceGroupIdentifier: diskTraits.deviceGroupIdentifier,
            deviceVendorName: diskTraits.deviceVendorName,
            deviceProductName: diskTraits.deviceProductName,
            mediaRegistryID: diskTraits.mediaRegistryID
        )
    }

    public func allMountedVolumes(
        under rootURL: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default,
        includeCapacity: Bool = true
    ) -> [MountedVolume] {
        var keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeUUIDStringKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey
        ]
        if includeCapacity {
            keys.formUnion([
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
        }
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return urls.map { mountedVolume(from: $0, includeCapacity: includeCapacity) }
    }

    public func mountedVolumes(
        under rootURL: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default,
        includeCapacity: Bool = true
    ) -> [MountedVolume] {
        likelyImportVolumes(
            from: allMountedVolumes(
                under: rootURL,
                fileManager: fileManager,
                includeCapacity: includeCapacity
            )
        )
    }

    public func likelyImportVolumes(from volumes: [MountedVolume]) -> [MountedVolume] {
        volumes
            .filter(isLikelyImportVolume)
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    public func isLikelyImportVolume(_ volume: MountedVolume) -> Bool {
        let lowercasedName = volume.name.lowercased()
        guard !ignoredNameFragments.contains(where: lowercasedName.contains) else {
            return false
        }
        return isRemovableSourceVolume(volume)
    }

    func isRemovableSourceVolume(_ volume: MountedVolume) -> Bool {
        volume.isRemovable && volume.mountURL.path.hasPrefix("/Volumes/") && !isDiskImage(volume)
    }

    public func containsImportableMedia(
        at rootURL: URL,
        fileManager: FileManager = .default,
        maximumCandidates: Int = 20_000,
        maximumDuration: TimeInterval = 2.0
    ) -> Bool {
        let deadline = Date().addingTimeInterval(maximumDuration)
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var inspectedFiles = 0
        for case let url as URL in enumerator {
            if Task.isCancelled || Date() > deadline {
                return false
            }
            if url.lastPathComponent.hasPrefix(".") {
                if isDirectory(url, fileManager: fileManager) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if isDirectory(url, fileManager: fileManager) {
                continue
            }

            inspectedFiles += 1
            if classifier.classify(url: url) != .unsupported {
                return true
            }
            if inspectedFiles >= maximumCandidates {
                return false
            }
        }

        return false
    }

    private func isDiskImage(_ volume: MountedVolume) -> Bool {
        volume.isDiskImage || Self.hasDiskImageNameOrPath(name: volume.name, path: volume.mountURL.path)
    }

    private static func hasDiskImageNameOrPath(name: String, path: String) -> Bool {
        let name = name.lowercased()
        let path = path.lowercased()
        return name.hasSuffix(".dmg")
            || name.hasSuffix(".sparsebundle")
            || path.hasSuffix(".dmg")
            || path.hasSuffix(".sparsebundle")
    }

    private static func diskTraits(for volumeURL: URL) -> DiskTraits {
        guard
            let session = DASessionCreate(kCFAllocatorDefault),
            let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
            let description = DADiskCopyDescription(disk) as? [String: Any]
        else {
            return DiskTraits()
        }

        let wholeDiskIdentifier: String?
        if
            let wholeDisk = DADiskCopyWholeDisk(disk),
            let bsdName = DADiskGetBSDName(wholeDisk)
        {
            // Keep the copied DADisk alive while copying its borrowed BSD-name pointer.
            wholeDiskIdentifier = validatedWholeDiskIdentifier(String(cString: bsdName))
        } else {
            wholeDiskIdentifier = nil
        }
        let media = DADiskCopyIOMedia(disk)
        let mediaRegistryID = registryEntryID(of: media)
        let deviceTraits = usbDeviceTraits(consuming: media)

        return DiskTraits(
            deviceModel: description[kDADiskDescriptionDeviceModelKey as String] as? String,
            mediaName: description[kDADiskDescriptionMediaNameKey as String] as? String,
            isRemovable: boolValue(description[kDADiskDescriptionMediaRemovableKey as String]),
            isEjectable: boolValue(description[kDADiskDescriptionMediaEjectableKey as String]),
            wholeDiskIdentifier: wholeDiskIdentifier,
            deviceGroupIdentifier: deviceTraits?.identifier,
            deviceVendorName: deviceTraits?.vendorName,
            deviceProductName: sanitizedDeviceProductName(deviceTraits?.productName),
            mediaRegistryID: mediaRegistryID
        )
    }

    private static func registryEntryID(of entry: io_registry_entry_t) -> UInt64? {
        guard entry != IO_OBJECT_NULL else { return nil }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS ? id : nil
    }

    // Takes ownership of the reference returned by DADiskCopyIOMedia.
    private static func usbDeviceTraits(consuming media: io_registry_entry_t) -> USBDeviceTraits? {
        var entry = media
        while entry != IO_OBJECT_NULL {
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                let traits = registryEntryID(of: entry).map { id in
                    USBDeviceTraits(
                        identifier: String(id, radix: 16),
                        vendorName: registryStringProperty("USB Vendor Name", entry: entry),
                        productName: registryStringProperty("USB Product Name", entry: entry)
                    )
                }
                IOObjectRelease(entry)
                return traits
            }

            var parent = IO_OBJECT_NULL
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else {
                return nil
            }
            entry = parent
        }
        return nil
    }

    private static func registryStringProperty(_ key: String, entry: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        return value.takeRetainedValue() as? String
    }

    static func sanitizedDeviceProductName(_ productName: String?) -> String? {
        guard let productName else {
            return nil
        }
        let trimmed = productName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let components = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        let suffix = components.last
        let letterCount = suffix?.count(where: \.isLetter) ?? 0
        let numberCount = suffix?.count(where: \.isNumber) ?? 0
        guard
            components.count > 1,
            let suffix,
            suffix.count >= 12,
            letterCount >= 4,
            numberCount >= 4,
            suffix.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            return trimmed
        }
        return components.dropLast().joined(separator: "-")
    }

    static func validatedWholeDiskIdentifier(_ identifier: String?) -> String? {
        guard let identifier, identifier.hasPrefix("disk") else {
            return nil
        }
        let number = identifier.dropFirst(4)
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else {
            return nil
        }
        return identifier
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return false
    }

    private struct DiskTraits: Sendable {
        let deviceModel: String?
        let mediaName: String?
        let isRemovable: Bool
        let isEjectable: Bool
        let wholeDiskIdentifier: String?
        let deviceGroupIdentifier: String?
        let deviceVendorName: String?
        let deviceProductName: String?
        let mediaRegistryID: UInt64?

        init(
            deviceModel: String? = nil,
            mediaName: String? = nil,
            isRemovable: Bool = false,
            isEjectable: Bool = false,
            wholeDiskIdentifier: String? = nil,
            deviceGroupIdentifier: String? = nil,
            deviceVendorName: String? = nil,
            deviceProductName: String? = nil,
            mediaRegistryID: UInt64? = nil
        ) {
            self.deviceModel = deviceModel
            self.mediaName = mediaName
            self.isRemovable = isRemovable
            self.isEjectable = isEjectable
            self.wholeDiskIdentifier = wholeDiskIdentifier
            self.deviceGroupIdentifier = deviceGroupIdentifier
            self.deviceVendorName = deviceVendorName
            self.deviceProductName = deviceProductName
            self.mediaRegistryID = mediaRegistryID
        }

        var isDiskImage: Bool {
            [deviceModel, mediaName]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains("disk image") }
        }
    }

    private struct USBDeviceTraits: Sendable {
        let identifier: String
        let vendorName: String?
        let productName: String?
    }

    private func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func sourceAvailableCapacity(available: Int64?, importantUsage: Int64?) -> Int64? {
        if let available, available > 0 {
            return available
        }
        if let importantUsage, importantUsage > 0 {
            return importantUsage
        }
        return available ?? importantUsage
    }
}
