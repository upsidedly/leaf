import AppKit
import SwiftUI
import LeafCore
import MarkdownEngine
import WebKit

@MainActor extension LeafNativeChecks {
    static func editingWorkflows(document:LeafDocument,editor:NSTextView,fixture:String,root:URL,output:URL) async throws -> [String] {
        func require(_ condition:Bool,_ message:String) throws { if !condition { throw NativeCheckFailure.failed(message) } }
        var result:[String] = []
        func report(_ message:String) { result.append(message); FileHandle.standardOutput.write(Data(("CHECK " + message + "\n").utf8)) }
        let model = document.model
        try require(MarkdownHTMLRenderer.html(from:"Follow [[Notes|a useful detail]].").contains("Follow a useful detail."),"Formatted copy did not preserve the visible wiki alias.")
        func replace(_ source:String) {
            _ = editor.tryToPerform(NSSelectorFromString("leafClearCarets:"),with:nil)
            editor.breakUndoCoalescing(); editor.selectAll(nil); editor.insertText(source,replacementRange:editor.selectedRange()); editor.breakUndoCoalescing()
        }

        editor.breakUndoCoalescing(); editor.undoManager?.removeAllActions()
        model.mode = .source
        try await settle { model.textView === editor && editor.isEditable }
        editor.setSelectedRange(.init(location:(editor.string as NSString).length,length:0))
        editor.insertText("MODE-UNDO",replacementRange:editor.selectedRange()); editor.breakUndoCoalescing()
        try await settle { model.source.hasSuffix("MODE-UNDO") }
        model.mode = .reading
        try await settle { model.textView === editor && !editor.isEditable }
        model.mode = .live
        try await settle { editor.isEditable }
        editor.undoManager?.undo()
        try await settle { model.source == fixture }
        report("Source/live/reading transitions preserve the native editor and typing Undo")
        editor.setSelectedRange(.init(location:0,length:0))
        editor.setMarkedText("日本",selectedRange:.init(location:2,length:0),replacementRange:editor.selectedRange())
        model.mode = .source
        try await settle { !editor.hasMarkedText() && model.source.hasPrefix("日本") }
        model.mode = .live
        replace(fixture)
        try await settle { model.source == fixture }
        report("A presentation change commits active IME text without replacing composition")

        model.mode = .source
        replace("abcd\nabcd\nabcd\n")
        try await settle { model.source == "abcd\nabcd\nabcd\n" }
        editor.layoutSubtreeIfNeeded()
        func rect(_ index:Int) -> NSRect {
            let screen = editor.firstRect(forCharacterRange:.init(location:index,length:0),actualRange:nil)
            guard let window = editor.window else { return .zero }
            return editor.convert(window.convertFromScreen(screen),from:nil)
        }
        let first = rect(0), column = rect(2), last = rect(10)
        editor.leafSelectRectangle(from:.init(x:first.minX,y:first.midY),to:.init(x:column.minX,y:last.midY))
        if let window = editor.window { try snapshot(window,to:output.appendingPathComponent("leaf-rectangle.png")) }
        try require(editor.leafAdditionalSelections.count == 2,"Rectangular selection did not select three native visual lines.")
        editor.breakUndoCoalescing(); editor.undoManager?.removeAllActions()
        editor.insertText("zz",replacementRange:editor.selectedRange())
        try await settle { model.source == editor.string }
        try require(editor.string == "zzcd\nzzcd\nzzcd\n","Rectangular editing changed the wrong columns.")
        editor.undoManager?.undo()
        try await settle { model.source == "abcd\nabcd\nabcd\n" }
        report("TextKit 2 rectangular selection, column replacement and Undo")

        model.mode = .live
        replace("**mark**\n\n**mark**\n\nA note[^1].\n\n[^1]: Footnote detail.\n")
        try await settle { !model.rendering && model.source == editor.string }
        editor.setSelectedRange(.init(location:2,length:4))
        _ = editor.tryToPerform(NSSelectorFromString("leafAddNextOccurrence:"),with:nil)
        try await settle { (editor.textStorage?.attribute(.font,at:10,effectiveRange:nil) as? NSFont)?.pointSize ?? 0 > 5 }
        try require(editor.leafAdditionalSelections.count == 1,"The second live Markdown selection was not retained.")
        _ = editor.tryToPerform(NSSelectorFromString("leafClearCarets:"),with:nil)
        try await settle { (editor.textStorage?.attribute(.font,at:10,effectiveRange:nil) as? NSFont)?.pointSize ?? 100 < 2 }
        let footnote = (editor.string as NSString).range(of:"1]").location
        try require((editor.textStorage?.attribute(.baselineOffset,at:footnote,effectiveRange:nil) as? NSNumber)?.doubleValue ?? 0 > 0,"Live footnote references were not presented as superscripts.")
        report("Independent source reveal at secondary carets and live footnote presentation")

        replace(fixture)
        try await settle { model.source == fixture }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size:.init(width:160,height:100))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x:0,y:0,width:160,height:100).fill(); image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data:tiff), let png = bitmap.representation(using:.png,properties:[:]) else { throw NativeCheckFailure.failed("Image fixture encoding failed.") }
        pasteboard.setData(png,forType:.png)
        try require(editor.leafDropImage(from:pasteboard,at:rect((editor.string as NSString).length).origin),"The native image drop destination rejected a PNG.")
        try await settle { model.assetTasks.isEmpty && model.source.contains("](assets/") }
        let imageLink = MarkdownIndex(source:model.source).links.first { $0.isEmbed && $0.target.hasPrefix("assets/") }
        guard let imageLink else { throw NativeCheckFailure.failed("Image drop did not insert a relative Markdown target.") }
        let imageURL = root.appendingPathComponent(imageLink.target.removingPercentEncoding ?? imageLink.target)
        try require(try Data(contentsOf:imageURL) == png,"Dropped image bytes were not stored next to the document.")
        let jpeg = root.appendingPathComponent("Smaller.jpg")
        try await model.assetProcessor.jpeg(from:imageURL,width:32,quality:0.7,to:jpeg)
        guard let resized = NSImage(contentsOf:jpeg) else { throw NativeCheckFailure.failed("JPEG compression did not produce a readable image.") }
        try require(resized.size.width <= 32 && resized.size.height <= 32,"JPEG resizing ignored the maximum dimension.")
        let savedJPEG = try Data(contentsOf:jpeg)
        do { try await model.assetProcessor.jpeg(from:root.appendingPathComponent("Missing.png"),width:32,quality:0.7,to:jpeg); throw NativeCheckFailure.failed("Invalid image input was accepted.") }
        catch is NativeCheckFailure { throw NativeCheckFailure.failed("Invalid image input was accepted.") }
        catch { try require(try Data(contentsOf:jpeg) == savedJPEG,"Failed compression replaced an existing asset.") }
        report("Native image drop path, relative asset insertion and asynchronous local image write")
        try await settle { !model.rendering && model.html.contains("data:image/png;base64,") }
        let web = WKWebView(frame:NSRect(x:0,y:0,width:360,height:260))
        web.configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let coordinator = HTMLReader.Coordinator(onLink:{ _ in })
        web.navigationDelegate = coordinator
        let previewWindow = NSWindow(contentRect:web.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        previewWindow.contentView = web; previewWindow.orderFront(nil)
        defer { previewWindow.orderOut(nil) }
        let rawPreview = try await model.markupEngine.html("![Image](\(imageLink.target))").replacingOccurrences(of:"loading=\"lazy\"",with:"width=\"120\" height=\"120\"")
        let preview = try await DocumentExporter.embedAssets(in:rawPreview,baseURL:root,strict:false)
        web.loadHTMLString(preview,baseURL:model.fileURL)
        try await settle { coordinator.finished && !web.isLoading }
        let webImage: NSImage = try await withCheckedThrowingContinuation { continuation in
            web.takeSnapshot(with:nil) { image,error in
                if let image { continuation.resume(returning:image) }
                else { continuation.resume(throwing:error ?? NativeCheckFailure.failed("The reading preview did not produce an image.")) }
            }
        }
        guard let webTIFF = webImage.tiffRepresentation, let webPixels = NSBitmapImageRep(data:webTIFF), let webPNG = webPixels.representation(using:.png,properties:[:]) else { throw NativeCheckFailure.failed("Reading preview PNG encoding failed.") }
        try webPNG.write(to:output.appendingPathComponent("leaf-local-image-preview.png"))
        var blue = 0
        for y in stride(from:0,to:webPixels.pixelsHigh,by:4) { for x in stride(from:0,to:webPixels.pixelsWide,by:4) {
            if let color = webPixels.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),color.blueComponent > 0.65,color.redComponent < 0.4,color.greenComponent > 0.2 { blue += 1 }
        } }
        try require(blue > 500,"The reading view did not load the local image.")
        let missingPreview = try await DocumentExporter.embedAssets(in:"<img src='missing.png' alt='A missing image'>",baseURL:root,strict:false)
        try require(missingPreview.contains("Image unavailable: A missing image"),"Missing preview images do not have a readable fallback.")
        report("JavaScript-disabled reading view decodes local relative images")
        let failureRoot = root.appendingPathComponent("BlockedAssets",isDirectory:true)
        try FileManager.default.createDirectory(at:failureRoot,withIntermediateDirectories:true)
        try Data("This file prevents creating an assets directory.".utf8).write(to:failureRoot.appendingPathComponent("assets"))
        let failureDocument = LeafDocument(); failureDocument.fileURL = failureRoot.appendingPathComponent("Untouched.md")
        failureDocument.model.load("Keep this selected text.",bytes:Data("Keep this selected text.".utf8))
        _ = failureDocument.model.pasteImage(pasteboard)
        try await settle { failureDocument.model.assetTasks.isEmpty }
        try require(failureDocument.model.source == "Keep this selected text." && failureDocument.model.status?.hasPrefix("Image could not be saved:") == true,"Failed image persistence changed source or failed silently.")
        failureDocument.model.stop()
        report("Failed image persistence preserves source and reports the failure")

        replace(fixture)
        try await settle { model.source == fixture && !model.rendering }
        try document.writeSafely(to:root.appendingPathComponent("Recovery.mdx"),ofType:"dev.upsided.leaf.mdx",for:.autosaveElsewhereOperation)
        try require(try Data(contentsOf:root.appendingPathComponent("Recovery.mdx")) == Data(fixture.utf8),"Recovery autosave did not preserve source bytes.")
        try require(document.buffer.snapshot().baseline == Data(fixture.utf8),"Recovery autosave changed the on-disk baseline.")
        let bom = Data([0xef,0xbb,0xbf]) + Data("# Unicode 🐊\r\n".utf8)
        let bomDocument = LeafDocument(); try bomDocument.read(from:bom,ofType:"net.daringfireball.markdown")
        try require(try bomDocument.data(ofType:"net.daringfireball.markdown") == bom,"BOM or CRLF source did not round-trip.")
        document.updateChangeCount(.changeCleared)
        report("Recovery autosave keeps the original baseline; UTF-8 BOM, emoji and CRLF round-trip")
        editor.setSelectedRange(.init(location:(editor.string as NSString).length,length:0))
        editor.insertText("NATIVE-AUTOSAVE",replacementRange:editor.selectedRange()); editor.breakUndoCoalescing()
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,any Error>) in
            document.autosave(withImplicitCancellability:false) { error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume() }
            }
        }
        guard let savedFile = document.fileURL else { throw NativeCheckFailure.failed("Autosave lost the document URL.") }
        try require(try String(contentsOf:savedFile,encoding:.utf8) == fixture + "NATIVE-AUTOSAVE","Coordinated autosave did not save the latest source.")
        replace(fixture)
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,any Error>) in
            document.save(to:savedFile,ofType:"dev.upsided.leaf.mdx",for:.saveOperation) { error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume() }
            }
        }
        try require(try Data(contentsOf:savedFile) == Data(fixture.utf8),"Coordinated save did not restore exact source bytes.")
        report("AppKit coordinated autosave and save commit current source with version preservation enabled")
        if let window = editor.window {
            model.mode = .split
            try await Task.sleep(for:.milliseconds(350))
            try snapshot(window,to:output.appendingPathComponent("leaf-split.png"))
            model.mode = .reading
            try await Task.sleep(for:.milliseconds(350))
            try snapshot(window,to:output.appendingPathComponent("leaf-reading.png"))
            model.mode = .live
            let tools = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:560),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            tools.title = "Leaf Settings"; tools.contentView = NSHostingView(rootView:SettingsView()); tools.orderFront(nil)
            try await Task.sleep(for:.milliseconds(200)); try snapshot(tools,to:output.appendingPathComponent("leaf-settings.png")); tools.orderOut(nil)
            let canvasState = CanvasCheckState()
            let diagramSource = "flowchart LR\n" + (1...7).map { "N\($0)[A deliberate step \($0)] --> N\($0 + 1)[A deliberate step \($0 + 1)]" }.joined(separator:"\n")
            let diagram = try await model.diagramEngine.render(diagramSource)
            guard let diagramImage = NSImage(data:Data(diagram.svg.utf8)) else { throw NativeCheckFailure.failed("The canvas diagram did not decode.") }
            let canvasWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            canvasWindow.contentView = NSHostingView(rootView:CanvasCheckView(state:canvasState,image:diagramImage)); canvasWindow.orderFront(nil)
            defer { canvasWindow.orderOut(nil) }
            func scrollView(in view:NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView(in:$0) }.first
            }
            try await settle { canvasState.zoom < 1 && canvasState.zoom > 0.1 }
            guard let content = canvasWindow.contentView, let canvas = scrollView(in:content) else { throw NativeCheckFailure.failed("The native diagram canvas did not attach.") }
            canvas.magnification = 1.5
            try await settle { abs(canvasState.zoom - 1.5) < 0.01 }
            try snapshot(canvasWindow,to:output.appendingPathComponent("leaf-diagram-canvas.png"))
            report("Native diagram canvas fits after layout and tracks native magnification")
        }
        return result
    }

    static func workspaceWorkflows(document:LeafDocument,root:URL) async throws -> [String] {
        func require(_ condition:Bool,_ message:String) throws { if !condition { throw NativeCheckFailure.failed(message) } }
        let model = document.model
        let originalSettings = model.settings
        let settingsFile = root.appendingPathComponent(".leaf/settings.json")
        var override = originalSettings
        override.bodySize = originalSettings.bodySize == 18 ? 19 : 18
        override.showCounts = false; override.shortcuts["palette"] = "@j"; override.colors["text"] = "#334455"
        try override.save(to:settingsFile)
        model.document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        try await settle { NSApp.keyWindow === model.document?.windowControllers.first?.window }
        model.reloadSettings()
        try await settle { model.settings.bodySize == override.bodySize && !model.rendering }
        (NSApp.delegate as? LeafAppDelegate)?.refreshMenus()
        func commandItem(_ menu:NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.representedObject as? String == "palette" { return item }
                if let found = commandItem(item.submenu) { return found }
            }
            return nil
        }
        try require(commandItem(NSApp.mainMenu)?.keyEquivalent == "j","Folder-specific keyboard shortcuts did not update the native menu.")
        let styled = try NativeHTMLRenderer.attributed("<p>Configured HTML</p>",settings:override,baseURL:root)
        let color = (styled.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor)?.leafHex
        try require(color?.uppercased() == "#334455","Custom text colors did not apply to native HTML blocks.")
        try FileManager.default.removeItem(at:settingsFile)
        model.reloadSettings()
        try await settle { model.settings == originalSettings && !model.rendering }
        let child = root.appendingPathComponent("Sub/Linked.md"), renamed = root.appendingPathComponent("Sub/Renamed.md")
        try FileManager.default.createDirectory(at:child.deletingLastPathComponent(),withIntermediateDirectories:true)
        let childSource = "# Linked note\n\n## Target\n\nA useful target.\n"
        try Data(childSource.utf8).write(to:child)
        let referring = root.appendingPathComponent("References.md")
        try Data("[Target](Sub/Linked.md#target)\n".utf8).write(to:referring)
        model.openWorkspace(root,reveal:false)
        try await settle { model.workspace?.document(at:child) != nil }
        model.follow("leaf://open?target=Sub%2FLinked.md%23target")
        try await settle {
            NSDocumentController.shared.documents.contains { ($0 as? LeafDocument)?.fileURL == child && ($0 as? LeafDocument)?.model.textView != nil }
        }
        guard let opened = NSDocumentController.shared.documents.compactMap({$0 as? LeafDocument}).first(where:{$0.fileURL == child}) else { throw NativeCheckFailure.failed("Linked note did not open in a native document.") }
        defer { opened.updateChangeCount(.changeCleared); opened.close() }
        let target = MarkdownIndex(source:childSource).headings.first { $0.anchor == "target" }?.range.location
        try await settle { opened.model.textView?.selectedRange().location == target && opened.model.root == root }
        var checks = ["Folder typography, native HTML colors and keyboard shortcuts apply and reset", "Cross-file heading navigation, multiple native documents and originating folder preservation"]

        guard let workspace = model.workspace else { throw NativeCheckFailure.failed("Workspace did not load.") }
        let changes = try workspace.previewRenameFile(child,to:renamed)
        try await model.applyChanges(changes)
        try require(opened.fileURL == renamed && opened.model.source == childSource && !opened.isDocumentEdited,"Workspace rename did not reconcile the open document.")
        try require(try String(contentsOf:referring,encoding:.utf8).contains("Sub/Renamed.md#target"),"Rename did not update incoming links.")
        model.undoWorkspace()
        try await settle { model.journal == nil && !model.workspaceBusy && opened.fileURL == child }
        try require(try String(contentsOf:referring,encoding:.utf8).contains("Sub/Linked.md#target"),"Workspace Undo did not restore incoming links.")
        try require(opened.model.source == childSource && !opened.isDocumentEdited,"Workspace Undo did not restore the open file path and clean buffer.")
        checks.append("File rename and durable workspace Undo restore disk links, open paths and buffers")

        let fresh = try await model.loader.load(root)
        let second = try fresh.previewRenameFile(child,to:renamed)
        let locked = try model.lockWorkspaceDocuments(second,root:root,undo:false)
        let journal = try await model.loader.apply(second,root:root)
        opened.model.edit(childSource + "Late in-memory edit\n")
        model.reconcileWorkspaceDocuments(locked,changes:second,root:root,undo:false)
        model.unlockWorkspaceDocuments(locked)
        try require(opened.model.source.hasSuffix("Late in-memory edit\n") && opened.model.conflict != nil,"A late edit was silently replaced by a workspace change.")
        // Restore the isolated fixture through the explicit recovery path.
        opened.model.useExternal(); opened.updateChangeCount(.changeCleared)
        try await model.loader.undo(journal)
        opened.fileURL = child; opened.model.load(childSource,bytes:Data(childSource.utf8)); opened.updateChangeCount(.changeCleared)
        checks.append("Workspace transactions lock open editors and preserve bypassed late edits as explicit conflicts")

        model.document?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        let note = root.appendingPathComponent("Notes.md")
        let original = try Data(contentsOf:note)
        try Data("# Notes\n\n## One useful detail\n\nSYNCHRONIZED-EMBED-CHECK\n".utf8).write(to:note,options:.atomic)
        try await settle { model.html.contains("SYNCHRONIZED-EMBED-CHECK") }
        try original.write(to:note,options:.atomic)
        model.refresh()
        try await settle { !model.html.contains("SYNCHRONIZED-EMBED-CHECK") && !model.rendering }
        checks.append("External note edits refresh and restore linked heading transclusions")
        return checks
    }
}

@MainActor private final class CanvasCheckState:ObservableObject { @Published var zoom = 1.0 }
private struct CanvasCheckView:View {
    @ObservedObject var state:CanvasCheckState
    let image:NSImage
    var body:some View { DiagramCanvas(image:image,zoom:$state.zoom,fitToken:0) }
}
