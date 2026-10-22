import Foundation

/// Changes the description alone. Targets, titles, HTML dimensions and other
/// attributes remain byte-for-byte identical.
public enum AssetDescriptionEdit {
    public static func replacing(_ link: MarkdownLink, in source: String, with description: String) throws -> String {
        guard link.isEmbed, NSMaxRange(link.range) <= (source as NSString).length else { throw WorkspaceError.invalidChange("Select an image embed to edit its description.") }
        let raw = (source as NSString).substring(with:link.range) as NSString
        let range: NSRange, replacement: String
        if link.kind == .markdown, raw.hasPrefix("![") {
            var cursor = 2, depth = 1, closing: Int?
            while cursor < raw.length {
                let unit = raw.character(at:cursor)
                if unit == 92 { cursor += 2; continue }
                if unit == 91 { depth += 1 }
                if unit == 93 { depth -= 1; if depth == 0 { closing = cursor; break } }
                cursor += 1
            }
            guard let closing else { throw WorkspaceError.invalidChange("The image description is incomplete.") }
            range = NSRange(location:link.range.location + 2,length:closing - 2)
            replacement = description.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"]",with:"\\]").replacingOccurrences(of:"\n",with:" ")
        } else if link.kind == .html, raw.lowercased.hasPrefix("<img") {
            let escaped = description.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&#39;").replacingOccurrences(of:"<",with:"&lt;")
            let regex = try NSRegularExpression(pattern:"(?is)\\balt\\s*=\\s*([\"'])(.*?)\\1")
            if let match = regex.firstMatch(in:raw as String,range:NSRange(location:0,length:raw.length)) {
                range = NSRange(location:link.range.location + match.range(at:2).location,length:match.range(at:2).length); replacement = escaped
            } else {
                let close = raw.range(of:"/>",options:.backwards).location
                let position = close == NSNotFound ? raw.range(of:">",options:.backwards).location : close
                guard position != NSNotFound else { throw WorkspaceError.invalidChange("The image element is incomplete.") }
                range = NSRange(location:link.range.location + position,length:0); replacement = " alt=\"\(escaped)\""
            }
        } else { throw WorkspaceError.invalidChange("Edit this image description in its source syntax.") }
        return WorkspaceIndex.replacing(source,replacements:[(range,replacement)])
    }
}
