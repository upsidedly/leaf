import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks

struct ConfiguredHighlighter: SyntaxHighlighter {
    let base: HighlightJSBridge
    let font: String
    let background: NSColor?
    func codeFont(size: CGFloat) -> NSFont { font == "System Mono" ? .monospacedSystemFont(ofSize:size,weight:.regular) : NSFont(name:font,size:size) ?? base.codeFont(size:size) }
    func backgroundColor() -> NSColor { background ?? base.backgroundColor() }
    func highlight(code: String, language: String?) -> NSAttributedString? { base.highlight(code:code,language:language) }
    var appearanceDidChangeNotification: Notification.Name? { base.appearanceDidChangeNotification }
}
