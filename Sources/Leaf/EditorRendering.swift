import AppKit
import SwiftUI
import WebKit
import LeafCore
import LeafRender
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex

@MainActor final class EditorRenderCache {
    var source = ""
    var blocks: [RenderedMarkdownBlock] = []
    var images: [String: NSImage] = [:]
    var version = 0
    let highlighter = HighlightJSBridge()
    let math = SwiftMathBridge()
}

/// An immutable snapshot: native styling reads only prepared images, with no file
/// access or JavaScript execution on a keystroke.
struct RenderSnapshot: EmbeddedImageProvider, RenderedBlockProvider {
    let source: String
    let rendered: [RenderedMarkdownBlock]
    let images: [String: NSImage]
    let version: Int
    func image(for reference: EmbeddedImageRequest) -> NSImage? { images[reference.name] }
    func fingerprint() -> AnyHashable { version }
    func blocks(in source: String) -> [RenderedMarkdownBlock] { source == self.source ? rendered : [] }
}

@MainActor extension DocumentModel {
    func buildBlockCache(_ input: String, index: MarkdownIndex, generation: Int, preferences: LeafSettings, workspace: WorkspaceIndex?) async throws {
        var blocks: [RenderedMarkdownBlock] = [], images: [String: NSImage] = [:]
        let blockWidth = max(260,min(preferences.contentWidth,editorWidth - 72))
        let dark = isDark
        let theme = preferences.diagramTheme == "auto" ? (dark ? "dark" : "light") : preferences.diagramTheme
        for code in index.codeBlocks where ["mermaid", "pele"].contains(code.language.lowercased()) {
            try Task.checkCancellation()
            do {
                let result = try await diagramEngine.render(code.source, theme: theme)
                if let image = NSImage(data: Data(result.svg.utf8)) {
                    blocks.append(.init(range: code.range, image: image, accessibilityLabel: "\(result.type) diagram"))
                }
            } catch { /* The canvas presents the exact engine error; live source stays editable. */ }
        }
        for block in HTMLSourceBlocks.scan(input, excluding: index.codeBlocks.map(\.range)) {
            try Task.checkCancellation()
            let fragment = try await markupEngine.fragment((input as NSString).substring(with: block))
            if let image = NativeHTMLRenderer.image(fragment, width: blockWidth, settings: preferences, dark: dark, baseURL: fileURL?.deletingLastPathComponent()) {
                blocks.append(.init(range: block, image: image, accessibilityLabel: "HTML content"))
            }
        }
        for link in index.links where link.isEmbed {
            try Task.checkCancellation()
            if let workspace, let fileURL, let resolved = workspace.resolve(link.target, from: fileURL),
               ["md", "markdown", "mdx"].contains(resolved.url.pathExtension.lowercased()) {
                do {
                    let embed = try TransclusionResolver(workspace: workspace).resolve(link.target, from: fileURL)
                    let fragment = try await markupEngine.fragment(embed.source)
                    if let image = NativeHTMLRenderer.image(fragment, width: blockWidth, settings: preferences, dark: dark, baseURL: resolved.url.deletingLastPathComponent()) {
                        blocks.append(.init(range: (input as NSString).paragraphRange(for: link.range), image: image, accessibilityLabel: "Embedded \(link.target)"))
                    }
                } catch { }
            } else if let parent = fileURL?.deletingLastPathComponent() {
                let url = URL(fileURLWithPath: link.target.removingPercentEncoding ?? link.target, relativeTo: parent).standardizedFileURL
                if let data = try? await loader.bytes(url), let image = NSImage(data: data) { images[link.target] = image }
            }
        }
        guard generation == revision, !Task.isCancelled else { return }
        renderCache.source = input; renderCache.blocks = blocks; renderCache.images = images; renderCache.version += 1
    }

    func editorConfiguration(sourceMode: Bool, availableWidth: Double) -> MarkdownEditorConfiguration {
        let s = settings
        let available = availableWidth
        var c = MarkdownEditorConfiguration.default
        let snapshot = RenderSnapshot(source: renderCache.source, rendered: renderCache.blocks, images: renderCache.images, version: renderCache.version)
        c.services = MarkdownEditorServices(blocks: snapshot, images: snapshot, syntaxHighlighter: ConfiguredHighlighter(base:renderCache.highlighter,font:s.codeFont,background:s.colors["codeBackground"].flatMap(NSColor.init(leafHex:))), latex: renderCache.math)
        c.theme.bodyText = LeafStyle.color("text",s,fallback:.labelColor)
        c.theme.mutedText = LeafStyle.color("muted",s,fallback:.secondaryLabelColor)
        c.theme.link = LeafStyle.color("link",s,fallback:s.accent == "system" ? .linkColor : LeafStyle.accent(s))
        c.headingTextColor = s.colors["heading"].flatMap(NSColor.init(leafHex:))
        c.leafRevision = renderCache.version
        c.focusMode = focusMode
        c.readingWidth = sourceMode ? nil : max(260,min(s.contentWidth,available - 72))
        c.rawSourceMode = sourceMode
        c.textInsets = .init(horizontal: sourceMode ? 28 : 24, vertical: 30)
        c.paragraph.spacingFactor = s.paragraphSpacing
        c.paragraph.lineHeightExtraSpacing = s.lineSpacing
        c.codeBlock.fontSizeScale = s.codeSize / s.bodySize
        c.headings.fontMultipliers = [2, 1.6, 1.3, 1.14, 1.04, 1].map { $0 * s.headingScale }
        c.lists.helpersEnabled = s.smartLists
        c.spellChecking.continuousSpellChecking = s.spellCheck
        c.spellChecking.automaticSpellingCorrection = s.autoCorrect
        c.extensions = [StrikethroughExtension(), HighlightExtension(), ContainerExtension(), FootnoteExtension(size:s.bodySize)]
        c.customCaret = s.caret.animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        c.headingFontName = s.headingFont == "System" ? nil : s.headingFont
        c.codeFontName = s.codeFont == "System Mono" ? nil : s.codeFont
        return c
    }
}

/// The existing engine's extension seam owns marker reveal and source ranges.
/// Reading/export views add footnote numbering and backlinks through marked.
private struct FootnoteExtension: MarkdownExtension {
    let size: Double
    var id: String { "leaf-footnote" }
    var inline: InlineSyntax? { .init(open:"[^",close:"]",parsesContent:false) }
    func contentAttributes(theme:MarkdownEditorTheme) -> [NSAttributedString.Key:Any] {
        [.font:NSFont.systemFont(ofSize:size * 0.72), .baselineOffset:size * 0.3, .foregroundColor:theme.link]
    }
    func html(childrenHTML:String) -> String { "<sup>\(childrenHTML)</sup>" }
}

struct NativeEditor: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var settings = SettingsStore.shared
    let sourceMode: Bool
    var isEditable = true
    var body: some View {
        GeometryReader { geometry in
        NativeTextViewWrapper(
            text: Binding(get: { model.source }, set: { model.edit($0) }),
            configuration: model.editorConfiguration(sourceMode: sourceMode,availableWidth:geometry.size.width),
            fontName: sourceMode ? (model.settings.codeFont == "System Mono" ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontName : model.settings.codeFont) : (model.settings.bodyFont == "System" ? NSFont.systemFont(ofSize: 16).fontName : model.settings.bodyFont),
            fontSize: sourceMode ? model.settings.codeSize : model.settings.bodySize,
            documentId: String(ObjectIdentifier(model).hashValue),
            isEditable: isEditable && !model.workspaceBusy,
            onEditorReady: { view in
                model.textView = view
                model.document?.undoManager = view.undoManager
                model.enhancements?.stop()
                model.enhancements = EditorEnhancements(textView: view, model: model)
                view.setAccessibilityLabel(sourceMode ? "Markdown source" : "Document editor")
            },
            onPasteImage: { model.pasteImage($0) },
            onLinkClick: { model.follow($0) },
            onBuildContextMenu: { menu, _ in
                let item = NSMenuItem(title: "Open Diagram Canvas", action: #selector(LeafAppDelegate.menuAction(_:)), keyEquivalent: "")
                item.target = NSApp.delegate; item.representedObject = "diagram"; menu.addItem(.separator()); menu.addItem(item)
                return menu
            },
            placeholder: NSAttributedString(string: "Start writing…", attributes: [.font: NSFont.systemFont(ofSize: model.settings.bodySize), .foregroundColor: NSColor.placeholderTextColor])
        ).background(Color(nsColor: LeafStyle.color("background",model.settings,fallback:.textBackgroundColor)))
            .onChange(of: model.renderedRevision) { _, _ in model.enhancements?.refreshSettings() }
            .onChange(of: settings.value) { _, _ in model.reloadSettings() }
            .onChange(of:geometry.size.width,initial:true) { _, width in
                if abs(model.editorWidth - width) > 1 { model.editorWidth = width; model.scheduleRender() }
            }
        }
    }
}

enum NativeHTMLRenderer {
    @MainActor private static let images: NSCache<NSString,NSImage> = {
        let cache = NSCache<NSString,NSImage>(); cache.countLimit = 128; cache.totalCostLimit = 64 * 1024 * 1024; return cache
    }()
    @MainActor static func attributed(_ fragment: String, settings: LeafSettings, dark: Bool = false, baseURL: URL?) throws -> NSAttributedString {
        // Native HTML import supports static document semantics. Strip network
        // image sources before import; render engines already remove executable HTML.
        let cleaned = fragment.replacingOccurrences(of: "(?i)\\s(?:src|href)=[\"'](?:https?:)?//[^\"']*[\"']", with: "", options: .regularExpression)
        let font = settings.bodyFont == "System" ? "-apple-system" : settings.bodyFont.replacingOccurrences(of: "'", with: "")
        let html = "<html><head><meta charset='utf-8'><style>body{font-family:'\(font)';font-size:\(settings.bodySize)px;color:\(dark ? "#e5e5e5" : "#303030");line-height:1.5}h1{font-size:2em}h2{font-size:1.6em}h3{font-size:1.3em}a{color:#2472bd}pre,code{font-family:monospace}table{border-collapse:collapse}td,th{padding:6px;border:1px solid #aaa}blockquote{color:#777}img{max-width:100%}</style>\(LeafStyle.css(settings))</head><body>\(cleaned)</body></html>"
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue]
        if let baseURL { options[.baseURL] = baseURL }
        return try NSAttributedString(data: Data(html.utf8), options: options, documentAttributes: nil)
    }
    @MainActor static func image(_ fragment: String, width: Double, settings: LeafSettings, dark: Bool = false, baseURL: URL?) -> NSImage? {
        let key = "\(width)|\(settings.bodyFont)|\(settings.headingFont)|\(settings.bodySize)|\(settings.codeFont)|\(settings.codeSize)|\(settings.colors.sorted { $0.key < $1.key })|\(dark)|\(baseURL?.path ?? "")|" + fragment
        if let cached = images.object(forKey:key as NSString) { return cached }
        guard let attributed = try? attributed(fragment, settings: settings, dark: dark, baseURL: baseURL), attributed.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: attributed), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(200, width), height: 20000))
        container.lineFragmentPadding = 0; manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let size = NSSize(width: max(200, width), height: min(20000, max(24, ceil(manager.usedRect(for: container).height) + 12)))
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        manager.drawBackground(forGlyphRange: manager.glyphRange(for: container), at: .zero)
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
        image.unlockFocus()
        images.setObject(image,forKey:key as NSString,cost:Int(size.width * size.height * 4))
        return image
    }
}

enum HTMLSourceBlocks {
    static func scan(_ source: String, excluding code: [NSRange]) -> [NSRange] {
        let text = source as NSString
        guard let regex = try? NSRegularExpression(pattern: "(?m)^[ \\t]*<[A-Za-z][^\\n]*") else { return [] }
        var result: [NSRange] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            guard !code.contains(where: { NSLocationInRange(match.range.location, $0) }),
                  !result.contains(where: { NSLocationInRange(match.range.location, $0) }) else { continue }
            let start = match.range.location
            let rest = text.substring(from: start)
            var end = NSMaxRange(text.paragraphRange(for: match.range))
            if let tagMatch = rest.range(of: "^\\s*<([A-Za-z][A-Za-z0-9-]*)", options: .regularExpression) {
                let opening = String(rest[tagMatch]); let tag = opening.drop(while: { $0 != "<" }).dropFirst()
                if !["img", "hr", "br", "input", "meta", "link"].contains(String(tag).lowercased()),
                   let close = rest.range(of: "</\(tag)>", options: .caseInsensitive) {
                    end = start + (String(rest[..<close.upperBound]) as NSString).length
                    end = NSMaxRange(text.paragraphRange(for: NSRange(location: max(start, end - 1), length: 1)))
                }
            }
            result.append(NSRange(location: start, length: min(text.length, end) - start))
        }
        // Inline HTML is presented with its surrounding paragraph so native layout
        // can apply nested tags without introducing source/presentation drift.
        if let inline = try? NSRegularExpression(pattern: "<[/]?[A-Za-z][^>]*>") {
            for match in inline.matches(in: source, range: NSRange(location: 0, length: text.length)) {
                guard !code.contains(where: { NSLocationInRange(match.range.location, $0) }), !result.contains(where: { NSLocationInRange(match.range.location, $0) }) else { continue }
                result.append(text.paragraphRange(for: match.range))
            }
        }
        return result.sorted { $0.location < $1.location }
    }
}

struct HTMLReader: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    var onLink: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.underPageBackgroundColor = .textBackgroundColor
        web.setAccessibilityLabel("Rendered document")
        return web
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html || context.coordinator.lastBaseURL != baseURL else { return }
        context.coordinator.lastHTML = html; context.coordinator.lastBaseURL = baseURL
        context.coordinator.finished = false; view.loadHTMLString(html, baseURL: baseURL)
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""; var lastBaseURL: URL?; var finished = false
        let onLink: (String) -> Void
        init(onLink: @escaping (String) -> Void) { self.onLink = onLink }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url { if url.fragment != nil, let current = webView.url, url.path == current.path { decisionHandler(.allow); return }
                onLink(url.absoluteString); decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        }
    }
}
