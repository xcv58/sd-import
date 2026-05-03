import SDImportCore
import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var model: AppModel

    private var canComplete: Bool {
        sourceIsReadyForSetup
            && model.photosValidation.isUsable
            && model.videosValidation.isUsable
    }

    private var sourceIsReadyForSetup: Bool {
        model.sourceValidation.isUsable || model.sourceValidation.status == .placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Up SD Import")
                .font(.title2)
                .fontWeight(.semibold)

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
                    action: model.choosePhotosFolder
                )
                OnboardingFolderRow(
                    title: "Videos",
                    path: $model.videosPath,
                    validation: model.videosValidation,
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
        .frame(width: 520)
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

private struct OnboardingFolderRow: View {
    let title: String
    @Binding var path: String
    let validation: PathValidationResult
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

            Label(validation.message, systemImage: validation.isUsable ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(validation.isUsable ? Color.secondary : Color.orange)
                .padding(.leading, 108)
        }
    }
}
