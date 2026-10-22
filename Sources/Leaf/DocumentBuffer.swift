import Foundation

/// NSDocument's file-presenter callbacks can run outside the main actor. All
/// mutable fields in this bridge are private and accessed under the same lock;
/// only immutable Sendable snapshots leave it. UI state stays on the main actor.
final class DocumentBuffer: @unchecked Sendable {
    struct Snapshot: Sendable { let source: String; let bom: Bool; let baseline: Data?; let revision: Int; let conflicted: Bool }
    private let lock = NSLock()
    private var source = ""
    private var bom = false
    private var baseline: Data?
    private var revision = 0
    private var conflicted = false
    func snapshot() -> Snapshot { lock.withLock { .init(source:source,bom:bom,baseline:baseline,revision:revision,conflicted:conflicted) } }
    @discardableResult func read(_ text: String, data: Data) -> Int {
        lock.withLock { source = text; bom = data.starts(with:[0xef,0xbb,0xbf]); baseline = data; revision += 1; conflicted = false; return revision }
    }
    func edit(_ text: String) { lock.withLock { source = text; revision += 1 } }
    func saved(_ data: Data) { lock.withLock { baseline = data; conflicted = false } }
    func setConflict(_ value: Bool) { lock.withLock { conflicted = value } }
    func data() throws -> Data {
        try lock.withLock {
            if conflicted { throw NSError(domain:"Leaf",code:2,userInfo:[NSLocalizedDescriptionKey:"The file changed elsewhere. Choose which version to keep before saving."]) }
            return Data((bom ? "\u{feff}" + source : source).utf8)
        }
    }
}
