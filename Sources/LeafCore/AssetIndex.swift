import Foundation
import CryptoKit

public struct WorkspaceAssetUsage: Identifiable, Sendable {
    public let sourceURL: URL
    public let relativePath: String
    public let link: MarkdownLink
    public var id: String { "\(relativePath):\(link.id)" }
}

public struct WorkspaceAsset: Identifiable, Sendable {
    public let url: URL
    public let relativePath: String
    public let size: Int64
    public let sha256: String
    public let usages: [WorkspaceAssetUsage]
    public var id: String { relativePath }
    public var isUnused: Bool { usages.isEmpty }
}

public struct AssetIndex: Sendable {
    public let records: [WorkspaceAsset]
    public let issues: [WorkspaceIssue]
    public var duplicateGroups: [[WorkspaceAsset]] {
        Dictionary(grouping: records, by: \.sha256).values.filter { $0.count > 1 }
            .map { $0.sorted { $0.relativePath < $1.relativePath } }.sorted { $0[0].relativePath < $1[0].relativePath }
    }
    public var unused: [WorkspaceAsset] { records.filter(\.isUnused) }

    public init(workspace: WorkspaceIndex) throws {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: workspace.root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { throw WorkspaceError.invalidRoot }
        let excluded: Set<String> = [".git", ".leaf", ".build", "node_modules", ".Trash", ".svn", ".hg"]
        // The asset browser covers document media, rather than treating source code
        // and package lockfiles as orphaned images.
        let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "heif", "tiff", "tif", "bmp", "ico", "icns", "svg", "pdf", "mp4", "mov", "m4v", "webm", "mp3", "m4a", "wav", "aiff", "ogg", "flac", "woff", "woff2", "ttf", "otf", "csv", "tsv", "json", "drawio", "excalidraw"]
        var usageByPath: [String: [WorkspaceAssetUsage]] = [:]
        for document in workspace.documents {
            for link in document.index.links {
                guard let target = workspace.resolve(link.target, from: document.url), !target.isDocument else { continue }
                usageByPath[target.relativePath, default: []].append(.init(sourceURL: document.url, relativePath: document.relativePath, link: link))
            }
        }
        var records: [WorkspaceAsset] = [], issues: [WorkspaceIssue] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values?.isDirectory == true { if excluded.contains(url.lastPathComponent) { enumerator.skipDescendants() }; continue }
            let path = WorkspaceIndex.relativePath(of: url, root: workspace.root)
            guard values?.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) || usageByPath[path] != nil else { continue }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var digest = SHA256(), size: Int64 = 0
                while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty { digest.update(data: data); size += Int64(data.count) }
                let sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
                records.append(.init(url: url, relativePath: path, size: size, sha256: sha, usages: usageByPath[path] ?? []))
            } catch {
                issues.append(.init(url: url, relativePath: path, diagnostic: .init(code: "unreadable-asset", message: error.localizedDescription, range: NSRange(location: 0, length: 0))))
            }
        }
        self.records = records.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        self.issues = issues
    }
}
