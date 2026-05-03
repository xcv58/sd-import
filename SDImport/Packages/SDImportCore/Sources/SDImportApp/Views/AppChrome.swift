import SwiftUI

struct AppPage<Content: View>: View {
    let title: String
    let status: String?
    var statusRole: StatusRole = .neutral
    let content: Content

    enum StatusRole {
        case neutral
        case error
    }

    init(
        title: String,
        status: String? = nil,
        statusRole: StatusRole = .neutral,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.status = status
        self.statusRole = statusRole
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                content
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title)
                .fontWeight(.semibold)

            if let status, !status.isEmpty {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(statusRole == .error ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
