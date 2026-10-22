<p align="center"><img src="Assets/leaf-icon.png" width="120" alt="Leaf icon"></p>

# Leaf

A native Markdown and MDX editor for macOS. Write, connect notes, and work through diagrams in one quiet workspace.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-555?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![Offline](https://img.shields.io/badge/Works-offline-666)

- **Write naturally.** Live Markdown, source, split and reading views. Tables, tasks, code, math, HTML and footnotes.
- **See the system.** Offline Mermaid diagrams on a native vector canvas. Pan, zoom, fit, and export SVG, PNG or PDF.
- **Keep the context.** Folders, document tabs, Quick Open, search, wiki links, backlinks, and note or heading embeds.
- **Edit precisely.** Multiple carets, rectangular selection, regex replacement previews, link-aware renames, diagnostics and reversible workspace changes.
- **Make it yours.** Configurable fonts, spacing, colors, shortcuts and caret motion. Global settings, folder overrides, import and export.
- **Share the result.** HTML, paginated PDF, Word and EPUB. Document, report and book styles, contents pages and page breaks.

![Native live editing, diagrams, tables and math](Assets/editor.png)

## Build and install

Requires Apple Silicon, Swift 6 and the macOS SDK. The app and its engines work offline; Node is needed only to rebuild the bundled JavaScript.

```sh
Scripts/build.sh
Scripts/install.sh
```

The build script uses the installed macOS 26.5 SDK by default. Set `LEAF_SDK` to another compatible SDK path when needed. The local build uses ad hoc signing.

Run `Scripts/check.sh` for core and offline engine checks. Use `LEAF_NATIVE_CHECKS=1 Scripts/check.sh` to open a test document and verify native editing, recovery, workspace changes and exports. The checks use temporary fixtures.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Commands | ⌘K |
| Quick Open | ⌘P |
| Find in folder | ⇧⌘F |
| Source view | ⌥⌘S |
| Diagram canvas | ⌥⌘D |
| Add next occurrence | ⌘D |
| Add caret | ⌥⌘click |
| Rectangular selection | ⌥drag |
| Settings | ⌘, |

Save a document before adding images. Pasted and dropped images use a relative `assets` folder. Workspace changes keep a reversible journal in `.leaf/journal`.

MDX opens without running document JavaScript. Static HTML and JSX content can render; imports, expressions and project components remain editable source. Diagram support follows bundled [Pele](https://pele.run/). See [rendering details](Docs/rendering.md) for supported syntax and limits.

[Verification](Docs/verification.md) · [Plan](PLAN.md) · [Progress](PROGRESS.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)
