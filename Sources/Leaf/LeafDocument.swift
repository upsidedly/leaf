import AppKit
import SwiftUI
import LeafCore
import LeafRender

enum EditorMode: String, CaseIterable, Identifiable { case live = "Live", source = "Source", split = "Split", reading = "Reading"; var id: String { rawValue } }
enum InspectorTab: String, CaseIterable { case outline = "Outline", links = "Links", issues = "Issues", assets = "Assets" }
enum ToolSheet: String, Identifiable { case palette, quickOpen, search, rename, table, templates, export, diagram, assets; var id: String { rawValue } }

actor WorkspaceLoader {
    func load(_ root: URL) throws -> WorkspaceIndex { try WorkspaceIndex(root: root) }
    func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func preferences(_ global: LeafSettings, root: URL?) throws -> LeafSettings {
        guard let root else { return global }
        let url = root.appendingPathComponent(".leaf/settings.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return global }
        return try LeafSettings.merged(Data(contentsOf:url),over:global)
    }
    func index(_ source: String) -> (index: MarkdownIndex, words: Int, characters: Int) { (MarkdownIndex(source: source), source.split { $0.isWhitespace || $0.isNewline }.count, source.count) }
    func issues(_ workspace: WorkspaceIndex) -> [WorkspaceIssue] { workspace.diagnostics() }
    func assets(_ workspace: WorkspaceIndex) throws -> AssetIndex { try AssetIndex(workspace: workspace) }
    func apply(_ changes: WorkspaceChangeSet, root: URL) throws -> WorkspaceJournal { try changes.apply(to: root) }
    func undo(_ journal: WorkspaceJournal) throws { try journal.undo() }
}

@MainActor final class DocumentModel: ObservableObject {
    @Published var source = ""
    @Published var workspaceBusy = false
    var editorWidth: Double = 768
    @Published var mode: EditorMode = .live
    @Published var showSidebar = false
    @Published var showInspector = false
    @Published var inspector: InspectorTab = .outline
    @Published var sheet: ToolSheet?
    @Published var workspace: WorkspaceIndex?
    @Published var workspacePreferences: LeafSettings?
    @Published var workspaceIssues: [WorkspaceIssue] = []
    @Published var root: URL?
    @Published var status: String?
    @Published var conflict: Data?
    @Published var rendering = false
    @Published var html = ""
    @Published var revision = 0
    @Published var renderedRevision = 0
    @Published var focusMode = false
    @Published var typewriterMode = false
    @Published var journal: WorkspaceJournal?
    weak var document: LeafDocument?
    weak var textView: NSTextView?
    let diagramEngine = DiagramEngine()
    let markupEngine = MarkupEngine()
    let loader = WorkspaceLoader()
    let assetProcessor = AssetProcessor()
    var assetTasks: [UUID:Task<Void,Never>] = [:]
    let renderCache = EditorRenderCache()
    var enhancements: EditorEnhancements?
    private var lastDisk: Data?
    private var savedURL: URL?
    private var workspaceTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    var navigationTask: Task<Void,Never>?
    var workspaceOperation: Task<Void,Never>?
    private var workspaceStamp: Int?
    private var preferenceTask: Task<Void,Never>?
    @Published var index = MarkdownIndex(source: "")
    @Published var words = 0
    @Published var characterCount = 0
    var settings: LeafSettings { workspacePreferences ?? SettingsStore.shared.value }
    var isDark: Bool { (document?.windowControllers.first?.window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from:[.darkAqua,.aqua]) == .darkAqua }
    var title: String { document?.displayName ?? "Untitled" }
    var fileURL: URL? { document?.fileURL }

    func edit(_ value: String) {
        guard source != value else { return }
        source = value; revision += 1; document?.buffer.edit(value)
        let baseline = lastDisk.flatMap { String(data:$0,encoding:.utf8) } ?? ""
        document?.updateChangeCount(value == baseline ? .changeCleared : .changeDone)
        scheduleRender()
    }
    func load(_ value: String, bytes: Data?) {
        let value = value.hasPrefix("\u{feff}") ? String(value.dropFirst()) : value
        if source != value, textView != nil { document?.undoManager?.removeAllActions() }
        source = value; lastDisk = bytes; revision += 1
        if let bytes { document?.buffer.read(value, data: bytes) } else { document?.buffer.edit(value) }
        scheduleRender()
    }
    func didSave(_ bytes: Data) {
        lastDisk = bytes; conflict = nil; document?.buffer.saved(bytes)
        if savedURL != fileURL, let fileURL {
            savedURL = fileURL
            if root.map({ !fileURL.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }) ?? true {
                openWorkspace(fileURL.deletingLastPathComponent(),reveal:showSidebar)
            } else { scheduleRender() }
        }
    }
    func start() {
        savedURL = fileURL
        focusMode = settings.focusMode; typewriterMode = settings.typewriterMode
        if let parent = fileURL?.deletingLastPathComponent() { openWorkspace(parent, reveal: false) }
        scheduleRender(); startMonitor()
    }
    func stop() { workspaceTask?.cancel(); monitorTask?.cancel(); renderTask?.cancel(); preferenceTask?.cancel(); navigationTask?.cancel(); workspaceOperation?.cancel(); assetTasks.values.forEach { $0.cancel() }; enhancements?.stop() }
    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open Folder"
        if panel.runModal() == .OK, let url = panel.url { openWorkspace(url) }
    }
    func openWorkspace(_ url: URL, reveal: Bool = true) {
        root = url; reloadSettings(); if reveal { showSidebar = true }
        workspaceTask?.cancel()
        workspaceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await loader.load(url)
                try Task.checkCancellation()
                guard self.root == url else { return }
                workspace = snapshot
                workspaceStamp = try await loader.stamp(url)
                journal = await loader.latestJournal(url)
                workspaceIssues = await loader.issues(snapshot)
                guard !Task.isCancelled else { return }
                scheduleRender()
            } catch is CancellationError { }
            catch { status = "Folder could not be read: \(error.localizedDescription)" }
        }
    }
    func open(_ url: URL, range: NSRange? = nil, fragment: String? = nil) {
        let originatingRoot = root
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error { NSApp.presentError(error); return }
            guard let target = document as? LeafDocument else { return }
            if let originatingRoot, url.standardizedFileURL.path.hasPrefix(originatingRoot.standardizedFileURL.path + "/"), target.model.root != originatingRoot { target.model.openWorkspace(originatingRoot,reveal:self.showSidebar) }
            if range != nil || fragment != nil { target.model.requestNavigation(range:range,fragment:fragment) }
        }
    }
    func follow(_ raw: String) {
        let components = URLComponents(string:raw)
        let reference = components?.scheme == "leaf" && components?.host == "open"
            ? components?.queryItems?.first(where:{$0.name == "target"})?.value ?? raw : raw
        let target = reference.components(separatedBy:"|").first ?? reference
        if target.hasPrefix("#") { requestNavigation(fragment:String(target.dropFirst())); return }
        if let url = URL(string:target), url.isFileURL {
            if url.standardizedFileURL.path == fileURL?.standardizedFileURL.path, let fragment = url.fragment { requestNavigation(fragment:fragment); return }
            let file = URL(fileURLWithPath:url.path)
            if WorkspaceIndex.markdownExtensions.contains(file.pathExtension.lowercased()) { open(file,fragment:url.fragment) }
            else { NSWorkspace.shared.open(file) }
            return
        }
        if let workspace, let resolved = workspace.resolve(target, from: fileURL ?? workspace.root) {
            if resolved.isDocument { open(resolved.url,fragment:resolved.fragment) }
            else { NSWorkspace.shared.open(resolved.url) }
            return
        }
        if let url = URL(string:target), ["http","https","mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        else { status = "Could not find \(target)." }
    }
    func jump(_ range: NSRange) {
        guard let textView else { return }
        let safe = NSRange(location: min(range.location, (textView.string as NSString).length), length: 0)
        textView.setSelectedRange(safe); textView.scrollRangeToVisible(safe); textView.window?.makeFirstResponder(textView)
    }
    func insert(_ text: String) {
        guard !workspaceBusy else { return }
        guard let textView else { edit(source + text); return }
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
    func wrap(_ prefix: String, _ suffix: String) {
        guard !workspaceBusy else { return }
        guard let textView else { return }
        let range = textView.selectedRange(), selected = (textView.string as NSString).substring(with: range)
        textView.insertText(prefix + selected + suffix, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + (prefix as NSString).length, length: (selected as NSString).length))
    }
    func refresh() { if let root { openWorkspace(root, reveal: false) }; scheduleRender() }
    func keepMine() {
        guard let url = fileURL, let other = conflict else { return }
        do {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Leaf/Conflicts")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let backup = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try other.write(to: backup, options: .atomic)
            lastDisk = other; conflict = nil; document?.buffer.saved(other); document?.save(nil)
        } catch { status = "Could not preserve the external copy: \(error.localizedDescription)" }
    }
    func useExternal() {
        guard let data = conflict, let text = String(data: data, encoding: .utf8) else { return }
        let previous = source
        document?.buffer.setConflict(false)
        load(text, bytes: data); conflict = nil; document?.updateChangeCount(.changeCleared)
        document?.undoManager?.registerUndo(withTarget:self) { target in target.replaceWholeSource(previous,title:"Use External Copy") }
    }
    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var polls = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
                guard let self, !self.workspaceBusy, let url = self.fileURL else { continue }
                do {
                    polls += 1
                    if polls % 2 == 0, let root = self.root {
                        let stamp = try await loader.stamp(root)
                        if stamp != workspaceStamp { openWorkspace(root,reveal:false) }
                    }
                    let data = try await self.loader.bytes(url)
                    guard !Task.isCancelled, data != self.lastDisk else { continue }
                    if self.document?.isDocumentEdited == true || self.textView?.hasMarkedText() == true { self.conflict = data; self.document?.buffer.setConflict(true) }
                    else if let text = String(data: data, encoding: .utf8) {
                        self.load(text, bytes: data); self.document?.updateChangeCount(.changeCleared); self.refresh()
                    }
                } catch { self.status = "File is unavailable: \(error.localizedDescription)" }
            }
        }
    }
    func reloadSettings() {
        preferenceTask?.cancel()
        let global = SettingsStore.shared.value, directory = root
        preferenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await loader.preferences(global,root:directory)
                try Task.checkCancellation()
                guard root == directory else { return }
                workspacePreferences = value; enhancements?.refreshSettings(); scheduleRender()
                (NSApp.delegate as? LeafAppDelegate)?.refreshMenus()
            } catch is CancellationError { } catch { status = "Folder settings could not be read: \(error.localizedDescription)" }
        }
    }
    func scheduleRender() {
        renderTask?.cancel()
        let generation = revision, input = source, preferences = settings, workspaceSnapshot = workspace
        rendering = true
        renderTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(160))
                let parsed = await loader.index(input)
                try Task.checkCancellation()
                guard generation == revision else { return }
                index = parsed.index; words = parsed.words; characterCount = parsed.characters
                let expanded: String
                if let workspaceSnapshot, let fileURL {
                    expanded = (try? TransclusionResolver(workspace: workspaceSnapshot).expand(input, from: fileURL).source) ?? input
                } else { expanded = input }
                var options = RenderOptions()
                options.title = title; options.bodyFont = preferences.bodyFont == "System" ? "-apple-system" : preferences.bodyFont
                options.codeFont = preferences.codeFont == "System Mono" ? "ui-monospace" : preferences.codeFont
                options.fontSize = preferences.bodySize; options.lineHeight = 1.5; options.contentWidth = preferences.contentWidth
                options.dark = isDark
                options.includeTOC = preferences.exportTOC
                let rendered = try await markupEngine.html(expanded, options: options)
                let html = try await DocumentExporter.embedAssets(in:rendered,baseURL:fileURL?.deletingLastPathComponent(),strict:false)
                try Task.checkCancellation()
                guard generation == revision else { return }
                self.html = html.replacingOccurrences(of:"</head>",with:LeafStyle.css(preferences) + "</head>")
                try await buildBlockCache(input, index: parsed.index, generation: generation, preferences: preferences, workspace: workspaceSnapshot)
                guard !Task.isCancelled, generation == revision else { return }
                rendering = false; renderedRevision += 1
            } catch is CancellationError { }
            catch { if generation == revision { rendering = false; status = error.localizedDescription } }
        }
    }
}

@MainActor final class LeafDocument: NSDocument {
    let model = DocumentModel()
    nonisolated let buffer = DocumentBuffer()
    override init() { super.init(); model.document = self; hasUndoManager = true }
    // AppKit queries these constants from its file-coordination queue as well
    // as the main thread. They have no UI state and must not inherit the
    // document's main-actor isolation (including Objective-C entry thunks).
    nonisolated override class var autosavesInPlace: Bool { true }
    nonisolated override class var preservesVersions: Bool { true }
    override var autosavingFileType: String? { fileType ?? "net.daringfireball.markdown" }
    override func makeWindowControllers() {
        let initial = buffer.snapshot()
        model.load(initial.source, bytes: initial.baseline)
        let controller = LeafWindowController(model: model)
        addWindowController(controller)
        model.start()
    }
    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        guard let raw = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        let text = raw.hasPrefix("\u{feff}") ? String(raw.dropFirst()) : raw
        let revision = buffer.read(text, data: data)
        Task { @MainActor [weak self] in
            guard let self, self.buffer.snapshot().revision == revision else { return }
            self.model.load(text, bytes: data)
        }
    }
    nonisolated override func data(ofType typeName: String) throws -> Data { try buffer.data() }
    nonisolated override func writeSafely(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) throws {
        let snapshot = buffer.snapshot()
        if let baseline = snapshot.baseline, FileManager.default.fileExists(atPath: url.path),
           saveOperation == .saveOperation || saveOperation == .autosaveInPlaceOperation {
            let actual = try Data(contentsOf: url)
            if actual != baseline, actual != (try? buffer.data()) {
                buffer.setConflict(true)
                Task { @MainActor [weak self] in
                    guard let self, self.buffer.snapshot().revision == snapshot.revision,
                          self.buffer.snapshot().conflicted else { return }
                    self.model.conflict = actual
                }
                throw NSError(domain: "Leaf", code: 3, userInfo: [NSLocalizedDescriptionKey: "The file changed elsewhere. Review the external copy before saving."])
            }
        }
        // This boundary surrounds AppKit's staging AND final replacement. A
        // write(to:) override sees a temporary URL during coordinated saves.
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        let written = try Data(contentsOf: url)
        if saveOperation != .autosaveElsewhereOperation {
            buffer.saved(written)
            Task { @MainActor [weak self] in
                guard let self, self.buffer.snapshot().baseline == written else { return }
                self.model.didSave(written)
            }
        }
    }
    override func close() { model.stop(); super.close() }
}

@MainActor final class LeafDocumentController: NSDocumentController {
    override var defaultType: String? { "net.daringfireball.markdown" }
    override func documentClass(forType typeName: String) -> AnyClass? { LeafDocument.self }
}
