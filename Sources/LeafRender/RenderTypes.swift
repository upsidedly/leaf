import Foundation

public struct DiagramResult: Sendable, Equatable {
    public let svg: String
    public let width: Double
    public let height: Double
    public let type: String

    public init(svg: String, width: Double, height: Double, type: String) {
        self.svg = svg
        self.width = width
        self.height = height
        self.type = type
    }
}

public struct RenderOptions: Sendable, Equatable {
    public var title: String
    public var bodyFont: String
    public var codeFont: String
    public var fontSize: Double
    public var lineHeight: Double
    public var contentWidth: Double
    public var dark: Bool
    public var includeTOC: Bool

    public init(
        title: String = "Untitled", bodyFont: String = "system-ui", codeFont: String = "ui-monospace",
        fontSize: Double = 16, lineHeight: Double = 1.65, contentWidth: Double = 760,
        dark: Bool = false, includeTOC: Bool = false
    ) {
        self.title = title
        self.bodyFont = bodyFont
        self.codeFont = codeFont
        self.fontSize = fontSize
        self.lineHeight = lineHeight
        self.contentWidth = contentWidth
        self.dark = dark
        self.includeTOC = includeTOC
    }

    var values: [String: Any] {
        ["title": title, "bodyFont": bodyFont, "codeFont": codeFont, "fontSize": fontSize,
         "lineHeight": lineHeight, "contentWidth": contentWidth, "dark": dark, "includeTOC": includeTOC]
    }
}

public enum RenderError: Error, LocalizedError, Sendable, Equatable {
    case resourceMissing(String)
    case invalidResult(String)
    case sourceTooLarge(limit: Int)
    case rendering(message: String, code: String, line: Int, column: Int)

    public var errorDescription: String? {
        switch self {
        case .resourceMissing(let name): "The bundled renderer could not be loaded (\(name))."
        case .invalidResult(let message): "The renderer returned an invalid result: \(message)."
        case .sourceTooLarge(let limit): "This source exceeds the \(limit.formatted()) character rendering limit."
        case let .rendering(message, _, line, column):
            line > 0 ? "Line \(line), column \(max(column, 1)): \(message)" : message
        }
    }
}
