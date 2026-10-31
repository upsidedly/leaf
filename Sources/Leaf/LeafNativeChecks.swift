import AppKit
import SwiftUI
import LeafCore
import LeafRender
import MarkdownEngine

enum NativeCheckFailure: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? { if case .failed(let message) = self { return message }; return nil }
}

@MainActor enum LeafNativeChecks {
    static func run(in output: URL) async throws -> [String] {
        NSApp.activate(ignoringOtherApps:true)
        // Automatic saves would race deliberately conflicting fixture writes.
        // Explicit coordinated save/autosave checks below own their timing.
        NSDocumentController.shared.autosavingDelay = 3600
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var checks: [String] = []
        func record(_ text: String) { checks.append(text); FileHandle.standardOutput.write(Data(("PASS " + text + "\n").utf8)) }
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw NativeCheckFailure.failed(message) } }
        let root = output.appendingPathComponent("Workspace",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let fixture = "# A little room to think\n\nWrite **clearly**, keep *context*, and follow [[Notes|a useful detail]].\n\n## A clear path\n\n- [x] Start with a thought\n- [ ] Give it shape\n\n```mermaid\nflowchart LR\n A[Think] --> B[Write] --> C[Share]\n```\n\n| Tool | Purpose |\n| --- | --- |\n| Outline | Structure |\n| Links | Context |\n\n$$\nf(x) = \\sum_{i=1}^n x_i^2\n$$\n\n<div><h3>HTML belongs here</h3><p>Ordinary <strong>HTML</strong>, with sensible defaults.</p></div>\n\n![[Notes#One useful detail]]\n\nEnd of the document.\n"
        let file = root.appendingPathComponent("Draft.mdx")
        try Data(fixture.utf8).write(to:file)
        try Data("# Notes\n\n## One useful detail\n\nKeep the explanation close.\n".utf8).write(to:root.appendingPathComponent("Notes.md"))
        let document = LeafDocument()
        document.fileURL = file; document.fileType = "dev.upsided.leaf.mdx"
        try document.read(from:Data(fixture.utf8),ofType:"dev.upsided.leaf.mdx")
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers(); document.showWindows()
        guard let window = document.windowControllers.first?.window else { throw NativeCheckFailure.failed("Document window was not created.") }
        defer { document.updateChangeCount(.changeCleared); document.close() }
        window.makeKeyAndOrderFront(nil)
        try await settle { NSApp.keyWindow === window }
        try await settle { document.model.textView != nil && !document.model.rendering && !document.model.html.isEmpty }
        guard let editor = document.model.textView else { throw NativeCheckFailure.failed("The native editor was not attached.") }
        window.makeFirstResponder(editor)
        try require(editor.textLayoutManager != nil, "The primary editor is not using TextKit 2.")
        try require(editor.string == fixture, "Live presentation changed source characters or wiki-link aliases.")
        try require(try document.data(ofType:"dev.upsided.leaf.mdx") == Data(fixture.utf8), "MDX did not round-trip unchanged.")
        try require(document.model.renderCache.blocks.count >= 3, "Native diagram, HTML or embed block was not rendered.")
        try require(editor.accessibilityLabel() == "Document editor", "The editor has no accessible name.")
        record("Native TextKit 2 editor, lossless MDX/wiki aliases, accessible name, and live diagram/HTML/embed blocks")
        editor.setSelectedRange(NSRange(location:(editor.string as NSString).length,length:0))
        let targetPrefix = (editor.string as NSString).range(of:"Notes|")
        try require((editor.textStorage?.attribute(.font,at:targetPrefix.location,effectiveRange:nil) as? NSFont)?.pointSize ?? 100 < 1,"An inactive wiki alias still displays its target prefix.")
        try snapshot(window,to:output.appendingPathComponent("leaf-initial.png"))
        let before = editor.string
        editor.breakUndoCoalescing(); editor.insertText("Native edit",replacementRange:editor.selectedRange()); editor.breakUndoCoalescing()
        try await settle { document.model.source == editor.string }
        try require(editor.string.hasSuffix("Native edit"), "Native insertion failed.")
        editor.undoManager?.undo()
        try await settle { document.model.source == before }
        try require(editor.string == before, "Native Undo failed.")
        editor.undoManager?.redo()
        try await settle { document.model.source.hasSuffix("Native edit") }
        record("Native insertion, binding feedback, Undo and Redo")

        editor.setSelectedRange(NSRange(location:0,length:0))
        editor.setMarkedText("にほん",selectedRange:NSRange(location:3,length:0),replacementRange:editor.selectedRange())
        try require(editor.hasMarkedText(), "Native IME composition was lost.")
        editor.unmarkText()
        try require(!editor.hasMarkedText(), "Native IME composition did not commit.")
        record("Native marked-text composition and commit with the animated caret enabled")

        editor.selectAll(nil); editor.insertText("cat cat cat\ncat cat cat\n",replacementRange:editor.selectedRange())
        try await settle { document.model.source == editor.string }
        // Isolate the batch command from fixture setup. Do not close AppKit's
        // implicit event groups: NSTextView also keeps coalescing state for them.
        editor.breakUndoCoalescing(); editor.undoManager?.removeAllActions()
        editor.setSelectedRange(NSRange(location:0,length:3))
        _ = editor.tryToPerform(NSSelectorFromString("leafAddNextOccurrence:"),with:nil)
        _ = editor.tryToPerform(NSSelectorFromString("leafAddNextOccurrence:"),with:nil)
        try require(editor.leafAdditionalSelections.count == 2, "Additional selections were not created.")
        editor.insertText("dog",replacementRange:editor.selectedRange())
        try await settle { document.model.source == editor.string }
        try require(editor.string == "dog dog dog\ncat cat cat\n", "Multiple-caret insertion changed the wrong ranges.")
        editor.undoManager?.undo()
        try await settle { document.model.source == "cat cat cat\ncat cat cat\n" }
        try require(editor.leafAdditionalSelections.count == 2, "Batch Undo did not restore secondary selections.")
        _ = editor.tryToPerform(NSSelectorFromString("leafClearCarets:"),with:nil)
        record("Multiple-caret replacement and exact grouped Undo with selection restoration")

        editor.selectAll(nil); editor.insertText(fixture,replacementRange:editor.selectedRange())
        try await settle { document.model.source == fixture && !document.model.rendering }
        try document.writeSafely(to:file,ofType:"dev.upsided.leaf.mdx",for:.saveOperation)
        try require(try Data(contentsOf:file) == Data(fixture.utf8), "Document save changed the source.")
        document.updateChangeCount(.changeCleared)
        let reopened = LeafDocument(); try reopened.read(from:Data(contentsOf:file),ofType:"dev.upsided.leaf.mdx")
        try require(try reopened.buffer.data() == Data(fixture.utf8), "Reopening the saved MDX changed the source.")
        record("Native document write/reopen preserves exact MDX bytes")
        for check in try await editingWorkflows(document:document,editor:editor,fixture:fixture,root:root,output:output) { record(check) }
        for check in try await workspaceWorkflows(document:document,root:root) { record(check) }

        let external = Data("# External edit\n".utf8)
        try external.write(to:file,options:.atomic)
        document.model.edit(fixture + "Unsaved local edit\n")
        do { try document.writeSafely(to:file,ofType:"dev.upsided.leaf.mdx",for:.saveOperation); throw NativeCheckFailure.failed("A conflicting external edit was overwritten.") }
        catch is NativeCheckFailure { throw NativeCheckFailure.failed("A conflicting external edit was overwritten.") }
        catch { try require(try Data(contentsOf:file) == external,"External content changed during conflict detection.") }
        document.model.conflict = external; document.model.useExternal()
        try require(document.model.source == "# External edit\n", "Conflict recovery did not load the external copy.")
        record("External-edit protection and explicit conflict recovery")

        try Data(fixture.utf8).write(to:file,options:.atomic)
        document.model.load(fixture,bytes:Data(fixture.utf8)); document.model.conflict = nil
        document.updateChangeCount(.changeCleared)
        document.model.showSidebar = true; document.model.showInspector = true
        try await settle { !document.model.rendering }
        try require(document.model.textView === editor,"Showing navigation panes remounted the native editor and its Undo state.")
        NSApp.appearance = NSAppearance(named:.aqua); window.appearance = NSAppearance(named:.aqua); document.model.scheduleRender()
        try await settle { !document.model.rendering }
        editor.scrollRangeToVisible(.init(location:0,length:0))
        try snapshot(window,to:output.appendingPathComponent("leaf-light.png"))
        NSApp.appearance = NSAppearance(named:.darkAqua); window.appearance = NSAppearance(named:.darkAqua); document.model.scheduleRender()
        try await settle { !document.model.rendering }
        try snapshot(window,to:output.appendingPathComponent("leaf-dark.png"))
        window.setContentSize(NSSize(width:680,height:480)); document.model.showSidebar = false; document.model.showInspector = false
        try await settle {
            guard let content = window.contentView,let displayed = document.model.textView,let clip = displayed.enclosingScrollView?.contentView else { return false }
            content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let viewport = content.convert(clip.bounds,from:clip)
            return viewport.maxX <= content.bounds.width + 1 && viewport.minX >= -1 && !document.model.rendering
        }
        try require(document.model.textView === editor,"Hiding navigation panes remounted the native editor and its Undo state.")
        if let scroll = editor.enclosingScrollView {
            try require(editor.frame.width <= scroll.contentView.bounds.width + 1,"The compact editor column overflows its viewport.")
            if let content = window.contentView {
                let viewport = content.convert(scroll.contentView.bounds,from:scroll.contentView)
                try require(viewport.maxX <= content.bounds.width + 1 && viewport.minX >= -1,"The native editor viewport extends outside the compact window.")
            }
        }
        try snapshot(window,to:output.appendingPathComponent("leaf-compact.png"))
        window.setContentSize(NSSize(width:1100,height:760)); NSApp.appearance = NSAppearance(named:.aqua); window.appearance = NSAppearance(named:.aqua)
        record("Actual native light/dark and compact/wide rendered views")
        document.model.status = nil; document.model.scheduleRender()
        window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await settle { !document.model.rendering }
        editor.scrollRangeToVisible(.init(location:0,length:0))
        try snapshot(window,to:output.appendingPathComponent("leaf-editor.png"))
        for check in try await DocumentExporter.checkExports(in:output.appendingPathComponent("Exports")) { record(check) }
        for check in try await clipboard(in:output.appendingPathComponent("Clipboard")) { record(check) }
        return checks
    }
    static func settle(line: Int = #line, _ predicate: @escaping @MainActor () -> Bool) async throws {
        let start = Date()
        while !predicate() {
            if Date().timeIntervalSince(start) > 15 { throw NativeCheckFailure.failed("The native document did not settle within 15 seconds (check line \(line)).") }
            try await Task.sleep(for:.milliseconds(40))
        }
        try await Task.sleep(for:.milliseconds(60))
    }
    static func snapshot(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView else { throw NativeCheckFailure.failed("No native content view.") }
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw NativeCheckFailure.failed("Native snapshot failed.") }
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in:view.bounds,to:rep) }
        guard let data = rep.representation(using:.png,properties:[:]) else { throw NativeCheckFailure.failed("Native PNG encoding failed.") }
        try data.write(to:url,options:.atomic)
    }
}
