import SDImportCore
import SwiftUI

struct MountPromptView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    let promptID: UUID

    var body: some View {
        let _ = locale
        if let prompt = model.pendingMountPrompt, prompt.id == promptID,
           let firstVolume = prompt.deviceGroup.volumes.first {
            let group = prompt.deviceGroup
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    if group.isMultiVolume {
                        Text(group.displayName).font(.headline)
                    } else {
                        volumeLabel(firstVolume)
                    }
                }

                Text(promptMessage(volumeCount: group.volumes.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if group.isMultiVolume {
                    ForEach(group.volumes, id: \.mountPath) { volume in
                        Button {
                            model.acceptMountedVolumePrompt(volume, from: prompt)
                        } label: {
                            HStack {
                                volumeLabel(volume)
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(L10n.tr("Scan \(volume.name)"))
                        .accessibilityValue(volume.mountURL.path)
                        .accessibilityIdentifier("import.mount-prompt.volume.\(volume.mountPath)")
                    }
                }

                HStack {
                    Spacer()
                    Button(skipButtonTitle) {
                        model.skipMountedVolumePrompt(promptID)
                    }
                    .accessibilityIdentifier("import.mount-prompt.decline")
                    if group.volumes.count == 2 {
                        Button(L10n.tr("Scan Both")) {
                            model.acceptScanBoth(prompt)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("import.mount-prompt.both")
                    } else if !group.isMultiVolume {
                        Button(scanButtonTitle(firstVolume)) {
                            model.acceptMountedVolumePrompt(firstVolume, from: prompt)
                        }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("import.mount-prompt.allow")
                    }
                }
            }
            .padding(22)
            .frame(width: 420)
        }
    }

    private func volumeLabel(_ volume: MountedVolume) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(volume.name).font(.headline)
            Text(volume.mountURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func promptMessage(volumeCount: Int) -> String {
        if volumeCount == 2 {
            return L10n.tr("Choose one or both storage volumes to scan.")
        }
        if volumeCount > 1 {
            return L10n.tr("Choose a storage volume to scan and preview what would be copied.")
        }
        if AppDistribution.current == .macAppStore {
            return L10n.tr("\(AppDistribution.current.displayName) detected this removable volume but has not scanned its contents. Allow a scan now to preview what would be copied?")
        }
        return L10n.tr("Scan this volume to preview what would be copied.")
    }

    private var skipButtonTitle: String {
        AppDistribution.current == .macAppStore ? L10n.tr("Don't Scan") : L10n.tr("Skip")
    }

    private func scanButtonTitle(_ volume: MountedVolume) -> String {
        AppDistribution.current == .macAppStore ? L10n.tr("Allow Scan") : L10n.tr("Scan \(volume.name)")
    }
}
