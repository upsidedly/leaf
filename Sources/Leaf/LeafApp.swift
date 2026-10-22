import AppKit
import SwiftUI
import LeafCore

@MainActor final class LeafAppDelegate: NSObject, NSApplicationDelegate {
    private var documentController: LeafDocumentController?
    private var settingsWindow: NSWindow?
    private var windowFocusObserver: NSObjectProtocol?
    var activeModel: DocumentModel? { (NSApp.keyWindow?.windowController as? LeafWindowController)?.model ?? NSDocumentController.shared.currentDocument.flatMap { ($0 as? LeafDocument)?.model } }

    func applicationWillFinishLaunching(_ notification: Notification) {
        documentController = LeafDocumentController()
        NSWindow.allowsAutomaticWindowTabbing = true
        buildMenu()
        SettingsStore.shared.applyAppearance()
        NSDocumentController.shared.autosavingDelay = SettingsStore.shared.value.autosaveDelay
        // App-lifetime observation: key equivalents follow the active folder.
        windowFocusObserver = NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshMenus() }
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let flag = CommandLine.arguments.firstIndex(of: "--check-native") {
            let output = CommandLine.arguments.count > flag + 1 ? URL(fileURLWithPath:CommandLine.arguments[flag + 1]) : FileManager.default.temporaryDirectory.appendingPathComponent("LeafNativeChecks")
            Task { @MainActor in
                let watchdog = Task { @MainActor in
                    do { try await Task.sleep(for:.seconds(180)); FileHandle.standardError.write(Data("FAIL Native checks exceeded 180 seconds.\n".utf8)); exit(2) } catch { }
                }
                defer { watchdog.cancel() }
                do { let checks = try await LeafNativeChecks.run(in: output); print("PASS \(checks.count) native workflow checks"); exit(0) }
                catch { FileHandle.standardError.write(Data("FAIL \(error.localizedDescription)\n".utf8)); exit(1) }
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if NSDocumentController.shared.documents.isEmpty {
            let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            if let path = paths.first { openURL(URL(fileURLWithPath: path)) }
            else { newDocument(nil) }
        }
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames.forEach { openURL(URL(fileURLWithPath: $0)) }; sender.reply(toOpenOrPrint: .success)
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func openURL(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in if let error { NSApp.presentError(error) } }
    }
    @objc func openRecent(_ sender: NSMenuItem) { if let url = sender.representedObject as? URL { openURL(url) } }
    @objc func newDocument(_ sender: Any?) { NSDocumentController.shared.newDocument(sender) }
    @objc func settings(_ sender: Any?) {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Leaf Settings"; window.contentView = NSHostingView(rootView: SettingsView()); window.isReleasedWhenClosed = false; window.center()
        settingsWindow = window; window.makeKeyAndOrderFront(nil)
    }
    @objc func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        perform(action)
    }
    func perform(_ action: String) {
        guard let model = activeModel else { return }
        switch action {
        case "folder": model.chooseWorkspace()
        case "sidebar": model.showSidebar.toggle()
        case "inspector": model.showInspector.toggle()
        case "palette": model.sheet = .palette
        case "quickOpen": model.sheet = .quickOpen
        case "search": model.sheet = .search
        case "rename": model.sheet = .rename
        case "table": model.sheet = .table
        case "templates": model.sheet = .templates
        case "export": model.sheet = .export
        case "diagram": model.sheet = .diagram
        case "assets": model.sheet = .assets
        case "focus": model.focusMode.toggle()
        case "typewriter": model.typewriterMode.toggle(); model.enhancements?.refreshSettings()
        case "source": model.mode = model.mode == .source ? .live : .source
        case "mode.live": model.mode = .live
        case "mode.source": model.mode = .source
        case "mode.split": model.mode = .split
        case "mode.reading": model.mode = .reading
        case "bold": model.wrap("**", "**")
        case "italic": model.wrap("*", "*")
        case "code": model.wrap("`", "`")
        case "strike": model.wrap("~~", "~~")
        case "highlight": model.wrap("==", "==")
        case "link": model.wrap("[", "](url)")
        case "task": model.insert("- [ ] ")
        case "image": model.chooseImage()
        case "math": model.insert("\n$$\nx^2 + y^2 = z^2\n$$\n")
        case "mermaid": model.insert("\n```mermaid\nflowchart LR\n  Idea --> Draft --> Publish\n```\n")
        case "codeBlock": model.insert("\n```swift\n\n```\n")
        case "pageBreak": model.insert("\n<div class=\"page-break\"></div>\n")
        case "undoWorkspace": model.undoWorkspace()
        case "workspaceSettings": SettingsStore.shared.exportSettings(to: model.root); model.reloadSettings()
        default:
            if action.hasPrefix("heading"), let level = Int(action.replacingOccurrences(of: "heading", with: "")) { model.insert(String(repeating: "#", count: level) + " ") }
        }
    }

    func refreshMenus() { buildMenu(); NSDocumentController.shared.autosavingDelay = SettingsStore.shared.value.autosaveDelay }
    private func buildMenu() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let result = NSMenu(title: title); item.submenu = result; main.addItem(item); return result
        }
        func native(_ title: String, _ selector: Selector?, _ key: String = "", _ target: AnyObject? = nil, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = target; item.keyEquivalentModifierMask = modifiers; return item
        }
        func action(_ title: String, _ id: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = native(title, #selector(menuAction(_:)), key, self, modifiers); item.representedObject = id
            if let shortcut = (activeModel?.settings ?? SettingsStore.shared.value).shortcuts[id] {
                item.keyEquivalent = String(shortcut.filter { !"@~^$".contains($0) }).lowercased()
                var mask: NSEvent.ModifierFlags = []
                if shortcut.contains("@") { mask.insert(.command) }; if shortcut.contains("~") { mask.insert(.option) }
                if shortcut.contains("^") { mask.insert(.control) }; if shortcut.contains("$") { mask.insert(.shift) }
                item.keyEquivalentModifierMask = mask
            }
            return item
        }
        let app = menu("Leaf")
        app.addItem(native("About Leaf", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", NSApp))
        app.addItem(native("Settings…", #selector(settings(_:)), ",", self)); app.addItem(.separator())
        let services = NSMenu(title: "Services"), servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: ""); servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(native("Hide Leaf", #selector(NSApplication.hide(_:)), "h", NSApp)); app.addItem(native("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", NSApp, [.command, .option])); app.addItem(native("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", NSApp)); app.addItem(.separator()); app.addItem(native("Quit Leaf", #selector(NSApplication.terminate(_:)), "q", NSApp))
        let file = menu("File")
        file.addItem(native("New", #selector(newDocument(_:)), "n", self))
        file.addItem(native("Open…", #selector(NSDocumentController.openDocument(_:)), "o", NSDocumentController.shared))
        file.addItem(action("Open Folder…", "folder", "o", [.command, .shift]))
        let recent = NSMenu(title: "Open Recent"); let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: ""); recentItem.submenu = recent; file.addItem(recentItem); for url in NSDocumentController.shared.recentDocumentURLs.prefix(12) { let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: ""); entry.target = self; entry.representedObject = url; recent.addItem(entry) }
        file.addItem(.separator()); file.addItem(native("Close", #selector(NSWindow.performClose(_:)), "w")); file.addItem(native("Save", #selector(NSDocument.save(_:)), "s")); file.addItem(native("Save As…", #selector(NSDocument.saveAs(_:)), "s", nil, [.command, .shift])); file.addItem(native("Revert to Saved…", #selector(NSDocument.revertToSaved(_:))))
        file.addItem(.separator()); file.addItem(action("Templates & Snippets…", "templates")); file.addItem(action("Rename & Update Links…", "rename")); file.addItem(action("Export…", "export", "e", [.command, .shift])); file.addItem(action("Save Workspace Settings", "workspaceSettings"))
        let edit = menu("Edit")
        edit.addItem(native("Undo", Selector(("undo:")), "z")); edit.addItem(native("Redo", Selector(("redo:")), "z", nil, [.command, .shift])); edit.addItem(.separator())
        edit.addItem(native("Cut", #selector(NSText.cut(_:)), "x")); edit.addItem(native("Copy", #selector(NSText.copy(_:)), "c")); edit.addItem(native("Paste", #selector(NSText.paste(_:)), "v")); edit.addItem(native("Select All", #selector(NSText.selectAll(_:)), "a")); edit.addItem(.separator())
        edit.addItem(native("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f")); edit.items.last?.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        edit.addItem(action("Find & Replace in Folder…", "search", "f", [.command, .shift])); edit.addItem(native("Add Next Occurrence", NSSelectorFromString("leafAddNextOccurrence:"), "d")); edit.addItem(native("Add Caret Below", NSSelectorFromString("leafAddCaretBelow:"), "\u{f701}", nil, [.control, .option])); edit.addItem(native("Clear Additional Carets", NSSelectorFromString("leafClearCarets:"))); edit.addItem(action("Undo Last Workspace Change", "undoWorkspace"))
        let format = menu("Format")
        for (title,id,key) in [("Bold","bold","b"),("Italic","italic","i"),("Code","code","`"),("Strikethrough","strike",""),("Highlight","highlight",""),("Link","link","l")] { format.addItem(action(title,id,key)) }
        format.addItem(.separator()); for level in 1...6 { format.addItem(action("Heading \(level)","heading\(level)",String(level),[.command,.option])) }
        let insert = menu("Insert")
        for (title,id) in [("Table…","table"),("Image…","image"),("Task","task"),("Code Block","codeBlock"),("Math","math"),("Mermaid Diagram","mermaid"),("Page Break","pageBreak")] { insert.addItem(action(title,id)) }
        let view = menu("View")
        view.addItem(action("Toggle Sidebar","sidebar","s",[.command,.control])); view.addItem(action("Toggle Inspector","inspector","i",[.command,.option])); view.addItem(.separator())
        for mode in EditorMode.allCases { view.addItem(action(mode.rawValue,"mode.\(mode.rawValue.lowercased())")) }
        view.addItem(action("Toggle Source","source")); view.addItem(.separator()); view.addItem(action("Focus Mode","focus")); view.addItem(action("Typewriter Mode","typewriter")); view.addItem(action("Diagram Canvas…","diagram")); view.addItem(action("Asset Manager…","assets")); view.addItem(action("Command Palette…","palette","k")); view.addItem(action("Quick Open…","quickOpen","p"))
        let window = menu("Window"); NSApp.windowsMenu = window
        window.addItem(native("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")); window.addItem(native("Zoom", #selector(NSWindow.performZoom(_:)))); window.addItem(native("Show All Tabs", NSSelectorFromString("toggleTabOverview:"))); window.addItem(native("Merge All Windows", NSSelectorFromString("mergeAllWindows:"))); window.addItem(.separator()); window.addItem(native("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", NSApp))
        let help = menu("Help"); help.addItem(action("Templates & Examples…","templates")); NSApp.helpMenu = help
    }
}

@MainActor final class LeafWindowController: NSWindowController, NSToolbarDelegate {
    let model: DocumentModel
    init(model: DocumentModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 640, height: 440); window.title = model.title
        window.tabbingMode = .preferred; window.tabbingIdentifier = "LeafDocuments"; window.isRestorable = true
        window.toolbarStyle = .unified; window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: DocumentView(model: model))
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "LeafWritingToolbar"); toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = true
        window.toolbar = toolbar; window.center()
        if !CommandLine.arguments.contains("--check-native") { window.setFrameAutosaveName("LeafDocumentWindow") }
    }
    required init?(coder: NSCoder) { nil }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("sidebar"), .flexibleSpace, .init("mode"), .init("diagram"), .init("inspector"), .init("actions")] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) + [.space] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let value = identifier.rawValue
        if value == "mode" {
            let menu = NSMenu()
            for mode in EditorMode.allCases {
                let choice = NSMenuItem(title: mode.rawValue, action: #selector(LeafAppDelegate.menuAction(_:)), keyEquivalent: "")
                choice.target = NSApp.delegate; choice.representedObject = "mode.\(mode.rawValue.lowercased())"; menu.addItem(choice)
            }
            let button = NSPopUpButton(frame: .zero, pullsDown: true)
            button.addItem(withTitle: "View"); button.menu?.items.first?.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: "View mode")
            for child in menu.items { menu.removeItem(child); button.menu?.addItem(child) }
            button.bezelStyle = .texturedRounded; button.setAccessibilityLabel("View mode"); item.view = button; item.label = "View"; return item
        }
        if value == "actions" {
            let menu = NSMenu()
            for (title, action) in [("Command Palette…","palette"),("Find in Folder…","search"),("Asset Manager…","assets"),("Export…","export")] {
                let entry = NSMenuItem(title: title, action: #selector(LeafAppDelegate.menuAction(_:)), keyEquivalent: ""); entry.target = NSApp.delegate; entry.representedObject = action; menu.addItem(entry)
            }
            let button = NSPopUpButton(frame: .zero, pullsDown: true); button.addItem(withTitle: ""); button.menu?.items.first?.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More actions")
            for entry in menu.items { menu.removeItem(entry); button.menu?.addItem(entry) }
            button.bezelStyle = .texturedRounded; button.setAccessibilityLabel("More actions"); item.view = button; item.label = "Actions"; return item
        }
        let names = ["sidebar": ("sidebar.left", "Sidebar"), "diagram": ("point.3.connected.trianglepath.dotted", "Diagram canvas"), "inspector": ("sidebar.right", "Inspector")]
        guard let (symbol, label) = names[value] else { return nil }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label); item.label = label; item.toolTip = label
        item.target = self; item.action = #selector(toolbarAction(_:)); return item
    }
    @objc private func toolbarAction(_ sender: NSToolbarItem) { (NSApp.delegate as? LeafAppDelegate)?.perform(sender.itemIdentifier.rawValue) }
}
