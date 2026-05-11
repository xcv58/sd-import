import Sparkle
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    let updater: SPUUpdater?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $model.selection) {
                ForEach(SidebarItem.allCases) { item in
                    SidebarRow(item: item)
                        .tag(item)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                        .help("\(item.title), \(item.shortcutHint)")
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 184, idealWidth: 196, maxWidth: 220)
            .navigationSplitViewColumnWidth(min: 184, ideal: 196, max: 220)
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
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(item.title)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
    }
}
