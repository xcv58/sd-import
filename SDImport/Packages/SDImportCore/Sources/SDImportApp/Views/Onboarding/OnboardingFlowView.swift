import SwiftUI

struct OnboardingFlowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Up SD Import")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                OnboardingFolderRow(
                    title: "Card or source",
                    path: $model.cardPath,
                    action: model.chooseCardFolder
                )
                OnboardingFolderRow(
                    title: "Photos",
                    path: $model.photosPath,
                    action: model.choosePhotosFolder
                )
                OnboardingFolderRow(
                    title: "Videos",
                    path: $model.videosPath,
                    action: model.chooseVideosFolder
                )
                TextField("Location", text: $model.location)
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
                .disabled(model.photosPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.videosPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(true)
    }
}

private struct OnboardingFolderRow: View {
    let title: String
    @Binding var path: String
    let action: () -> Void

    var body: some View {
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
        }
    }
}
