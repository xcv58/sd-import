import SDImportCore
import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var model: AppModel

    private var canComplete: Bool {
        sourceIsReadyForSetup
    }

    private var sourceIsReadyForSetup: Bool {
        model.sourceValidation.isUsable || model.sourceValidation.status == .placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set Up SD Import")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Choose where cards are scanned and where copied media should land. SD Import previews everything before copying.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                OnboardingGuideItem(
                    title: "Source",
                    systemImage: "externaldrive",
                    text: "Start with /Volumes or pick a specific mounted card or source folder."
                )
                OnboardingGuideItem(
                    title: "Destinations",
                    systemImage: "folder",
                    text: "Photos and videos can use different folders. The preview shows exact destination folders before copying."
                )
                OnboardingGuideItem(
                    title: "Known files",
                    systemImage: "checkmark.seal",
                    text: "Files already imported are shown as known or skipped so reinserting a card does not duplicate originals."
                )
                OnboardingGuideItem(
                    title: "Sidecars",
                    systemImage: "paperclip",
                    text: "Camera support files stay skipped for photo imports, and can be kept for footage backups when needed."
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                OnboardingFolderRow(
                    title: "Card or source",
                    path: $model.cardPath,
                    validation: model.sourceValidation,
                    action: model.chooseCardFolder
                )
                OnboardingFolderRow(
                    title: "Photos",
                    path: $model.photosPath,
                    validation: model.photosValidation,
                    isRequired: false,
                    action: model.choosePhotosFolder
                )
                OnboardingFolderRow(
                    title: "Videos",
                    path: $model.videosPath,
                    validation: model.videosValidation,
                    isRequired: false,
                    action: model.chooseVideosFolder
                )
                TextField("Shoot name", text: $model.location)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                Toggle("Prompt on card mount", isOn: $model.autoPromptEnabled)
            }

            HStack {
                Spacer()
                Button {
                    model.completeOnboarding()
                } label: {
                    Text("Done")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canComplete)
            }
        }
        .padding(24)
        .frame(width: 660)
        .interactiveDismissDisabled(true)
        .onAppear {
            model.validatePaths()
        }
        .onChange(of: model.cardPath) {
            model.sourcePathDidChange()
        }
        .onChange(of: model.photosPath) {
            model.validatePaths()
        }
        .onChange(of: model.videosPath) {
            model.validatePaths()
        }
    }
}

private struct OnboardingGuideItem: View {
    let title: String
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OnboardingFolderRow: View {
    let title: String
    @Binding var path: String
    let validation: PathValidationResult
    var isRequired = true
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 100, alignment: .leading)

                TextField(title, text: $path)
                    .textFieldStyle(.roundedBorder)

                Button {
                    action()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Choose \(title.lowercased())")
                .accessibilityLabel("Choose \(title.lowercased())")
            }

            Label(statusMessage, systemImage: statusImage)
                .font(.caption)
                .foregroundStyle(statusColor)
                .padding(.leading, 108)
        }
    }

    private var statusMessage: String {
        guard !isRequired, !validation.isUsable else {
            return validation.message
        }

        switch validation.status {
        case .empty:
            return "Optional: choose before copying \(title.lowercased())"
        case .missing:
            return "Optional: set this folder later"
        default:
            return validation.message
        }
    }

    private var statusImage: String {
        validation.isUsable ? "checkmark.circle" : (isSoftOptionalWarning ? "info.circle" : "exclamationmark.triangle")
    }

    private var statusColor: Color {
        validation.isUsable || isSoftOptionalWarning ? Color.secondary : Color.orange
    }

    private var isSoftOptionalWarning: Bool {
        guard !isRequired else {
            return false
        }
        return validation.status == .empty || validation.status == .missing
    }
}
