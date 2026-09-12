import SDImportCore
import SwiftUI

struct ShootNameField: View {
    @EnvironmentObject private var model: AppModel

    @Binding var name: String
    var showsQuickPicks = true

    private var suggestions: [RecentShootNameChoice] {
        model.recentShootNameSuggestions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(L10n.tr("Shoot name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(
                        minWidth: ImportFormLayout.minimumControlWidth,
                        maxWidth: .infinity
                    )
                    .onSubmit {
                        model.savePreferences()
                    }

                Menu {
                    if suggestions.isEmpty {
                        Text(L10n.tr("No recent shoot names"))
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
                .help(L10n.tr("Choose recent shoot name"))
                .accessibilityLabel(L10n.tr("Choose recent shoot name"))
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func menuTitle(for suggestion: RecentShootNameChoice) -> String {
        let usage = suggestion.useCount == 1 ? L10n.tr("used once") : L10n.tr("used \(suggestion.useCount) times")
        return "\(suggestion.name) · \(usage)"
    }
}
