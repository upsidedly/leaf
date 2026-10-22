import Foundation
import JavaScriptCore

/// Confined to its owning actor. Document text is passed as a value, never as executable code.
final class EngineRuntime {
    private let context: JSContext
    private let entry: JSValue

    private static var resources: Bundle {
        // SwiftPM's generated accessor checks the executable bundle root. A
        // sealed macOS app keeps resource bundles in Contents/Resources.
        if let url = Bundle.main.url(forResource: "Leaf_LeafRender", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    init() throws {
        guard let context = JSContext() else { throw RenderError.invalidResult("JavaScriptCore is unavailable") }
        self.context = context
        guard let sourceURL = Self.resources.url(forResource: "leaf-engines", withExtension: "js") else {
            throw RenderError.resourceMissing("leaf-engines.js")
        }
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        context.evaluateScript(source, withSourceURL: sourceURL)
        if let exception = context.exception {
            throw RenderError.rendering(message: exception.toString() ?? "Renderer initialization failed.", code: "initialization", line: 0, column: 0)
        }
        guard let entry = context.objectForKeyedSubscript("LeafEngines"), !entry.isUndefined else {
            throw RenderError.invalidResult("missing renderer entry point")
        }
        self.entry = entry
    }

    func call(_ method: String, arguments: [Any]) throws -> [String: Any] {
        context.exception = nil
        guard let function = entry.objectForKeyedSubscript(method), !function.isUndefined,
              let result = function.call(withArguments: arguments) else {
            throw RenderError.invalidResult("missing \(method) result")
        }
        if let exception = context.exception {
            throw RenderError.rendering(message: exception.toString() ?? "The renderer failed.", code: "runtime", line: 0, column: 0)
        }
        guard let value = result.toDictionary() as? [String: Any] else {
            throw RenderError.invalidResult("\(method) did not return an object")
        }
        if let error = value["error"] as? [String: Any] {
            throw RenderError.rendering(
                message: error["message"] as? String ?? "The source could not be rendered.",
                code: error["code"] as? String ?? "rendering",
                line: (error["line"] as? NSNumber)?.intValue ?? 0,
                column: (error["column"] as? NSNumber)?.intValue ?? 0
            )
        }
        return value
    }

    static func css() throws -> String {
        guard let url = Self.resources.url(forResource: "leaf-math", withExtension: "css") else {
            throw RenderError.resourceMissing("leaf-math.css")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
