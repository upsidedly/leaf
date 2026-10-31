import SwiftUI

/// Typora's compact chrome, adapted to AppKit's native document titlebar.
struct DocumentTitlebar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("View mode", selection: $model.mode) {
                    ForEach(EditorMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                icon(modeSymbol, label: "View mode")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("View mode: \(model.mode.rawValue)")
            .accessibilityLabel("View mode")
            .accessibilityValue(model.mode.rawValue)

            panelButton("Sidebar", symbol: "sidebar.left", isShown: $model.showSidebar)
            panelButton("Inspector", symbol: "sidebar.right", isShown: $model.showInspector)

            Menu {
                Button("Command Palette…") { model.sheet = .palette }
                Button("Find in Folder…") { model.sheet = .search }
                Divider()
                Button("Diagram Canvas…") { model.sheet = .diagram }
                Button("Asset Manager…") { model.sheet = .assets }
                Divider()
                Button("Export…") { model.sheet = .export }
            } label: {
                icon("ellipsis", label: "More actions")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("More actions")
            .accessibilityLabel("More actions")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.secondary)
        .padding(.trailing, 8)
        .frame(height: 28)
    }

    private var modeSymbol: String {
        switch model.mode {
        case .live: "text.alignleft"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .split: "rectangle.split.2x1"
        case .reading: "book"
        }
    }

    private func icon(_ symbol: String, label: String) -> some View {
        Label(label, systemImage: symbol)
            .labelStyle(.iconOnly)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }

    private func panelButton(_ name: String, symbol: String, isShown: Binding<Bool>) -> some View {
        Button { isShown.wrappedValue.toggle() } label: {
            icon(symbol, label: name)
                .foregroundStyle(isShown.wrappedValue ? Color.primary : Color.secondary)
        }
        .help("\(isShown.wrappedValue ? "Hide" : "Show") \(name)")
        .accessibilityLabel(name)
        .accessibilityValue(isShown.wrappedValue ? "Shown" : "Hidden")
    }
}
