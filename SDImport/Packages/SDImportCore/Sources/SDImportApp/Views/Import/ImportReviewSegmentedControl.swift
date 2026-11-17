import AppKit
import SwiftUI

/// Keeps selection in SwiftUI while the review scroll view measures and prefetches its children.
struct ImportReviewSegmentedControl<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [Value]
    var optionTitle: (Value) -> String
    var isOptionEnabled: (Value) -> Bool = { _ in true }
    var systemImage: ((Value) -> String)? = nil

    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var focusedOption: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(for: option)
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .onMoveCommand(perform: moveSelection)
    }

    private func segment(for option: Value) -> some View {
        let isSelected = selection == option
        let enabled = isOptionEnabled(option)

        return Button {
            select(option)
        } label: {
            Group {
                if let systemImage {
                    Image(systemName: systemImage(option))
                } else {
                    Text(optionTitle(option))
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .selectedContentBackgroundColor))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedOption, equals: option)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityLabel(Text(optionTitle(option)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func select(_ option: Value) {
        if selection != option {
            selection = option
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let enabledOptions = options.filter(isOptionEnabled)
        guard let focusedOption, let index = enabledOptions.firstIndex(of: focusedOption) else { return }

        let offset: Int
        switch direction {
        case .left:
            offset = layoutDirection == .rightToLeft ? 1 : -1
        case .right:
            offset = layoutDirection == .rightToLeft ? -1 : 1
        default:
            return
        }

        let nextIndex = index + offset
        guard enabledOptions.indices.contains(nextIndex) else { return }
        let nextOption = enabledOptions[nextIndex]
        select(nextOption)
        self.focusedOption = nextOption
    }
}
