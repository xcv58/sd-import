import Sparkle
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    let updater: SPUUpdater?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    ForEach(SidebarItem.allCases) { item in
                        SidebarRow(item: item)
                            .tag(item)
                            .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 10))
                            .help("\(item.title), \(item.shortcutHint)")
                    }
                }
                .listStyle(.sidebar)

                SidebarShortcutFooter()
            }
            .safeAreaPadding(.leading, 8)
            .frame(minWidth: 220, idealWidth: 220, maxWidth: 240)
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 240)
        } detail: {
            switch model.selection {
            case .import:
                ManualImportView()
            case .history:
                HistoryView()
            case .settings:
                SettingsView(updater: updater)
            case .diagnostics:
                DiagnosticsView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: onboardingBinding) {
            OnboardingFlowView()
                .environmentObject(model)
        }
        .sheet(item: $model.pendingMountedVolume) { volume in
            MountPromptView(
                volume: volume,
                continueAction: model.acceptMountedVolumePrompt,
                skipAction: model.skipMountedVolumePrompt
            )
        }
    }

    private var onboardingBinding: Binding<Bool> {
        Binding {
            !model.hasCompletedOnboarding
        } set: { isPresented in
            if !isPresented, !model.hasCompletedOnboarding {
                model.completeOnboarding()
            }
        }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(item.shortcutHint)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }
}

private struct SidebarShortcutFooter: View {
    var body: some View {
        HStack(spacing: 8) {
            ShortcutHint(text: "Ctrl Tab")
            Text("Next")
                .lineLimit(1)
            Spacer(minLength: 0)
            ShortcutHint(text: "Cmd Opt S")
            Text("Sidebar")
                .lineLimit(1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Control Tab next panel. Command Option S toggles the sidebar.")
    }
}

private struct ShortcutHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospaced())
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}
