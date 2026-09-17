import Foundation

/// Retains how an in-memory message was rendered so it can outlive other status text.
public struct RelocalizableMessage {
    public let text: String
    private let render: (() -> String)?

    public init(_ text: String, render: (() -> String)? = nil) {
        self.text = text
        self.render = render
    }

    public func relocalized(from previous: AppLanguage, to selected: AppLanguage) -> RelocalizableMessage {
        RelocalizableMessage(
            render?() ?? L10n.relocalizedStaticMessage(text, from: previous, to: selected),
            render: render
        )
    }
}
