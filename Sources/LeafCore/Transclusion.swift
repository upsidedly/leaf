import Foundation

public struct TransclusionResult: Sendable {
    public let source: String
    public let originURL: URL
    public let range: NSRange
    public let dependencies: [URL]
    public let diagnostics: [MarkdownDiagnostic]
}

/// Resolves ordinary note, heading and ^block-id embeds without changing files.
public struct TransclusionResolver: Sendable {
    public let workspace: WorkspaceIndex
    public let maximumDepth: Int
    public let maximumUTF16Length: Int

    public init(workspace: WorkspaceIndex, maximumDepth: Int = 12, maximumUTF16Length: Int = 2_000_000) {
        self.workspace = workspace
        self.maximumDepth = max(1, maximumDepth)
        self.maximumUTF16Length = max(1, maximumUTF16Length)
    }

    public func resolve(_ target: String, from sourceURL: URL) throws -> TransclusionResult {
        let selected = try selection(target, from: sourceURL)
        var dependencies: Set<URL> = [selected.document.url]
        var diagnostics: [MarkdownDiagnostic] = []
        let key = identity(selected.document.url, fragment: selected.fragment)
        let expanded = try expandSelected(selected.source, from: selected.document.url, stack: [key], dependencies: &dependencies, diagnostics: &diagnostics)
        return .init(source: expanded, originURL: selected.document.url, range: selected.range, dependencies: dependencies.sorted { $0.path < $1.path }, diagnostics: diagnostics)
    }

    public func expand(_ source: String, from sourceURL: URL) throws -> TransclusionResult {
        var dependencies: Set<URL> = [], diagnostics: [MarkdownDiagnostic] = []
        let expanded = try expandSelected(source, from: sourceURL, stack: [identity(sourceURL, fragment: nil)], dependencies: &dependencies, diagnostics: &diagnostics)
        return .init(source: expanded, originURL: sourceURL, range: NSRange(location: 0, length: (source as NSString).length), dependencies: dependencies.sorted { $0.path < $1.path }, diagnostics: diagnostics)
    }

    private func selection(_ target: String, from sourceURL: URL) throws -> (document: WorkspaceDocument, fragment: String?, range: NSRange, source: String) {
        let resolved = try workspace.resolveChecked(target, from: sourceURL)
        guard resolved.isDocument, let document = workspace.document(at: resolved.url) else { throw WorkspaceError.invalidChange("‘\(target)’ is an asset, not an embeddable note.") }
        var range = NSRange(location: 0, length: (document.source as NSString).length)
        if let fragment = resolved.fragment, !fragment.isEmpty {
            if fragment.hasPrefix("^") {
                guard let block = document.index.blockIDs.first(where: { $0.name == String(fragment.dropFirst()) }) else { throw WorkspaceError.missingHeading(fragment) }
                range = block.contentRange
            } else {
                guard let heading = document.index.heading(matching: fragment) else { throw WorkspaceError.missingHeading(fragment) }
                range = document.index.sectionRange(for: heading)
            }
        }
        return (document, resolved.fragment, range, (document.source as NSString).substring(with: range))
    }

    private func expandSelected(_ source: String, from url: URL, stack: [String], dependencies: inout Set<URL>, diagnostics: inout [MarkdownDiagnostic]) throws -> String {
        guard (source as NSString).length <= maximumUTF16Length else { throw WorkspaceError.transclusionTooLarge }
        let index = MarkdownIndex(source: source)
        var replacements: [(NSRange, String)] = []
        var projectedLength = (source as NSString).length
        for link in index.links where link.isEmbed && (link.kind == .wiki || link.kind == .markdown) {
            guard let resolved = workspace.resolve(link.target, from: url), resolved.isDocument else { continue }
            do {
                let selected = try selection(link.target, from: url)
                let key = identity(selected.document.url, fragment: selected.fragment)
                guard !stack.contains(key) else { throw WorkspaceError.transclusionCycle(stack + [key]) }
                guard stack.count < maximumDepth else { throw WorkspaceError.transclusionDepth }
                dependencies.insert(selected.document.url)
                let expanded = try expandSelected(selected.source, from: selected.document.url, stack: stack + [key], dependencies: &dependencies, diagnostics: &diagnostics)
                let rebased = rebase(expanded, from: selected.document.url, to: url)
                projectedLength += (rebased as NSString).length - link.range.length
                guard projectedLength <= maximumUTF16Length else { throw WorkspaceError.transclusionTooLarge }
                replacements.append((link.range, rebased))
            } catch {
                diagnostics.append(.init(code: "transclusion", message: error.localizedDescription, range: link.range, severity: .error))
                // Show a readable error in the preview; keep the on-disk source intact.
                let message = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
                replacements.append((link.range, "> **Embed unavailable:** " + message))
            }
        }
        let result = WorkspaceIndex.replacing(source, replacements: replacements)
        guard (result as NSString).length <= maximumUTF16Length else { throw WorkspaceError.transclusionTooLarge }
        return result
    }

    private func rebase(_ source: String, from origin: URL, to destination: URL) -> String {
        guard origin != destination else { return source }
        let index = MarkdownIndex(source: source)
        var replacements: [(NSRange, String)] = []
        for link in index.links {
            let parts = WorkspaceIndex.targetParts(link.target)
            guard !WorkspaceIndex.isExternalTarget(parts.path), !parts.path.hasPrefix("/"), let resolved = workspace.resolve(link.target, from: origin) else { continue }
            var target = WorkspaceIndex.relativeTarget(from: destination.deletingLastPathComponent(), to: resolved.url)
            if link.kind == .wiki, (parts.path as NSString).pathExtension.isEmpty { target = (target as NSString).deletingPathExtension }
            if link.kind != .wiki { target = WorkspaceIndex.encodePath(target) }
            if let fragment = parts.fragment { target += "#" + fragment }
            replacements.append((link.targetRange, target))
        }
        return WorkspaceIndex.replacing(source, replacements: replacements)
    }

    private func identity(_ url: URL, fragment: String?) -> String {
        WorkspaceIndex.relativePath(of: url, root: workspace.root) + (fragment.map { "#" + $0 } ?? "")
    }
}
