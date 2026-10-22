import AppKit
import SwiftUI
import LeafCore

struct ToolHost: View {
    @ObservedObject var model: DocumentModel
    let tool: ToolSheet
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button { model.sheet = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close \(title)")
            }.padding(.horizontal, 20).padding(.vertical, 15)
            Divider()
            Group {
                switch tool {
                case .palette: CommandPalette(model: model)
                case .quickOpen: QuickOpen(model: model)
                case .search: WorkspaceSearchTool(model: model)
                case .rename: RenameTool(model: model)
                case .table: TableTool(model: model)
                case .templates: TemplateTool(model: model)
                case .diagram: DiagramTool(model: model)
                case .export: ExportTool(model: model)
                case .assets: AssetTool(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(width: tool == .palette || tool == .quickOpen ? 560 : 800, height: tool == .palette || tool == .quickOpen ? 420 : 600)
    }
    private var title: String {
        switch tool { case .palette: "Commands"; case .quickOpen: "Quick Open"; case .search: "Find in Folder"; case .rename: "Rename & Update Links"; case .table: "Table"; case .templates: "Templates & Snippets"; case .export: "Export"; case .diagram: "Diagram Canvas"; case .assets: "Assets" }
    }
}

struct LeafCommand: Identifiable {
    let id: String, title: String, symbol: String
    static let all: [LeafCommand] = [
        .init(id:"folder",title:"Open Folder",symbol:"folder"), .init(id:"quickOpen",title:"Quick Open",symbol:"doc.text.magnifyingglass"),
        .init(id:"search",title:"Find & Replace in Folder",symbol:"magnifyingglass"), .init(id:"diagram",title:"Open Diagram Canvas",symbol:"point.3.connected.trianglepath.dotted"),
        .init(id:"table",title:"Edit Table",symbol:"tablecells"), .init(id:"templates",title:"Insert Template or Snippet",symbol:"text.badge.plus"),
        .init(id:"rename",title:"Rename File or Heading",symbol:"pencil.line"), .init(id:"assets",title:"Manage Assets",symbol:"photo.on.rectangle"),
        .init(id:"export",title:"Export Document",symbol:"square.and.arrow.up"), .init(id:"source",title:"Toggle Source",symbol:"chevron.left.forwardslash.chevron.right"),
        .init(id:"mode.live",title:"Live Editing",symbol:"pencil"), .init(id:"mode.split",title:"Split View",symbol:"rectangle.split.2x1"),
        .init(id:"mode.reading",title:"Reading View",symbol:"book"), .init(id:"focus",title:"Toggle Focus Mode",symbol:"circle.dotted.circle"),
        .init(id:"typewriter",title:"Toggle Typewriter Mode",symbol:"text.cursor"), .init(id:"sidebar",title:"Toggle Sidebar",symbol:"sidebar.left"),
        .init(id:"inspector",title:"Toggle Inspector",symbol:"sidebar.right"), .init(id:"image",title:"Insert Image",symbol:"photo"),
        .init(id:"mermaid",title:"Insert Mermaid Diagram",symbol:"point.3.connected.trianglepath.dotted"), .init(id:"math",title:"Insert Math",symbol:"function"),
        .init(id:"pageBreak",title:"Insert Page Break",symbol:"rectangle.split.1x2"), .init(id:"workspaceSettings",title:"Save Settings for This Folder",symbol:"slider.horizontal.3")]
}

struct CommandPalette: View {
    @ObservedObject var model: DocumentModel
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool
    private var results: [LeafCommand] { LeafCommand.all.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            TextField("Search commands", text: $query).textFieldStyle(.plain).font(.system(size: 18)).padding(18).focused($focused).onSubmit(run)
            Divider()
            List(results, selection: $selection) { command in
                Label(command.title, systemImage: command.symbol).padding(.vertical, 4).tag(command.id).onTapGesture(count: 2) { selection = command.id; run() }
            }.listStyle(.plain)
            HStack { Text("↑ ↓ to choose · Return to run").font(.caption).foregroundStyle(.tertiary); Spacer(); Button("Run", action: run).keyboardShortcut(.defaultAction) }.padding(12)
        }.onAppear { focused = true; selection = results.first?.id }.onChange(of: query) { _, _ in selection = results.first?.id }
    }
    private func run() {
        guard let selected = selection ?? results.first?.id else { return }
        model.sheet = nil
        DispatchQueue.main.async { (NSApp.delegate as? LeafAppDelegate)?.perform(selected) }
    }
}

struct QuickOpen: View {
    @ObservedObject var model: DocumentModel
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool
    private var urls: [URL] { (model.workspace?.documents.map(\.url) ?? NSDocumentController.shared.recentDocumentURLs).filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            TextField("Find a file", text: $query).textFieldStyle(.plain).font(.system(size: 18)).padding(18).focused($focused).onSubmit(open)
            Divider()
            List(urls, id: \.path, selection: $selection) { url in
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.deletingPathExtension().lastPathComponent)
                    Text(model.root.map { WorkspaceIndex.relativePath(of: url, root: $0) } ?? url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.padding(.vertical, 3).tag(url.path).onTapGesture(count: 2) { selection = url.path; open() }
            }.listStyle(.plain)
            HStack { if model.workspace == nil { Button("Open Folder…") { model.chooseWorkspace() } }; Spacer(); Button("Open", action: open).keyboardShortcut(.defaultAction).disabled(urls.isEmpty) }.padding(12)
        }.onAppear { focused = true; selection = urls.first?.path }.onChange(of: query) { _, _ in selection = urls.first?.path }
    }
    private func open() { guard let path = selection ?? urls.first?.path else { return }; model.sheet = nil; model.open(URL(fileURLWithPath: path)) }
}

private struct SearchInput: Equatable { let query: String, regex: Bool, sensitive: Bool }
struct WorkspaceSearchTool: View {
    @ObservedObject var model: DocumentModel
    @State private var query = ""
    @State private var replacement = ""
    @State private var error: String?
    @State private var regex = false
    @State private var sensitive = false
    @State private var working = false
    @State private var matches: [WorkspaceSearchMatch] = []
    @State private var preview: WorkspaceChangeSet?
    var body: some View {
        VStack(spacing: 12) {
            if let workspace = model.workspace {
                VStack(spacing: 8) {
                    HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Find", text: $query).textFieldStyle(.roundedBorder); Toggle("Regex", isOn: $regex).toggleStyle(.checkbox); Toggle("Match case", isOn: $sensitive).toggleStyle(.checkbox) }
                    HStack { TextField("Replace with", text: $replacement).textFieldStyle(.roundedBorder).onChange(of: replacement) { _, _ in preview = nil }; Button("Preview Changes") { previewChanges(workspace) }.disabled(query.isEmpty || working) }
                }.padding(.horizontal, 18).padding(.top, 16)
                if let preview { ChangePreview(changes: preview) }
                else {
                    List(matches) { match in
                        Button { model.open(match.url,range:match.range); model.sheet = nil } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(match.relativePath):\(match.line)").font(.caption).foregroundStyle(.secondary)
                                Text(match.lineText).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }.listStyle(.plain)
                }
                HStack {
                    Text(error ?? "\(matches.count.formatted()) matches").foregroundStyle(error == nil ? Color.secondary : Color.red).font(.caption)
                    Spacer()
                    if working { ProgressView().controlSize(.small) }
                    if let preview { Button("Apply to \(preview.changes.count) Files") { apply(preview) }.disabled(preview.isEmpty || working).keyboardShortcut(.defaultAction) }
                }.padding(.horizontal, 18).padding(.bottom, 15)
            } else { FolderRequired(model: model) }
        }
        .task(id: SearchInput(query: query, regex: regex, sensitive: sensitive)) {
            preview = nil; error = nil
            guard let workspace = model.workspace, !query.isEmpty else { matches = []; return }
            do {
                try await Task.sleep(for: .milliseconds(180))
                let result = try await model.loader.search(workspace, query: query, regex: regex, sensitive: sensitive)
                try Task.checkCancellation(); matches = result
            } catch is CancellationError { } catch { self.error = error.localizedDescription; matches = [] }
        }
    }
    private func previewChanges(_ workspace: WorkspaceIndex) {
        working = true
        Task {
            defer { working = false }
            do { preview = try await model.loader.replacements(workspace, query: query, replacement: replacement, regex: regex, sensitive: sensitive); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    private func apply(_ changes: WorkspaceChangeSet) {
        working = true
        Task { defer { working = false }; do { try await model.applyChanges(changes); preview = nil; error = nil; matches = [] } catch { self.error = error.localizedDescription } }
    }
}

struct ChangePreview: View {
    let changes: WorkspaceChangeSet
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(changes.changes.count) files · \(changes.replacementCount) replacements").font(.caption).foregroundStyle(.secondary)
                ForEach(changes.changes) { change in
                    DisclosureGroup {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading) { Text("Before").foregroundStyle(.secondary); Text(change.beforeText).textSelection(.enabled) }
                            Divider()
                            VStack(alignment: .leading) { Text("After").foregroundStyle(.secondary); Text(change.afterText).textSelection(.enabled) }
                        }.font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    } label: {
                        Label(change.isRename ? "\(change.beforePath ?? "") → \(change.afterPath ?? "")" : change.afterPath ?? change.beforePath ?? "", systemImage: change.isRename ? "pencil.line" : "doc.text")
                    }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                }
                if changes.isEmpty { Text("No files would change.").foregroundStyle(.secondary) }
            }.padding(18)
        }
    }
}

struct RenameTool: View {
    @ObservedObject var model: DocumentModel
    @State private var kind = "file"
    @State private var name = ""
    @State private var anchor = ""
    @State private var error: String?
    @State private var preview: WorkspaceChangeSet?
    @State private var working = false
    var body: some View {
        VStack(spacing: 14) {
            if let workspace = model.workspace, let url = model.fileURL {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Rename", selection: $kind) { Text("File").tag("file"); Text("Heading").tag("heading") }.pickerStyle(.segmented)
                    if kind == "heading" { Picker("Heading", selection: $anchor) { ForEach(model.index.headings) { Text($0.title).tag($0.anchor) } } }
                    TextField(kind == "file" ? "New relative path" : "New heading", text: $name).textFieldStyle(.roundedBorder)
                    HStack { Text("Incoming links are updated. Review every affected file before applying.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Preview") { makePreview(workspace, url) }.disabled(name.isEmpty || working) }
                }.padding(18)
                if let preview { ChangePreview(changes: preview) } else { Spacer() }
                HStack {
                    if let error { Text(error).foregroundStyle(.red).font(.caption) }
                    Spacer()
                    if let preview { Button("Apply Rename") { apply(preview) }.disabled(working || preview.isEmpty).keyboardShortcut(.defaultAction) }
                }.padding(18)
            } else { FolderRequired(model: model) }
        }.onAppear { if let url = model.fileURL, let root = model.root { name = WorkspaceIndex.relativePath(of: url, root: root) }; anchor = model.index.headings.first?.anchor ?? "" }
            .onChange(of: name) { _, _ in preview = nil }.onChange(of: kind) { _, kind in preview = nil; name = kind == "heading" ? model.index.headings.first?.title ?? "" : model.fileURL?.lastPathComponent ?? "" }
    }
    private func makePreview(_ workspace: WorkspaceIndex, _ url: URL) {
        working = true
        Task { defer { working = false }; do { preview = try await model.loader.rename(workspace, url: url, name: name, heading: kind == "heading" ? anchor : nil); error = nil } catch { self.error = error.localizedDescription } }
    }
    private func apply(_ changes: WorkspaceChangeSet) {
        working = true
        Task { defer { working = false }; do { try await model.applyChanges(changes); model.sheet = nil } catch { self.error = error.localizedDescription } }
    }
}

struct FolderRequired: View {
    @ObservedObject var model: DocumentModel
    var body: some View { VStack(spacing: 12) { Spacer(); Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(.tertiary); Text("Open a folder to use workspace tools.").foregroundStyle(.secondary); Button("Open Folder…") { model.chooseWorkspace() }; Spacer() } }
}

@MainActor extension DocumentModel {
    func applyChanges(_ changes: WorkspaceChangeSet) async throws {
        guard let root, !workspaceBusy else { throw WorkspaceError.invalidRoot }
        let affected = try lockWorkspaceDocuments(changes,root:root,undo:false)
        defer { unlockWorkspaceDocuments(affected) }
        try Task.checkCancellation()
        journal = try await loader.apply(changes,root:root)
        reconcileWorkspaceDocuments(affected,changes:changes,root:root,undo:false)
        refresh(); status = "\(changes.title) · \(changes.changes.count) files. Undo is available in Edit."
    }

}

extension WorkspaceLoader {
    func search(_ workspace: WorkspaceIndex, query: String, regex: Bool, sensitive: Bool) throws -> [WorkspaceSearchMatch] { try workspace.search(query, regularExpression: regex, caseSensitive: sensitive) }
    func replacements(_ workspace: WorkspaceIndex, query: String, replacement: String, regex: Bool, sensitive: Bool) throws -> WorkspaceChangeSet { try workspace.previewReplacement(query, with: replacement, regularExpression: regex, caseSensitive: sensitive) }
    func rename(_ workspace: WorkspaceIndex, url: URL, name: String, heading: String?) throws -> WorkspaceChangeSet {
        if let heading { return try workspace.previewRenameHeading(in: url, anchor: heading, to: name) }
        return try workspace.previewRenameFile(url, to: workspace.root.appendingPathComponent(name))
    }
}
