import AppKit
import SwiftUI
import LeafCore

struct DocumentView: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var preferences = SettingsStore.shared
    @State private var filter = ""
    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            if model.conflict != nil {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("This file changed elsewhere.")
                    Spacer()
                    Button("Use External Copy") { model.useExternal() }
                    Button("Keep My Edits") { model.keepMine() }
                }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 9).background(.orange.opacity(0.1))
            }
            HSplitView {
                if model.showSidebar && !model.focusMode && geometry.size.width >= 780 { sidebar.frame(minWidth: 170, idealWidth: 220, maxWidth: 320).id("leaf-files") }
                GeometryReader { writingGeometry in
                HSplitView {
                    ZStack {
                        NativeEditor(model:model,sourceMode:model.mode == .source || model.mode == .split,isEditable:model.mode != .reading)
                            .opacity(model.mode == .reading ? 0 : 1)
                            .allowsHitTesting(model.mode != .reading)
                            .accessibilityHidden(model.mode == .reading)
                        if model.mode == .reading {
                            HTMLReader(html:model.html,baseURL:model.fileURL,onLink:{ model.follow($0) })
                        }
                    }.frame(minWidth:280,maxWidth:.infinity)
                    if model.mode == .split {
                        HTMLReader(html:model.html,baseURL:model.fileURL,onLink:{ model.follow($0) }).frame(minWidth:280)
                    }
                }.frame(width:writingGeometry.size.width,height:writingGeometry.size.height)
                }.frame(minWidth:280,maxWidth:.infinity,maxHeight:.infinity).id("leaf-writing")
                if model.showInspector && !model.focusMode && geometry.size.width >= 980 { InspectorView(model: model).frame(minWidth: 220, idealWidth: 260, maxWidth: 360).id("leaf-inspector") }
            }.frame(width:geometry.size.width)
            footer
        }
        .background(Color(nsColor: LeafStyle.color("background",model.settings,fallback:.textBackgroundColor)))
        .tint(Color(nsColor:LeafStyle.accent(model.settings)))
        .font(.system(size: model.settings.interfaceSize))
        .sheet(item: $model.sheet) { sheet in ToolHost(model: model, tool: sheet) }
        .onChange(of: model.fileURL) { _, _ in model.document?.windowControllers.first?.window?.representedURL = model.fileURL }
        }
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.root?.lastPathComponent ?? "Files").fontWeight(.semibold).lineLimit(1)
                Spacer()
                Button { model.chooseWorkspace() } label: { Image(systemName: "folder.badge.plus") }.buttonStyle(.plain).help("Open folder").accessibilityLabel("Open folder")
            }.padding(.horizontal, 14).padding(.top, 15).padding(.bottom, 10)
            TextField("Filter files", text: $filter).textFieldStyle(.roundedBorder).padding(.horizontal, 10).padding(.bottom, 8)
            if let workspace = model.workspace {
                List {
                    ForEach(workspace.documents.filter { filter.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(filter) }) { document in
                        Button { model.open(document.url) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: document.url.pathExtension == "mdx" ? "chevron.left.forwardslash.chevron.right" : "doc.text").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.url.deletingPathExtension().lastPathComponent).lineLimit(1)
                                    if document.relativePath.contains("/") { Text((document.relativePath as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                                }
                            }.padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .listRowBackground(document.url == model.fileURL ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                }.listStyle(.sidebar)
                if workspace.documents.isEmpty { Text("No Markdown files in this folder.").foregroundStyle(.secondary).padding(16) }
            } else {
                Spacer()
                Image(systemName: "folder").font(.system(size: 25)).foregroundStyle(.tertiary)
                Button("Open Folder…") { model.chooseWorkspace() }.padding(.top, 8)
                Spacer()
            }
        }.background(.background.secondary)
    }
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let status = model.status {
                Text(status).lineLimit(1).foregroundStyle(.secondary)
                Button { model.status = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss status")
            } else if model.settings.showCounts {
                Text("\(model.words.formatted()) words").monospacedDigit()
                Text("\(model.characterCount.formatted()) characters").foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer(minLength: 8)
            if model.focusMode { Text("Focus").foregroundStyle(.secondary) }
            if model.typewriterMode { Text("Typewriter").foregroundStyle(.secondary) }
            if model.rendering { ProgressView().controlSize(.mini).scaleEffect(0.75).accessibilityLabel("Rendering") }
            Text(model.fileURL?.pathExtension.uppercased() ?? "MD").foregroundStyle(.tertiary)
            Menu(model.mode.rawValue) { ForEach(EditorMode.allCases) { mode in Button(mode.rawValue) { model.mode = mode } } }.menuStyle(.borderlessButton).controlSize(.small).fixedSize()
        }.font(.system(size: 10.5)).padding(.horizontal, 14).frame(height: 27)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InspectorView: View {
    @ObservedObject var model: DocumentModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.inspector) {
                ForEach(InspectorTab.allCases, id: \.self) { section in
                    Image(systemName: symbol(section)).help(section.rawValue).tag(section)
                }
            }.pickerStyle(.segmented).padding(10).labelsHidden().accessibilityLabel("Inspector section")
            switch model.inspector {
            case .outline:
                if model.index.headings.isEmpty { empty("No headings", "Use # to add a heading.", "list.bullet.indent") }
                else {
                    List(model.index.headings) { heading in
                        HStack {
                            Button { model.jump(heading.range) } label: {
                                Text(heading.title).padding(.leading, CGFloat(heading.level - 1) * 10).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("#" + heading.anchor, forType: .string)
                                model.status = "Heading link copied."
                            } label: { Image(systemName: "link") }.buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Copy link to \(heading.title)")
                        }.padding(.vertical, 3)
                    }.listStyle(.plain)
                }
            case .links:
                List {
                    Section("Links") {
                        ForEach(model.index.links.filter { !$0.isEmbed }) { link in
                            Button { model.follow(link.target) } label: { Label(link.label.isEmpty ? link.target : link.label, systemImage: "link").lineLimit(2) }.buttonStyle(.plain)
                        }
                    }
                    if let workspace = model.workspace, let url = model.fileURL {
                        Section("Backlinks") {
                            ForEach(workspace.backlinks(to: url)) { link in
                                Button { model.open(link.sourceURL) } label: { Label(link.relativePath, systemImage: "arrow.uturn.backward").lineLimit(2) }.buttonStyle(.plain)
                            }
                        }
                    }
                }.listStyle(.plain)
            case .issues:
                let issues = model.index.diagnostics
                if issues.isEmpty && model.workspaceIssues.isEmpty { empty("No issues found", "Links and document syntax are checked locally.", "checkmark.circle") }
                else {
                    List {
                        Section("This document") {
                            ForEach(issues) { issue in issueRow(issue, at: model.fileURL) }
                        }
                        Section("Folder") {
                            ForEach(model.workspaceIssues) { issue in
                                VStack(alignment: .leading, spacing: 4) { Text(issue.relativePath).font(.caption).foregroundStyle(.tertiary); issueRow(issue.diagnostic, at: issue.url) }
                            }
                        }
                    }.listStyle(.plain)
                }
            case .assets:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Document images and files").font(.headline)
                    Text("Review usage, find duplicates and prepare images.").foregroundStyle(.secondary)
                    Button("Open Asset Manager…") { model.sheet = .assets }
                    Button("Insert Image…") { model.chooseImage() }
                    Spacer()
                }.padding(16)
            }
        }.background(.background.secondary)
    }
    private func symbol(_ tab: InspectorTab) -> String {
        switch tab { case .outline: "list.bullet.indent"; case .links: "link"; case .issues: "exclamationmark.circle"; case .assets: "photo.on.rectangle" }
    }
    private func empty(_ title: String, _ detail: String, _ symbol: String) -> some View {
        VStack(spacing: 10) { Spacer(); Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(.tertiary); Text(title).fontWeight(.medium); Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center); Spacer() }.padding(24)
    }
    private func issueRow(_ issue: MarkdownDiagnostic, at url: URL?) -> some View {
        Button {
            if let url, url != model.fileURL { model.open(url,range:issue.range) } else { model.jump(issue.range) }
        } label: { Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.circle" : "exclamationmark.triangle").foregroundStyle(issue.severity == .error ? .red : .orange).font(.caption).multilineTextAlignment(.leading) }.buttonStyle(.plain)
    }
}
