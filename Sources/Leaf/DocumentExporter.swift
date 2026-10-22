import AppKit
import Foundation
import WebKit
import PDFKit
import LeafCore
import LeafRender
import MarkdownEngine
import MarkdownEngineLatex

@MainActor final class DocumentExporter {
    enum ExportError: Error, LocalizedError {
        case unsupportedFormat(String)
        case asset(String)
        case navigation(String)
        case timedOut
        case printing
        case invalidOutput(String)
        case busy
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let format): "Export to \(format.uppercased()) is not available."
            case .asset(let message): "A document asset could not be exported: \(message)"
            case .navigation(let message): "The document could not be prepared for export: \(message)"
            case .timedOut: "The document took too long to prepare for export."
            case .printing: "macOS could not create the PDF."
            case .invalidOutput(let format): "macOS returned an invalid \(format.uppercased()) document."
            case .busy: "This exporter is already preparing a document."
            }
        }
    }

    private var rendering: PDFRenderSession?
    private var isExporting = false
    private let math = SwiftMathBridge()

    func export(format: String, html: String, source: String, title: String, settings: LeafSettings, baseURL: URL?, to destination: URL) async throws {
        guard !isExporting else { throw ExportError.busy }
        isExporting = true
        defer { isExporting = false; rendering?.cancel(); rendering = nil }
        try Task.checkCancellation()
        let settings = settings.validated()
        guard ["html", "htm", "pdf", "docx"].contains(format.lowercased()) else { throw ExportError.unsupportedFormat(format) }
        let standalone = try await Self.embedAssets(in: html, baseURL: baseURL)
        try Task.checkCancellation()
        let printSource = ["pdf", "docx"].contains(format.lowercased()) ? Self.lightDiagrams(in: standalone) : standalone
        let prepared = Self.publicationHTML(printSource, source: source, title: title, settings: settings)
        let data: Data
        switch format.lowercased() {
        case "html", "htm": data = Data(prepared.utf8)
        case "pdf":
            let session = PDFRenderSession()
            rendering = session
            data = try await session.pdf(html: prepared, settings: settings, title: title)
            guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw ExportError.invalidOutput("pdf") }
        case "docx": data = try await officeDocument(html: prepared, title: title, settings: settings)
        default: throw ExportError.unsupportedFormat(format)
        }
        try Task.checkCancellation()
        try await Self.write(data, to: destination)
    }

    // Reads only explicit document image references. Every image is embedded, so
    // no WebKit directory grant, remote fetch, or companion asset folder is needed.
    nonisolated static func embedAssets(in html: String, baseURL: URL?, strict: Bool = true) async throws -> String {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            var result = html
            var embeddedBytes = 0
            let source = html as NSString
            let regex = try NSRegularExpression(pattern: "(?is)<img\\b[^>]*>")
            for match in regex.matches(in: html, range: NSRange(location: 0, length: source.length)).reversed() {
                try Task.checkCancellation()
                let tag = source.substring(with: match.range)
                guard let reference = Self.attribute("src", in: tag), !reference.isEmpty else { continue }
                let replacement: String
                if reference.lowercased().hasPrefix("data:") {
                    replacement = Self.replacingAttribute("srcset", value: nil, in: tag)
                } else if Self.isRemote(reference) {
                    let alt = Self.attribute("alt", in: tag) ?? "Remote image"
                    replacement = "<span class=\"leaf-unavailable-image\">[\(Self.escape(alt))]</span>"
                } else {
                    do {
                    guard let url = Self.localURL(reference, baseURL: baseURL) else { throw ExportError.asset(reference) }
                    let metadata = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard metadata.isRegularFile == true, (metadata.fileSize ?? 0) <= 50_000_000 else { throw ExportError.asset("\(url.lastPathComponent) is not an image file below 50 MB.") }
                    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                    embeddedBytes += bytes.count
                    guard embeddedBytes <= 100_000_000 else { throw ExportError.asset("Embedded images exceed 100 MB.") }
                    let mime = Self.mime(for: url.pathExtension)
                    let uri = "data:\(mime);base64,\(bytes.base64EncodedString())"
                    replacement = Self.replacingAttribute("srcset", value: nil, in: Self.replacingAttribute("src", value: uri, in: tag))
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if strict { throw error }
                        let alt = Self.attribute("alt",in:tag) ?? reference
                        replacement = "<span class=\"leaf-unavailable-image\">[Image unavailable: \(Self.escape(alt))]</span>"
                    }
                }
                guard let range = Range(match.range, in: result) else { throw ExportError.asset("Invalid image position.") }
                result.replaceSubrange(range, with: replacement)
            }
            // CSS from Leaf's render engine has only inline fonts. This also keeps
            // imported complete HTML from asking the native importer for a URL.
            result = result.replacingOccurrences(of: "(?is)<link\\b[^>]*>", with: "", options: .regularExpression)
            result = result.replacingOccurrences(of: "(?is)@import\\s+[^;]+;", with: "", options: .regularExpression)
            return result
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func officeDocument(html: String, title: String, settings: LeafSettings) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LeafOffice-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageBreakMarker = "LEAF-PAGE-BREAK-" + UUID().uuidString
        var rendered = html.replacingOccurrences(of: "(?is)<div\\b[^>]*class=[\"\'][^\"\']*\\bpage-break\\b[^\"\']*[\"\'][^>]*>\\s*</div>", with: "<p>\(pageBreakMarker)</p>", options: .regularExpression)
        var serial = 0
        func imageTag(_ image: NSImage, alt: String, display: Bool) throws -> String {
            serial += 1
            let width = min(max(1, image.size.width), Self.paperSize(settings).width - settings.pageMargin * 2)
            let ratio = width / max(1, image.size.width)
            let size = NSSize(width: width, height: max(1, image.size.height * ratio))
            let png = try Self.png(image, size: size)
            let url = directory.appendingPathComponent("image-\(serial).png")
            try png.write(to: url, options: .atomic)
            let tag = "<img src=\"\(Self.escape(url.absoluteString))\" width=\"\(Int(ceil(size.width)))\" height=\"\(Int(ceil(size.height)))\" alt=\"\(Self.escape(alt))\">"
            return display ? "<p style=\"text-align:center\">\(tag)</p>" : tag
        }
        // KaTeX includes the original TeX in an annotation. Turn the whole formula
        // into one native math attachment before the native HTML importer runs.
        let formulaRanges = Self.elements(in: rendered, matching: { tag in
            let classes = (Self.attribute("class", in: tag) ?? "").split(separator: " ")
            return classes.contains("katex") || classes.contains("katex-display")
        })
        for range in formulaRanges.reversed() {
            let fragment = (rendered as NSString).substring(with: range)
            guard let annotation = fragment.range(of: "(?is)<annotation\\b[^>]*encoding=[\"']application/x-tex[\"'][^>]*>(.*?)</annotation>", options: .regularExpression) else { continue }
            let markup = String(fragment[annotation])
            guard let open = markup.firstIndex(of: ">"), let close = markup.range(of: "</annotation>", options: .caseInsensitive) else { continue }
            let tex = Self.decode(String(markup[markup.index(after: open)..<close.lowerBound]))
            var theme = MarkdownEditorTheme.default
            theme.latexLightModeText = .black; theme.latexDarkModeText = .black
            let display = fragment.contains("katex-display")
            let replacement: String
            if let result = math.render(latex: tex, mode: display ? .display : .inline, fontSize: settings.bodySize, theme: theme) {
                replacement = try imageTag(result.image, alt: tex, display: display)
            } else { replacement = "<code>\(Self.escape(tex))</code>" }
            rendered = (rendered as NSString).replacingCharacters(in: range, with: replacement)
        }
        for range in Self.elements(in: rendered, matching: { $0.range(of: "^<svg\\b", options: [.regularExpression, .caseInsensitive]) != nil }).reversed() {
            let svg = (rendered as NSString).substring(with: range)
            guard let image = NSImage(data: Data(svg.utf8)) else { throw ExportError.asset("The diagram could not be converted for Word.") }
            rendered = (rendered as NSString).replacingCharacters(in: range, with: try imageTag(image, alt: "Diagram", display: true))
        }
        let images = try NSRegularExpression(pattern: "(?is)<img\\b[^>]*>")
        for match in images.matches(in: rendered, range: NSRange(location: 0, length: (rendered as NSString).length)).reversed() {
            let tag = (rendered as NSString).substring(with: match.range)
            guard let uri = Self.attribute("src", in: tag), uri.hasPrefix("data:"), let data = Self.dataURI(uri), let image = NSImage(data: data) else { continue }
            rendered = (rendered as NSString).replacingCharacters(in: match.range, with: try imageTag(image, alt: Self.attribute("alt", in: tag) ?? "Image", display: false))
        }
        // Native HTML import has no MathML renderer. All valid math and SVG has
        // become image content by this point; the text remains editable in Word.
        rendered = rendered.replacingOccurrences(of: "(?is)<style\\b[^>]*>.*?</style>", with: "", options: .regularExpression)
        let bodyFont = Self.font(settings.bodyFont, fallback: "Helvetica")
        let codeFont = Self.font(settings.codeFont, fallback: "Menlo")
        let style = "<style>body{font-family:'\(bodyFont)';font-size:\(settings.bodySize)px;color:#222}h1{font-size:2em}h2{font-size:1.6em}h3{font-size:1.3em}pre,code{font-family:'\(codeFont)'}table{border-collapse:collapse}td,th{border:1px solid #aaa;padding:6px}blockquote{color:#666}img{vertical-align:middle}</style>"
        rendered = Self.inject(style, into: rendered)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue, .baseURL: directory]
        let attributed = try NSAttributedString(data: Data(rendered.utf8), options: options, documentAttributes: nil)
        let paper = Self.paperSize(settings)
        let attributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.officeOpenXML, .title: title,
            .paperSize: paper, .leftMargin: settings.pageMargin, .rightMargin: settings.pageMargin,
            .topMargin: settings.pageMargin, .bottomMargin: settings.pageMargin
        ]
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: attributes)
        guard data.starts(with: [0x50, 0x4b]) else { throw ExportError.invalidOutput("docx") }
        return try await NativeWordPackage.complete(nativeData: data, attributed: attributed, settings: settings, pageBreakMarker: pageBreakMarker, in: directory)
    }

    nonisolated private static func lightDiagrams(in html: String) -> String {
        let palette = ["#1e1e1e": "#ffffff", "#e8e8e8": "#242424", "#aaaaaa": "#707070", "#bfbfbf": "#555555", "#2b2b2b": "#f5f5f5", "#393939": "#eaeaea", "#777777": "#b0b0b0", "#8aafd9": "#4b78b7"]
        var result = html
        for range in elements(in: html, matching: { $0.range(of: "^<svg\\b", options: [.regularExpression, .caseInsensitive]) != nil && (attribute("class", in: $0) ?? "").split(separator: " ").contains("pele") }).reversed() {
            var svg = (html as NSString).substring(with: range)
            if let attributes = try? NSRegularExpression(pattern: "(?is)\\s(fill|stroke|color|style)=\"([^\"]*)\"") {
                for match in attributes.matches(in: svg, range: NSRange(location: 0, length: (svg as NSString).length)).reversed() {
                    var value = (svg as NSString).substring(with: match.range(at: 2))
                    for (dark, light) in palette { value = value.replacingOccurrences(of: dark, with: light, options: .caseInsensitive) }
                    svg = (svg as NSString).replacingCharacters(in: match.range(at: 2), with: value)
                }
            }
            result = (result as NSString).replacingCharacters(in: range, with: svg)
        }
        return result
    }

    nonisolated private static func publicationHTML(_ html: String, source: String, title: String, settings: LeafSettings) -> String {
        var result = html
        if settings.exportTOC && !html.contains("class=\"leaf-toc\"") {
            let headings = MarkdownIndex(source: source).headings
            if !headings.isEmpty {
                let list = headings.map { "<li><a href=\"#\(escape($0.anchor))\">\(escape($0.title))</a></li>" }.joined()
                let toc = "<nav class=\"leaf-toc\" aria-label=\"Table of contents\"><h2>Contents</h2><ol>\(list)</ol></nav>"
                if let at = result.range(of: "<main>", options: .caseInsensitive) { result.insert(contentsOf: toc, at: at.upperBound) }
                else if let at = result.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) { result.insert(contentsOf: toc, at: at.upperBound) }
            }
        }
        let book = settings.exportProfile == "book"
        let report = settings.exportProfile == "report"
        let css = """
        <style id="leaf-publication-style">
        @page {size:\(settings.pageSize == "Letter" ? "letter" : "A4");margin:\(settings.pageMargin)pt}
        @media print {
          html,body{background:#fff!important;color:#222!important;color-scheme:light!important}
          body{padding:0!important;font-size:\(settings.bodySize * 0.75)pt!important;line-height:\(book ? 1.7 : 1.55)!important}
          main{max-width:none!important;margin:0!important}
          h1,h2,h3,h4,h5,h6{break-after:avoid;page-break-after:avoid;color:#222!important}
          p,li{orphans:3;widows:3}thead{display:table-header-group}tfoot{display:table-footer-group}
          tr,figure,img,pre,blockquote,.leaf-math,.leaf-callout{break-inside:avoid;page-break-inside:avoid}
          table{display:table!important;width:100%;font-size:.92em}pre{white-space:pre-wrap;overflow-wrap:anywhere}
          img{max-width:100%;max-height:\(paperSize(settings).height - settings.pageMargin * 2 - 30)pt;object-fit:contain}
          .leaf-toc{display:\(settings.exportTOC ? "block" : "none")!important}\(book ? ".leaf-toc{break-after:page}h1{break-before:page}main>h1:first-child{break-before:auto}" : "")
          \(report ? "h1{border-bottom:1px solid #bbb;padding-bottom:.3em}h2{border-bottom:1px solid #ddd;padding-bottom:.2em}" : "")
          .page-break{break-before:page;page-break-before:always;height:0;margin:0!important}
          a{color:#315e88!important}.leaf-diagram svg{max-width:100%;height:auto}
          .leaf-unavailable-image{font-style:italic;color:#777}
        }
        </style>
        """
        result = inject(css, into: result)
        return result
    }

    nonisolated private static func inject(_ head: String, into html: String) -> String {
        guard let at = html.range(of: "</head>", options: .caseInsensitive) else { return head + html }
        var result = html; result.insert(contentsOf: head, at: at.lowerBound); return result
    }
    nonisolated private static func paperSize(_ settings: LeafSettings) -> NSSize { settings.pageSize == "Letter" ? NSSize(width: 612, height: 792) : NSSize(width: 595.276, height: 841.89) }
    nonisolated private static func isRemote(_ reference: String) -> Bool {
        reference.hasPrefix("//") || reference.hasPrefix("\\\\") || URL(string: reference)?.scheme.map { !["file", "data"].contains($0.lowercased()) } == true
    }
    nonisolated private static func localURL(_ reference: String, baseURL: URL?) -> URL? {
        if reference.lowercased().hasPrefix("file:"), let url = URL(string: reference), url.isFileURL { return url.standardizedFileURL }
        let raw = reference.split(separator: "#", maxSplits: 1).first.map(String.init) ?? reference
        let path = decode(raw.removingPercentEncoding ?? raw)
        guard !path.isEmpty, path.hasPrefix("/") || baseURL != nil else { return nil }
        let directory = baseURL.map { URL(fileURLWithPath:$0.path,isDirectory:true) }
        return URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
    }
    nonisolated private static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "heic": "image/heic"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        default: "image/png"
        }
    }
    nonisolated private static func dataURI(_ value: String) -> Data? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[..<comma]
        let content = String(value[value.index(after: comma)...])
        return header.lowercased().contains(";base64") ? Data(base64Encoded: content) : content.removingPercentEncoding.map { Data($0.utf8) }
    }
    nonisolated private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)(?:^|\\s)\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for i in 1..<match.numberOfRanges where match.range(at: i).location != NSNotFound { return decode((tag as NSString).substring(with: match.range(at: i))) }
        return nil
    }
    nonisolated private static func replacingAttribute(_ name: String, value: String?, in tag: String) -> String {
        let pattern = "(?is)\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]+)"
        let cleaned = tag.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        guard let value, let end = cleaned.lastIndex(of: ">") else { return cleaned }
        var result = cleaned
        let insertion = result.index(before: end)
        result.insert(contentsOf: " \(name)=\"\(escape(value))\"", at: result[insertion] == "/" ? insertion : end)
        return result
    }
    nonisolated private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    nonisolated private static func decode(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: result, range: NSRange(location: 0, length: (result as NSString).length)).reversed() {
                let number = (result as NSString).substring(with: match.range(at: 1))
                if let raw = UInt32(number.hasPrefix("x") ? String(number.dropFirst()) : number, radix: number.hasPrefix("x") ? 16 : 10), let scalar = UnicodeScalar(raw) { result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar)) }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
    nonisolated private static func font(_ value: String, fallback: String) -> String {
        guard value != "System", value != "System Mono", value.range(of: "^[\\p{L}\\p{N} ._-]{1,100}$", options: .regularExpression) != nil else { return fallback }
        return value
    }
    nonisolated private static func elements(in html: String, matching predicate: (String) -> Bool) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: "(?is)</?([a-z][a-z0-9:-]*)\\b[^>]*>") else { return [] }
        let text = html as NSString
        let tags = regex.matches(in: html, range: NSRange(location: 0, length: text.length))
        var result: [NSRange] = [], selected: (name: String, start: Int, depth: Int)?
        for match in tags {
            let tag = text.substring(with: match.range), name = text.substring(with: match.range(at: 1)).lowercased()
            let closing = tag.hasPrefix("</")
            if var active = selected {
                if name == active.name {
                    active.depth += closing ? -1 : (tag.hasSuffix("/>") ? 0 : 1)
                    if active.depth == 0 { result.append(NSRange(location: active.start, length: NSMaxRange(match.range) - active.start)); selected = nil }
                    else { selected = active }
                }
            } else if !closing && predicate(tag) {
                if tag.hasSuffix("/>") { result.append(match.range) }
                else { selected = (name, match.range.location, 1) }
            }
        }
        return result
    }
    private static func png(_ image: NSImage, size: NSSize) throws -> Data {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw ExportError.asset("Invalid image dimensions.") }
        let scale = min(2, 4096 / max(size.width, size.height), sqrt(16_000_000 / (size.width * size.height)))
        let width = max(1, Int(ceil(size.width * scale))), height = max(1, Int(ceil(size.height * scale)))
        guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let graphics = NSGraphicsContext(bitmapImageRep: pixels) else { throw ExportError.asset("The image could not be drawn.") }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = pixels.representation(using: .png, properties: [:]) else { throw ExportError.asset("The image could not be encoded.") }
        return data
    }
    nonisolated private static func write(_ data: Data, to destination: URL) async throws {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try data.write(to: destination, options: .atomic)
        }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}

@MainActor private final class PDFRenderSession: NSObject, WKNavigationDelegate {
    private var view: WKWebView?
    private var window: NSWindow?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var deadline: Task<Void, Never>?
    private var printingContinuation: CheckedContinuation<Void, any Error>?
    private var operation: NSPrintOperation?

    func pdf(html: String, settings: LeafSettings, title: String) async throws -> Data {
        try Task.checkCancellation()
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let size = settings.pageSize == "Letter" ? NSSize(width: 612, height: 792) : NSSize(width: 595.276, height: 841.89)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: size.width - settings.pageMargin * 2, height: size.height), configuration: config)
        view.navigationDelegate = self
        self.view = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; window.isReleasedWhenClosed = false
        self.window = window
        defer { cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.continuation = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.complete(.failure(DocumentExporter.ExportError.timedOut))
                }
                view.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LeafPrint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("document.pdf")
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { throw DocumentExporter.ExportError.printing }
        info.paperSize = size; info.orientation = .portrait
        info.leftMargin = settings.pageMargin; info.rightMargin = settings.pageMargin
        info.topMargin = settings.pageMargin; info.bottomMargin = settings.pageMargin
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = false
        let operation = view.printOperation(with: info)
        operation.jobTitle = title; operation.showsPrintPanel = false; operation.showsProgressPanel = false
        operation.canSpawnSeparateThread = true
        self.operation = operation
        // WebKit calculates pagination on its secondary print thread. Running the
        // operation synchronously on the main thread treats NSIntegerMax preview
        // pages as a real range, so use the documented asynchronous print API.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.printingContinuation = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        try Task.checkCancellation()
        return try Data(contentsOf: output)
    }
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        // AppKit may deliver this selector on its secondary printing queue.
        Task { @MainActor [weak self] in self?.finishPrinting(success: success) }
    }
    private func finishPrinting(success: Bool) {
        self.operation = nil
        guard let continuation = printingContinuation else { return }
        printingContinuation = nil
        if success { continuation.resume() } else { continuation.resume(throwing: DocumentExporter.ExportError.printing) }
    }
    func cancel() {
        // NSPrintOperation has no safe public abort API. Keep WebKit alive until
        // its owned print callback completes; the caller then discards cancelled output.
        guard printingContinuation == nil else { return }
        view?.stopLoading(); view?.navigationDelegate = nil
        complete(.failure(CancellationError()))
        view = nil; window?.close(); window = nil
    }
    private func complete(_ result: Result<Void, any Error>) {
        deadline?.cancel(); deadline = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { complete(.failure(DocumentExporter.ExportError.navigation(error.localizedDescription))) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { complete(.failure(DocumentExporter.ExportError.navigation(error.localizedDescription))) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { complete(.failure(DocumentExporter.ExportError.navigation("The WebKit process stopped."))) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = action.request.url?.scheme?.lowercased()
        decisionHandler(action.navigationType == .other && (scheme == nil || scheme == "about") ? .allow : .cancel)
    }
}

@MainActor extension DocumentExporter {
    /// An integration seam for `Leaf --check-exports`; writes only inside the supplied directory.
    static func checkExports(in directory: URL) async throws -> [String] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let asset = NSImage(size: NSSize(width: 32, height: 20))
        asset.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 20).fill(); asset.unlockFocus()
        try png(asset, size: asset.size).write(to: directory.appendingPathComponent("local image.png"), options: .atomic)
        let paragraph = "A complete export preserves paragraphs, links, diagrams and mathematics. This paragraph is long enough to exercise native pagination with the selected paper and margins."
        let source = """
        # Export verification

        [Example link](https://example.com) and a local image:

        ![Local fixture](local%20image.png)

        | Feature | Status |
        | --- | --- |
        | Tables | Preserved |
        | Math | $x^2 + y^2 = z^2$ |

        ```mermaid
        flowchart LR
          Source[Markdown] --> Export[Export]
        ```

        $$
        \\frac{1}{2} + \\sqrt{x}
        $$

        ## Long section

        \((1...70).map { "Paragraph \($0). \(paragraph)\n" }.joined(separator: "\n"))

        <div class="page-break"></div>

        ## Final section

        FINAL-EXPORT-MARKER
        """
        var settings = LeafSettings()
        settings.pageSize = "Letter"; settings.pageMargin = 54; settings.exportProfile = "report"; settings.exportTOC = true
        let html = try await MarkupEngine().html(source, options: .init(title: "Export verification", includeTOC: true))
        let darkDiagram = try await DiagramEngine().render("flowchart LR\n A[\"#e8e8e8\"] --> B[Print]", theme: "dark")
        let printable = lightDiagrams(in: darkDiagram.svg)
        guard printable.contains("#e8e8e8</text>"), printable.contains("fill=\"#242424\""), NSImage(data: Data(printable.utf8)) != nil else { throw ExportError.invalidOutput("print diagram theme or label preservation") }
        let exporter = DocumentExporter()
        let htmlURL = directory.appendingPathComponent("verification.html")
        try await exporter.export(format: "html", html: html, source: source, title: "Export verification", settings: settings, baseURL: directory, to: htmlURL)
        let exportedHTML = try String(contentsOf: htmlURL, encoding: .utf8)
        guard exportedHTML.contains("data:image/png;base64,"), exportedHTML.contains("data:font/woff2;base64,"), exportedHTML.contains("FINAL-EXPORT-MARKER"), !exportedHTML.contains("src=\"local%20image.png\"") else { throw ExportError.invalidOutput("standalone html") }
        let pdfURL = directory.appendingPathComponent("verification.pdf")
        try await exporter.export(format: "pdf", html: html, source: source, title: "Export verification", settings: settings, baseURL: directory, to: pdfURL)
        guard let pdf = PDFDocument(url: pdfURL), pdf.pageCount >= 3,
              pdf.string?.contains("FINAL-EXPORT-MARKER") == true,
              let bounds = pdf.page(at: 0)?.bounds(for: .mediaBox), abs(bounds.width - 612) < 1, abs(bounds.height - 792) < 1 else { throw ExportError.invalidOutput("paginated Letter pdf") }
        let docxURL = directory.appendingPathComponent("verification.docx")
        try await exporter.export(format: "docx", html: html, source: source, title: "Export verification", settings: settings, baseURL: directory, to: docxURL)
        let word = try NSAttributedString(url: docxURL, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        var tables = 0
        word.enumerateAttributes(in: NSRange(location: 0, length: word.length)) { attributes, _, _ in
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle, !paragraph.textBlocks.isEmpty { tables += 1 }
        }
        guard word.string.contains("FINAL-EXPORT-MARKER"), word.string.contains("Tables"), tables > 0 else { throw ExportError.invalidOutput("docx text or table") }
        // The native Office importer drops DrawingML images and hyperlinks from
        // its attributed result, so inspect the actual package relationships too.
        let inspection = directory.appendingPathComponent("docx-inspection", isDirectory: true)
        if FileManager.default.fileExists(atPath: inspection.path) { try FileManager.default.removeItem(at: inspection) }
        try await ExportArchiveCommand().run("/usr/bin/ditto", ["-x", "-k", docxURL.path, inspection.path], in: directory)
        let xml = try XMLDocument(contentsOf: inspection.appendingPathComponent("word/document.xml"))
        let relationships = try XMLDocument(contentsOf: inspection.appendingPathComponent("word/_rels/document.xml.rels"))
        let pictures = try xml.nodes(forXPath: "//*[local-name()='blip']/@*[local-name()='embed']")
        let hyperlinks = try xml.nodes(forXPath: "//*[local-name()='hyperlink']/@*[local-name()='id']")
        let pageBreaks = try xml.nodes(forXPath: "//*[local-name()='br'][@*[local-name()='type']='page']")
        let relationElements = relationships.rootElement()?.elements(forName: "Relationship") ?? []
        let relationIDs = Set(relationElements.compactMap { $0.attribute(forName: "Id")?.stringValue })
        guard pictures.count >= 3, !hyperlinks.isEmpty, !pageBreaks.isEmpty, (pictures + hyperlinks).allSatisfy({ relationIDs.contains($0.stringValue ?? "") }) else { throw ExportError.invalidOutput("docx image/link relationships") }
        for relation in relationElements where relation.attribute(forName: "Type")?.stringValue?.hasSuffix("/image") == true {
            guard let target = relation.attribute(forName: "Target")?.stringValue, let image = NSImage(contentsOf: inspection.appendingPathComponent("word").appendingPathComponent(target)), image.size.width > 0 else { throw ExportError.invalidOutput("docx image payload") }
        }
        settings.pageSize = "A4"; settings.exportProfile = "book"
        let a4URL = directory.appendingPathComponent("verification-a4.pdf")
        try await exporter.export(format: "pdf", html: html, source: source, title: "Export verification", settings: settings, baseURL: directory, to: a4URL)
        guard let a4 = PDFDocument(url: a4URL), let size = a4.page(at: 0)?.bounds(for: .mediaBox), abs(size.width - 595.276) < 1, abs(size.height - 841.89) < 1,
              a4.string?.contains("FINAL-EXPORT-MARKER") == true else { throw ExportError.invalidOutput("A4 book pdf") }
        let protected = directory.appendingPathComponent("failure-preservation.html")
        let original = Data("KEEP-EXISTING-EXPORT".utf8)
        try original.write(to: protected, options: .atomic)
        let missing = try await MarkupEngine().html("![Missing](missing-image.png)")
        do {
            try await exporter.export(format: "html", html: missing, source: "", title: "Missing", settings: settings, baseURL: directory, to: protected)
            throw ExportError.invalidOutput("missing-asset rejection")
        } catch is CocoaError { }
        let cancelled = Task { @MainActor in
            try await exporter.export(format: "html", html: html, source: source, title: "Cancelled", settings: settings, baseURL: directory, to: protected)
        }
        cancelled.cancel()
        do { try await cancelled.value; throw ExportError.invalidOutput("cancellation rejection") }
        catch is CancellationError { }
        guard try Data(contentsOf: protected) == original else { throw ExportError.invalidOutput("failure preservation") }
        return ["Standalone HTML: local image and offline fonts embedded.", "Letter PDF: \(pdf.pageCount) pages, full final text and selected page bounds.", "DOCX: editable text, native table, \(pictures.count) packaged images and hyperlink relationships.", "A4 book PDF: \(a4.pageCount) pages and full final text.", "Failure/cancellation preserve an existing destination."]
    }
}

/// AppKit's OfficeOpenXML writer preserves text but drops tables, links and
/// attachments on current macOS. Keep its metadata/base package and serialize
/// those native attributed-string semantics into standard WordprocessingML.
@MainActor private enum NativeWordPackage {
    private struct Cell {
        let block: NSTextTableBlock
        var ranges: [NSRange]
    }
    static func complete(nativeData: Data, attributed: NSAttributedString, settings: LeafSettings, pageBreakMarker: String, in directory: URL) async throws -> Data {
        let base = directory.appendingPathComponent("native.docx"), package = directory.appendingPathComponent("package", isDirectory: true)
        try nativeData.write(to: base, options: .atomic)
        try await ExportArchiveCommand().run("/usr/bin/ditto", ["-x", "-k", base.path, package.path], in: directory)
        let media = package.appendingPathComponent("word/media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let writer = WordContent(attributed: attributed, settings: settings, media: media, pageBreakMarker: pageBreakMarker)
        let document = try writer.document()
        try Data(document.utf8).write(to: package.appendingPathComponent("word/document.xml"), options: .atomic)
        let relationshipsURL = package.appendingPathComponent("word/_rels/document.xml.rels")
        let relationships = try XMLDocument(contentsOf: relationshipsURL)
        guard let root = relationships.rootElement() else { throw DocumentExporter.ExportError.invalidOutput("docx relationships") }
        for relation in writer.relationships {
            let element = XMLElement(name: "Relationship")
            element.setAttributesWith(relation)
            root.addChild(element)
        }
        try relationships.xmlData.write(to: relationshipsURL, options: .atomic)
        let typesURL = package.appendingPathComponent("[Content_Types].xml")
        let types = try XMLDocument(contentsOf: typesURL)
        guard let typesRoot = types.rootElement() else { throw DocumentExporter.ExportError.invalidOutput("docx content types") }
        if typesRoot.elements(forName: "Default").allSatisfy({ $0.attribute(forName: "Extension")?.stringValue != "png" }) {
            let type = XMLElement(name: "Default")
            type.setAttributesWith(["Extension": "png", "ContentType": "image/png"])
            typesRoot.addChild(type)
        }
        try types.xmlData.write(to: typesURL, options: .atomic)
        let output = directory.appendingPathComponent("complete.docx")
        try Task.checkCancellation()
        try await ExportArchiveCommand().run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", package.path, output.path], in: directory)
        let data = try Data(contentsOf: output)
        guard data.starts(with: [0x50, 0x4b]) else { throw DocumentExporter.ExportError.invalidOutput("docx package") }
        return data
    }

    @MainActor private final class WordContent {
        let attributed: NSAttributedString
        let settings: LeafSettings
        let media: URL
        let text: NSString
        let pageBreakMarker: String
        var chapterCount = 0
        var relationships: [[String: String]] = []
        var serial = 0
        init(attributed: NSAttributedString, settings: LeafSettings, media: URL, pageBreakMarker: String) {
            self.attributed = attributed; self.settings = settings; self.media = media; self.pageBreakMarker = pageBreakMarker; text = attributed.string as NSString
        }
        func document() throws -> String {
            var body = "", cursor = 0, table: NSTextTable?, cells: [String: Cell] = [:]
            func flush() throws {
                guard let active = table else { return }
                body += try tableXML(active, cells: cells)
                table = nil; cells = [:]
            }
            while cursor < text.length {
                try Task.checkCancellation()
                var effective = NSRange()
                let style = attributed.attribute(.paragraphStyle, at: cursor, longestEffectiveRange: &effective, in: NSRange(location: cursor, length: text.length - cursor)) as? NSParagraphStyle
                effective = NSIntersectionRange(effective, NSRange(location: cursor, length: text.length - cursor))
                guard effective.length > 0 else { throw DocumentExporter.ExportError.invalidOutput("docx paragraph range") }
                if let block = style?.textBlocks.last as? NSTextTableBlock {
                    if let active = table, active !== block.table { try flush() }
                    table = block.table
                    let key = "\(block.startingRow):\(block.startingColumn)"
                    if var cell = cells[key] { cell.ranges.append(effective); cells[key] = cell }
                    else { cells[key] = Cell(block: block, ranges: [effective]) }
                    cursor = NSMaxRange(effective)
                } else {
                    try flush()
                    let paragraph = NSIntersectionRange(text.paragraphRange(for: NSRange(location: cursor, length: 0)), effective)
                    body += try paragraphXML(paragraph, style: style)
                    cursor = NSMaxRange(paragraph)
                }
            }
            try flush()
            let size = settings.pageSize == "Letter" ? NSSize(width: 612, height: 792) : NSSize(width: 595.276, height: 841.89)
            let margin = Int((settings.pageMargin * 20).rounded())
            body += "<w:sectPr><w:pgSz w:w=\"\(Int((size.width * 20).rounded()))\" w:h=\"\(Int((size.height * 20).rounded()))\"/><w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\" w:header=\"360\" w:footer=\"360\" w:gutter=\"0\"/></w:sectPr>"
            return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\"><w:body>\(body)</w:body></w:document>"
        }
        private func tableXML(_ table: NSTextTable, cells: [String: Cell]) throws -> String {
            guard table.numberOfColumns > 0, table.numberOfColumns <= 63 else { throw DocumentExporter.ExportError.invalidOutput("Word tables support up to 63 columns") }
            let columns = Int(table.numberOfColumns)
            let paperWidth = settings.pageSize == "Letter" ? 612.0 : 595.276
            let columnWidth = max(240, Int(((paperWidth - settings.pageMargin * 2) * 20) / Double(columns)))
            let rowCount = cells.values.map { $0.block.startingRow + $0.block.rowSpan }.max() ?? 0
            guard rowCount <= 10_000 else { throw DocumentExporter.ExportError.invalidOutput("docx table size") }
            var rows = ""
            for row in 0..<rowCount {
                var column = 0, content = ""
                while column < columns {
                    if let cell = cells["\(row):\(column)"] {
                        let span = min(columns - column, max(1, cell.block.columnSpan))
                        let properties = "<w:tcW w:w=\"0\" w:type=\"auto\"/>" + (span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "") + (cell.block.rowSpan > 1 ? "<w:vMerge w:val=\"restart\"/>" : "")
                        var paragraphs = ""
                        for range in cell.ranges {
                            var cursor = range.location
                            while cursor < NSMaxRange(range) {
                                let paragraph = NSIntersectionRange(text.paragraphRange(for: NSRange(location: cursor, length: 0)), NSRange(location: cursor, length: NSMaxRange(range) - cursor))
                                paragraphs += try paragraphXML(paragraph, style: attributed.attribute(.paragraphStyle, at: cursor, effectiveRange: nil) as? NSParagraphStyle)
                                cursor = NSMaxRange(paragraph)
                            }
                        }
                        content += "<w:tc><w:tcPr>\(properties)</w:tcPr>\(paragraphs.isEmpty ? "<w:p/>" : paragraphs)</w:tc>"
                        column += span
                    } else if let previous = cells.values.first(where: { $0.block.startingColumn == column && $0.block.startingRow < row && $0.block.startingRow + $0.block.rowSpan > row }) {
                        let span = min(columns - column, max(1, previous.block.columnSpan))
                        content += "<w:tc><w:tcPr>\(span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : "")<w:vMerge/></w:tcPr><w:p/></w:tc>"
                        column += span
                    } else { content += "<w:tc><w:p/></w:tc>"; column += 1 }
                }
                rows += "<w:tr>\(content)</w:tr>"
            }
            let borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"BBBBBB\"/>" }.joined()
            return "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>\(borders)</w:tblBorders></w:tblPr><w:tblGrid>\(String(repeating: "<w:gridCol w:w=\"\(columnWidth)\"/>", count: columns))</w:tblGrid>\(rows)</w:tbl>"
        }
        private func paragraphXML(_ input: NSRange, style: NSParagraphStyle?) throws -> String {
            if text.substring(with: input).contains(pageBreakMarker) { return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>" }
            var range = input
            while range.length > 0, [9, 10, 13].contains(Int(text.character(at: NSMaxRange(range) - 1))) { range.length -= 1 }
            var props = ""
            if let style {
                let align: String? = switch style.alignment { case .center: "center"; case .right: "right"; case .justified: "both"; default: nil }
                if let align { props += "<w:jc w:val=\"\(align)\"/>" }
                if style.headerLevel > 0 { props += "<w:outlineLvl w:val=\"\(min(8, style.headerLevel - 1))\"/><w:keepNext/>" }
                if style.headerLevel == 1 {
                    if settings.exportProfile == "book" && (chapterCount > 0 || settings.exportTOC) { props += "<w:pageBreakBefore/>" }
                    chapterCount += 1
                }
                if settings.exportProfile == "report" && [1, 2].contains(style.headerLevel) { props += "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"4\" w:color=\"BBBBBB\"/></w:pBdr>" }
                props += "<w:spacing w:before=\"\(max(0, Int(style.paragraphSpacingBefore * 20)))\" w:after=\"\(max(0, Int(style.paragraphSpacing * 20)))\"/>"
                if style.headIndent > 0 { props += "<w:ind w:left=\"\(Int(style.headIndent * 20))\"/>" }
            }
            var content = ""
            var error: (any Error)?
            attributed.enumerateAttributes(in: range) { attrs, part, stop in
                do { content += try runXML(part, attributes: attrs) }
                catch let failure { error = failure; stop.pointee = true }
            }
            if let error { throw error }
            return "<w:p>\(props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>")\(content)</w:p>"
        }
        private func runXML(_ range: NSRange, attributes: [NSAttributedString.Key: Any]) throws -> String {
            if let attachment = attributes[.attachment] as? NSTextAttachment { return try imageXML(attachment) }
            var properties = ""
            if let font = attributes[.font] as? NSFont {
                let name = escape(font.familyName ?? font.fontName)
                properties += "<w:rFonts w:ascii=\"\(name)\" w:hAnsi=\"\(name)\"/><w:sz w:val=\"\(Int((font.pointSize * 2).rounded()))\"/>"
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { properties += "<w:b/>" }
                if traits.contains(.italicFontMask) { properties += "<w:i/>" }
            }
            if let color = attributes[.foregroundColor] as? NSColor, let value = hex(color) { properties += "<w:color w:val=\"\(value)\"/>" }
            if let color = attributes[.backgroundColor] as? NSColor, color.alphaComponent > 0.01, let value = hex(color) { properties += "<w:shd w:fill=\"\(value)\"/>" }
            if (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0 != 0 { properties += "<w:u w:val=\"single\"/>" }
            if (attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0 != 0 { properties += "<w:strike/>" }
            let value = text.substring(with: range)
            let textRuns = value.components(separatedBy: .newlines).map { part in part.components(separatedBy: "\t").map { "<w:t xml:space=\"preserve\">\(escape($0))</w:t>" }.joined(separator: "<w:tab/>") }.joined(separator: "<w:br/>")
            let run = "<w:r>\(properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>")\(textRuns)</w:r>"
            if let link = attributes[.link] {
                let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                guard !target.isEmpty else { return run }
                serial += 1; let id = "rLeafLink\(serial)"
                relationships.append(["Id": id, "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink", "Target": target, "TargetMode": "External"])
                return "<w:hyperlink r:id=\"\(id)\">\(run)</w:hyperlink>"
            }
            return run
        }
        private func imageXML(_ attachment: NSTextAttachment) throws -> String {
            let bytes = attachment.fileWrapper?.regularFileContents ?? attachment.contents
            guard let image = attachment.image ?? bytes.flatMap(NSImage.init(data:)) else { throw DocumentExporter.ExportError.asset("A Word image attachment could not be read.") }
            serial += 1
            let cellSize = attachment.attachmentCell?.cellSize() ?? image.size
            let rawSize = attachment.bounds.size.width > 0 ? attachment.bounds.size : cellSize
            let maxWidth = (settings.pageSize == "Letter" ? 612.0 : 595.276) - settings.pageMargin * 2
            let ratio = min(1, maxWidth / max(1, rawSize.width))
            let size = NSSize(width: max(1, rawSize.width * ratio), height: max(1, rawSize.height * ratio))
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw DocumentExporter.ExportError.asset("A Word attachment could not be encoded.") }
            let name = "image-\(serial).png", id = "rLeafImage\(serial)"
            try png.write(to: media.appendingPathComponent(name), options: .atomic)
            relationships.append(["Id": id, "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "Target": "media/\(name)"])
            let cx = Int((size.width * 12700).rounded()), cy = Int((size.height * 12700).rounded())
            return """
            <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(serial)" name="\(name)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(serial)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
            """
        }
        private func hex(_ color: NSColor) -> String? {
            guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
            return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        private func escape(_ value: String) -> String {
            String(value.unicodeScalars.filter { $0.value >= 32 || [9, 10, 13].contains($0.value) }).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
    }
}

@MainActor private final class ExportArchiveCommand {
    private var process: Process?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var timeout: Task<Void, Never>?
    private var failure: (any Error)?
    private var cancellationDeadline: Task<Void, Never>?
    func run(_ executable: String, _ arguments: [String], in directory: URL) async throws {
        let log = directory.appendingPathComponent("archive-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory; process.standardOutput = handle; process.standardError = handle
        self.process = process
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                self.continuation = continuation
                process.terminationHandler = { [weak self] completed in
                    let status = completed.terminationStatus
                    Task { @MainActor in self?.finish(status: status) }
                }
                do {
                    try process.run()
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(20)) } catch { return }
                        self?.stop(DocumentExporter.ExportError.timedOut)
                    }
                } catch { finish(error) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.stop(CancellationError()) } }
        try Task.checkCancellation()
    }
    private func stop(_ error: any Error) {
        failure = error
        guard let process, process.isRunning else { finish(error); return }
        process.terminate()
        cancellationDeadline = Task { [weak self, weak process] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            self?.finish(error)
        }
    }
    private func finish(status: Int32) {
        if let failure { finish(failure) }
        else if status == 0 { finish(nil) }
        else { finish(DocumentExporter.ExportError.asset("The system archive tool exited with status \(status).")) }
    }
    private func finish(_ error: (any Error)?) {
        timeout?.cancel(); timeout = nil
        cancellationDeadline?.cancel(); cancellationDeadline = nil
        guard let continuation else { return }
        self.continuation = nil; process = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}
