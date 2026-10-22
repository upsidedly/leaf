import Foundation
import CryptoKit
import Darwin

public struct PublicationHeading: Hashable, Sendable {
    public let title: String
    public let level: Int
    public let anchor: String

    public init(title: String, level: Int, anchor: String) {
        self.title = title; self.level = min(6, max(1, level)); self.anchor = anchor
    }
}

public enum PublicationError: LocalizedError, Sendable {
    case invalidHTML(String)
    case unavailableAsset(String)
    case unsupportedAsset(String)
    case invalidArchive(String)
    case processFailed(String)
    case timedOut
    case tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidHTML(let reason): return "The publication HTML is invalid: \(reason)"
        case .unavailableAsset(let name): return "The publication asset could not be included: \(name)"
        case .unsupportedAsset(let name): return "This publication asset format is not supported: \(name)"
        case .invalidArchive(let reason): return "The EPUB could not be verified: \(reason)"
        case .processFailed(let reason): return "The publication archive could not be created: \(reason)"
        case .timedOut: return "Creating the publication archive took too long."
        case .tooLarge: return "The publication exceeds the export size limit."
        }
    }
}

/// Builds one offline EPUB 3 publication from already-rendered HTML. All work is
/// staged privately; a previous destination is replaced only after verification.
public actor PublicationArchive {
    public init() {}

    public func epub(html: String, title: String, author: String = "", baseURL: URL?, to destination: URL) async throws {
        try await epub(html: html, title: title, author: author, baseURL: baseURL, headings: [], to: destination)
    }

    /// Explicit headings must identify elements in the rendered document. With
    /// an empty array, h1–h6 elements supply the navigation automatically.
    public func epub(html: String, title: String, author: String = "", baseURL: URL?, headings: [PublicationHeading], to destination: URL) async throws {
        try Task.checkCancellation()
        guard destination.isFileURL, !destination.hasDirectoryPath else {
            throw PublicationError.invalidArchive("Choose a destination file.")
        }
        guard html.utf8.count <= PublicationLimits.resourceBytes else { throw PublicationError.tooLarge }
        let manager = FileManager.default
        let stage = manager.temporaryDirectory.appendingPathComponent("leaf-epub-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stage.appendingPathComponent("EPUB/assets"), withIntermediateDirectories: true)
        try manager.createDirectory(at: stage.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title
        let document = try PublicationHTML.document(html, title: normalizedTitle)
        let content = try PublicationHTML.headings(in: document, requested: headings)
        let assets = PublicationAssets(directory: stage.appendingPathComponent("EPUB/assets"), baseURL: baseURL)
        try assets.rewrite(document: document)
        let xhtml = document.xmlData(options: [.nodeCompactEmptyElement])
        try PublicationXML.validate(xhtml, named: "content.xhtml")
        try xhtml.write(to: stage.appendingPathComponent("EPUB/content.xhtml"))

        let language = document.rootElement()?.attribute(forName: "lang")?.stringValue ?? "en"
        let identifier = "urn:sha256:" + SHA256.hash(data: xhtml + Data((normalizedTitle + "\n" + author).utf8)).map { String(format: "%02x", $0) }.joined()
        let modified = ISO8601DateFormatter().string(from: Date())
        let properties = PublicationHTML.elements(in: document).reduce(into: Set<String>()) { result, element in
            if element.localName?.lowercased() == "svg" { result.insert("svg") }
            if element.localName?.lowercased() == "math" { result.insert("mathml") }
        }.sorted().joined(separator: " ")
        let manifest = assets.entries.sorted { $0.path < $1.path }.enumerated().map { index, item in
            "<item id=\"asset-\(index)\" href=\"\(PublicationXML.escape(item.path))\" media-type=\"\(item.mediaType)\"/>"
        }.joined(separator: "\n")
        let creator = author.isEmpty ? "" : "<dc:creator>\(PublicationXML.escape(author))</dc:creator>"
        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="publication-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="publication-id">\(identifier)</dc:identifier>
            <dc:title>\(PublicationXML.escape(normalizedTitle))</dc:title><dc:language>\(PublicationXML.escape(language))</dc:language>
            \(creator)<meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest><item id="content" href="content.xhtml" media-type="application/xhtml+xml"\(properties.isEmpty ? "" : " properties=\"\(properties)\"")/>
            <item id="navigation" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(manifest)
          </manifest><spine><itemref idref="content"/></spine>
        </package>
        """
        let navigation = PublicationHTML.navigation(title: normalizedTitle, language: language, headings: content)
        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
        for (path, text) in [("EPUB/package.opf", opf), ("EPUB/nav.xhtml", navigation), ("META-INF/container.xml", container)] {
            let data = Data(text.utf8)
            try PublicationXML.validate(data, named: path)
            try data.write(to: stage.appendingPathComponent(path))
        }
        try Data("application/epub+zip".utf8).write(to: stage.appendingPathComponent("mimetype"))
        let archive = stage.appendingPathComponent("publication.epub")
        // -X excludes extended attributes/extra fields; OCF requires mimetype
        // first, uncompressed, with no extra field in its local ZIP header.
        _ = try await PublicationProcess.run("/usr/bin/zip", ["-X", "-0", "-q", archive.path, "mimetype"], directory: stage)
        let paths = ["META-INF/container.xml", "EPUB/package.opf", "EPUB/nav.xhtml", "EPUB/content.xhtml"] + assets.entries.map { "EPUB/" + $0.path }.sorted()
        _ = try await PublicationProcess.run("/usr/bin/zip", ["-X", "-9", "-q", archive.path] + paths, directory: stage)
        _ = try await PublicationChecks.verifyEPUB(at: archive)
        try Task.checkCancellation()
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard data.count <= PublicationLimits.archiveBytes else { throw PublicationError.tooLarge }
        try data.write(to: destination, options: .atomic)
    }
}

enum PublicationLimits {
    static let resourceBytes = 32 * 1024 * 1024
    static let archiveBytes = 128 * 1024 * 1024
    static let files = 512
}

enum PublicationXML {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func validate(_ data: Data, named name: String) throws {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw PublicationError.invalidHTML("\(name): \(parser.parserError?.localizedDescription ?? "Malformed XML")") }
    }

    static func parse(_ data: Data, named name: String) throws -> XMLDocument {
        try validate(data, named: name)
        return try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
    }
}

private enum PublicationHTML {
    static func elements(in node: XMLNode) -> [XMLElement] {
        var result: [XMLElement] = []
        if let element = node as? XMLElement { result.append(element) }
        for child in node.children ?? [] { result.append(contentsOf: elements(in: child)) }
        return result
    }

    static func document(_ html: String, title: String) throws -> XMLDocument {
        let options: XMLNode.Options = [.nodeLoadExternalEntitiesNever]
        // XMLSerializer output takes this lossless path, including SVG/MathML.
        let document: XMLDocument
        if let strict = try? XMLDocument(xmlString: html, options: options), strict.rootElement()?.localName?.lowercased() == "html" {
            document = strict
        } else {
            // Apple's HTML repair predates SVG/MathML. Preserve these islands
            // separately rather than silently dropping rendered diagrams/math.
            var repaired = html
            var islands: [String: String] = [:]
            let regex = try NSRegularExpression(pattern: #"<(svg|math)\b[\s\S]*?</\1\s*>"#, options: [.caseInsensitive])
            let ns = repaired as NSString
            for match in regex.matches(in: repaired, range: NSRange(location: 0, length: ns.length)).reversed() {
                let key = "leaf-foreign-\(UUID().uuidString)"
                islands[key] = ns.substring(with: match.range)
                repaired = (repaired as NSString).replacingCharacters(in: match.range, with: "<div data-leaf-foreign=\"\(key)\"></div>")
            }
            document = try XMLDocument(xmlString: repaired, options: options.union(.documentTidyHTML))
            for element in elements(in: document) {
                guard let key = element.attribute(forName: "data-leaf-foreign")?.stringValue, let source = islands[key] else { continue }
                let island = try PublicationXML.parse(Data(source.utf8), named: "Inline SVG/MathML")
                guard let replacement = island.rootElement(), let parent = element.parent as? XMLElement else { continue }
                replacement.detach()
                parent.replaceChild(at: element.index, with: replacement)
            }
        }
        document.dtd = nil
        document.version = "1.0"; document.characterEncoding = "UTF-8"
        guard let root = document.rootElement(), root.localName?.lowercased() == "html" else {
            throw PublicationError.invalidHTML("A document body is required.")
        }
        if root.attribute(forName: "lang") == nil {
            root.addAttribute(XMLNode.attribute(withName: "lang", stringValue: "en") as! XMLNode)
        }
        root.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/1999/xhtml") as! XMLNode)
        let all = elements(in: document)
        for element in all.reversed() {
            let name = element.localName?.lowercased() ?? ""
            if ["script", "iframe", "base", "noscript"].contains(name) { element.detach(); continue }
            for attribute in element.attributes ?? [] where attribute.name?.lowercased().hasPrefix("on") == true { attribute.detach() }
            if name == "meta", element.attribute(forName: "http-equiv") != nil { element.detach() }
            if name == "img", element.attribute(forName: "alt") == nil { element.addAttribute(XMLNode.attribute(withName: "alt", stringValue: "") as! XMLNode) }
            if name == "svg", element.namespace(forPrefix: "")?.stringValue != "http://www.w3.org/2000/svg" {
                element.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/2000/svg") as! XMLNode)
            }
            if name == "math", element.namespace(forPrefix: "")?.stringValue != "http://www.w3.org/1998/Math/MathML" {
                element.addNamespace(XMLNode.namespace(withName: "", stringValue: "http://www.w3.org/1998/Math/MathML") as! XMLNode)
            }
        }
        let head = root.elements(forName: "head").first ?? XMLElement(name: "head")
        if head.parent == nil { root.insertChild(head, at: 0) }
        for old in head.elements(forName: "title") { old.detach() }
        head.addChild(XMLElement(name: "title", stringValue: title))
        guard !root.elements(forName: "body").isEmpty else { throw PublicationError.invalidHTML("A document body is required.") }
        return document
    }

    static func headings(in document: XMLDocument, requested: [PublicationHeading]) throws -> [PublicationHeading] {
        let all = elements(in: document)
        var used = Set(all.compactMap { $0.attribute(forName: "id")?.stringValue })
        let nodes = all.filter { element in
            guard let name = element.localName?.lowercased(), name.count == 2, name.first == "h", let level = name.last?.wholeNumberValue else { return false }
            return (1...6).contains(level)
        }
        var derived: [PublicationHeading] = []
        for element in nodes {
            let title = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            var anchor = element.attribute(forName: "id")?.stringValue ?? ""
            if anchor.isEmpty {
                let base = MarkdownIndex.anchor(for: title).isEmpty ? "section" : MarkdownIndex.anchor(for: title)
                anchor = base
                var suffix = 1
                while used.contains(anchor) { anchor = "\(base)-\(suffix)"; suffix += 1 }
                element.addAttribute(XMLNode.attribute(withName: "id", stringValue: anchor) as! XMLNode)
                used.insert(anchor)
            }
            derived.append(.init(title: title, level: element.localName?.last?.wholeNumberValue ?? 1, anchor: anchor))
        }
        for heading in requested where !used.contains(heading.anchor) || heading.anchor.isEmpty {
            throw PublicationError.invalidHTML("The table of contents target ‘\(heading.anchor)’ is missing.")
        }
        return requested.isEmpty ? derived : requested
    }

    private final class NavigationNode {
        let heading: PublicationHeading
        var children: [NavigationNode] = []
        init(_ heading: PublicationHeading) { self.heading = heading }
    }

    static func navigation(title: String, language: String, headings: [PublicationHeading]) -> String {
        var roots: [NavigationNode] = [], stack: [NavigationNode] = []
        for heading in headings {
            while let last = stack.last, last.heading.level >= heading.level { stack.removeLast() }
            let node = NavigationNode(heading)
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        func list(_ nodes: [NavigationNode]) -> String {
            "<ol>" + nodes.map { node in
                let fragment = node.heading.anchor.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.subtracting(CharacterSet(charactersIn: "#"))) ?? node.heading.anchor
                return "<li><a href=\"content.xhtml#\(PublicationXML.escape(fragment))\">\(PublicationXML.escape(node.heading.title))</a>\(node.children.isEmpty ? "" : list(node.children))</li>"
            }.joined() + "</ol>"
        }
        let links = roots.isEmpty ? "<ol><li><a href=\"content.xhtml\">\(PublicationXML.escape(title))</a></li></ol>" : list(roots)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(PublicationXML.escape(language))"><head><title>\(PublicationXML.escape(title))</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1>\(links)</nav></body></html>
        """
    }
}

private final class PublicationAssets {
    struct Entry { let path: String; let mediaType: String }
    let directory: URL
    let baseURL: URL?
    var entries: [Entry] = []
    private var included: [String: String] = [:]
    private var totalBytes = 0

    init(directory: URL, baseURL: URL?) {
        self.directory = directory
        if let baseURL {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: baseURL.path, isDirectory: &isDirectory)
            self.baseURL = baseURL.hasDirectoryPath || (exists && isDirectory.boolValue) ? baseURL : baseURL.deletingLastPathComponent()
        } else { self.baseURL = nil }
    }

    func rewrite(document: XMLDocument) throws {
        for element in PublicationHTML.elements(in: document) {
            let name = element.localName?.lowercased() ?? ""
            let attributes: [String]
            switch name {
            case "img", "audio", "video", "source", "track": attributes = ["src", "poster"]
            case "image", "use": attributes = ["href", "xlink:href"]
            case "object": attributes = ["data"]
            case "link": attributes = element.attribute(forName: "rel")?.stringValue?.lowercased() == "stylesheet" ? ["href"] : []
            default: attributes = []
            }
            for name in attributes {
                guard let attribute = element.attribute(forName: name), let reference = attribute.stringValue, !reference.isEmpty else { continue }
                attribute.stringValue = try include(reference, relativeTo: baseURL, fromAsset: false)
            }
            // A portable single source avoids unbundled responsive alternatives.
            element.removeAttribute(forName: "srcset")
            if let style = element.attribute(forName: "style"), let css = style.stringValue { style.stringValue = try rewriteCSS(css, relativeTo: baseURL, fromAsset: false) }
            if name == "style" { element.stringValue = try rewriteCSS(element.stringValue ?? "", relativeTo: baseURL, fromAsset: false) }
        }
    }

    private func include(_ reference: String, relativeTo base: URL?, fromAsset: Bool) throws -> String {
        if reference.hasPrefix("#") { return reference }
        let data: Data, mediaType: String, suffix: String, resourceBase: URL?, key: String
        let fragment = URLComponents(string: reference)?.percentEncodedFragment.map { "#" + $0 } ?? ""
        if reference.lowercased().hasPrefix("data:") {
            guard let comma = reference.firstIndex(of: ",") else { throw PublicationError.unavailableAsset("Malformed inline image") }
            let header = String(reference[reference.index(reference.startIndex, offsetBy: 5)..<comma])
            let payload = String(reference[reference.index(after: comma)...])
            mediaType = String(header.split(separator: ";").first ?? "").lowercased()
            guard let ext = Self.extensions[mediaType] else { throw PublicationError.unsupportedAsset(mediaType) }
            suffix = ext; resourceBase = base
            if header.lowercased().contains(";base64") {
                guard let decoded = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { throw PublicationError.unavailableAsset("Malformed inline image") }
                data = decoded
            } else {
                guard let decoded = payload.removingPercentEncoding else { throw PublicationError.unavailableAsset("Malformed inline image") }
                data = Data(decoded.utf8)
            }
            key = "data:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ":" + mediaType
        } else {
            guard let url = URL(string: reference, relativeTo: base)?.absoluteURL, url.isFileURL else {
                throw PublicationError.unavailableAsset("\(reference) (offline export needs a local file)")
            }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)
            parts?.fragment = nil; parts?.query = nil
            let file = (parts?.url ?? url).standardizedFileURL
            key = file.path
            if let path = included[key] { return (fromAsset ? "" : "assets/") + path + fragment }
            guard let type = Self.mediaTypes[file.pathExtension.lowercased()] else { throw PublicationError.unsupportedAsset(file.lastPathComponent) }
            mediaType = type; suffix = Self.extensions[type] ?? file.pathExtension.lowercased()
            let values: URLResourceValues
            do { values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) }
            catch { throw PublicationError.unavailableAsset(file.lastPathComponent) }
            guard values.isRegularFile == true else { throw PublicationError.unavailableAsset(file.lastPathComponent) }
            guard (values.fileSize ?? 0) <= PublicationLimits.resourceBytes else { throw PublicationError.tooLarge }
            do { data = try Data(contentsOf: file, options: .mappedIfSafe) } catch { throw PublicationError.unavailableAsset(file.lastPathComponent) }
            resourceBase = file.deletingLastPathComponent()
        }
        if let path = included[key] { return (fromAsset ? "" : "assets/") + path + fragment }
        guard data.count <= PublicationLimits.resourceBytes, entries.count < PublicationLimits.files else { throw PublicationError.tooLarge }
        totalBytes += data.count
        guard totalBytes <= PublicationLimits.archiveBytes else { throw PublicationError.tooLarge }
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let filename = String(hash.prefix(24)) + "." + suffix
        included[key] = filename
        entries.append(.init(path: "assets/" + filename, mediaType: mediaType))
        let output: Data
        if mediaType == "text/css" {
            guard let css = String(data: data, encoding: .utf8) else { throw PublicationError.unsupportedAsset("A stylesheet must use UTF-8") }
            output = Data(try rewriteCSS(css, relativeTo: resourceBase, fromAsset: true).utf8)
        } else if mediaType == "image/svg+xml" {
            // Reject nested external resources rather than ship a broken SVG.
            let svg = try PublicationXML.parse(data, named: "SVG image")
            for element in PublicationHTML.elements(in: svg) {
                if element.localName?.lowercased() == "script" { throw PublicationError.unsupportedAsset("Scripted SVG") }
                for name in ["href", "xlink:href"] {
                    guard let attribute = element.attribute(forName: name), let value = attribute.stringValue, !value.hasPrefix("#") else { continue }
                    attribute.stringValue = try include(value, relativeTo: resourceBase, fromAsset: true)
                }
                if let style = element.attribute(forName: "style"), let css = style.stringValue { style.stringValue = try rewriteCSS(css, relativeTo: resourceBase, fromAsset: true) }
                if element.localName?.lowercased() == "style" { element.stringValue = try rewriteCSS(element.stringValue ?? "", relativeTo: resourceBase, fromAsset: true) }
            }
            output = svg.xmlData(options: [.nodeCompactEmptyElement])
        } else { output = data }
        try output.write(to: directory.appendingPathComponent(filename))
        return (fromAsset ? "" : "assets/") + filename + fragment
    }

    private func rewriteCSS(_ css: String, relativeTo base: URL?, fromAsset: Bool) throws -> String {
        // @import with a quoted string is normalized to url() so its dependency
        // follows the same local-only path as images and fonts.
        let imports = try NSRegularExpression(pattern: #"@import\s+(["'])([^"']+)\1"#, options: [.caseInsensitive])
        var result = imports.stringByReplacingMatches(in: css, range: NSRange(location: 0, length: (css as NSString).length), withTemplate: "@import url(\"$2\")")
        let regex = try NSRegularExpression(pattern: #"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)"#, options: [.caseInsensitive])
        let ns = result as NSString
        for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
            let range = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            let reference = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = try include(reference, relativeTo: base, fromAsset: fromAsset)
            result = (result as NSString).replacingCharacters(in: match.range, with: "url(\"\(replacement)\")")
        }
        return result
    }

    private static let mediaTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp", "css": "text/css", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "mp3": "audio/mpeg", "m4a": "audio/mp4", "vtt": "text/vtt"]
    private static let extensions = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/svg+xml": "svg", "image/webp": "webp", "text/css": "css", "font/woff": "woff", "font/woff2": "woff2", "font/ttf": "ttf", "font/otf": "otf", "audio/mpeg": "mp3", "audio/mp4": "m4a", "text/vtt": "vtt"]
}

/// Blocking process and pipe handling runs off the caller's actor. Both streams
/// are continuously drained, retained output is bounded, and timeout kills the
/// child before returning. Commands and paths never pass through a shell.
enum PublicationProcess {
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil, outputLimit: Int = 64 * 1024, timeout: TimeInterval = 30) async throws -> Data {
        try Task.checkCancellation()
        let result = try await Task.detached(priority: .utility) {
            try runSynchronously(executable, arguments, directory: directory, outputLimit: outputLimit, timeout: timeout)
        }.value
        try Task.checkCancellation()
        return result
    }

    private static func runSynchronously(_ executable: String, _ arguments: [String], directory: URL?, outputLimit: Int, timeout: TimeInterval) throws -> Data {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments; process.currentDirectoryURL = directory
            process.standardOutput = output; process.standardError = errors
            process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "COPYFILE_DISABLE": "1"]
            let exited = DispatchSemaphore(value: 0), drained = DispatchGroup()
            let stdout = PublicationCapture(limit: outputLimit), stderr = PublicationCapture(limit: 16 * 1024)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            for (pipe, capture) in [(output, stdout), (errors, stderr)] {
                drained.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { drained.leave(); try? pipe.fileHandleForReading.close() }
                    while let data = try? pipe.fileHandleForReading.read(upToCount: 32 * 1024), !data.isEmpty { capture.append(data) }
                }
            }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                if exited.wait(timeout: .now() + 0.5) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = exited.wait(timeout: .now() + 2) }
                _ = drained.wait(timeout: .now() + 2)
                throw PublicationError.timedOut
            }
            guard drained.wait(timeout: .now() + 5) == .success else { throw PublicationError.timedOut }
            guard process.terminationStatus == 0 else {
                let message = String(data: stderr.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Exit status \(process.terminationStatus)"
                throw PublicationError.processFailed(message)
            }
            guard !stdout.overflowed else { throw PublicationError.tooLarge }
            return stdout.data
    }
}

private final class PublicationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()
    private var truncated = false
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let count = min(data.count, max(0, limit - bytes.count))
        bytes.append(data.prefix(count)); truncated = truncated || count < data.count
    }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return truncated }
}
