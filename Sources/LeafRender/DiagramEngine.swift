import Foundation

/// Offline Mermaid parsing and layout. SVG can be drawn directly by AppKit's NSImage.
public actor DiagramEngine {
    private var runtime: EngineRuntime?
    public init() {}

    public func render(_ source: String, theme: String = "light") throws -> DiagramResult {
        try Task.checkCancellation()
        guard source.utf16.count <= 50_000 else { throw RenderError.sourceTooLarge(limit: 50_000) }
        let engine: EngineRuntime
        if let runtime { engine = runtime } else {
            engine = try EngineRuntime()
            runtime = engine
        }
        let value = try engine.call("diagram", arguments: [source, theme])
        try Task.checkCancellation()
        guard let svg = value["svg"] as? String,
              let width = (value["width"] as? NSNumber)?.doubleValue,
              let height = (value["height"] as? NSNumber)?.doubleValue,
              let type = value["type"] as? String,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 100_000, height <= 100_000 else {
            throw RenderError.invalidResult("invalid diagram dimensions or unresolved theme")
        }
        return DiagramResult(svg: svg, width: width, height: height, type: type)
    }
}
