import AppKit
import LeafCore

@MainActor enum LeafStyle {
    static func accent(_ settings: LeafSettings) -> NSColor {
        switch settings.accent { case "graphite": .secondaryLabelColor; case "blue": .systemBlue; case "green": .systemGreen; case "orange": .systemOrange; case "purple": .systemPurple; default: .controlAccentColor }
    }
    static func color(_ key: String, _ settings: LeafSettings, fallback: NSColor) -> NSColor { settings.colors[key].flatMap(NSColor.init(leafHex:)) ?? fallback }
    static func css(_ settings: LeafSettings) -> String {
        func font(_ value: String, fallback: String) -> String {
            let safe = value.filter { $0.isLetter || $0.isNumber || " -_".contains($0) }
            return value == "System" || value == "System Mono" || safe.isEmpty ? fallback : "'\(safe)'"
        }
        let body = font(settings.bodyFont,fallback:"-apple-system, BlinkMacSystemFont, sans-serif")
        let heading = font(settings.headingFont,fallback:body), code = font(settings.codeFont,fallback:"ui-monospace, monospace")
        let rules = settings.colors.compactMap { key,value -> String? in
            guard NSColor(leafHex:value) != nil else { return nil }
            switch key { case "text": return "body{color:\(value)}"; case "background": return "html,body{background:\(value)}"; case "link": return "a{color:\(value)}"; case "heading": return "h1,h2,h3,h4,h5,h6{color:\(value)}"; case "codeBackground": return "pre,code{background:\(value)}"; case "muted": return "blockquote,figcaption,.footnotes{color:\(value)}"; default:return nil }
        }.joined()
        return "<style id='leaf-preferences'>body{font-family:\(body);font-size:\(settings.bodySize)px;line-height:\((settings.bodySize * 1.25 + settings.lineSpacing) / settings.bodySize)}h1,h2,h3,h4,h5,h6{font-family:\(heading)}h1{font-size:\(2*settings.headingScale)em}h2{font-size:\(1.6*settings.headingScale)em}h3{font-size:\(1.3*settings.headingScale)em}pre,code{font-family:\(code);font-size:\(settings.codeSize)px}p{margin-block:\(settings.paragraphSpacing + 0.4)em}\(rules)</style>"
    }
}

extension NSColor {
    convenience init?(leafHex: String) {
        let value = leafHex.hasPrefix("#") ? String(leafHex.dropFirst()) : leafHex
        guard value.count == 6, let rgb = UInt32(value,radix:16) else { return nil }
        self.init(srgbRed:CGFloat((rgb >> 16) & 255)/255,green:CGFloat((rgb >> 8) & 255)/255,blue:CGFloat(rgb & 255)/255,alpha:1)
    }
    var leafHex: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#888888" }
        return String(format:"#%02X%02X%02X",Int(rgb.redComponent*255),Int(rgb.greenComponent*255),Int(rgb.blueComponent*255))
    }
}
