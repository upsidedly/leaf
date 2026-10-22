import AppKit
import LeafCore

@MainActor extension DocumentModel {
    func replaceSource(_ range: NSRange, with value: String, title: String) {
        guard !workspaceBusy, range.location >= 0, NSMaxRange(range) <= (source as NSString).length else { return }
        if let textView, textView.isEditable {
            textView.breakUndoCoalescing(); textView.insertText(value,replacementRange:range)
            textView.undoManager?.setActionName(title); textView.breakUndoCoalescing()
        } else {
            replaceWholeSource(WorkspaceIndex.replacing(source,replacements:[(range,value)]),title:title)
        }
    }
    func replaceWholeSource(_ value: String, title: String) {
        guard !workspaceBusy else { return }
        let previous = source
        document?.undoManager?.registerUndo(withTarget:self) { target in target.replaceWholeSource(previous,title:title) }
        document?.undoManager?.setActionName(title); edit(value)
    }
    func requestNavigation(range: NSRange? = nil, fragment: String? = nil) {
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = source, parsed = await loader.index(source)
            guard snapshot == source, !Task.isCancelled else { return }
            var target = range
            if let fragment {
                let anchor = fragment.removingPercentEncoding ?? fragment
                target = anchor.hasPrefix("^") ? parsed.index.blockIDs.first { $0.name == String(anchor.dropFirst()) }?.contentRange : parsed.index.heading(matching:anchor)?.range
            }
            guard let target else { return }
            for _ in 0..<50 {
                try? await Task.sleep(for:.milliseconds(40))
                guard !Task.isCancelled, snapshot == source else { return }
                if textView != nil {
                    mode = .live
                    document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                    jump(target); return
                }
            }
            status = "The document opened, but its editor is not ready for navigation."
        }
    }
    func undoWorkspace() {
        guard let journal else { status = "No workspace change is available to undo."; return }
        workspaceOperation?.cancel()
        workspaceOperation = Task { [weak self] in
            guard let self else { return }
            do {
                let affected = try lockWorkspaceDocuments(journal.changeSet,root:journal.root,undo:true)
                defer { unlockWorkspaceDocuments(affected) }
                try Task.checkCancellation()
                try await loader.undo(journal)
                reconcileWorkspaceDocuments(affected,changes:journal.changeSet,root:journal.root,undo:true)
                self.journal = nil; refresh(); status = "Workspace change undone."
            } catch is CancellationError { } catch { status = error.localizedDescription }
        }
    }
    func lockWorkspaceDocuments(_ changes: WorkspaceChangeSet, root: URL, undo: Bool) throws -> [LockedWorkspaceDocument] {
        var result: [LockedWorkspaceDocument] = []
        for case let document as LeafDocument in NSDocumentController.shared.documents {
            guard let url = document.fileURL else { continue }
            let relative = WorkspaceIndex.relativePath(of:url,root:root)
            guard changes.changes.contains(where:{ (undo ? $0.afterPath : $0.beforePath) == relative }) else { continue }
            guard !document.isDocumentEdited, !document.model.workspaceBusy else { throw WorkspaceError.invalidChange("Save open documents before applying this workspace change.") }
            result.append(.init(document:document,revision:document.model.revision,path:relative))
        }
        for item in result { item.document.model.workspaceBusy = true; item.document.model.textView?.isEditable = false }
        return result
    }
    func unlockWorkspaceDocuments(_ documents: [LockedWorkspaceDocument]) {
        for item in documents { item.document.model.workspaceBusy = false; item.document.model.textView?.isEditable = item.document.model.mode != .reading }
    }
    func reconcileWorkspaceDocuments(_ documents: [LockedWorkspaceDocument], changes: WorkspaceChangeSet, root: URL, undo: Bool) {
        for item in documents {
            guard let change = changes.changes.first(where:{ (undo ? $0.afterPath : $0.beforePath) == item.path }),
                  let path = undo ? change.beforePath : change.afterPath,
                  let data = undo ? change.before : change.after,
                  let source = String(data:data,encoding:.utf8) else { continue }
            let model = item.document.model
            item.document.fileURL = root.appendingPathComponent(path)
            if model.revision != item.revision {
                // Preserve a late in-memory edit, even if a caller bypassed the
                // temporarily read-only native view while the disk batch ran.
                model.conflict = data; item.document.buffer.setConflict(true)
                model.status = "A workspace change updated this file. Your unsaved edits were kept."
            } else {
                model.load(source,bytes:data); item.document.updateChangeCount(.changeCleared)
            }
        }
    }
}

@MainActor struct LockedWorkspaceDocument {
    let document: LeafDocument
    let revision: Int
    let path: String
}

extension WorkspaceLoader {
    func latestJournal(_ root: URL) -> WorkspaceJournal? { try? WorkspaceJournal.history(in:root).first }
    /// Metadata only, bounded and off-main. Two polls per current-file check
    /// detect note/asset additions and edits without rereading every note.
    func stamp(_ root: URL) throws -> Int {
        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey,.fileSizeKey]
        guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys),options:[.skipsHiddenFiles]) else { throw WorkspaceError.invalidRoot }
        var entries: [(String,Double,Int)] = [], visited = 0
        let ignored: Set<String> = ["node_modules","Vendor","build"]
        for case let url as URL in iterator {
            visited += 1
            if visited > 50_000 { break }
            let values = try url.resourceValues(forKeys:keys)
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if values.isDirectory == true { if ignored.contains(url.lastPathComponent) { iterator.skipDescendants() }; continue }
            entries.append((url.path,values.contentModificationDate?.timeIntervalSince1970 ?? 0,values.fileSize ?? 0))
        }
        let settings = root.appendingPathComponent(".leaf/settings.json")
        if let values = try? settings.resourceValues(forKeys:keys) { entries.append((settings.path,values.contentModificationDate?.timeIntervalSince1970 ?? 0,values.fileSize ?? 0)) }
        var hash = Hasher()
        for item in entries.sorted(by: { $0.0 < $1.0 }) { hash.combine(item.0); hash.combine(item.1); hash.combine(item.2) }
        return hash.finalize()
    }
}
