import SDImportCore
import SwiftUI

struct MountPromptView: View {
    let volume: MountedVolume
    let deviceGroup: MountedDeviceGroup
    let continueAction: () -> Void
    let skipAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(deviceGroup.isMultiVolume ? deviceGroup.displayName : volume.name)
                        .font(.headline)
                    Text("\(volume.name) · \(volume.mountURL.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text(promptMessage)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(skipButtonTitle) {
                    skipAction()
                }
                .accessibilityIdentifier("import.mount-prompt.decline")
                Button(scanButtonTitle) {
                    continueAction()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("import.mount-prompt.allow")
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    private var promptMessage: String {
        if AppDistribution.current == .macAppStore {
            if deviceGroup.isMultiVolume {
                let names = ListFormatter.localizedString(byJoining: deviceGroup.volumes.map(\.name))
                return "\(AppDistribution.current.displayName) detected \(deviceGroup.displayName), with \(deviceGroup.volumes.count) storage volumes: \(names). It has not scanned their contents. Allow a scan of \(volume.name)?"
            }
            return "\(AppDistribution.current.displayName) detected this removable volume but has not scanned its contents. Allow a scan now to preview what would be copied?"
        }
        if deviceGroup.isMultiVolume {
            let names = ListFormatter.localizedString(byJoining: deviceGroup.volumes.map(\.name))
            return "\(deviceGroup.displayName) exposes \(deviceGroup.volumes.count) storage volumes: \(names). Scan \(volume.name) now; the source menu keeps all volumes available."
        }
        return "\(AppDistribution.current.displayName) found supported media on this volume. Scan it now to preview what will be copied."
    }

    private var skipButtonTitle: String {
        AppDistribution.current == .macAppStore ? "Don't Scan" : "Skip"
    }

    private var scanButtonTitle: String {
        AppDistribution.current == .macAppStore ? "Allow Scan" : "Scan \(volume.name)"
    }
}
