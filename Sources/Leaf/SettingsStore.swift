import AppKit
import SwiftUI
import LeafCore

@MainActor final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    @Published var value = LeafSettings() { didSet { scheduleSave() } }
    @Published var error: String?
    private var saving: Task<Void, Never>?
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Leaf/settings.json")

    init() {
        if FileManager.default.fileExists(atPath: url.path) {
            do { value = try LeafSettings.merged(Data(contentsOf: url)) }
            catch { self.error = "Settings could not be read: \(error.localizedDescription)" }
        }
    }
    private func scheduleSave() {
        saving?.cancel()
        let snapshot = value.validated(), destination = url
        saving = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await Task.detached { try snapshot.save(to: destination) }.value
                self?.error = nil
            } catch is CancellationError { }
            catch { self?.error = "Settings could not be saved: \(error.localizedDescription)" }
        }
        applyAppearance()
        (NSApp.delegate as? LeafAppDelegate)?.refreshMenus()
    }
    func applyAppearance() {
        NSApp.appearance = value.appearance == "dark" ? NSAppearance(named: .darkAqua)
            : value.appearance == "light" ? NSAppearance(named: .aqua) : nil
    }
    func effective(in workspace: URL?) -> LeafSettings {
        guard let workspace else { return value }
        let file = workspace.appendingPathComponent(".leaf/settings.json")
        guard let data = try? Data(contentsOf: file) else { return value }
        do { return try LeafSettings.merged(data, over: value) }
        catch { return value }
    }
    func importSettings() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do { value = try LeafSettings.merged(Data(contentsOf: selected), over: value) }
        catch { self.error = error.localizedDescription }
    }
    func exportSettings(to workspace: URL? = nil) {
        do {
            if let workspace {
                try value.save(to: workspace.appendingPathComponent(".leaf/settings.json"))
            } else {
                let panel = NSSavePanel(); panel.nameFieldStringValue = "Leaf Settings.json"; panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try value.save(to: destination)
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct SettingsView: View {
    @ObservedObject var store = SettingsStore.shared
    @State private var section = "Writing"
    private let sections = ["Writing", "Appearance", "Caret", "Shortcuts", "Files & Export"]
    private var fonts: [String] { NSFontManager.shared.availableFontFamilies.sorted() }
    var body: some View {
        HStack(spacing: 0) {
            List(sections, id: \.self, selection: $section) { Text($0).tag($0) }
                .listStyle(.sidebar).frame(width: 155)
            Form {
                switch section {
                case "Writing":
                    Section("Typography") {
                        fontPicker("Body", $store.value.bodyFont)
                        fontPicker("Headings", $store.value.headingFont)
                        fontPicker("Code", $store.value.codeFont)
                        number("Body size", $store.value.bodySize, 10...36, suffix: "pt")
                        number("Code size", $store.value.codeSize, 8...30, suffix: "pt")
                        number("Heading scale", $store.value.headingScale, 0.65...2, suffix: "×")
                        number("Line spacing", $store.value.lineSpacing, 0...24, suffix: "pt")
                        number("Paragraph spacing", $store.value.paragraphSpacing, 0...2, suffix: "×")
                        number("Writing width", $store.value.contentWidth, 360...1600, suffix: "pt")
                    }
                    Section("Editing") {
                        Toggle("Continue lists automatically", isOn: $store.value.smartLists)
                        Toggle("Check spelling", isOn: $store.value.spellCheck)
                        Toggle("Correct spelling automatically", isOn: $store.value.autoCorrect)
                        Toggle("Show word and character counts", isOn: $store.value.showCounts)
                    }
                case "Appearance":
                    Section {
                        Picker("Appearance", selection: $store.value.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                        Picker("Accent", selection: $store.value.accent) {
                            ForEach(["system", "graphite", "blue", "green", "orange", "purple"], id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        number("Interface size", $store.value.interfaceSize, 10...18, suffix: "pt")
                        Picker("Diagram theme", selection: $store.value.diagramTheme) { Text("Match appearance").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark"); Text("Monochrome").tag("mono") }
                    }
                    Section("Custom colors") {
                        ForEach(["text","background","heading","link","muted","codeBackground"],id: \.self) { key in
                            HStack {
                                ColorPicker(colorTitle(key),selection:Binding(get:{ Color(nsColor:store.value.colors[key].flatMap(NSColor.init(leafHex:)) ?? defaultColor(key)) },set:{ store.value.colors[key] = NSColor($0).leafHex }),supportsOpacity:false)
                                if store.value.colors[key] != nil { Button("Reset") { store.value.colors[key] = nil }.font(.caption) }
                            }
                        }
                    }
                case "Caret":
                    Section {
                        Toggle("Animate caret", isOn: $store.value.caret.animated)
                        Picker("Shape", selection: $store.value.caret.shape) { Text("Bar").tag("bar"); Text("Block").tag("block"); Text("Underline").tag("underline") }
                        Picker("Color", selection: $store.value.caret.color) { Text("Accent").tag("accent"); Text("Text").tag("text"); Text("Blue").tag("blue"); Text("Orange").tag("orange") }
                        number("Movement duration", $store.value.caret.duration, 0.025...0.5, suffix: "s")
                        number("Trail length", $store.value.caret.trail, 0...1, suffix: "")
                        number("Motion blur", $store.value.caret.blur, 0...1, suffix: "")
                        number("Width", $store.value.caret.width, 1...8, suffix: "pt")
                        Toggle("Blink caret", isOn: $store.value.caret.blink)
                        Text("Reduce Motion uses the standard caret. Composition and selection keep native input behavior.").font(.caption).foregroundStyle(.secondary)
                    }
                case "Shortcuts":
                    Section("Modifiers: @ Command · ~ Option · ^ Control · $ Shift") {
                        ForEach(store.value.shortcuts.keys.sorted(), id: \.self) { key in
                            TextField(key == "quickOpen" ? "Quick Open" : key.capitalized, text: Binding(get: { store.value.shortcuts[key] ?? "" }, set: { store.value.shortcuts[key] = $0 }))
                        }
                        Text("Use a modifier prefix followed by a key. Changes apply immediately.").font(.caption).foregroundStyle(.secondary)
                    }
                default:
                    Section("Documents") {
                        number("Autosave delay", $store.value.autosaveDelay, 1...60, suffix: "s")
                        Text("Files use macOS autosave and document recovery. Workspace overrides live in .leaf/settings.json.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Export defaults") {
                        Picker("Profile", selection: $store.value.exportProfile) { Text("Document").tag("document"); Text("Report").tag("report"); Text("Book").tag("book") }
                        Picker("Paper", selection: $store.value.pageSize) { Text("A4").tag("A4"); Text("US Letter").tag("Letter") }
                        number("Margins", $store.value.pageMargin, 18...144, suffix: "pt")
                        Toggle("Include table of contents", isOn: $store.value.exportTOC)
                    }
                }
                if let error = store.error { Text(error).foregroundStyle(.red).font(.caption) }
                Section {
                    HStack {
                        Button("Import…") { store.importSettings() }
                        Button("Export…") { store.exportSettings() }
                        Spacer()
                        Button("Reset") { store.value = LeafSettings() }
                    }
                }
            }.formStyle(.grouped).frame(maxWidth: .infinity)
        }.frame(width: 650, height: 560)
    }
    private func colorTitle(_ key: String) -> String { ["text":"Text","background":"Page","heading":"Headings","link":"Links","muted":"Secondary text","codeBackground":"Code background"][key] ?? key }
    private func defaultColor(_ key: String) -> NSColor { switch key { case "background": .textBackgroundColor; case "link": .linkColor; case "muted": .secondaryLabelColor; case "codeBackground": .controlBackgroundColor; default:.labelColor } }
    private func fontPicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) { ForEach([title == "Code" ? "System Mono" : "System"] + fonts, id: \.self) { Text($0).tag($0) } }
    }
    private func number(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, suffix: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range).frame(width: 135)
                Text("\(value.wrappedValue, specifier: range.upperBound <= 2 ? "%.2f" : "%.0f") \(suffix)")
                    .monospacedDigit().frame(width: 60, alignment: .trailing)
            }
        }
    }
}
