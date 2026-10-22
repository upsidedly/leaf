import AppKit
import SwiftUI
import LeafCore

private struct TableColumnDraft: Identifiable { let id: String; var alignment = "left" }
private struct TableRowDraft: Identifiable { let id: String; var cells: [String:String] }

struct TableTool: View {
    @ObservedObject var model: DocumentModel
    @State private var columns = [TableColumnDraft(id:"a"),TableColumnDraft(id:"b"),TableColumnDraft(id:"c")]
    @State private var rows = [TableRowDraft(id:"header",cells:["a":"Column 1","b":"Column 2","c":"Column 3"]),TableRowDraft(id:"row-a",cells:[:]),TableRowDraft(id:"row-b",cells:[:])]
    @State private var tableRange: NSRange?
    @State private var loadedRevision = 0
    @State private var error: String?
    var body: some View {
        VStack(spacing:16) {
            HStack {
                Button { rows.append(.init(id:UUID().uuidString,cells:[:])) } label:{ Label("Row",systemImage:"plus") }
                Button { columns.append(.init(id:UUID().uuidString)) } label:{ Label("Column",systemImage:"plus") }
                Button("Remove Row") { if rows.count > 2 { rows.removeLast() } }.disabled(rows.count <= 2)
                Button("Remove Column") { if columns.count > 1 { columns.removeLast() } }.disabled(columns.count <= 1)
                Spacer()
            }
            ScrollView([.horizontal,.vertical]) {
                Grid(horizontalSpacing:8,verticalSpacing:8) {
                    GridRow {
                        ForEach(columns) { column in
                            Picker("Alignment",selection:alignment(column.id)) { Text("Left").tag("left"); Text("Center").tag("center"); Text("Right").tag("right") }.labelsHidden().frame(width:160)
                        }
                    }
                    ForEach(rows) { row in
                        GridRow {
                            ForEach(columns) { column in
                                TextField(row.id == rows.first?.id ? "Heading" : "Cell",text:cell(row.id,column.id))
                                    .textFieldStyle(.roundedBorder).fontWeight(row.id == rows.first?.id ? .semibold : .regular).frame(width:160)
                                    .accessibilityLabel("Table cell")
                            }
                        }
                    }
                }.padding(4)
            }
            HStack {
                Text(error ?? "The first row contains column headings.").font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.red)
                Spacer(); Button(tableRange == nil ? "Insert Table" : "Update Table",action:commit).keyboardShortcut(.defaultAction)
            }
        }.padding(18).onAppear(perform:loadSelected)
    }
    private func cell(_ rowID: String, _ columnID: String) -> Binding<String> {
        Binding(get:{ rows.first { $0.id == rowID }?.cells[columnID] ?? "" },set:{ value in if let index = rows.firstIndex(where:{ $0.id == rowID }) { rows[index].cells[columnID] = value } })
    }
    private func alignment(_ columnID: String) -> Binding<String> {
        Binding(get:{ columns.first { $0.id == columnID }?.alignment ?? "left" },set:{ value in if let index = columns.firstIndex(where:{ $0.id == columnID }) { columns[index].alignment = value } })
    }
    private func loadSelected() {
        loadedRevision = model.revision
        guard let caret = model.textView?.selectedRange().location else { return }
        let ns = model.source as NSString
        var candidates: [NSRange] = [], active: NSRange?
        ns.enumerateSubstrings(in:NSRange(location:0,length:ns.length),options:.byLines) { _,range,enclosing,_ in
            if ns.substring(with:range).contains("|") {
                if let current = active, NSMaxRange(current) == enclosing.location { active = NSUnionRange(current,enclosing) }
                else { if let current = active { candidates.append(current) }; active = enclosing }
            } else if let current = active { candidates.append(current); active = nil }
        }
        if let active { candidates.append(active) }
        guard let range = candidates.first(where:{ NSLocationInRange(caret,$0) }), !model.index.codeBlocks.contains(where:{ NSIntersectionRange($0.range,range).length > 0 }) else { return }
        let lines = ns.substring(with:range).split(whereSeparator:\.isNewline).map(String.init)
        guard lines.count >= 2, lines[1].contains("---") else { return }
        func parse(_ line: String) -> [String] {
            var content = line.trimmingCharacters(in:.whitespaces)
            if content.hasPrefix("|") { content.removeFirst() }; if content.hasSuffix("|") { content.removeLast() }
            return content.replacingOccurrences(of:"\\|",with:"\u{0001}").split(separator:"|",omittingEmptySubsequences:false).map { $0.replacingOccurrences(of:"\u{0001}",with:"|").trimmingCharacters(in:.whitespaces) }
        }
        let header = parse(lines[0]), markers = parse(lines[1])
        columns = header.enumerated().map { index,_ in
            let marker = index < markers.count ? markers[index] : "---"
            return TableColumnDraft(id:"column-\(index)",alignment:marker.hasPrefix(":") && marker.hasSuffix(":") ? "center" : marker.hasSuffix(":") ? "right" : "left")
        }
        let parsed = [header] + lines.dropFirst(2).map(parse)
        rows = parsed.enumerated().map { index,values in .init(id:"row-\(index)",cells:Dictionary(uniqueKeysWithValues:zip(columns,values).map { ($0.0.id,$0.1) })) }
        if rows.count == 1 { rows.append(.init(id:UUID().uuidString,cells:[:])) }
        tableRange = range
    }
    private func commit() {
        guard loadedRevision == model.revision else { error = "The document changed. Reopen the table editor to review its current contents."; return }
        func line(_ values: [String]) -> String { "| " + values.map { $0.replacingOccurrences(of:"|",with:"\\|").replacingOccurrences(of:"\n",with:"<br>") }.joined(separator:" | ") + " |" }
        let markers = columns.map { $0.alignment == "center" ? ":---:" : $0.alignment == "right" ? "---:" : "---" }
        let rendered = rows.map { row in line(columns.map { row.cells[$0.id] ?? "" }) }
        let result = ([rendered[0],line(markers)] + rendered.dropFirst()).joined(separator:"\n") + "\n"
        if let tableRange { model.replaceSource(tableRange,with:result,title:"Edit Table") }
        else { model.insert("\n" + result + "\n") }
        model.sheet = nil
    }
}

struct LeafTemplate: Identifiable {
    let id: String, title: String, source: String
    static let builtins: [LeafTemplate] = [
        .init(id:"note",title:"Note",source:"# Title\n\nA thought worth keeping.\n\n## Notes\n\n- \n"),
        .init(id:"meeting",title:"Meeting",source:"# Meeting\n\n**Date:** \n**People:** \n\n## Agenda\n\n- \n\n## Decisions\n\n- \n\n## Next steps\n\n- [ ] \n"),
        .init(id:"technical",title:"Technical Document",source:"---\ntitle: Technical Document\n---\n\n# Technical Document\n\n## Purpose\n\n## Design\n\n```mermaid\nflowchart LR\n    Input --> Process --> Output\n```\n\n## Model\n\n$$\nf(x) = \\sum_{i=1}^{n} x_i^2\n$$\n\n## Implementation\n\n```swift\nstruct Idea {\n    let title: String\n}\n```\n\n## Verification\n\n- [ ] \n"),
        .init(id:"report",title:"Report",source:"---\ntitle: Report\nauthor: \n---\n\n# Report\n\n## Overview\n\n## Findings\n\n| Topic | Finding |\n| --- | --- |\n| | |\n\n<div class=\"page-break\"></div>\n\n## Recommendations\n\n1. \n"),
        .init(id:"mdx",title:"MDX & HTML",source:"import { Card } from './components'\n\n# MDX document\n\n<div style=\"padding: 16px; border: 1px solid #aaa; border-radius: 8px\">\n  <h2>Native defaults</h2>\n  <p>Embedded <strong>HTML</strong> is rendered with the document.</p>\n</div>\n\n<Card title=\"A component\">\n  Static content stays readable.\n</Card>\n\n{ /* JavaScript is preserved as source. */ }\n"),
        .init(id:"sequence",title:"Sequence Diagram",source:"```mermaid\nsequenceDiagram\n  participant Writer\n  participant Leaf\n  Writer->>Leaf: Open a document\n  Leaf-->>Writer: A little room to think\n```\n"),
        .init(id:"linked",title:"Linked Notes",source:"# Linked notes\n\nLink to a note with [[Note]] or a [relative link](Note.md).\n\nEmbed a note or section:\n\n![[Note#heading]]\n\nA reusable paragraph. ^reusable\n\n![[Note#^reusable]]\n")]
}

struct TemplateTool: View {
    @ObservedObject var model: DocumentModel
    @State private var templates = LeafTemplate.builtins
    @State private var selection = "note"
    @State private var error: String?
    private var selected: LeafTemplate { templates.first { $0.id == selection } ?? LeafTemplate.builtins[0] }
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                List(templates, selection: $selection) { Text($0.title).tag($0.id) }.listStyle(.sidebar).frame(width: 190)
                ScrollView { Text(selected.source).font(.system(size: 13,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(20) }
            }
            Divider()
            HStack {
                Button("Save Selection as Snippet…") { saveSnippet() }
                Button("Open Snippets Folder") { NSWorkspace.shared.open(snippetsFolder) }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                Spacer()
                Button("Insert") { model.insert(selected.source); model.sheet = nil }.keyboardShortcut(.defaultAction)
            }.padding(14)
        }.onAppear(perform: load)
    }
    private var snippetsFolder: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Leaf/Snippets") }
    private func load() {
        do {
            try FileManager.default.createDirectory(at: snippetsFolder, withIntermediateDirectories:true)
            let files = try FileManager.default.contentsOfDirectory(at: snippetsFolder,includingPropertiesForKeys:nil).filter { $0.pathExtension == "md" || $0.pathExtension == "mdx" }
            templates = LeafTemplate.builtins + files.compactMap { url in (try? String(contentsOf:url,encoding:.utf8)).map { LeafTemplate(id:url.path,title:url.deletingPathExtension().lastPathComponent,source:$0) } }
        } catch { self.error = error.localizedDescription }
    }
    private func saveSnippet() {
        guard let view = model.textView, view.selectedRange().length > 0 else { error = "Select text in the editor first."; return }
        let source = (view.string as NSString).substring(with:view.selectedRange())
        let panel = NSSavePanel(); panel.directoryURL = snippetsFolder; panel.nameFieldStringValue = "Snippet.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try source.write(to:url,atomically:true,encoding:.utf8); load(); selection = url.path } catch { self.error = error.localizedDescription }
    }
}
