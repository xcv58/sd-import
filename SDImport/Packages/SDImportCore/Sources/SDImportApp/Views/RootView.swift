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
                        .listRowInsets(EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 10))
                }
            }
            .listStyle(.sidebar)
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
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
    }
}
