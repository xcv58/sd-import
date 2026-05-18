import SDImportCore
import SwiftUI

struct ShootNameField: View {
    @EnvironmentObject private var model: AppModel

    @Binding var name: String
    var width: CGFloat = 260
    var showsQuickPicks = true

    private var suggestions: [RecentShootNameChoice] {
        model.recentShootNameSuggestions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Shoot name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: width)
                    .onSubmit {
                        model.savePreferences()
                    }

                Menu {
                    if suggestions.isEmpty {
                        Text("No recent shoot names")
                    } else {
                        ForEach(suggestions) { suggestion in
                            Button {
                                name = suggestion.name
                                model.savePreferences()
                            } label: {
                                Text(menuTitle(for: suggestion))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Choose recent shoot name")
                .accessibilityLabel("Choose recent shoot name")
            }

            if showsQuickPicks, !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions.prefix(3)) { suggestion in
                        Button {
                            name = suggestion.name
                            model.savePreferences()
                        } label: {
                            Text(suggestion.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: 108)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                        .help(menuTitle(for: suggestion))
                    }
                }
                .font(.caption)
            }
        }
    }

    private func menuTitle(for suggestion: RecentShootNameChoice) -> String {
        let usage = suggestion.useCount == 1 ? "used once" : "used \(suggestion.useCount) times"
        return "\(suggestion.name) · \(usage)"
    }
}
