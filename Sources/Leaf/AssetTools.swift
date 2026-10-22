import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import LeafCore
import MarkdownEngine

actor AssetProcessor {
    func write(data: Data?, file: URL?, to destination: URL) throws {
        try Task.checkCancellation()
        if let data, data.count > 50_000_000 { throw WorkspaceError.invalidChange("Choose an image below 50 MB.") }
        if let file {
            let values = try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
            guard values.isRegularFile == true, values.fileSize ?? Int.max <= 50_000_000 else { throw WorkspaceError.invalidChange("Choose an image file below 50 MB.") }
        }
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".leaf-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:staged) }
        if let data { try data.write(to:staged,options:.atomic) }
        else if let file { try FileManager.default.copyItem(at:file,to:staged) }
        else { throw CocoaError(.fileReadUnknown) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at:staged,to:destination)
    }
    func jpeg(from url: URL, width: Int, quality: Double, to destination: URL) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".leaf-jpeg-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at:staged) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:max(32,min(12000,width))] as CFDictionary),
              let output = CGImageDestinationCreateWithURL(staged as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { throw CocoaError(.fileReadCorruptFile) }
        CGImageDestinationAddImage(output,image,[kCGImageDestinationLossyCompressionQuality:max(0.1,min(1,quality))] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        try Data(contentsOf:staged).write(to:destination,options:.atomic)
    }
}

@MainActor extension DocumentModel {
    func pasteImage(_ pasteboard: NSPasteboard) -> String? {
        let file = PasteboardImageReader.imageFileURL(from:pasteboard)
        let data = file == nil ? PasteboardImageReader.imageData(from:pasteboard) : nil
        let ext = file?.pathExtension.lowercased() ?? "png"
        guard data != nil || file != nil else { return nil }
        guard let parent = fileURL?.deletingLastPathComponent() else { status = "Save this document before adding images."; return "" }
        let stem = file?.deletingPathExtension().lastPathComponent ?? "Image"
        let name = stem + "-" + UUID().uuidString.prefix(6) + "." + ext
        let relative = "assets/" + name, destination = parent.appendingPathComponent(relative)
        let original = source, sourceURL = fileURL
        let anchor = textView?.selectedRange() ?? NSRange(location:(source as NSString).length,length:0)
        let description = stem.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"]",with:"\\]")
        let markdown = "![\(description)](\(WorkspaceIndex.encodePath(relative)))"
        let id = UUID(), assetData = data, assetFile = file
        assetTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { assetTasks[id] = nil }
            do {
                try await assetProcessor.write(data:assetData,file:assetFile,to:destination)
                try Task.checkCancellation()
                guard fileURL == sourceURL, !workspaceBusy,
                      let range = Self.rebasedImageRange(anchor,from:original,to:source) else {
                    status = "Image saved in assets. Insert it from the Asset Manager when ready."; refresh(); return
                }
                let text = source as NSString
                let prefix = range.location > 0 && text.character(at:range.location - 1) != 10 ? "\n" : ""
                let suffix = NSMaxRange(range) < text.length && text.character(at:NSMaxRange(range)) != 10 ? "\n" : ""
                replaceSource(range,with:prefix + markdown + suffix,title:"Insert Image")
                refresh()
            }
            catch is CancellationError { }
            catch { status = "Image could not be saved: \(error.localizedDescription)" }
        }
        // The native paste/drop delegate is handled. Source changes only after
        // persistence succeeds; a failed image write never replaces selection.
        return ""
    }
    private static func rebasedImageRange(_ range:NSRange,from original:String,to current:String) -> NSRange? {
        guard original != current else { return range }
        let old = original as NSString, new = current as NSString
        var prefix = 0, suffix = 0
        while prefix < min(old.length,new.length), old.character(at:prefix) == new.character(at:prefix) { prefix += 1 }
        while suffix < min(old.length,new.length) - prefix, old.character(at:old.length - suffix - 1) == new.character(at:new.length - suffix - 1) { suffix += 1 }
        let end = old.length - suffix
        if prefix == end, prefix == range.location, range.length == 0 { return range }
        if end <= range.location { return NSRange(location:range.location + new.length - old.length,length:range.length) }
        if prefix >= NSMaxRange(range) { return range }
        return nil
    }
    func chooseImage() {
        guard fileURL != nil else { status = "Save this document before adding images."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image,.pdf]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let pasteboard = NSPasteboard.withUniqueName(); pasteboard.writeObjects([file as NSURL])
        if let text = pasteImage(pasteboard), !text.isEmpty { insert("\n" + text + "\n") }
        pasteboard.releaseGlobally()
    }
}

struct AssetTool: View {
    @ObservedObject var model: DocumentModel
    @State private var assets: AssetIndex?
    @State private var selectedPath: String?
    @State private var filter = "all"
    @State private var error: String?
    @State private var preview: WorkspaceChangeSet?
    @State private var destination = ""
    @State private var alt = ""
    @State private var width = 1600.0
    @State private var quality = 0.8
    @State private var image: NSImage?
    @State private var working = false
    private var records: [WorkspaceAsset] {
        guard let assets else { return [] }
        switch filter { case "unused": return assets.unused; case "duplicates": let hashes = Set(assets.duplicateGroups.flatMap { $0.map(\.sha256) }); return assets.records.filter { hashes.contains($0.sha256) }; default: return assets.records }
    }
    private var selected: WorkspaceAsset? { records.first { $0.relativePath == selectedPath } }
    var body: some View {
        VStack(spacing: 0) {
            if let workspace = model.workspace {
                HSplitView {
                    VStack(spacing: 8) {
                        Picker("Show",selection:$filter) { Text("All").tag("all"); Text("Unused").tag("unused"); Text("Duplicates").tag("duplicates") }.labelsHidden().padding(10)
                        List(records,selection:$selectedPath) { asset in
                            VStack(alignment:.leading,spacing:3) { Text(asset.url.lastPathComponent).lineLimit(1); Text(ByteCountFormatter.string(fromByteCount:asset.size,countStyle:.file)).font(.caption).foregroundStyle(.secondary) }.tag(asset.relativePath)
                        }.listStyle(.sidebar)
                    }.frame(width:220)
                    if let preview { ChangePreview(changes:preview) }
                    else if let selected {
                        ScrollView {
                            VStack(alignment:.leading,spacing:14) {
                                if let image { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(maxWidth:.infinity,maxHeight:160).background(.quaternary.opacity(0.4)) }
                                Text(selected.relativePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                LabeledContent("Used by", value:"\(selected.usages.count) links")
                                HStack { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([selected.url]) }; Button("Insert") { insert(selected) } }
                                Divider()
                                Text("Organize").font(.headline)
                                TextField("Relative path",text:$destination).textFieldStyle(.roundedBorder)
                                Button("Preview Move & Link Updates") { move(selected,workspace:workspace) }.disabled(destination == selected.relativePath || working)
                                if let usage = selected.usages.first(where:{ $0.link.isEmbed && ($0.link.kind == .markdown || $0.link.kind == .html) }) {
                                    Divider(); Text("Alt text").font(.headline)
                                    Text(usage.relativePath).font(.caption).foregroundStyle(.secondary)
                                    TextField("Image description",text:$alt).textFieldStyle(.roundedBorder)
                                    Button("Preview Alt Text Change") { altText(selected,workspace:workspace) }
                                }
                                if image != nil {
                                    Divider(); Text("Prepare a smaller copy").font(.headline)
                                    HStack { Text("Max dimension"); Slider(value:$width,in:320...6000,step:80); Text("\(Int(width)) px").monospacedDigit().frame(width:65) }
                                    HStack { Text("JPEG quality"); Slider(value:$quality,in:0.3...1); Text("\(Int(quality*100))%").monospacedDigit().frame(width:40) }
                                    Button("Save JPEG Copy…") { resize(selected) }.disabled(working)
                                }
                            }.padding(18)
                        }
                    } else {
                        VStack(spacing:10) { Spacer(); Image(systemName:"photo.on.rectangle").font(.system(size:30)).foregroundStyle(.tertiary); Text(records.isEmpty ? "No matching assets." : "Select an asset.").foregroundStyle(.secondary); Spacer() }.frame(maxWidth:.infinity)
                    }
                }
                Divider()
                HStack {
                    Button("Insert Image…") { model.chooseImage() }
                    if preview != nil { Button("Back") { preview = nil } }
                    Text(error ?? "\(assets?.records.count ?? 0) assets").font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red).lineLimit(2)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    if let preview { Button("Apply Changes") { apply(preview) }.disabled(working || preview.isEmpty).keyboardShortcut(.defaultAction) }
                }.padding(12)
            } else { FolderRequired(model:model) }
        }
        .task(id:model.workspace?.documents.map(\.data).hashValue) { await load() }
        .task(id:selectedPath) {
            image = nil; preview = nil; error = nil
            guard let selected else { return }
            destination = selected.relativePath; alt = selected.usages.first(where:{ $0.link.isEmbed })?.link.label ?? ""
            if let data = try? await model.loader.bytes(selected.url), !Task.isCancelled { image = NSImage(data:data) }
        }
    }
    private func load() async {
        guard let workspace = model.workspace else { return }
        do { let result = try await model.loader.assets(workspace); try Task.checkCancellation(); assets = result; if selectedPath == nil { selectedPath = records.first?.relativePath } } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    private func insert(_ asset: WorkspaceAsset) {
        guard let fileURL = model.fileURL else { error = "Save this document first."; return }
        model.insert("![\(asset.url.deletingPathExtension().lastPathComponent)](\(WorkspaceIndex.encodePath(WorkspaceIndex.relativeTarget(from:fileURL.deletingLastPathComponent(),to:asset.url))))")
        model.sheet = nil
    }
    private func move(_ asset: WorkspaceAsset, workspace: WorkspaceIndex) {
        working = true
        Task {
            defer { working = false }
            do { preview = try await model.loader.moveAsset(asset,workspace:workspace,to:destination); error = nil } catch { self.error = error.localizedDescription }
        }
    }
    private func altText(_ asset: WorkspaceAsset, workspace: WorkspaceIndex) {
        guard let usage = asset.usages.first(where:{ $0.link.isEmbed && ($0.link.kind == .markdown || $0.link.kind == .html) }), let document = workspace.document(at:usage.sourceURL) else { return }
        do {
            let source = try AssetDescriptionEdit.replacing(usage.link,in:document.source,with:alt)
            preview = WorkspaceChangeSet(title:"Change Alt Text",changes:[.init(beforePath:document.relativePath,afterPath:document.relativePath,before:document.data,after:Data(source.utf8),replacementCount:1)])
        } catch { self.error = error.localizedDescription }
    }
    private func resize(_ asset: WorkspaceAsset) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = asset.url.deletingPathExtension().lastPathComponent + "-small.jpg"; panel.directoryURL = asset.url.deletingLastPathComponent(); panel.allowedContentTypes = [.jpeg]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        working = true
        Task { defer { working = false }; do { try await model.assetProcessor.jpeg(from:asset.url,width:Int(width),quality:quality,to:destination); model.refresh(); await load() } catch { self.error = error.localizedDescription } }
    }
    private func apply(_ changes: WorkspaceChangeSet) {
        working = true
        Task { defer { working = false }; do { try await model.applyChanges(changes); preview = nil; selectedPath = destination; await load() } catch { self.error = error.localizedDescription } }
    }
}

extension WorkspaceLoader {
    func moveAsset(_ asset: WorkspaceAsset, workspace: WorkspaceIndex, to path: String) throws -> WorkspaceChangeSet {
        let target = workspace.root.appendingPathComponent(path).standardizedFileURL
        var changes: [WorkspaceFileChange] = [.init(beforePath:asset.relativePath,afterPath:path,before:try Data(contentsOf:asset.url),after:try Data(contentsOf:asset.url))]
        for document in workspace.documents {
            let edits = asset.usages.filter { $0.sourceURL == document.url }.map { usage in
                (usage.link.targetRange, WorkspaceIndex.encodePath(WorkspaceIndex.relativeTarget(from:document.url.deletingLastPathComponent(),to:target)))
            }
            guard !edits.isEmpty else { continue }
            changes.append(.init(beforePath:document.relativePath,afterPath:document.relativePath,before:document.data,after:Data(WorkspaceIndex.replacing(document.source,replacements:edits).utf8),replacementCount:edits.count))
        }
        return WorkspaceChangeSet(title:"Move Asset",changes:changes)
    }
}
