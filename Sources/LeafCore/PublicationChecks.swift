import Foundation

public struct PublicationReport: Sendable {
    public let title: String
    public let entries: [String]
    public let navigationTargets: [String]
    public let assetCount: Int
    public let uncompressedBytes: Int
}

/// Structural checks for Leaf's offline EPUB files. This checks ZIP integrity,
/// required EPUB documents and all bundled resource/TOC targets; it is not a
/// replacement for the complete EPUBCheck conformance suite.
public enum PublicationChecks {
    public static func verifyEPUB(at url: URL) async throws -> PublicationReport {
        guard url.isFileURL else { throw PublicationError.invalidArchive("A local file is required.") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= PublicationLimits.archiveBytes else { throw PublicationError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let zip = try PublicationZIP(data)
        let names = Set(zip.entries.map(\.name))
        let required = ["mimetype", "META-INF/container.xml", "EPUB/package.opf", "EPUB/content.xhtml", "EPUB/nav.xhtml"]
        guard required.allSatisfy(names.contains) else { throw PublicationError.invalidArchive("A required EPUB document is missing.") }
        guard let first = zip.entries.first, first.name == "mimetype", first.localOffset == 0,
              first.method == 0, first.extraLength == 0, first.flags & 1 == 0,
              first.uncompressedBytes == 20, first.compressedBytes == 20,
              data.subdata(in: first.payloadOffset..<(first.payloadOffset + 20)) == Data("application/epub+zip".utf8) else {
            throw PublicationError.invalidArchive("mimetype must be the first, uncompressed entry with no extra field.")
        }
        _ = try await PublicationProcess.run("/usr/bin/unzip", ["-tq", url.path])
        func member(_ path: String) async throws -> Data {
            guard names.contains(path) else { throw PublicationError.invalidArchive("The file ‘\(path)’ is missing.") }
            return try await PublicationProcess.run("/usr/bin/unzip", ["-p", url.path, path], outputLimit: PublicationLimits.resourceBytes)
        }
        let container = try PublicationXML.parse(try await member("META-INF/container.xml"), named: "container.xml")
        guard let containerRoot = container.rootElement(), containerRoot.localName == "container",
              containerRoot.namespace(forPrefix: "")?.stringValue == "urn:oasis:names:tc:opendocument:xmlns:container",
              descendants(containerRoot, named: "rootfile").contains(where: { attribute($0, "full-path") == "EPUB/package.opf" && attribute($0, "media-type") == "application/oebps-package+xml" }) else {
            throw PublicationError.invalidArchive("container.xml does not identify the package document.")
        }
        let package = try PublicationXML.parse(try await member("EPUB/package.opf"), named: "package.opf")
        guard let root = package.rootElement(), root.localName == "package", attribute(root, "version") == "3.0",
              root.namespace(forPrefix: "")?.stringValue == "http://www.idpf.org/2007/opf" else {
            throw PublicationError.invalidArchive("The EPUB 3 package is invalid.")
        }
        let title = descendants(root, named: "title").first?.stringValue ?? ""
        let language = descendants(root, named: "language").first?.stringValue ?? ""
        let identifierID = attribute(root, "unique-identifier")
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !language.isEmpty,
              descendants(root, named: "identifier").contains(where: { attribute($0, "id") == identifierID && !($0.stringValue ?? "").isEmpty }),
              descendants(root, named: "meta").contains(where: { attribute($0, "property") == "dcterms:modified" && ISO8601DateFormatter().date(from: $0.stringValue ?? "") != nil }) else {
            throw PublicationError.invalidArchive("Required publication metadata is missing.")
        }
        var manifested: [String: (path: String, type: String)] = [:]
        var paths = Set<String>(), navigationID: String?
        for item in descendants(root, named: "item") {
            let id = attribute(item, "id"), href = attribute(item, "href"), type = attribute(item, "media-type")
            let path = try resourcePath(href, relativeTo: "EPUB/package.opf")
            guard !id.isEmpty, !type.isEmpty, manifested[id] == nil, paths.insert(path).inserted, names.contains(path) else {
                throw PublicationError.invalidArchive("The manifest contains an invalid or missing resource.")
            }
            manifested[id] = (path, type)
            if attribute(item, "properties").split(separator: " ").contains("nav") {
                guard navigationID == nil, type == "application/xhtml+xml" else { throw PublicationError.invalidArchive("The publication must have one XHTML navigation document.") }
                navigationID = id
            }
        }
        let documentPaths = names.subtracting(["mimetype", "META-INF/container.xml", "EPUB/package.opf"])
        guard paths == documentPaths, let navigationID, let navigationPath = manifested[navigationID]?.path else {
            throw PublicationError.invalidArchive("The manifest does not describe every publication file.")
        }
        let spine = descendants(root, named: "itemref")
        guard !spine.isEmpty, spine.allSatisfy({ manifested[attribute($0, "idref")]?.type == "application/xhtml+xml" && attribute($0, "idref") != navigationID }) else {
            throw PublicationError.invalidArchive("The reading order does not identify a content document.")
        }

        var documents: [String: XMLDocument] = [:], idsByPath: [String: Set<String>] = [:]
        for item in manifested.values.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            if item.type == "application/xhtml+xml" || item.type == "image/svg+xml" {
                let document = try PublicationXML.parse(try await member(item.path), named: item.path)
                if item.type == "application/xhtml+xml" {
                    guard document.rootElement()?.localName == "html", document.rootElement()?.namespace(forPrefix: "")?.stringValue == "http://www.w3.org/1999/xhtml" else {
                        throw PublicationError.invalidArchive("An XHTML document has the wrong namespace.")
                    }
                    documents[item.path] = document
                }
                var ids = Set<String>()
                for element in descendants(document) {
                    if let id = element.attribute(forName: "id")?.stringValue, !ids.insert(id).inserted {
                        throw PublicationError.invalidArchive("The document ‘\(item.path)’ has duplicate IDs.")
                    }
                    let name = element.localName?.lowercased() ?? ""
                    if ["script", "iframe", "base"].contains(name) { throw PublicationError.invalidArchive("The book contains active or external document content.") }
                    let resourceAttributes: [String]
                    switch name {
                    case "img", "audio", "video", "source", "track": resourceAttributes = ["src", "poster"]
                    case "image", "use": resourceAttributes = ["href", "xlink:href"]
                    case "object": resourceAttributes = ["data"]
                    case "link": resourceAttributes = attribute(element, "rel").lowercased() == "stylesheet" ? ["href"] : []
                    default: resourceAttributes = []
                    }
                    for key in resourceAttributes {
                        let reference = attribute(element, key)
                        if !reference.isEmpty { try checkResource(reference, from: item.path, names: paths) }
                    }
                    if name == "style" { try checkCSS(element.stringValue ?? "", from: item.path, names: paths) }
                    if let css = element.attribute(forName: "style")?.stringValue { try checkCSS(css, from: item.path, names: paths) }
                }
                idsByPath[item.path] = ids
            } else if item.type == "text/css" {
                guard let css = String(data: try await member(item.path), encoding: .utf8) else { throw PublicationError.invalidArchive("A stylesheet is not UTF-8.") }
                try checkCSS(css, from: item.path, names: paths)
            }
        }
        guard let navigation = documents[navigationPath], let toc = descendants(navigation, named: "nav").first(where: { attribute($0, "epub:type").split(separator: " ").contains("toc") }),
              !descendants(toc, named: "ol").isEmpty else {
            throw PublicationError.invalidArchive("The navigation document has no table of contents.")
        }
        var targets: [String] = []
        for link in descendants(toc, named: "a") {
            let href = attribute(link, "href")
            let path = try resourcePath(href, relativeTo: navigationPath)
            guard documents[path] != nil else { throw PublicationError.invalidArchive("A table of contents target is missing.") }
            if let fragment = URLComponents(string: href)?.fragment, !fragment.isEmpty, idsByPath[path]?.contains(fragment) != true {
                throw PublicationError.invalidArchive("The table of contents anchor ‘\(fragment)’ is missing.")
            }
            targets.append(href)
        }
        guard !targets.isEmpty else { throw PublicationError.invalidArchive("The table of contents is empty.") }
        return .init(title: title, entries: zip.entries.map(\.name), navigationTargets: targets,
                     assetCount: paths.filter { $0.hasPrefix("EPUB/assets/") }.count,
                     uncompressedBytes: zip.entries.reduce(0) { $0 + $1.uncompressedBytes })
    }

    /// Temporary fixtures prove packaging, dependency rewriting, UTF-8/XML,
    /// navigation, failure preservation, ZIP rejection and process timeout.
    @discardableResult
    public static func run() async throws -> [String] {
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw PublicationError.invalidArchive("Publication check failed: \(message)") }
        }
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("leaf-publication-checks-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("styles"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1sAAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("images/a b.png"))
        try Data("body{background-image:url('../images/a%20b.png')}".utf8).write(to: root.appendingPathComponent("styles/book.css"))
        let html = """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><link rel="stylesheet" href="styles/book.css"></head><body><h1 id="intro">Café &amp; 🐊</h1><h2>Details</h2><p>A&nbsp;book.<br><img src="images/a%20b.png" alt="Picture"><img src="data:image/png;base64,\(png.base64EncodedString())" alt="Inline"></p><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 12"><circle cx="6" cy="6" r="5"/></svg><math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math><script>throw new Error('must not ship')</script></body></html>
        """
        let writer = PublicationArchive(), output = root.appendingPathComponent("Book.epub")
        try await writer.epub(html: html, title: "Café & Crocs 🐊", author: "A & B", baseURL: root, to: output)
        let report = try await verifyEPUB(at: output)
        try check(report.title == "Café & Crocs 🐊", "UTF-8 title round-trips")
        try check(report.navigationTargets == ["content.xhtml#intro", "content.xhtml#details"], "headings supply unique TOC anchors")
        try check(report.assetCount == 3, "relative image, data image and CSS dependency are packaged once per source")
        let body = try await PublicationProcess.run("/usr/bin/unzip", ["-p", output.path, "EPUB/content.xhtml"], outputLimit: PublicationLimits.resourceBytes)
        let xml = try PublicationXML.parse(body, named: "fixture")
        try check(!descendants(xml, named: "svg").isEmpty && !descendants(xml, named: "math").isEmpty, "HTML repair retains SVG and MathML")
        try check(descendants(xml, named: "svg").first?.attribute(forName: "viewBox")?.stringValue == "0 0 12 12", "SVG attribute case remains intact")
        var passed = ["EPUB: OCF ZIP header, XML metadata, navigation, UTF-8, local/data images, CSS dependencies and SVG/MathML"]

        let original = try Data(contentsOf: output)
        do {
            try await writer.epub(html: "<p><img src=\"https://example.invalid/image.png\"></p>", title: "Remote", baseURL: root, to: output)
            throw PublicationError.invalidArchive("Expected a remote asset failure")
        } catch PublicationError.unavailableAsset { }
        try check(try Data(contentsOf: output) == original, "a failed export preserves an existing destination")
        var broken = original
        broken[8] = 8 // Change the mimetype local compression method only.
        let invalid = root.appendingPathComponent("Invalid.epub")
        try broken.write(to: invalid)
        do { _ = try await verifyEPUB(at: invalid); throw PublicationError.invalidArchive("Expected ZIP verification to fail") }
        catch PublicationError.invalidArchive(let message) { try check(!message.contains("Expected ZIP"), "the verifier rejects damaged ZIP metadata") }
        passed.append("EPUB failures: remote assets are rejected, previous files survive, invalid ZIP headers fail verification")

        let explicit = root.appendingPathComponent("Explicit.epub")
        try await writer.epub(html: "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Old</title></head><body><h2 id=\"a\">Original</h2></body></html>", title: "Explicit", baseURL: nil,
                              headings: [.init(title: "Custom TOC label", level: 2, anchor: "a")], to: explicit)
        let explicitReport = try await verifyEPUB(at: explicit)
        try check(explicitReport.navigationTargets == ["content.xhtml#a"], "explicit TOC metadata is supported")
        do { _ = try await PublicationProcess.run("/bin/sleep", ["2"], timeout: 0.02); throw PublicationError.invalidArchive("Expected a process timeout") }
        catch PublicationError.timedOut { }
        do { _ = try await PublicationProcess.run("/usr/bin/printf", ["%200000s", ""], outputLimit: 32); throw PublicationError.invalidArchive("Expected bounded output rejection") }
        catch PublicationError.tooLarge { }
        passed.append("EPUB integration: explicit heading metadata, bounded process timeout and pipe-output draining")
        return passed
    }

    private static func descendants(_ node: XMLNode, named name: String? = nil) -> [XMLElement] {
        var result: [XMLElement] = []
        if let element = node as? XMLElement, name == nil || element.localName == name { result.append(element) }
        for child in node.children ?? [] { result.append(contentsOf: descendants(child, named: name)) }
        return result
    }

    private static func attribute(_ node: XMLElement, _ name: String) -> String { node.attribute(forName: name)?.stringValue ?? "" }

    private static func resourcePath(_ reference: String, relativeTo path: String) throws -> String {
        guard let components = URLComponents(string: reference), components.scheme == nil, components.host == nil,
              !components.path.hasPrefix("/"), !components.path.contains("\\") else {
            throw PublicationError.invalidArchive("A resource reference leaves the publication.")
        }
        let base = URL(fileURLWithPath: "/" + path).deletingLastPathComponent()
        let resolved = URL(fileURLWithPath: components.path, relativeTo: base).standardizedFileURL.path
        guard resolved.hasPrefix("/EPUB/"), !components.path.isEmpty else { throw PublicationError.invalidArchive("A resource reference leaves the publication.") }
        return String(resolved.dropFirst())
    }

    private static func checkResource(_ reference: String, from path: String, names: Set<String>) throws {
        if reference.hasPrefix("#") { return }
        let resource = try resourcePath(reference, relativeTo: path)
        guard names.contains(resource) else { throw PublicationError.invalidArchive("The resource ‘\(reference)’ is missing from the book.") }
    }

    private static func checkCSS(_ css: String, from path: String, names: Set<String>) throws {
        let regex = try NSRegularExpression(pattern: #"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*?))\s*\)"#, options: [.caseInsensitive])
        let ns = css as NSString
        for match in regex.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            let range = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            try checkResource(ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines), from: path, names: names)
        }
    }
}

private struct PublicationZIP {
    struct Entry {
        let name: String, method: Int, flags: Int, localOffset: Int, payloadOffset: Int, extraLength: Int
        let compressedBytes: Int, uncompressedBytes: Int
    }
    let entries: [Entry]

    init(_ data: Data) throws {
        func number(_ offset: Int, _ bytes: Int) throws -> Int {
            guard offset >= 0, bytes <= 4, offset <= data.count - bytes else { throw PublicationError.invalidArchive("The ZIP directory is truncated.") }
            return (0..<bytes).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard data.count >= 22 else { throw PublicationError.invalidArchive("The ZIP file is truncated.") }
        let lower = max(0, data.count - 65_557)
        var end: Int?
        for offset in stride(from: data.count - 22, through: lower, by: -1) {
            if try number(offset, 4) == 0x06054b50, offset + 22 + (try number(offset + 20, 2)) == data.count { end = offset; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw PublicationError.invalidArchive("The ZIP directory is missing or split across disks.") }
        let count = try number(end + 10, 2), directorySize = try number(end + 12, 4), directoryOffset = try number(end + 16, 4)
        guard count > 0, count <= PublicationLimits.files + 5, try number(end + 8, 2) == count, directoryOffset + directorySize == end else {
            throw PublicationError.invalidArchive("The ZIP directory has invalid bounds.")
        }
        var cursor = directoryOffset, found: [Entry] = [], names = Set<String>(), totalBytes = 0
        for _ in 0..<count {
            guard try number(cursor, 4) == 0x02014b50 else { throw PublicationError.invalidArchive("The ZIP directory entry is invalid.") }
            let flags = try number(cursor + 8, 2), method = try number(cursor + 10, 2)
            let compressed = try number(cursor + 20, 4), uncompressed = try number(cursor + 24, 4)
            let nameLength = try number(cursor + 28, 2), extra = try number(cursor + 30, 2), comment = try number(cursor + 32, 2)
            let local = try number(cursor + 42, 4), nameStart = cursor + 46, nameEnd = nameStart + nameLength
            guard nameEnd <= end, let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8),
                  !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("-"), !name.contains("\\"), !name.contains("\0"),
                  !name.contains("*"), !name.contains("?"), !name.contains("["),
                  !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == ".." || $0 == "." }),
                  names.insert(name).inserted, flags & 9 == 0, [0, 8].contains(method), try number(cursor + 34, 2) == 0,
                  uncompressed <= PublicationLimits.resourceBytes else {
                throw PublicationError.invalidArchive("The ZIP contains an unsafe or unsupported entry.")
            }
            totalBytes += uncompressed
            guard totalBytes <= PublicationLimits.archiveBytes, try number(local, 4) == 0x04034b50,
                  try number(local + 6, 2) == flags, try number(local + 8, 2) == method,
                  try number(local + 18, 4) == compressed, try number(local + 22, 4) == uncompressed else {
                throw PublicationError.invalidArchive("The ZIP local header does not match its directory.")
            }
            let localNameLength = try number(local + 26, 2), localExtraLength = try number(local + 28, 2)
            let payload = local + 30 + localNameLength + localExtraLength
            guard localNameLength == nameLength, local + 30 + localNameLength <= data.count,
                  data.subdata(in: (local + 30)..<(local + 30 + localNameLength)) == data.subdata(in: nameStart..<nameEnd),
                  payload + compressed <= directoryOffset else { throw PublicationError.invalidArchive("A ZIP entry extends outside the archive.") }
            found.append(.init(name: name, method: method, flags: flags, localOffset: local, payloadOffset: payload, extraLength: localExtraLength, compressedBytes: compressed, uncompressedBytes: uncompressed))
            cursor = nameEnd + extra + comment
        }
        guard cursor == end else { throw PublicationError.invalidArchive("The ZIP directory has trailing data.") }
        found.sort { $0.localOffset < $1.localOffset }
        for pair in zip(found, found.dropFirst()) where pair.0.payloadOffset + pair.0.compressedBytes > pair.1.localOffset {
            throw PublicationError.invalidArchive("The ZIP contains overlapping entries.")
        }
        self.entries = found
    }
}
