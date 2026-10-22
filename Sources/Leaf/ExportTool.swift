import AppKit
import SwiftUI
import LeafCore
import LeafRender

struct ExportTool: View {
    @ObservedObject var model: DocumentModel
    @State private var format = "pdf"
    @State private var profile = "document"
    @State private var contents = false
    @State private var author = ""
    @State private var error: String?
    @State private var working = false
    @State private var lastURL: URL?
    @State private var operation: Task<Void,Never>?
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Format",selection:$format) { Text("PDF").tag("pdf"); Text("HTML").tag("html"); Text("Word (DOCX)").tag("docx"); Text("EPUB").tag("epub") }
                    Picker("Style",selection:$profile) { Text("Document").tag("document"); Text("Report").tag("report"); Text("Book").tag("book") }
                    Toggle("Include table of contents",isOn:$contents)
                    if format == "epub" { TextField("Author",text:$author) }
                }
                Section {
                    LabeledContent("Title",value:model.title)
                    LabeledContent("Paper",value:model.settings.pageSize)
                    LabeledContent("Margins",value:"\(Int(model.settings.pageMargin)) pt")
                    Text("Fonts and page defaults can be changed in Settings. Use Insert → Page Break for a new print page.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let lastURL { HStack { Label("Exported \(lastURL.lastPathComponent)",systemImage:"checkmark.circle").foregroundStyle(.green); Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([lastURL]) } } }
            }.formStyle(.grouped)
            HStack {
                if working { ProgressView().controlSize(.small); Text("Exporting…").foregroundStyle(.secondary) }
                Spacer()
                Button("Export…",action:export).disabled(working).keyboardShortcut(.defaultAction)
            }.padding(18)
        }.onAppear { profile = model.settings.exportProfile; contents = model.settings.exportTOC }.onDisappear { operation?.cancel() }
    }
    private func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = (model.title as NSString).deletingPathExtension + "." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true; error = nil; lastURL = nil
        operation = Task {
            defer { working = false }
            do {
                var settings = model.settings; settings.exportProfile = profile; settings.exportTOC = contents
                var options = RenderOptions(title:model.title,bodyFont:settings.bodyFont == "System" ? "system-ui" : settings.bodyFont,codeFont:settings.codeFont == "System Mono" ? "ui-monospace" : settings.codeFont,fontSize:settings.bodySize,lineHeight:1.5,contentWidth:settings.contentWidth,dark:false,includeTOC:contents)
                options.dark = false
                let source = model.workspace.flatMap { workspace in model.fileURL.flatMap { try? TransclusionResolver(workspace:workspace).expand(model.source,from:$0).source } } ?? model.source
                let rendered = try await model.markupEngine.html(source,options:options)
                let html = rendered.replacingOccurrences(of:"</head>",with:LeafStyle.css(settings) + "</head>")
                try Task.checkCancellation()
                if format == "epub" {
                    try await PublicationArchive().epub(html:html,title:model.title,author:author,baseURL:model.fileURL?.deletingLastPathComponent(),to:url)
                } else {
                    try await DocumentExporter().export(format:format,html:html,source:source,title:model.title,settings:settings,baseURL:model.fileURL?.deletingLastPathComponent(),to:url)
                }
                lastURL = url; model.status = "\(format.uppercased()) exported."
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}
