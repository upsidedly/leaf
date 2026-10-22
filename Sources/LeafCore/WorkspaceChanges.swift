import Foundation

public struct WorkspaceFileChange: Identifiable, Codable, Equatable, Sendable {
    public let beforePath: String?
    public let afterPath: String?
    public let before: Data?
    public let after: Data?
    public let replacementCount: Int
    public var id: String { "\(beforePath ?? "new")→\(afterPath ?? "deleted")" }
    public var isRename: Bool { beforePath != nil && afterPath != nil && beforePath != afterPath }
    public var beforeText: String { before.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    public var afterText: String { after.flatMap { String(data: $0, encoding: .utf8) } ?? "" }

    public init(beforePath: String?, afterPath: String?, before: Data?, after: Data?, replacementCount: Int = 0) {
        self.beforePath = beforePath; self.afterPath = afterPath; self.before = before; self.after = after; self.replacementCount = replacementCount
    }
}

public struct WorkspaceChangeSet: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let changes: [WorkspaceFileChange]
    public var replacementCount: Int { changes.reduce(0) { $0 + $1.replacementCount } }
    public var isEmpty: Bool { changes.isEmpty }

    public init(id: UUID = UUID(), title: String, changes: [WorkspaceFileChange]) {
        self.id = id; self.title = title; self.changes = changes
    }

    /// Each file replacement is atomic. A failed batch rolls back its own completed
    /// writes, while refusing to overwrite edits made by another application.
    @discardableResult
    public func apply(to root: URL) throws -> WorkspaceJournal {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let journal = WorkspaceJournal(id: id, root: root, changeSet: self, appliedAt: Date())
        let journalURL = try Self.journalURL(id: id, root: root)
        guard !FileManager.default.fileExists(atPath: journalURL.path) else { throw WorkspaceError.invalidChange("This change has already been applied. Review a new preview.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let pendingURL = journalURL.deletingPathExtension().appendingPathExtension("pending")
        let journalData = try encoder.encode(journal)
        // The undo payload is durable before the first source file is touched.
        try journalData.write(to: pendingURL, options: .atomic)
        let journalHandle = try FileHandle(forWritingTo: pendingURL)
        try journalHandle.synchronize(); try journalHandle.close()
        do {
            try Self.perform(changes, root: root)
            do { try FileManager.default.moveItem(at: pendingURL, to: journalURL) }
            catch {
                let inverse = changes.map { WorkspaceFileChange(beforePath: $0.afterPath, afterPath: $0.beforePath, before: $0.after, after: $0.before) }
                try Self.perform(inverse, root: root)
                throw error
            }
        } catch {
            // A pending journal is retained on failure for recovery and inspection.
            throw error
        }
        return journal
    }

    static func journalURL(id: UUID, root: URL) throws -> URL {
        let directory = try safeURL(".leaf/journal", root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    static func safeURL(_ relativePath: String, root: URL) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\0") else { throw WorkspaceError.outsideWorkspace(relativePath) }
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard WorkspaceIndex.isInside(url, root: root), WorkspaceIndex.isInside(url.resolvingSymlinksInPath(), root: root) else { throw WorkspaceError.outsideWorkspace(relativePath) }
        // A symlink is never a writable note, even when its destination is in scope.
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw WorkspaceError.invalidChange("Leaf does not replace symbolic links: \(relativePath)") }
        return url
    }

    private static func state(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var directory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        guard !directory.boolValue else { throw WorkspaceError.invalidChange("A folder occupies ‘\(url.lastPathComponent)’.") }
        return try Data(contentsOf: url)
    }

    static func perform(_ changes: [WorkspaceFileChange], root: URL) throws {
        var before: [String: Data] = [:], after: [String: Data] = [:], paths: Set<String> = []
        var attributes: [String: [FileAttributeKey: Any]] = [:]
        for change in changes {
            guard (change.beforePath == nil) == (change.before == nil), (change.afterPath == nil) == (change.after == nil), change.beforePath != nil || change.afterPath != nil else { throw WorkspaceError.invalidChange("The change preview is incomplete.") }
            for path in [change.beforePath, change.afterPath].compactMap({ $0 }) {
                let normalized = WorkspaceIndex.relativePath(of: try safeURL(path, root: root), root: root)
                guard ![".leaf", ".git", ".hg", ".svn"].contains(normalized.split(separator: "/").first.map(String.init) ?? "") else { throw WorkspaceError.invalidChange("Workspace changes cannot modify ‘\(path)’.") }
            }
            if let path = change.beforePath, let bytes = change.before {
                guard before[path] == nil else { throw WorkspaceError.invalidChange("The preview modifies ‘\(path)’ more than once.") }
                before[path] = bytes; paths.insert(path)
                let url = try safeURL(path, root: root)
                attributes[path] = try? FileManager.default.attributesOfItem(atPath: url.path)
            }
            if let path = change.afterPath, let bytes = change.after {
                guard after[path] == nil else { throw WorkspaceError.invalidChange("More than one file would be written to ‘\(path)’.") }
                after[path] = bytes; paths.insert(path)
            }
        }
        var urls: [String: URL] = [:]
        for path in paths.sorted() {
            let url = try safeURL(path, root: root); urls[path] = url
            guard try state(at: url) == before[path] else { throw WorkspaceError.conflict(path) }
        }
        var touched: [String] = []
        do {
            // Write destinations before removing old names, so every rename has
            // a durable destination even if the process is interrupted.
            for path in paths.sorted(by: { (after[$0] == nil ? 1 : 0, $0) < (after[$1] == nil ? 1 : 0, $1) }) {
                guard let url = urls[path] else { continue }
                _ = try safeURL(path, root: root)
                guard try state(at: url) == before[path] else { throw WorkspaceError.conflict(path) }
                if let bytes = after[path] {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: url, options: .atomic)
                    touched.append(path)
                    if let original = changes.first(where: { $0.afterPath == path })?.beforePath,
                       let permissions = attributes[original]?[.posixPermissions] {
                        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
                    }
                } else {
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    touched.append(path)
                }
            }
        } catch {
            var rollbackConflicts: [String] = []
            for path in touched.reversed() {
                guard let url = urls[path] else { continue }
                do {
                    _ = try safeURL(path, root: root)
                    guard try state(at: url) == after[path] else { rollbackConflicts.append(path); continue }
                    if let bytes = before[path] {
                        try bytes.write(to: url, options: .atomic)
                        if let permissions = attributes[path]?[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
                    }
                    else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                } catch { rollbackConflicts.append(path) }
            }
            if !rollbackConflicts.isEmpty { throw WorkspaceError.invalidChange("The batch stopped, and other edits prevented rollback of: \(rollbackConflicts.joined(separator: ", ")). The recovery journal is in .leaf/journal.") }
            throw error
        }
    }
}

public struct WorkspaceJournal: Identifiable, Codable, Sendable {
    public let id: UUID
    public let root: URL
    public let changeSet: WorkspaceChangeSet
    public let appliedAt: Date
    public var url: URL { root.appendingPathComponent(".leaf/journal/\(id.uuidString.lowercased()).json") }

    public func undo() throws {
        let inverse = changeSet.changes.map { WorkspaceFileChange(beforePath: $0.afterPath, afterPath: $0.beforePath, before: $0.after, after: $0.before) }
        try WorkspaceChangeSet.perform(inverse, root: root.standardizedFileURL.resolvingSymlinksInPath())
        let marker = url.deletingPathExtension().appendingPathExtension("undone")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.moveItem(at: url, to: marker) }
    }

    public static func load(from url: URL) throws -> WorkspaceJournal {
        let journal = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        let expectedRoot = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard journal.root.standardizedFileURL.resolvingSymlinksInPath() == expectedRoot else { throw WorkspaceError.invalidChange("This journal belongs to another workspace.") }
        return journal
    }

    public static func history(in root: URL) throws -> [WorkspaceJournal] {
        let directory = root.appendingPathComponent(".leaf/journal")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.load(from: $0) }
            .sorted { $0.appliedAt > $1.appliedAt }
    }
}
