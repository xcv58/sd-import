/// Keeps related display fields together when a changing app state is shown again.
public struct LivePresentation<Value> {
    public let value: Value
    private let render: @MainActor () -> Value

    @MainActor
    public init(_ render: @escaping @MainActor () -> Value) {
        self.value = render()
        self.render = render
    }

    @MainActor
    public func refreshed() -> LivePresentation<Value> {
        LivePresentation(render)
    }
}
