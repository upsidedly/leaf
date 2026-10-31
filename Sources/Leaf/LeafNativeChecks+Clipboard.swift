import AppKit

@MainActor extension LeafNativeChecks {
    /// Exercise only the real editor's copy/paste boundary. Keep the user's
    /// clipboard in memory and restore it unless another app replaces it.
    static func clipboard(in output: URL) async throws -> [String] {
        NSDocumentController.shared.autosavingDelay = 3600
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let original = try (pasteboard.pasteboardItems ?? []).map { item in
            try item.types.map { type -> (NSPasteboard.PasteboardType, Data) in
                guard let data = item.data(forType: type) else {
                    throw NativeCheckFailure.failed("Cannot preserve the current clipboard's \(type.rawValue) data.")
                }
                return (type, data)
            }
        }
        guard pasteboard.changeCount == originalChangeCount else {
            throw NativeCheckFailure.failed("The clipboard changed while it was being preserved; no checks were performed.")
        }
        var ownedChangeCount = originalChangeCount
        defer {
            if pasteboard.changeCount == ownedChangeCount {
                pasteboard.clearContents()
                let items = original.map { entries in
                    let item = NSPasteboardItem()
                    for (type, data) in entries { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }
        }
        func requireClipboardOwnership() throws {
            guard pasteboard.changeCount == ownedChangeCount else {
                throw NativeCheckFailure.failed("The clipboard changed outside the checks; preserving that newer content.")
            }
        }
        func data(for type: NSPasteboard.PasteboardType) throws -> Data? {
            try requireClipboardOwnership()
            let result = pasteboard.data(forType: type)
            try requireClipboardOwnership()
            return result
        }

        let document = LeafDocument()
        document.fileURL = output.appendingPathComponent("Clipboard.md")
        document.fileType = "net.daringfireball.markdown"
        try document.read(from: Data(), ofType: "net.daringfireball.markdown")
        document.model.mode = .source
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        defer { document.updateChangeCount(.changeCleared); document.close() }
        try await settle { document.model.textView != nil }
        guard let editor = document.model.textView else { throw NativeCheckFailure.failed("Clipboard checks have no native editor.") }
        func replace(_ source: String) {
            editor.selectAll(nil)
            editor.insertText(source, replacementRange: editor.selectedRange())
            editor.breakUndoCoalescing()
        }
        func copy(_ source: String) throws {
            try requireClipboardOwnership()
            replace(source)
            editor.selectAll(nil)
            editor.copy(nil)
            ownedChangeCount = pasteboard.changeCount
        }
        func imported(_ data: Data?, as type: NSAttributedString.DocumentType) throws -> NSAttributedString {
            guard let data else { throw NativeCheckFailure.failed("A copied clipboard format is missing.") }
            return try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
        }
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        let sources = ["first\nsecond", "\nfirst\n\n\nsecond\n\n", "one\r\ntwo\r\n", "\n\n", "  indented\n\tmore\n", "📝 first\nsecond\n"]
        for source in sources {
            try copy(source)
            check(pasteboard.string(forType: .string) == source, "Plain-text copy changed \(source.debugDescription).")
            check(pasteboard.string(forType: .init("dev.markdownengine.raw-markdown")) == source, "Raw Markdown copy changed \(source.debugDescription).")
            replace("")
            try requireClipboardOwnership()
            editor.paste(nil)
            try requireClipboardOwnership()
            check(editor.string == source, "In-app copy/paste lost whitespace in \(source.debugDescription).")

            try requireClipboardOwnership()
            pasteboard.clearContents()
            pasteboard.setString(source, forType: .string)
            ownedChangeCount = pasteboard.changeCount
            replace("")
            editor.paste(nil)
            try requireClipboardOwnership()
            check(editor.string == source, "Plain-text paste lost whitespace in \(source.debugDescription).")
        }

        // Cocoa imports <br> as U+2028, a real rich-text line break. Normalize
        // that representation for comparison; raw clipboard text stays exact.
        func logicalLines(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\u{2029}", with: "\n")
        }
        let richSources = [
            ("first\n**second**\nthird", "first\nsecond\nthird"),
            ("first\n\n\nsecond", "first\n\n\nsecond"),
            ("first\n\nsecond\n\n\nthird", "first\n\nsecond\n\n\nthird"),
            ("\n\nfirst\nsecond", "\n\nfirst\nsecond"),
            ("first\r\nsecond", "first\nsecond"),
            ("> first\n>\n> second", "first\n\nsecond"),
            ("```text\nfirst\n\nsecond\n```", "first\n\nsecond"),
            ("`first\nsecond`", "first\nsecond")
        ]
        for (source, expected) in richSources {
            try copy(source)
            let html = try imported(data(for: .html), as: .html)
            check(logicalLines(html.string).hasPrefix(expected), "HTML copy changed newlines in \(source.debugDescription).")
            let rtf = try imported(data(for: .rtf), as: .rtf)
            check(logicalLines(rtf.string).hasPrefix(expected), "RTF copy changed newlines in \(source.debugDescription).")
            guard let archive = try data(for: .init("com.apple.webarchive")),
                  let plist = try PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
                  let resource = plist["WebMainResource"] as? [String: Any],
                  let webHTML = resource["WebResourceData"] as? Data else {
                throw NativeCheckFailure.failed("The copied web archive is missing its HTML resource.")
            }
            let web = try imported(webHTML, as: .html)
            check(logicalLines(web.string).hasPrefix(expected), "Web-archive copy changed newlines in \(source.debugDescription).")
        }
        try copy("Visit https://example.com\nKeep **bold** text.")
        let formatted = try imported(data(for: .html), as: .html)
        let visible = formatted.string as NSString
        let link = visible.range(of: "https://example.com")
        let bold = visible.range(of: "bold")
        check(link.location != NSNotFound && (formatted.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.host == "example.com", "Newline preservation dropped the copied link.")
        if bold.location != NSNotFound, let font = formatted.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont {
            check(NSFontManager.shared.traits(of: font).contains(.boldFontMask), "Newline preservation dropped bold formatting.")
        } else { failures.append("The copied bold text is missing.") }
        if !failures.isEmpty { throw NativeCheckFailure.failed(failures.joined(separator: "\n")) }
        let checks = ["Plain-text and Markdown copy preserve exact whitespace", "In-app copy/paste preserves leading, repeated and trailing newlines", "Plain-text paste preserves LF, CRLF, Unicode and indentation", "HTML, RTF and web-archive copy preserve typed newlines, paragraphs, quotes and code", "Rich copy retains links and bold formatting"]
        return checks
    }
}
