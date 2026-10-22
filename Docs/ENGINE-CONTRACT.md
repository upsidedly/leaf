# Architecture

Ordinary UTF-8 Markdown/MDX files are the source of truth. Live styling, indexes, diagrams, HTML and exports are derived. Editing never serializes a rendered document over the original source.

## Leaf

AppKit owns documents, windows, menus, text input and file conventions. SwiftUI owns compact navigation, settings and contextual tools. The primary writing surface uses TextKit 2 through the vendored MarkdownEngine. WKWebView is limited to static reading/split views and printing; document JavaScript stays disabled.

DocumentModel owns the active source, render tasks, workspace snapshot, navigation and pending operations. Generations reject stale renders. A lock-protected DocumentBuffer supplies immutable snapshots to NSDocument's file callbacks without moving UI state off MainActor. Image insertion commits only after its local asset write succeeds.

## LeafCore

Sendable value models use UTF-16 NSRange positions. MarkdownIndex extracts headings, links, blocks and diagnostics. WorkspaceIndex resolves links and creates replacement/rename previews. WorkspaceChangeSet verifies the original bytes before applying, rolls back failed batches and persists an Undo journal. Undo rejects files edited after the batch.

Transclusion supports notes, headings and block IDs, rebases relative assets and guards cycles/depth. AssetIndex tracks usage and duplicate hashes. EPUB export uses validated XHTML/XML, a bounded ZIP process and staged replacement. These services have no UI dependency.

## LeafRender

DiagramEngine and MarkupEngine each own a JavaScriptCore context. Bundled pinned libraries parse text passed as values, with no document-code execution or runtime downloads. Diagram results contain concrete SVG and dimensions; native NSImage drawing stays on the UI side. HTML output includes offline math fonts and a restrictive content policy.

See [rendering](rendering.md), [exports](exports.md) and [verification](verification.md) for supported grammar, limits and evidence.
