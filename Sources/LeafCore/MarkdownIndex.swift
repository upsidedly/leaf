import Foundation

public struct MarkdownHeading: Identifiable, Hashable, Codable, Sendable {
    public let title: String
    public let level: Int
    public let anchor: String
    public let range: NSRange
    public let titleRange: NSRange
    public var id: String { "heading:\(range.location):\(anchor)" }
}

public enum MarkdownLinkKind: String, Codable, Sendable { case markdown, wiki, referenceDefinition, html }

public struct MarkdownLink: Identifiable, Hashable, Codable, Sendable {
    public let target: String
    public let label: String
    public let range: NSRange
    public let targetRange: NSRange
    public let isEmbed: Bool
    public let kind: MarkdownLinkKind
    public var id: String { "link:\(range.location):\(range.length)" }
}

public struct MarkdownCodeBlock: Identifiable, Hashable, Codable, Sendable {
    public let language: String
    public let source: String
    public let range: NSRange
    public let contentRange: NSRange
    public let isClosed: Bool
    public var id: String { "code:\(range.location)" }
}

public struct MarkdownBlockID: Identifiable, Hashable, Codable, Sendable {
    public let name: String
    public let range: NSRange
    public let contentRange: NSRange
    public var id: String { "block:\(range.location):\(name)" }
}

public enum MarkdownDiagnosticSeverity: String, Codable, Sendable { case warning, error }

public struct MarkdownDiagnostic: Identifiable, Hashable, Codable, Sendable {
    public let code: String
    public let message: String
    public let range: NSRange
    public let severity: MarkdownDiagnosticSeverity
    public var id: String { "\(code):\(range.location)" }

    public init(code: String, message: String, range: NSRange, severity: MarkdownDiagnosticSeverity = .warning) {
        self.code = code; self.message = message; self.range = range; self.severity = severity
    }
}

/// A read-only source index. All offsets use UTF-16, like NSTextView and NSRange.
/// Parsing never rewrites the document, including MDX that Leaf does not interpret.
public struct MarkdownIndex: Sendable {
    public let source: String
    public let headings: [MarkdownHeading]
    public let links: [MarkdownLink]
    public let codeBlocks: [MarkdownCodeBlock]
    public let blockIDs: [MarkdownBlockID]
    public let diagnostics: [MarkdownDiagnostic]

    public init(source: String) {
        self.source = source
        let text = source as NSString
        let lines = SourceLine.lines(in: text)
        var headings: [MarkdownHeading] = [], links: [MarkdownLink] = []
        var blocks: [MarkdownCodeBlock] = [], ids: [MarkdownBlockID] = []
        var diagnostics: [MarkdownDiagnostic] = []
        var excluded: [NSRange] = []
        var fence: (character: Character, count: Int, language: String, line: SourceLine)?
        var headingCounts: [String: Int] = [:]
        var usedAnchors: Set<String> = []
        var explicitAnchors: Set<String> = []
        var usedBlocks: Set<String> = []
        var frontMatter = false

        func addHeading(title: String, level: Int, range: NSRange, titleRange: NSRange) {
            var cleanTitle = title.trimmingCharacters(in: .whitespaces)
            var explicit: String?
            if let match = leafRegex(#"\s*\{#([^}\s]+)\}\s*$"#).firstMatch(in: cleanTitle, range: NSRange(location: 0, length: (cleanTitle as NSString).length)) {
                let t = cleanTitle as NSString
                explicit = t.substring(with: match.range(at: 1))
                cleanTitle = t.substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
            }
            let base = explicit ?? Self.anchor(for: cleanTitle)
            var anchor = base
            if explicit != nil {
                if !explicitAnchors.insert(base).inserted || usedAnchors.contains(base) {
                    diagnostics.append(.init(code: "duplicate-anchor", message: "The anchor ‘\(base)’ is used more than once.", range: range))
                }
            } else {
                var suffix = headingCounts[base, default: 0]
                while usedAnchors.contains(anchor) { suffix += 1; anchor = "\(base)-\(suffix)" }
                headingCounts[base] = suffix
            }
            usedAnchors.insert(anchor)
            headings.append(.init(title: cleanTitle, level: level, anchor: anchor, range: range, titleRange: titleRange))
        }

        for (i, line) in lines.enumerated() {
            let raw = text.substring(with: line.contentRange)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if i == 0 && (trimmed == "---" || trimmed == "\u{FEFF}---") {
                frontMatter = true; excluded.append(line.range); continue
            }
            if frontMatter {
                excluded.append(line.range)
                if trimmed == "---" || trimmed == "..." { frontMatter = false }
                continue
            }
            if let opening = fence {
                if let closing = Self.fence(in: raw), closing.character == opening.character,
                   closing.count >= opening.count, closing.info.isEmpty {
                    let content = NSRange(location: NSMaxRange(opening.line.range), length: line.range.location - NSMaxRange(opening.line.range))
                    let range = NSRange(location: opening.line.range.location, length: NSMaxRange(line.range) - opening.line.range.location)
                    blocks.append(.init(language: opening.language, source: text.substring(with: content), range: range, contentRange: content, isClosed: true))
                    excluded.append(range); fence = nil
                }
                continue
            }
            if let opening = Self.fence(in: raw) {
                fence = (opening.character, opening.count, opening.info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "", line)
                continue
            }
            if raw.hasPrefix("    ") || raw.hasPrefix("\t") { excluded.append(line.range); continue }
            if let match = leafRegex(#"^ {0,3}(#{1,6})[\t ]+(.*?)[\t ]*$"#).firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                var titleRange = shifted(match.range(at: 2), by: line.range.location)
                let title = text.substring(with: titleRange)
                if let closing = leafRegex(#"[\t ]+#+[\t ]*$"#).firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) { titleRange.length = closing.range.location }
                addHeading(title: text.substring(with: titleRange), level: match.range(at: 1).length, range: line.contentRange, titleRange: titleRange)
            } else if i > 0, let match = leafRegex(#"^ {0,3}(=+|-+)\s*$"#).firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                let previous = lines[i - 1]
                let title = text.substring(with: previous.contentRange).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty, !excluded.contains(where: { NSIntersectionRange($0, previous.range).length > 0 }),
                   !title.hasPrefix("#"), !title.hasPrefix(">"), !title.hasPrefix("- "), !title.hasPrefix("* ") {
                    let range = NSRange(location: previous.range.location, length: NSMaxRange(line.contentRange) - previous.range.location)
                    addHeading(title: title, level: (raw as NSString).substring(with: match.range(at: 1)).hasPrefix("=") ? 1 : 2, range: range, titleRange: previous.contentRange)
                }
            }
            if let match = leafRegex(#"(?:^|\s)\^([A-Za-z0-9_-]+)\s*$"#).firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                let name = (raw as NSString).substring(with: match.range(at: 1))
                let idRange = shifted(match.range(at: 1), by: line.range.location)
                var start = line.range.location
                var j = i - 1
                if trimmed.hasPrefix("^") {
                    while j >= 0 {
                        let candidate = text.substring(with: lines[j].contentRange).trimmingCharacters(in: .whitespaces)
                        if candidate.isEmpty || candidate.hasPrefix("#") { break }
                        start = lines[j].range.location; j -= 1
                    }
                } else {
                    while j >= 0 {
                        let candidate = text.substring(with: lines[j].contentRange).trimmingCharacters(in: .whitespaces)
                        if candidate.isEmpty || candidate.hasPrefix("#") || excluded.contains(where: { NSIntersectionRange($0, lines[j].range).length > 0 }) { break }
                        start = lines[j].range.location; j -= 1
                    }
                }
                let end = line.range.location + match.range.location
                ids.append(.init(name: name, range: idRange, contentRange: NSRange(location: start, length: max(0, end - start))))
                if !usedBlocks.insert(name).inserted { diagnostics.append(.init(code: "duplicate-block-id", message: "The block ID ‘\(name)’ is used more than once.", range: idRange)) }
            }
        }
        if let opening = fence {
            let content = NSRange(location: NSMaxRange(opening.line.range), length: text.length - NSMaxRange(opening.line.range))
            let range = NSRange(location: opening.line.range.location, length: text.length - opening.line.range.location)
            blocks.append(.init(language: opening.language, source: text.substring(with: content), range: range, contentRange: content, isClosed: false))
            excluded.append(range)
            diagnostics.append(.init(code: "unclosed-fence", message: "This code fence has no closing fence.", range: opening.line.contentRange, severity: .error))
        }
        if frontMatter { diagnostics.append(.init(code: "unclosed-front-matter", message: "The front matter has no closing delimiter.", range: lines.first?.range ?? NSRange(location: 0, length: 0))) }

        // Hide inline code and comments only for link discovery, not for source preservation.
        for match in leafRegex(#"<!--(?:[\s\S]*?)-->|(`+)[^`\r\n]*?\1"#).matches(in: source, range: NSRange(location: 0, length: text.length)) { excluded.append(match.range) }
        func isExcluded(_ range: NSRange) -> Bool { excluded.contains { NSIntersectionRange($0, range).length > 0 } }
        var claimed: [NSRange] = []
        for match in leafRegex(#"(!?)\[\[([^\]\r\n]+)\]\]"#).matches(in: source, range: NSRange(location: 0, length: text.length)) where !isExcluded(match.range) {
            let contents = text.substring(with: match.range(at: 2)) as NSString
            let pipe = contents.range(of: "|")
            let targetLength = pipe.location == NSNotFound ? contents.length : pipe.location
            let targetRange = NSRange(location: match.range(at: 2).location, length: targetLength)
            let target = text.substring(with: targetRange)
            let label = pipe.location == NSNotFound ? target : contents.substring(from: NSMaxRange(pipe))
            links.append(.init(target: target, label: label, range: match.range, targetRange: targetRange, isEmbed: match.range(at: 1).length > 0, kind: .wiki)); claimed.append(match.range)
        }
        // Definitions represent the editable destination of reference-style links.
        for line in lines where !isExcluded(line.range) {
            let raw = text.substring(with: line.contentRange)
            if let match = leafRegex(#"^ {0,3}\[([^\]\r\n]+)\]:\s*(?:<([^>]+)>|(\S+))"#).firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
                let chosen = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
                let destination = shifted(chosen, by: line.range.location)
                links.append(.init(target: text.substring(with: destination), label: (raw as NSString).substring(with: match.range(at: 1)), range: shifted(match.range, by: line.range.location), targetRange: destination, isEmbed: false, kind: .referenceDefinition)); claimed.append(line.range)
            }
        }
        var cursor = 0
        while cursor < text.length {
            let c = text.character(at: cursor)
            guard c == 91, (cursor == 0 || text.character(at: cursor - 1) != 92),
                  !isExcluded(NSRange(location: cursor, length: 1)), !claimed.contains(where: { NSLocationInRange(cursor, $0) }) else { cursor += 1; continue }
            let labelStart = cursor + 1
            var end = labelStart, depth = 1
            while end < text.length && depth > 0 {
                let ch = text.character(at: end)
                if ch == 92 { end += 2; continue }
                if ch == 91 { depth += 1 }; if ch == 93 { depth -= 1 }
                if depth > 0 { end += 1 }
            }
            guard depth == 0, end + 1 < text.length, text.character(at: end + 1) == 40 else { cursor += 1; continue }
            var p = end + 2
            while p < text.length && [9, 10, 13, 32].contains(Int(text.character(at: p))) { p += 1 }
            let angle = p < text.length && text.character(at: p) == 60
            if angle { p += 1 }
            let targetStart = p
            var parens = 0
            while p < text.length {
                let ch = text.character(at: p)
                if ch == 92 { p = min(text.length, p + 2); continue }
                if angle && ch == 62 { break }
                if !angle {
                    if ch == 40 { parens += 1 }
                    if ch == 41 { if parens == 0 { break }; parens -= 1 }
                    if [9, 10, 13, 32].contains(Int(ch)) && parens == 0 { break }
                }
                p += 1
            }
            let targetEnd = p
            if angle && p < text.length { p += 1 }
            // A title may follow the destination, but it must terminate on this paragraph.
            var quoted: UInt16?
            while p < text.length {
                let ch = text.character(at: p)
                if ch == 92 { p += 2; continue }
                if let q = quoted { if ch == q { quoted = nil } }
                else if ch == 34 || ch == 39 { quoted = ch }
                else if ch == 41 { break }
                else if ch == 10 || ch == 13 { break }
                p += 1
            }
            guard p < text.length, text.character(at: p) == 41, targetEnd >= targetStart else { cursor += 1; continue }
            let embed = cursor > 0 && text.character(at: cursor - 1) == 33
            let start = embed ? cursor - 1 : cursor
            let range = NSRange(location: start, length: p + 1 - start)
            let targetRange = NSRange(location: targetStart, length: targetEnd - targetStart)
            links.append(.init(target: text.substring(with: targetRange), label: text.substring(with: NSRange(location: labelStart, length: end - labelStart)), range: range, targetRange: targetRange, isEmbed: embed, kind: .markdown))
            claimed.append(range); cursor = p + 1
        }
        for match in leafRegex(#"(?i)<(?:img|a|video|audio|source)\b[^>]*?\b(?:src|href)\s*=\s*(["'])(.*?)\1[^>]*>"#).matches(in: source, range: NSRange(location: 0, length: text.length)) where !isExcluded(match.range) {
            let targetRange = match.range(at: 2)
            links.append(.init(target: text.substring(with: targetRange), label: "", range: match.range, targetRange: targetRange, isEmbed: !text.substring(with: match.range).lowercased().hasPrefix("<a"), kind: .html))
        }
        self.headings = headings.sorted { $0.range.location < $1.range.location }
        self.links = links.sorted { $0.range.location < $1.range.location }
        self.codeBlocks = blocks
        self.blockIDs = ids
        self.diagnostics = diagnostics.sorted { $0.range.location < $1.range.location }
    }

    public static func anchor(for heading: String) -> String {
        let stripped = heading.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        var result = ""
        for scalar in stripped.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { result.append("-") }
            else if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" { result.unicodeScalars.append(scalar) }
        }
        return result
    }

    public func heading(matching fragment: String) -> MarkdownHeading? {
        let fragment = fragment.removingPercentEncoding ?? fragment
        return headings.first { $0.anchor == fragment || $0.title.caseInsensitiveCompare(fragment) == .orderedSame || $0.anchor == Self.anchor(for: fragment) }
    }

    public func sectionRange(for heading: MarkdownHeading) -> NSRange {
        let next = headings.first { $0.range.location > heading.range.location && $0.level <= heading.level }
        return NSRange(location: heading.range.location, length: (next?.range.location ?? (source as NSString).length) - heading.range.location)
    }

    private static func fence(in line: String) -> (character: Character, count: Int, info: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let stripped = line.dropFirst(indent)
        guard let character = stripped.first, character == "`" || character == "~" else { return nil }
        let count = stripped.prefix(while: { $0 == character }).count
        guard count >= 3 else { return nil }
        let info = String(stripped.dropFirst(count)).trimmingCharacters(in: .whitespaces)
        guard character != "`" || !info.contains("`") else { return nil }
        return (character, count, info)
    }
}

struct SourceLine: Sendable {
    let range: NSRange
    let contentRange: NSRange
    static func lines(in text: NSString) -> [SourceLine] {
        var result: [SourceLine] = [], location = 0
        while location < text.length {
            var start = 0, end = 0, contentsEnd = 0
            text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            result.append(.init(range: NSRange(location: start, length: end - start), contentRange: NSRange(location: start, length: contentsEnd - start)))
            location = end
        }
        return result
    }
}

func leafRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // All callers supply compile-time expressions controlled by Leaf.
    do { return try NSRegularExpression(pattern: pattern, options: options) }
    catch { preconditionFailure("Invalid internal Markdown expression: \(error)") }
}

func shifted(_ range: NSRange, by offset: Int) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
