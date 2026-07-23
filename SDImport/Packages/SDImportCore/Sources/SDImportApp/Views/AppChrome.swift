import SwiftUI

struct AppPage<Content: View>: View {
    let status: String?
    var statusRole: StatusRole = .neutral
    var scrolls = true
    var maxContentWidth: CGFloat = 1120
    let content: Content

    enum StatusRole {
        case neutral
        case error
    }

    init(
        status: String? = nil,
        statusRole: StatusRole = .neutral,
        scrolls: Bool = true,
        maxContentWidth: CGFloat = 1120,
        @ViewBuilder content: () -> Content
    ) {
        self.status = status
        self.statusRole = statusRole
        self.scrolls = scrolls
        self.maxContentWidth = maxContentWidth
        self.content = content()
    }

    var body: some View {
        Group {
            if scrolls {
                ScrollView {
                    pageContent
                }
            } else {
                pageContent
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let status, !status.isEmpty {
                statusBanner(status)
            }

            if scrolls {
                content
            } else {
                content
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(24)
        .frame(maxWidth: maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private func statusBanner(_ status: String) -> some View {
        Label(
            status,
            systemImage: statusRole == .error ? "exclamationmark.triangle.fill" : "info.circle"
        )
        .font(.callout)
        .foregroundStyle(statusRole == .error ? Color.red : Color.secondary)
        .lineLimit(2)
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (statusRole == .error ? Color.red : Color.accentColor).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    (statusRole == .error ? Color.red : Color.accentColor).opacity(0.22),
                    lineWidth: 1
                )
        }
    }
}

struct AppSection<Content: View>: View {
    let title: String
    let systemImage: String
    let subtitle: String?
    let content: Content

    init(
        _ title: String,
        systemImage: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            content
        }
        .padding(16)
        .appCardSurface()
    }
}

private struct AppCardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let fillOpacity = colorScheme == .dark ? 0.055 : 0.032
        let strokeOpacity = colorScheme == .dark ? 0.18 : 0.09

        content
            .background(Color.primary.opacity(fillOpacity), in: shape)
            .overlay {
                shape.stroke(Color.primary.opacity(strokeOpacity), lineWidth: 1)
            }
    }
}

extension View {
    func appCardSurface(cornerRadius: CGFloat = 8) -> some View {
        modifier(AppCardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

struct InfoPill: View {
    let title: String
    let systemImage: String
    var role: Role = .neutral

    enum Role {
        case neutral
        case success
        case warning
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundStyle, in: Capsule())
            .foregroundStyle(foregroundStyle)
    }

    private var foregroundStyle: Color {
        switch role {
        case .neutral:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        }
    }

    private var backgroundStyle: Color {
        switch role {
        case .neutral:
            return Color.secondary.opacity(0.10)
        case .success:
            return Color.green.opacity(0.12)
        case .warning:
            return Color.orange.opacity(0.12)
        }
    }
}
