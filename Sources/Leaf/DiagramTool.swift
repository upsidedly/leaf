import AppKit
import SwiftUI
import LeafCore
import LeafRender

struct DiagramTool: View {
    @ObservedObject var model: DocumentModel
    @State private var selection = ""
    @State private var source = ""
    @State private var theme = "light"
    @State private var error: String?
    @State private var result: DiagramResult?
    @State private var image: NSImage?
    @State private var zoom = 1.0
    @State private var showSource = false
    @State private var busy = false
    @State private var fitToken = 0
    @State private var documentSnapshot = ""
    private var diagrams: [MarkdownCodeBlock] { model.index.codeBlocks.filter { ["mermaid","pele"].contains($0.language.lowercased()) } }
    private var selected: MarkdownCodeBlock? { diagrams.first { $0.id == selection } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Diagram",selection:$selection) {
                    ForEach(Array(diagrams.enumerated()), id: \.element.id) { offset, block in Text("Diagram \(offset + 1)").tag(block.id) }
                }.labelsHidden().frame(width: 150)
                Picker("Theme",selection:$theme) { Text("Light").tag("light"); Text("Dark").tag("dark"); Text("Mono").tag("mono") }.labelsHidden().frame(width: 105)
                Spacer()
                Button { zoom = max(0.1,zoom / 1.2) } label: { Image(systemName:"minus.magnifyingglass") }.help("Zoom out").accessibilityLabel("Zoom out")
                Text("\(Int(zoom * 100))%").monospacedDigit().frame(width:42)
                Button { zoom = min(8,zoom * 1.2) } label: { Image(systemName:"plus.magnifyingglass") }.help("Zoom in").accessibilityLabel("Zoom in")
                Button("Fit") { fitToken += 1 }
                Menu { Button("SVG…") { export("svg") }; Button("PNG…") { export("png") }; Button("PDF…") { export("pdf") } } label: { Label("Export",systemImage:"square.and.arrow.up") }.disabled(result == nil || busy)
            }.padding(12)
            Divider()
            if diagrams.isEmpty {
                VStack(spacing: 12) {
                    Spacer(); Image(systemName:"point.3.connected.trianglepath.dotted").font(.system(size:34)).foregroundStyle(.tertiary)
                    Text("Add a Mermaid diagram to this document.").foregroundStyle(.secondary)
                    Button("Insert Diagram") { model.sheet = nil; model.insert("\n```mermaid\nflowchart LR\n  Idea --> Draft --> Publish\n```\n") }
                    Spacer()
                }
            } else if let error {
                VStack(alignment:.leading,spacing:12) {
                    Label("Diagram could not be rendered",systemImage:"exclamationmark.triangle").font(.headline).foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).font(.system(size:13,design:.monospaced))
                    Button("Edit Source") { showSource = true }
                    Spacer()
                }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
            } else if let image {
                DiagramCanvas(image:image,zoom:$zoom,fitToken:fitToken)
            } else { Spacer(); ProgressView(); Spacer() }
            if showSource, !diagrams.isEmpty {
                Divider()
                TextEditor(text:$source).font(.system(size:12,design:.monospaced)).frame(height:150).padding(8).accessibilityLabel("Diagram source")
            }
            Divider()
            HStack {
                Toggle("Source",isOn:$showSource).toggleStyle(.checkbox)
                if busy { ProgressView().controlSize(.mini) }
                Text(result.map { "\($0.type) · \(Int($0.width)) × \(Int($0.height))" } ?? "").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if let selected, source != selected.source {
                    Button("Apply to Document") {
                        guard model.source == documentSnapshot else { error = "The document changed. Reopen this canvas before applying edits."; return }
                        let newline = model.source.contains("\r\n") ? "\r\n" : "\n"
                        let body = source.hasSuffix("\n") ? source : source + newline
                        model.replaceSource(selected.contentRange,with:body,title:"Edit Diagram")
                        model.status = "Diagram updated."
                    }
                }
                Button("Go to Source") { if let selected { model.sheet = nil; model.jump(selected.contentRange) } }.disabled(selected == nil)
            }.padding(12)
        }
        .onAppear {
            let location = model.textView?.selectedRange().location ?? 0
            selection = diagrams.first { NSLocationInRange(location,$0.range) }?.id ?? diagrams.first?.id ?? ""
            source = selected?.source ?? ""
            documentSnapshot = model.source
            theme = model.settings.diagramTheme == "auto" ? (NSApp.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? "dark" : "light") : model.settings.diagramTheme
        }
        .onChange(of:selection) { _, _ in source = selected?.source ?? ""; documentSnapshot = model.source; fitToken += 1 }
        .task(id: source + "\u{0}" + theme) {
            guard !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { result = nil; image = nil; busy = false; error = diagrams.isEmpty ? nil : "Enter diagram source to render it."; return }
            busy = true
            do {
                try await Task.sleep(for:.milliseconds(160))
                let output = try await model.diagramEngine.render(source,theme:theme)
                try Task.checkCancellation()
                guard let native = NSImage(data:Data(output.svg.utf8)) else { throw RenderError.invalidResult("The SVG image could not be decoded.") }
                result = output; image = native; error = nil; busy = false
            } catch is CancellationError { } catch { self.error = error.localizedDescription; result = nil; image = nil; busy = false }
        }
    }
    private func export(_ format: String) {
        guard let result, let image else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Diagram.\(format)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data: Data
            switch format {
            case "svg": data = Data(result.svg.utf8)
            case "pdf":
                let view = NSImageView(frame:NSRect(origin:.zero,size:image.size)); view.image = image
                data = view.dataWithPDF(inside:view.bounds)
            default:
                let scale = min(2,sqrt(32_000_000 / max(1,image.size.width * image.size.height)))
                let raster = NSImage(size:NSSize(width:image.size.width * scale,height:image.size.height * scale))
                raster.lockFocus(); image.draw(in:NSRect(origin:.zero,size:raster.size)); raster.unlockFocus()
                guard let tiff = raster.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let png = rep.representation(using:.png,properties:[:]) else { throw CocoaError(.fileWriteUnknown) }
                data = png
            }
            try data.write(to:destination,options:.atomic); model.status = "Diagram exported."
        } catch { self.error = error.localizedDescription }
    }
}

struct DiagramCanvas: NSViewRepresentable {
    let image: NSImage
    @Binding var zoom: Double
    let fitToken: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.allowsMagnification = true; scroll.minMagnification = 0.1; scroll.maxMagnification = 8
        scroll.backgroundColor = .controlBackgroundColor
        scroll.documentView = DiagramImageView()
        context.coordinator.attach(scroll)
        scroll.setAccessibilityLabel("Diagram canvas. Drag to pan; pinch to zoom.")
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let canvas = view.documentView as? DiagramImageView else { return }
        context.coordinator.zoom = $zoom
        let changed = canvas.image !== image
        if changed { canvas.image = image; canvas.frame = NSRect(x:0,y:0,width:max(1,image.size.width + 80),height:max(1,image.size.height + 80)); canvas.needsDisplay = true }
        if context.coordinator.fit != fitToken || changed {
            context.coordinator.fit = fitToken
            context.coordinator.needsFit = true
            context.coordinator.fitWhenReady()
        } else if !context.coordinator.needsFit, abs(view.magnification - zoom) > 0.001 { view.magnification = zoom }
    }
    static func dismantleNSView(_ view:NSScrollView,coordinator:Coordinator) { coordinator.stop() }
    @MainActor final class Coordinator {
        var fit = -1, needsFit = true
        var zoom:Binding<Double>?
        weak var view:NSScrollView?
        private var magnification:NSKeyValueObservation?
        private var geometry:NSObjectProtocol?
        func attach(_ view:NSScrollView) {
            self.view = view
            magnification = view.observe(\.magnification,options:[.new]) { [weak self] _,_ in
                Task { @MainActor [weak self] in
                    guard let self, let view = self.view else { return }
                    self.zoom?.wrappedValue = view.magnification
                }
            }
            view.contentView.postsFrameChangedNotifications = true
            geometry = NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:view.contentView,queue:.main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.fitWhenReady() }
            }
        }
        func fitWhenReady() {
            guard needsFit,let view,let canvas = view.documentView,
                  view.contentView.frame.width > 40,view.contentView.frame.height > 40 else { return }
            needsFit = false
            let fit = min(1,min((view.contentView.frame.width - 40) / max(1,canvas.bounds.width),(view.contentView.frame.height - 40) / max(1,canvas.bounds.height)))
            view.magnification = max(0.1,fit)
        }
        func stop() { magnification?.invalidate(); if let geometry { NotificationCenter.default.removeObserver(geometry) }; geometry = nil }
    }
}

@MainActor final class DiagramImageView: NSView {
    var image: NSImage?
    override func draw(_ dirtyRect: NSRect) { image?.draw(in:NSRect(origin:NSPoint(x:40,y:40),size:image?.size ?? .zero)) }
    override func mouseDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView, let window else { return }
        let start = event.locationInWindow, offset = scroll.contentView.bounds.origin
        while let next = window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
            let delta = next.locationInWindow
            scroll.contentView.scroll(to:NSPoint(x:offset.x - (delta.x-start.x) / scroll.magnification,y:offset.y - (delta.y-start.y) / scroll.magnification))
            scroll.reflectScrolledClipView(scroll.contentView)
            if next.type == .leftMouseUp { break }
        }
    }
}
