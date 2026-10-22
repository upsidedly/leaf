import Foundation
import LeafCore
import LeafRender

@main struct LeafChecks {
    static func main() async throws {
        let settings = try LeafSettings.merged(Data("{\"bodySize\":19,\"caret\":{\"blur\":0.8}}".utf8))
        guard settings.bodySize == 19, settings.caret.blur == 0.8, settings.caret.animated else {
            throw CocoaError(.coderReadCorrupt)
        }
        print("PASS settings merge and validation")
        let imageSource = "![old](assets/figure.png \"Keep this title\")\n<img class=\"figure\" src=\"assets/figure.png\" width=\"120\" alt='old'>\n[paper](paper.pdf)\n"
        let images = MarkdownIndex(source:imageSource).links
        guard let markdownImage = images.first(where: { $0.isEmbed && $0.kind == .markdown }),
              let htmlImage = images.first(where: { $0.isEmbed && $0.kind == .html }),
              let ordinaryLink = images.first(where: { !$0.isEmbed }) else { throw CocoaError(.coderReadCorrupt) }
        let newMarkdown = try AssetDescriptionEdit.replacing(markdownImage,in:imageSource,with:"Clear [detail]")
        guard newMarkdown.contains("![Clear \\[detail\\]](assets/figure.png \"Keep this title\")") else { throw CocoaError(.coderReadCorrupt) }
        let newHTML = try AssetDescriptionEdit.replacing(htmlImage,in:imageSource,with:"A \"clear\" detail")
        guard newHTML.contains("class=\"figure\" src=\"assets/figure.png\" width=\"120\" alt='A &quot;clear&quot; detail'") else { throw CocoaError(.coderReadCorrupt) }
        do { _ = try AssetDescriptionEdit.replacing(ordinaryLink,in:imageSource,with:"No"); throw CocoaError(.coderReadCorrupt) }
        catch is WorkspaceError { }
        print("PASS image descriptions preserve titles and HTML attributes; normal links are protected")
        for check in try LeafCoreChecks.run() { print("PASS \(check)") }
        for check in try await PublicationChecks.run() { print("PASS \(check)") }
        let diagram = try await DiagramEngine().render("flowchart LR\n A[Write] --> B[Publish]")
        guard diagram.width > 0, diagram.height > 0, diagram.svg.contains("<svg"), !diagram.svg.contains("var(--") else { throw CocoaError(.coderReadCorrupt) }
        print("PASS offline JavaScriptCore diagram and concrete native SVG")
        let html = try await MarkupEngine().html("# Native\n\n**Bold** and $x^2$.[^1]\n\n[^1]: A footnote.\n\n<div><em>HTML</em></div>\n\n<script>throw new Error('never')</script>")
        guard html.contains("<strong>Bold</strong>"), html.contains("katex"), html.contains("<em>HTML</em>"), !html.contains("<script>") else { throw CocoaError(.coderReadCorrupt) }
        print("PASS offline Markdown, math, footnotes and static HTML")
    }
}
