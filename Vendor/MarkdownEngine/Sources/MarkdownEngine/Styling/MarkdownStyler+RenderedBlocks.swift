// Leaf source-preserving diagram, HTML and transclusion extension. Apache-2.0.
import AppKit

extension MarkdownStyler {
    static func styleRenderedBlocks(_ ctx: StylingContext, caretLocation: Int, selection: NSRange?, secondarySelections: [NSRange] = []) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for block in ctx.services.blocks.blocks(in: ctx.nsText as String) {
            let range = block.range
            guard range.length > 0, range.location >= 0, NSMaxRange(range) <= ctx.nsText.length,
                  !ctx.outsideScope(range) else { continue }
            let token = MarkdownToken(kind: .table, range: range, contentRange: range, markerRanges: [])
            if token.containsSelectionOrStandaloneParagraph(caretLocation, in: ctx.nsText) { continue }
            if let selection, selection.length > 0, NSIntersectionRange(selection, range).length > 0 { continue }
            if secondarySelections.contains(where:{ token.containsSelectionOrStandaloneParagraph($0.location,in:ctx.nsText) || NSIntersectionRange($0,range).length > 0 }) { continue }
            let maxWidth = ctx.configuration.readingWidth ?? 720
            let factor = min(1, maxWidth / max(1, block.image.size.width))
            let size = NSSize(width: block.image.size.width * factor, height: block.image.size.height * factor)
            guard size.width > 0, size.height > 0 else { continue }
            _ = appendRenderedStandaloneBlock(
                for: token, rawContent: ctx.nsText.substring(with: range), image: block.image,
                imageBounds: CGRect(origin: .zero, size: size), paragraphSpacingBefore: 12,
                paragraphSpacing: 14, alignment: .left, mode: .collapsedSource(markerTexts: []),
                ctx: ctx, attrs: &attrs)
            attrs.append((range, [.spellingState: 0]))
        }
        return attrs
    }
}
