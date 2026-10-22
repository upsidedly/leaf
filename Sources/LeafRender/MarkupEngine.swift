import Foundation

/// Produces static HTML. The preview must keep document JavaScript disabled.
public actor MarkupEngine {
    private var runtime: EngineRuntime?
    private var mathCSS: String?
    public init() {}

    public func html(_ source: String, options: RenderOptions = .init()) throws -> String {
        try validate(source)
        let engine = try engine()
        if mathCSS == nil { mathCSS = try EngineRuntime.css() }
        let value = try engine.call("document", arguments: [source, options.values, mathCSS ?? ""])
        try Task.checkCancellation()
        guard let html = value["html"] as? String else { throw RenderError.invalidResult("missing HTML document") }
        return html
    }

    public func fragment(_ source: String) throws -> String {
        try validate(source)
        let value = try engine().call("fragment", arguments: [source])
        try Task.checkCancellation()
        guard let html = value["html"] as? String else { throw RenderError.invalidResult("missing HTML fragment") }
        return html
    }

    private func validate(_ source: String) throws {
        try Task.checkCancellation()
        guard source.utf16.count <= 2_000_000 else { throw RenderError.sourceTooLarge(limit: 2_000_000) }
    }

    private func engine() throws -> EngineRuntime {
        if let runtime { return runtime }
        let value = try EngineRuntime()
        runtime = value
        return value
    }
}
