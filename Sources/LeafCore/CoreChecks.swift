import Foundation

public enum LeafCoreChecks {
    /// Uses only a private temporary workspace. No user document is opened or changed.
    @discardableResult
    public static func run() throws -> [String] {
        var passed: [String] = []
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw WorkspaceError.invalidChange("Core check failed: \(message)") }
        }
        let sample = "---\r\ntitle: fixture\r\n---\r\n# Café 🐊\r\n## Same\r\n## Same\r\n# Hash#\r\n# Trim ###\r\n[go](folder/a(b).md#hello) ![[Guide#First|section]]\r\n`[ignored](missing.md)`\r\n```mermaid\r\ngraph LR\r\nA-->B\r\n[ignored](also-missing.md)\r\n```\r\n"
        let index = MarkdownIndex(source: sample)
        try check(index.headings.map(\.anchor) == ["café-", "same", "same-1", "hash", "trim"], "unique heading anchors, Unicode and closing hashes")
        try check(index.headings[3].title == "Hash#", "a hash without preceding whitespace belongs to the heading")
        try check(index.links.count == 2 && index.links[0].target == "folder/a(b).md#hello", "nested destinations and code exclusions")
        try check(index.links[1].isEmbed && index.links[1].label == "section", "wiki embeds retain their display label")
        try check((sample as NSString).substring(with: index.links[1].targetRange) == "Guide#First", "UTF-16 source ranges after emoji")
        try check(index.codeBlocks.count == 1 && index.codeBlocks[0].language == "mermaid" && index.codeBlocks[0].source.contains("A-->B"), "fence contents and CRLF ranges")
        try check(index.diagnostics.isEmpty, "valid sample has no syntax diagnostics")
        let malformed = MarkdownIndex(source: "## One {#fixed}\n## Two {#fixed}\n~~~swift\nlet value = 1\n")
        try check(Set(malformed.diagnostics.map(\.code)) == ["duplicate-anchor", "unclosed-fence"], "duplicate explicit anchors and malformed fences")
        let setext = MarkdownIndex(source: "Overview\n========\n\nText. ^paragraph\n\nA paragraph\nwith two lines.\n^standalone\n")
        try check(setext.headings.first?.level == 1 && setext.headings.first?.title == "Overview", "setext headings")
        try check(setext.blockIDs.map(\.name) == ["paragraph", "standalone"], "inline and standalone block IDs")
        passed.append("Markdown: UTF-16 ranges, fences, wiki links, nested URLs, anchors and block IDs")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("leaf-core-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ source: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(source.utf8).write(to: url)
        }
        func read(_ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        let a = "# Plan\r\n\r\n[Guide](notes/Guide.md#first)\r\n![[notes/Guide#First]]\r\n![[notes/Guide#^detail]]\r\n\r\nNumber 12 and number 34.\r\n"
        let guide = "# Guide\n\n## First\n\nA useful paragraph. ^detail\n\n![Picture](../assets/picture.png)\n\n## Second\n\nThe end.\n"
        let mdx = "---\r\ntitle: 'Source remains intact'\r\n---\r\nimport Chart from './Chart.jsx'\r\n\r\n# MDX 🐊\r\n<Chart value={12} />\r\n"
        try write("A.md", a); try write("notes/Guide.md", guide); try write("Example.mdx", mdx)
        try write("assets/picture.png", "same image bytes"); try write("assets/copy.png", "same image bytes"); try write("assets/unused.svg", "<svg/>")
        try write(".leaf/ignored.md", "# Internal journal")
        var workspace = try WorkspaceIndex(root: root)
        let aURL = root.appendingPathComponent("A.md"), guideURL = root.appendingPathComponent("notes/Guide.md")
        try check(workspace.documents.count == 3, "workspace scans MDX and excludes internal state")
        try check(workspace.resolve("Guide#First", from: aURL)?.url == guideURL, "unique wiki basename resolution")
        try check(workspace.resolve("../A.md", from: guideURL)?.url == aURL, "relative note resolution")
        try check(workspace.backlinks(to: guideURL).count == 3, "incoming links include heading and block embeds")
        try check(workspace.diagnostics().isEmpty, "valid note, heading, block and image references")
        let matches = try workspace.search("number \\d+", regularExpression: true)
        try check(matches.count == 2 && matches.allSatisfy { $0.line == 7 }, "regex search locations")
        do { _ = try workspace.search("[", regularExpression: true); throw WorkspaceError.invalidChange("Expected an invalid expression error") }
        catch WorkspaceError.invalidExpression { }
        try write("other/Guide.md", "# Duplicate name\n")
        workspace = try WorkspaceIndex(root: root)
        do { _ = try workspace.resolveChecked("Guide", from: aURL); throw WorkspaceError.invalidChange("Expected an ambiguous note error") }
        catch WorkspaceError.ambiguousTarget { }
        try FileManager.default.removeItem(at: root.appendingPathComponent("other/Guide.md"))
        workspace = try WorkspaceIndex(root: root)
        passed.append("Workspace: MD/MDX snapshots, links, backlinks, diagnostics and regex search")

        let replacement = try workspace.previewReplacement("(number) (\\d+)", with: "$1 [$2]", regularExpression: true)
        try check(replacement.changes.count == 1 && replacement.replacementCount == 2, "replace preview includes captures and counts")
        try check(try read("A.md") == a, "preview performs no document writes")
        let journal = try replacement.apply(to: root)
        try check(try read("A.md").contains("Number [12] and number [34].\r\n"), "capture replacement preserves line endings")
        try check(try read("Example.mdx") == mdx, "unmodified MDX bytes remain lossless")
        let history = try WorkspaceJournal.history(in: root)
        try check(history.count == 1 && history[0].id == journal.id, "reversible journal survives loading")
        try journal.undo()
        try check(try read("A.md") == a, "undo restores exact before bytes")
        let undoConflictJournal = try workspace.previewReplacement("Number 12", with: "Number 56").apply(to: root)
        try write("A.md", "An edit made after the batch.\n")
        do { try undoConflictJournal.undo(); throw WorkspaceError.invalidChange("Expected an undo conflict") }
        catch WorkspaceError.conflict { }
        try check(try read("A.md") == "An edit made after the batch.\n", "undo never overwrites a later external edit")
        try write("A.md", a)
        let stale = try workspace.previewReplacement("useful", with: "helpful")
        try write("notes/Guide.md", guide + "External change.\n")
        do { _ = try stale.apply(to: root); throw WorkspaceError.invalidChange("Expected a stale-preview conflict") }
        catch WorkspaceError.conflict { }
        try check(try read("notes/Guide.md") == guide + "External change.\n" && read("A.md") == a, "conflict leaves other edits intact")
        try write("notes/Guide.md", guide)
        workspace = try WorkspaceIndex(root: root)
        passed.append("Batch edits: preview, capture replacement, durable journal, exact undo and stale-preview conflicts")

        let destination = root.appendingPathComponent("moved/deep/Manual.md")
        let rename = try workspace.previewRenameFile(guideURL, to: destination)
        try check(rename.changes.count == 2, "rename preview includes note and all incoming links")
        let renameJournal = try rename.apply(to: root)
        try check(!FileManager.default.fileExists(atPath: guideURL.path) && FileManager.default.fileExists(atPath: destination.path), "note moves to its destination")
        try check(try read("A.md").contains("moved/deep/Manual.md#first") && read("A.md").contains("[[moved/deep/Manual#First]]"), "incoming Markdown and wiki paths are updated")
        try check(try read("moved/deep/Manual.md").contains("../../assets/picture.png"), "moving a note rebases its outgoing relative assets")
        try renameJournal.undo()
        try check(try read("A.md") == a && read("notes/Guide.md") == guide, "rename undo restores file names and exact links")
        let headingRename = try workspace.previewRenameHeading(in: guideURL, anchor: "first", to: "Fresh start")
        let headingJournal = try headingRename.apply(to: root)
        try check(try read("A.md").contains("Guide.md#fresh-start") && read("A.md").contains("Guide#Fresh start"), "heading rename updates slug and readable wiki fragments")
        try headingJournal.undo()
        try write("Duplicates.md", "# Same\n# Same\n[one](#same) [two](#same-1)\n")
        let duplicates = try WorkspaceIndex(root: root)
        let duplicateRename = try duplicates.previewRenameHeading(in: root.appendingPathComponent("Duplicates.md"), anchor: "same", to: "Different")
        let duplicateJournal = try duplicateRename.apply(to: root)
        try check(try read("Duplicates.md").contains("[one](#different) [two](#same)"), "renaming a duplicate heading updates later anchor suffixes")
        try duplicateJournal.undo()
        try FileManager.default.removeItem(at: root.appendingPathComponent("Duplicates.md"))
        passed.append("Renames: incoming links, moved-note assets, heading suffixes and reversible file moves")

        workspace = try WorkspaceIndex(root: root)
        let resolver = TransclusionResolver(workspace: workspace)
        let headingEmbed = try resolver.resolve("notes/Guide#First", from: aURL)
        try check(headingEmbed.source.hasPrefix("## First") && !headingEmbed.source.contains("## Second"), "heading transclusion stops at the next peer")
        let blockEmbed = try resolver.resolve("notes/Guide#^detail", from: aURL)
        try check(blockEmbed.source.contains("A useful paragraph.") && !blockEmbed.source.contains("^detail"), "block transclusion strips its marker")
        let expanded = try resolver.expand(a, from: aURL)
        try check(expanded.source.contains("assets/picture.png") && !expanded.source.contains("../assets/picture.png"), "embedded asset paths are rebased to the host note")
        try write("Cycle.md", "# Cycle\n![[Cycle]]\n")
        let cyclic = try WorkspaceIndex(root: root)
        let cycle = try TransclusionResolver(workspace: cyclic).resolve("Cycle", from: aURL)
        try check(cycle.diagnostics.contains { $0.code == "transclusion" && $0.message.contains("cycle") }, "embed cycles stop with an actionable diagnostic")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Cycle.md"))
        let assets = try AssetIndex(workspace: workspace)
        try check(assets.records.count == 3 && assets.duplicateGroups.count == 1 && assets.duplicateGroups[0].count == 2, "streamed SHA-256 duplicate groups")
        try check(assets.records.first { $0.relativePath == "assets/picture.png" }?.usages.count == 1 && assets.unused.count == 2, "asset usage and unused media")
        passed.append("Transclusion and assets: heading/block ranges, rebased links, cycle guards, usage and duplicate hashes")

        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("leaf-outside-\(UUID().uuidString).md")
        try Data("Outside must remain unchanged".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let traversal = WorkspaceChangeSet(title: "Invalid path fixture", changes: [.init(beforePath: nil, afterPath: "../\(outside.lastPathComponent)", before: nil, after: Data("overwrite".utf8))])
        do { _ = try traversal.apply(to: root); throw WorkspaceError.invalidChange("Expected a path-scope error") }
        catch WorkspaceError.outsideWorkspace { }
        try check(try String(contentsOf: outside, encoding: .utf8) == "Outside must remain unchanged", "batch edits cannot escape the workspace")
        passed.append("Filesystem scope: traversal is rejected before any document write")
        return passed
    }
}
