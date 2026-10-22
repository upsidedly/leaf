import Foundation

public struct CaretSettings: Codable, Sendable, Equatable {
    public var animated = true
    public var duration = 0.09
    public var trail = 0.45
    public var blur = 0.5
    public var width = 2.0
    public var shape = "bar"
    public var color = "accent"
    public var blink = true
    public init() {}
}

public struct LeafSettings: Codable, Sendable, Equatable {
    public var bodyFont = "System"
    public var headingFont = "System"
    public var codeFont = "System Mono"
    public var bodySize = 16.0
    public var codeSize = 13.0
    public var headingScale = 1.0
    public var interfaceSize = 12.0
    public var lineSpacing = 5.0
    public var paragraphSpacing = 0.55
    public var contentWidth = 720.0
    public var appearance = "system"
    public var accent = "system"
    public var colors: [String:String] = [:]
    public var diagramTheme = "auto"
    public var spellCheck = true
    public var autoCorrect = false
    public var smartLists = true
    public var showCounts = true
    public var focusMode = false
    public var typewriterMode = false
    public var autosaveDelay = 2.0
    public var exportProfile = "document"
    public var exportTOC = false
    public var pageSize = "A4"
    public var pageMargin = 54.0
    public var caret = CaretSettings()
    public var shortcuts: [String: String] = ["palette": "@k", "quickOpen": "@p", "diagram": "@~d", "focus": "@~f", "source": "@~s"]
    public init() {}

    public func validated() -> LeafSettings {
        var result = self
        result.bodySize = min(36, max(10, bodySize))
        result.codeSize = min(30, max(8, codeSize))
        result.headingScale = min(2, max(0.65, headingScale))
        result.contentWidth = min(1600, max(360, contentWidth))
        result.lineSpacing = min(24, max(0, lineSpacing))
        result.paragraphSpacing = min(2, max(0, paragraphSpacing))
        result.interfaceSize = min(18, max(10, interfaceSize))
        result.caret.duration = min(0.5, max(0.025, caret.duration))
        result.caret.trail = min(1, max(0, caret.trail))
        result.caret.blur = min(1, max(0, caret.blur))
        result.caret.width = min(8, max(1, caret.width))
        result.autosaveDelay = min(60, max(1, autosaveDelay))
        result.pageMargin = min(144, max(18, pageMargin))
        result.colors = colors.filter { _,value in
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            return hex.count == 6 && UInt32(hex,radix:16) != nil
        }
        return result
    }

    public static func load(from url: URL) throws -> LeafSettings {
        try JSONDecoder().decode(LeafSettings.self, from: Data(contentsOf: url)).validated()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(validated()).write(to: url, options: .atomic)
    }

    /// Missing keys in a portable settings file retain sensible defaults.
    public static func merged(_ data: Data, over base: LeafSettings = .init()) throws -> LeafSettings {
        let encoder = JSONEncoder()
        guard var defaults = try JSONSerialization.jsonObject(with: encoder.encode(base)) as? [String: Any],
              let overrides = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        for (key, value) in overrides {
            if let nested = value as? [String: Any], var existing = defaults[key] as? [String: Any] {
                existing.merge(nested) { _, new in new }; defaults[key] = existing
            } else { defaults[key] = value }
        }
        return try JSONDecoder().decode(LeafSettings.self, from: JSONSerialization.data(withJSONObject: defaults)).validated()
    }
}
