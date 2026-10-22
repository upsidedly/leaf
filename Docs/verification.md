# Verification

Environment: macOS 27.2 Golden Gate, Apple Silicon M4 Pro, Apple Swift 6.3.2, explicit macOS 26.5 SDK. Deployment target: macOS 14. Only the installed runtime has been exercised; older runtime behavior is not claimed as tested.

## Reproduce

Run Scripts/check.sh for settings, core, EPUB and offline engine probes. Set LEAF_NATIVE_CHECKS=1 to include the real native application checks. Native fixtures and exported artifacts use a temporary directory.

## Passing evidence

- Swift 6 debug and release builds, with no new compiler warnings.
- Settings merging and validation, UTF-16 source ranges, links/search/backlinks/diagnostics, replacement and rename previews, journal Undo/conflicts, transclusion cycles and asset usage/duplicates.
- EPUB ZIP/XML structure, metadata/navigation, images, CSS dependencies, SVG/MathML, process timeout/draining and failed-export preservation.
- All 33 Pele diagram families in light/dark: 66 actual native SVG decode/draw cases. Static MDX, GFM, footnotes, inline HTML formatting, math, code, relative links, scripts/URL filtering and offline fonts also pass.
- Real TextKit 2 input, native Undo/Redo, marked text, IME during mode changes, multiple carets, rectangular editing and independent syntax reveal. View changes and pane toggles retain the same editor and Undo state.
- Exact MDX write/reopen, UTF-8 BOM/emoji/CRLF, recovery autosave, coordinated AppKit save/autosave and explicit external-change conflict recovery.
- Local image drop, relative asset persistence, JPEG preparation and failed writes preserving text/files. A JavaScript-disabled WKWebView snapshot verifies that the local image actually decodes.
- Cross-file heading navigation and folder preservation; file rename/workspace Undo reconcile open paths and buffers; late edits survive transactions; external note changes refresh heading embeds.
- Native diagram canvas fits after layout and tracks magnification. Native light/dark, compact/wide, split/reading and settings views are captured for rendered inspection.
- Self-contained HTML, 10-page Letter PDF, 12-page A4 book PDF and DOCX media/table/link relationships. Final-page content and failure/cancellation preservation are checked. Quick Look and LibreOffice independently render the DOCX with its images, table, math and diagram.

## Repairs covered by regression checks

Native Undo notifications now synchronize the document binding. Committed input is synchronized before a view rebuild can use stale source; active composition is committed before intentional mode/font changes. File conflict checks surround AppKit's safe staging/replacement operation. Image insertion waits for persistence. Workspace edits lock affected open documents and preserve late edits as conflicts. The writing pane receives its actual available width when the window shrinks.

## Scope of UI evidence

The in-app harness creates real documents, windows, editors and WebKit views, invokes native input APIs and captures their actual rendering. It does not synthesize external pointer or hardware keyboard events. The separate computer-use helper failed before app access with “Sky Computer Use native pipe startup failed”, including after a fresh automation session. External UI automation, VoiceOver navigation and older macOS runtimes are not claimed as exercised.

The installed /Applications/Leaf.app passed all 27 native workflow checks with the development .build directory temporarily unavailable. Native math, highlighting, JavaScriptCore engines, images and exports therefore loaded from the sealed app package. The build directory was restored after the check. codesign --verify --strict and Info.plist validation pass. The installed app is built locally with ad hoc signing; notarization and automatic updates are outside this release.

Verdict: **ACCEPT** for the declared local macOS release and evidence scope above.
