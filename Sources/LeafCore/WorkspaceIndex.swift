import Foundation

public enum WorkspaceError: LocalizedError, Sendable {
    case invalidRoot, outsideWorkspace(String), invalidUTF8(String), missingFile(String), ambiguousTarget(String)
    case invalidExpression(String), searchTimedOut, tooManyMatches, conflict(String), invalidChange(String)
    case missingHeading(String), fileExists(String), transclusionCycle([String]), transclusionDepth, transclusionTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidRoot: return "Choose a readable folder for this workspace."
        case .outsideWorkspace(let path): return "‘\(path)’ is outside this workspace."
        case .invalidUTF8(let path): return "‘\(path)’ is not a UTF-8 text file."
        case .missingFile(let path): return "‘\(path)’ could not be found."
        case .ambiguousTarget(let target): return "More than one note matches ‘\(target)’. Use its relative path."
        case .invalidExpression(let message): return "The regular expression is invalid: \(message)"
        case .searchTimedOut: return "This search took too long. Use a more specific expression."
        case .tooManyMatches: return "There are too many matches. Narrow the search before replacing."
        case .conflict(let path): return "‘\(path)’ changed after the preview. Review a fresh preview before applying."
        case .invalidChange(let message): return message
        case .missingHeading(let anchor): return "The heading or block ‘\(anchor)’ could not be found."
        case .fileExists(let path): return "‘\(path)’ already exists."
        case .transclusionCycle(let paths): return "Embed cycle: " + paths.joined(separator: " → ")
        case .transclusionDepth: return "This embed exceeds the maximum nesting depth."
        case .transclusionTooLarge: return "The expanded embeds exceed the document size limit."
        }
    }
}

public struct WorkspaceDocument: Identifiable, Sendable {
    public let url: URL
    public let relativePath: String
    public let data: Data
    public let source: String
    public let index: MarkdownIndex
    public var id: String { relativePath }
    public var title: String { index.headings.first?.title ?? url.deletingPathExtension().lastPathComponent }
}

public struct WorkspaceIssue: Identifiable, Sendable {
    public let url: URL
    public let relativePath: String
    public let diagnostic: MarkdownDiagnostic
    public var id: String { "\(relativePath):\(diagnostic.id)" }
}

public struct ResolvedWorkspaceLink: Hashable, Sendable {
    public let url: URL
    public let relativePath: String
    public let fragment: String?
    public let isDocument: Bool
}

public struct WorkspaceBacklink: Identifiable, Sendable {
    public let sourceURL: URL
    public let relativePath: String
    public let link: MarkdownLink
    public var id: String { "\(relativePath):\(link.id)" }
}

public struct WorkspaceSearchMatch: Identifiable, Sendable {
    public let url: URL
    public let relativePath: String
    public let range: NSRange
    public let line: Int
    public let column: Int
    public let lineText: String
    public let matchedText: String
    public var id: String { "\(relativePath):\(range.location):\(range.length)" }
}

/// A stable, read-only snapshot. Construct a fresh index after filesystem changes.
public struct WorkspaceIndex: Sendable {
    public let root: URL
    public let documents: [WorkspaceDocument]
    public let scanIssues: [WorkspaceIssue]
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "mdwn", "mmd", "mdtxt", "mdtext"]

    public init(root: URL) throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else { throw WorkspaceError.invalidRoot }
        self.root = root
        var documents: [WorkspaceDocument] = [], issues: [WorkspaceIssue] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { throw WorkspaceError.invalidRoot }
        let excludedDirectories: Set<String> = [".git", ".leaf", ".build", "node_modules", ".Trash", ".svn", ".hg"]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values?.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, Self.markdownExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = Self.relativePath(of: url, root: root)
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard let source = String(data: data, encoding: .utf8) else { throw WorkspaceError.invalidUTF8(path) }
                documents.append(.init(url: url.standardizedFileURL, relativePath: path, data: data, source: source, index: MarkdownIndex(source: source)))
            } catch {
                issues.append(.init(url: url, relativePath: path, diagnostic: .init(code: "unreadable-file", message: error.localizedDescription, range: NSRange(location: 0, length: 0), severity: .error)))
            }
        }
        self.documents = documents.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        self.scanIssues = issues.sorted { $0.relativePath < $1.relativePath }
    }

    public func document(at url: URL) -> WorkspaceDocument? { documents.first { $0.url.standardizedFileURL == url.standardizedFileURL } }

    public func document(path: String) -> WorkspaceDocument? { documents.first { $0.relativePath == path } }

    public func resolve(_ target: String, from sourceURL: URL) -> ResolvedWorkspaceLink? {
        try? resolveChecked(target, from: sourceURL)
    }

    public func resolveChecked(_ target: String, from sourceURL: URL) throws -> ResolvedWorkspaceLink {
        let parts = Self.targetParts(target)
        if Self.isExternalTarget(parts.path) { throw WorkspaceError.outsideWorkspace(target) }
        if parts.path.isEmpty {
            guard let document = document(at: sourceURL) else { throw WorkspaceError.missingFile(sourceURL.lastPathComponent) }
            return .init(url: document.url, relativePath: document.relativePath, fragment: parts.fragment, isDocument: true)
        }
        let path = parts.path.removingPercentEncoding ?? parts.path
        let base = path.hasPrefix("/") ? root : sourceURL.deletingLastPathComponent()
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let direct = base.appendingPathComponent(relative).standardizedFileURL
        guard Self.isInside(direct, root: root) else { throw WorkspaceError.outsideWorkspace(path) }
        let extensions = [""] + Self.markdownExtensions.sorted().map { "." + $0 }
        var candidates: [URL] = []
        for suffix in extensions {
            let url = URL(fileURLWithPath: direct.path + suffix).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path), Self.isInside(url.resolvingSymlinksInPath(), root: root) {
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                if !isDirectory.boolValue { candidates.append(url) }
            }
            if !candidates.isEmpty { break }
        }
        if candidates.isEmpty {
            // Wiki links often name a note without repeating its enclosing folder.
            let requested = path.lowercased()
            let requestedWithoutExtension = (path as NSString).deletingPathExtension.lowercased()
            candidates = documents.filter {
                $0.relativePath.lowercased() == requested || ($0.relativePath as NSString).deletingPathExtension.lowercased() == requested ||
                (!path.contains("/") && ($0.url.lastPathComponent.lowercased() == requested || $0.url.deletingPathExtension().lastPathComponent.lowercased() == requestedWithoutExtension))
            }.map(\.url)
        }
        guard candidates.count <= 1 else { throw WorkspaceError.ambiguousTarget(target) }
        guard let url = candidates.first else { throw WorkspaceError.missingFile(path) }
        return .init(url: url, relativePath: Self.relativePath(of: url, root: root), fragment: parts.fragment, isDocument: Self.markdownExtensions.contains(url.pathExtension.lowercased()))
    }

    public func backlinks(to targetURL: URL) -> [WorkspaceBacklink] {
        documents.flatMap { document in
            document.index.links.compactMap { link in
                guard let target = resolve(link.target, from: document.url), target.url.standardizedFileURL == targetURL.standardizedFileURL else { return nil }
                return WorkspaceBacklink(sourceURL: document.url, relativePath: document.relativePath, link: link)
            }
        }
    }

    public func search(_ query: String, regularExpression: Bool = false, caseSensitive: Bool = false) throws -> [WorkspaceSearchMatch] {
        guard !query.isEmpty else { return [] }
        let expression = try Self.expression(query, regularExpression: regularExpression, caseSensitive: caseSensitive)
        var results: [WorkspaceSearchMatch] = []
        for document in documents {
            let text = document.source as NSString
            let lines = SourceLine.lines(in: text)
            let matches = try Self.matches(expression, in: document.source)
            for match in matches {
                guard results.count < 10_000 else { throw WorkspaceError.tooManyMatches }
                let line = lines.lastIndex { $0.range.location <= match.range.location } ?? 0
                let content = lines.isEmpty ? NSRange(location: 0, length: 0) : lines[line].contentRange
                results.append(.init(url: document.url, relativePath: document.relativePath, range: match.range, line: line + 1, column: match.range.location - content.location + 1, lineText: text.substring(with: content), matchedText: text.substring(with: match.range)))
            }
        }
        return results
    }

    public func diagnostics() -> [WorkspaceIssue] {
        var issues = scanIssues
        for document in documents {
            issues += document.index.diagnostics.map { .init(url: document.url, relativePath: document.relativePath, diagnostic: $0) }
            for link in document.index.links where !Self.isExternalTarget(Self.targetParts(link.target).path) {
                do {
                    let target = try resolveChecked(link.target, from: document.url)
                    if let fragment = target.fragment, !fragment.isEmpty, target.isDocument, let destination = self.document(at: target.url) {
                        let exists = fragment.hasPrefix("^") ? destination.index.blockIDs.contains { $0.name == String(fragment.dropFirst()) } : destination.index.heading(matching: fragment) != nil
                        if !exists { issues.append(.init(url: document.url, relativePath: document.relativePath, diagnostic: .init(code: "broken-anchor", message: "The heading or block ‘\(fragment)’ could not be found in ‘\(target.relativePath)’.", range: link.range))) }
                    }
                } catch {
                    let code = link.isEmbed ? "missing-embed" : "broken-link"
                    issues.append(.init(url: document.url, relativePath: document.relativePath, diagnostic: .init(code: code, message: error.localizedDescription, range: link.range)))
                }
            }
        }
        return issues.sorted { $0.relativePath == $1.relativePath ? $0.diagnostic.range.location < $1.diagnostic.range.location : $0.relativePath < $1.relativePath }
    }

    public func previewReplacement(_ query: String, with replacement: String, regularExpression: Bool = false, caseSensitive: Bool = false) throws -> WorkspaceChangeSet {
        guard !query.isEmpty else { return .init(title: "Replace in workspace", changes: []) }
        let expression = try Self.expression(query, regularExpression: regularExpression, caseSensitive: caseSensitive)
        var changes: [WorkspaceFileChange] = [], total = 0
        for document in documents {
            let matches = try Self.matches(expression, in: document.source)
            total += matches.count
            guard total <= 10_000 else { throw WorkspaceError.tooManyMatches }
            let result = NSMutableString(string: document.source)
            for match in matches.reversed() {
                let value = regularExpression ? expression.replacementString(for: match, in: document.source, offset: 0, template: replacement) : replacement
                result.replaceCharacters(in: match.range, with: value)
            }
            if result as String != document.source {
                changes.append(.init(beforePath: document.relativePath, afterPath: document.relativePath, before: document.data, after: Data((result as String).utf8), replacementCount: matches.count))
            }
        }
        return .init(title: "Replace in \(changes.count) file\(changes.count == 1 ? "" : "s")", changes: changes)
    }

    public func previewRenameFile(_ sourceURL: URL, to destinationURL: URL) throws -> WorkspaceChangeSet {
        guard let source = document(at: sourceURL) else { throw WorkspaceError.missingFile(sourceURL.lastPathComponent) }
        let destination = destinationURL.standardizedFileURL
        guard Self.isInside(destination, root: root) else { throw WorkspaceError.outsideWorkspace(destination.path) }
        guard Self.markdownExtensions.contains(destination.pathExtension.lowercased()) else { throw WorkspaceError.invalidChange("Keep a Markdown or MDX extension when renaming a note.") }
        if destination == source.url { return .init(title: "Rename note", changes: []) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw WorkspaceError.fileExists(destination.lastPathComponent) }
        let destinationPath = Self.relativePath(of: destination, root: root)
        var changes: [WorkspaceFileChange] = []
        for document in documents {
            let finalURL = document.url == source.url ? destination : document.url
            var replacements: [(NSRange, String)] = []
            for link in document.index.links {
                guard let resolved = resolve(link.target, from: document.url), !Self.targetParts(link.target).path.isEmpty else { continue }
                let finalTarget = resolved.url == source.url ? destination : resolved.url
                // Moving a note also changes its outgoing relative links.
                guard resolved.url == source.url || finalURL != document.url else { continue }
                let originalParts = Self.targetParts(link.target)
                var rewritten: String
                if originalParts.path.hasPrefix("/") { rewritten = "/" + Self.relativePath(of: finalTarget, root: root) }
                else { rewritten = Self.relativeTarget(from: finalURL.deletingLastPathComponent(), to: finalTarget) }
                if link.kind == .wiki, (originalParts.path as NSString).pathExtension.isEmpty { rewritten = (rewritten as NSString).deletingPathExtension }
                if link.kind != .wiki { rewritten = Self.encodePath(rewritten) }
                if let fragment = originalParts.fragment { rewritten += "#" + fragment }
                replacements.append((link.targetRange, rewritten))
            }
            let output = Self.replacing(document.source, replacements: replacements)
            if finalURL != document.url || output != document.source {
                changes.append(.init(beforePath: document.relativePath, afterPath: finalURL == destination ? destinationPath : document.relativePath, before: document.data, after: Data(output.utf8), replacementCount: replacements.count))
            }
        }
        return .init(title: "Rename \(source.url.lastPathComponent)", changes: changes)
    }

    public func previewRenameHeading(in url: URL, anchor: String, to title: String) throws -> WorkspaceChangeSet {
        guard let document = document(at: url) else { throw WorkspaceError.missingFile(url.lastPathComponent) }
        guard let heading = document.index.heading(matching: anchor) else { throw WorkspaceError.missingHeading(anchor) }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !title.contains("\n"), !title.contains("\r") else { throw WorkspaceError.invalidChange("A heading must contain text on one line.") }
        guard !document.index.diagnostics.contains(where: { $0.code == "duplicate-anchor" }) else { throw WorkspaceError.invalidChange("Give duplicate explicit anchors unique names before renaming a heading.") }
        let oldTitle = (document.source as NSString).substring(with: heading.titleRange)
        let explicitSuffix = leafRegex(#"\s*\{#[^}\s]+\}\s*$"#).firstMatch(in: oldTitle, range: NSRange(location: 0, length: (oldTitle as NSString).length)).map { (oldTitle as NSString).substring(with: $0.range) } ?? ""
        let replacementTitle = title + explicitSuffix
        let editedSource = Self.replacing(document.source, replacements: [(heading.titleRange, replacementTitle)])
        let editedIndex = MarkdownIndex(source: editedSource)
        guard editedIndex.headings.count == document.index.headings.count,
              !editedIndex.diagnostics.contains(where: { $0.code == "duplicate-anchor" || $0.code == "unclosed-front-matter" }) else {
            throw WorkspaceError.invalidChange("That title would change the document’s Markdown structure. Choose another title.")
        }
        // Recompute every anchor: renaming one duplicate can change later suffixes.
        let changesByAnchor = Dictionary(uniqueKeysWithValues: zip(document.index.headings, editedIndex.headings).compactMap { old, new in old.anchor == new.anchor ? nil : (old.anchor, new.anchor) })
        var changes: [WorkspaceFileChange] = []
        for current in documents {
            var replacements: [(NSRange, String)] = []
            if current.url == url { replacements.append((heading.titleRange, replacementTitle)) }
            for link in current.index.links {
                if current.url == url, NSIntersectionRange(link.range, heading.titleRange).length > 0 { continue }
                guard let resolved = resolve(link.target, from: current.url), resolved.url == url, let fragment = resolved.fragment else { continue }
                let decoded = fragment.removingPercentEncoding ?? fragment
                let oldAnchor = document.index.heading(matching: decoded)?.anchor ?? decoded
                guard let newAnchor = changesByAnchor[oldAnchor] else { continue }
                let parts = Self.targetParts(link.target)
                let fragmentValue = link.kind == .wiki && decoded == heading.title ? title : newAnchor
                replacements.append((link.targetRange, parts.path + "#" + fragmentValue))
            }
            let output = Self.replacing(current.source, replacements: replacements)
            if output != current.source { changes.append(.init(beforePath: current.relativePath, afterPath: current.relativePath, before: current.data, after: Data(output.utf8), replacementCount: replacements.count)) }
        }
        return .init(title: "Rename heading to \(title)", changes: changes)
    }

    static func expression(_ query: String, regularExpression: Bool, caseSensitive: Bool) throws -> NSRegularExpression {
        do { return try NSRegularExpression(pattern: regularExpression ? query : NSRegularExpression.escapedPattern(for: query), options: caseSensitive ? [] : [.caseInsensitive]) }
        catch { throw WorkspaceError.invalidExpression(error.localizedDescription) }
    }

    static func matches(_ expression: NSRegularExpression, in source: String) throws -> [NSTextCheckingResult] {
        var matches: [NSTextCheckingResult] = [], expired = false, tooMany = false
        let deadline = Date().addingTimeInterval(2)
        expression.enumerateMatches(in: source, options: [.reportProgress], range: NSRange(location: 0, length: (source as NSString).length)) { match, _, stop in
            if Date() > deadline { expired = true; stop.pointee = true; return }
            if let match { matches.append(match) }
            if matches.count > 10_000 { tooMany = true; stop.pointee = true }
        }
        if expired { throw WorkspaceError.searchTimedOut }; if tooMany { throw WorkspaceError.tooManyMatches }
        return matches
    }

    static func targetParts(_ target: String) -> (path: String, fragment: String?) {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\\([\[\]() ])"#, with: "$1", options: .regularExpression)
        guard let hash = target.firstIndex(of: "#") else { return (target, nil) }
        return (String(target[..<hash]), String(target[target.index(after: hash)...]))
    }

    public static func isExternalTarget(_ target: String) -> Bool {
        if target.hasPrefix("//") { return true }
        return leafRegex(#"^[A-Za-z][A-Za-z0-9+.-]*:"#).firstMatch(in: target, range: NSRange(location: 0, length: (target as NSString).length)) != nil
    }

    public static func relativePath(of url: URL, root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    static func isInside(_ url: URL, root: URL) -> Bool { url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") }

    public static func relativeTarget(from base: URL, to target: URL) -> String {
        let source = base.standardizedFileURL.pathComponents, destination = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(source.count, destination.count), source[common] == destination[common] { common += 1 }
        return (Array(repeating: "..", count: source.count - common) + Array(destination.dropFirst(common))).joined(separator: "/")
    }

    public static func encodePath(_ path: String) -> String { path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?"))) ?? path }

    public static func replacing(_ source: String, replacements: [(NSRange, String)]) -> String {
        let output = NSMutableString(string: source)
        var used: Set<NSRange> = []
        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) where used.insert(range).inserted {
            guard range.location != NSNotFound, NSMaxRange(range) <= output.length else { continue }
            output.replaceCharacters(in: range, with: replacement)
        }
        return output as String
    }
}
