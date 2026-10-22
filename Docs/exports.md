# Document export

`DocumentExporter` is a MainActor service with one owned export at a time:

```swift
try await DocumentExporter().export(
    format: "pdf", html: html, source: source, title: title,
    settings: settings, baseURL: documentDirectory, to: destination
)
```

The UI supplies the current source/render snapshot and an already selected destination. Errors propagate to the caller. The destination is replaced atomically after successful preparation; failed or cancelled exports preserve its previous bytes.

## HTML

The complete rendered document keeps its embedded math fonts and includes local images as data URLs. Explicit remote images become readable alt-text placeholders. Export never fetches remote resources. Individual local image files are limited to 50 MB, with a 100 MB combined image budget. Local links remain links. Unsupported or missing local assets produce errors rather than silently disappearing.

## PDF

An owned, nonpersistent WKWebView loads the complete static document with content JavaScript disabled. A 30-second load deadline handles navigation errors, a terminated WebKit process or failed loading. No file-access permission is needed because images and fonts are embedded.

PDF generation uses WebKit's native print operation and AppKit pagination. A4/US Letter, margins, report/book profiles, optional contents and explicit `.page-break` elements participate in page layout. It is a paginated document, not a screenshot crop. Print colors stay legible on white, including diagrams created while the app uses a dark theme.

Use the asynchronous `NSPrintOperation.runModal` API with secondary printing. WebKit's synchronous main-thread printing path returns an unknown preview page count and can produce an unbounded page range. AppKit may deliver the completion selector on its print queue; the service explicitly returns to MainActor before resuming.

AppKit exposes no safe public abort for an active print operation. Cancellation before preparation stops the load; cancellation during the final native print waits for that operation's callback, then discards the result. The view and window stay alive until the callback completes.

## Word (.docx)

Native HTML import creates an attributed document with editable text, fonts, paragraph styles, table cells, links and image attachments. Mermaid SVG becomes a bounded native PNG. KaTeX's original TeX annotation is typeset by SwiftMath and becomes a PNG attachment. Unsupported formula commands remain visible as TeX. Equations and diagrams are images in Word; they are not editable Word equation objects or diagram shapes.

Current macOS native OfficeOpenXML writing omits image attachments, hyperlinks and tables even when these attributes exist in the imported document. Leaf retains the native base package and metadata, then writes standard WordprocessingML from the native attributes. This restores DrawingML image references, hyperlink relationships, table cells, fonts, paragraph alignment, heading levels, page breaks and the selected page/margin geometry. Tables support Word's 63-column limit, including horizontal/vertical spans. The existing system `ditto` tool stages and packages the document with bounded, cancellable execution. No Office installation or Node runtime is required to export.

The native attributed Office importer also omits modern image and link attributes when reading a valid DOCX. Therefore, verification combines native text/table re-import with ZIP/XML relationship and media checks. Rendered inspection uses an independent Office document renderer, rather than treating that lossy importer as a visual oracle.

## Verification evidence

`DocumentExporter.checkExports(in:)` runs as part of the app's `--check-native` mode. Its fixture includes a local image, table, normal link, inline and display math, a Mermaid flowchart, a contents list, long text and an explicit page break. Checks cover:

- Self-contained HTML with local image and offline math fonts.
- Letter PDF with 10 pages, correct 612 × 792 point page bounds and the final text marker.
- A4 book PDF with 12 pages, correct page bounds and the final marker.
- DOCX native text/table re-import, four image payloads, valid image/link relationships and an explicit page break.
- Missing assets and cancellation preserving an existing destination.

The service compiles under Swift 6 strict concurrency with the macOS 26.5 SDK. A system QuickLook thumbnail visibly includes the image, table, inline formula, Mermaid diagram and display formula. The installed LibreOffice headless renderer also converts the resulting DOCX to a full PDF: 9 pages, the final text marker, one working external PDF link, and visibly preserved image/table/math/diagram content. Application UI verification and relocated, sealed-app packaging remain the application owner's gates.
