# Leaf — release plan

Status: implementation, native verification and local installation complete; final GitHub publication authorized. Matthew gave an explicit **go**, approved additions 1, 2, 5, 6, 7, 9 and 10, and required HTML rendering in MD/MDX. Continue through verification, local installation and the GitHub push.

## Product

A native macOS Markdown editor for writing, diagrams and technical documents. Use SwiftUI/AppKit for the interface and editing surface, ordinary Markdown files as the source of truth, and the monochrome identity shared with Snap, Tuck and Cell.

## Intended final features

1. **Live Markdown editing.** A Typora-style writing surface that renders completed formatting and reveals the relevant syntax near the caret. Optional source, split and reading views. Headings, lists, tasks, tables, quotes, links, local images, footnotes, front matter and fenced code.
2. **Native diagram workspace.** Offline Mermaid rendering through bundled Pele, displayed as native vector graphics. Support Pele’s available diagram families, including flowcharts, sequence, class, ER, state, Gantt, mind maps and charts. A dedicated canvas with pan, zoom, fit, themes, document diagram navigation and actionable render errors. Export diagrams as SVG, PNG and PDF.
3. **Technical writing.** Inline and block LaTeX math, syntax-highlighted code, a table editor, document outline, heading links and reusable snippets/templates.
4. **Workspace navigation.** Folder browser, document tabs, Quick Open, full-text search, wiki links, backlinks and navigation to linked notes.
5. **Writing tools.** Keyboard formatting, command palette, list continuation, image paste/drop with relative assets, focus and typewriter modes, and live word/character counts.
6. **Native document handling.** Open/save ordinary Markdown, autosave, Undo/Redo, recovery, external-change/conflict handling and macOS document conventions. Export documents as HTML and PDF.
7. **Finished delivery.** Original matching app icon, compact settings, local installation, meaningful checks and native UI verification, concise README with icon/badges, reproducible build/install instructions, dependency notices, and a finished push to `Upsidedly/leaf`.
8. **MDX documents.** Open, edit and save `.mdx`, recognize and preserve JSX, JavaScript expressions and import/export statements, and provide MDX-aware syntax presentation. Interactive execution of project components is not implied by opening the file format.
9. **Animated caret.** Neovide-style smooth caret motion and a motion-blur trail. Configure movement duration, trail length, blur strength, shape, width, color and blinking; provide a normal caret option and respect Reduce Motion. Preserve native selection, IME and accessibility behavior.
10. **Extensive configuration.** Fonts, typography, editor width, spacing, colors, themes, keybindings, caret motion, editing behavior, diagrams and exports. Provide global settings, workspace overrides, portable settings import/export and reset controls. Keep normal editing chrome compact.

## Additional feature decisions

Approved: 1, 2, 5, 6, 7, 9 and 10. Not selected: Vim mode, Git UI, bibliography/citations.

1. **Multiple cursors and rectangular selection:** make the same edit in several places and edit table/code columns efficiently.
2. **Project-wide regex replacement:** inspect affected matches and files before applying a reversible batch change.
3. **Optional Vim-style editing:** modal navigation, visual selections, repeatable edits and configurable mappings.
4. **Git tools:** inspect diffs, file history and changed lines, stage changes and create commits from the app.
5. **Document diagnostics:** find broken links, missing assets, duplicate heading anchors and malformed document syntax, with fixes that jump to the source.
6. **Safe workspace refactoring:** rename files and headings while previewing and updating incoming links.
7. **Linked blocks and transclusion:** embed another note, heading or reusable block and keep the embedded view synchronized with its source.
8. **Citations and bibliographies:** use BibTeX/CSL references, insert citation keys and produce formatted bibliographies.
9. **Asset manager:** organize document images, edit alt text, resize/compress assets and identify duplicates or unused files.
10. **Book and report exports:** add DOCX/EPUB, configurable print styles, generated contents pages and controlled page breaks.

## Implementation constraints

- Render embedded HTML in MD/MDX, including native default styling for unstyled HTML. Preserve MDX imports, exports, expressions and components; opening a file does not execute arbitrary JavaScript.
- Provide configurable body, headings, code and interface typography, with system font defaults. Take layout cues from Bear and Things while keeping Leaf's identity original.
- Advanced capabilities belong in contextual tools, menus, inspectors and settings. The ordinary writing surface stays simple.
- Prefer pre-existing, license-compatible implementations. Investigate difficult native and JavaScript components before reducing capability or visual quality.

- Keep the editing interface native; do not replace the primary writing surface with a browser page.
- Use pinned, license-compatible engines rather than incomplete parser reimplementations. Typora’s proprietary source/assets are reference evidence only and must not be redistributed.
- Pele can run locally in JavaScriptCore and return SVG for native NSImage rendering. Resolve CSS variables to concrete theme values before native SVG decoding.
- Keep source text lossless; rendering, indexing and exports are derived state. Own background work and reject stale results.
- Verify real editing, persistence/recovery, diagram families/errors, math, exports, keyboard operation and relevant accessibility. Match checks to changed risk.

## Work sequence

- [x] Incorporate Matthew’s scope/name changes and freeze the release checklist.
- [x] Build the document model and native live editor.
- [x] Integrate offline diagrams, math and code rendering.
- [x] Add workspace navigation, writing tools and exports.
- [x] Exercise and repair the complete native workflows.
- [ ] Install the verified app, finish documentation and push the completed project to GitHub.
