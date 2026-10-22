# Offline rendering

Leaf uses native AppKit and SwiftUI for documents, editing and diagram navigation. Markdown-to-HTML and Mermaid parsing run in an actor-owned JavaScriptCore context. The app bundles these engines. Opening or rendering a document does not download code, fonts or diagram services.

## Engines and provenance

| Engine | Pinned version | License | Purpose |
| --- | --- | --- | --- |
| [Pele](https://github.com/obsidianmd/pele) | 1.8.0 | MIT, plus ISC notice for an included Lucide control icon | Mermaid parsing, layout and SVG generation |
| [Marked](https://github.com/markedjs/marked) | 18.1.1 | MIT | CommonMark/GFM parsing |
| [marked-footnote](https://github.com/bent10/marked-extensions/tree/main/packages/footnote) | 1.4.0 | MIT | Footnote definitions and back references |
| [highlight.js](https://github.com/highlightjs/highlight.js) | 11.12.0 | BSD-3-Clause | Fenced-code syntax highlighting |
| [KaTeX](https://github.com/KaTeX/KaTeX) | 0.19.0 | MIT | Inline and block mathematics |
| [js-xss](https://github.com/leizongmin/js-xss) | 1.0.16 | MIT | Static HTML allowlist and URL filtering |
| [cssfilter](https://github.com/leizongmin/js-css-filter) | 0.0.10 | MIT | Included by js-xss |

The lockfile pins package artifacts with integrity hashes. `Licenses/LeafRender` contains notices and a generated manifest with SHA-256 hashes of the shipped JavaScript and math CSS. Notices are also included in the application resources. Esbuild 0.28.2 is a development dependency, not an application runtime.

Rebuild the committed resources after changing an engine:

```sh
npm ci --ignore-scripts
npm run bundle:engines
npm run check:engines
npm run check:native-engines
```

The app itself needs neither Node nor npm. Normal Swift builds use the committed resources. Resource loading first locates `Leaf_LeafRender.bundle` through the application's `Contents/Resources`; only command-line/development launches fall back to SwiftPM's generated accessor. An installed app does not rely on an absolute checkout or `.build` path.

## Mermaid

`DiagramEngine.render(_:theme:)` returns the SVG, natural dimensions and diagram type. The renderer supports the 33 families provided by Pele 1.8.0: flowcharts, sequence, class, state, ER, pie, Gantt, Git graphs, mindmaps, timelines, journeys, XY and quadrant charts, requirements, C4, Sankey, blocks, packets, kanban, architecture, radar, treemaps, info, agentflow, use cases, railroad grammars, tree views, Venn, Cynefin, Wardley, swimlanes, Ishikawa and event modeling.

Pele targets the built-in Mermaid 12.1.0 grammar. It has its own geometry and appearance; it does not reproduce Mermaid's exact layout. External Mermaid plugins, JavaScript callbacks, arbitrary HTML labels and Mermaid theme settings are not supported. Diagram links and remote images are disabled. Math inside diagram labels remains readable TeX source; mathematics in Markdown is typeset by KaTeX.

Pele normally uses CSS custom properties. AppKit's SVG decoder does not resolve them. Leaf resolves the theme and font properties to concrete SVG attributes before returning the result. Literal `var(...)` text in diagram labels stays intact. The resulting SVG loads through public `NSImage(data:)` and can be displayed and exported with native AppKit drawing. Diagram navigation and export UI do not require a WebView.

Limits are 50,000 UTF-16 source units, 5,000 flowchart/agentflow edges and 4 MB SVG output. Extreme or malformed diagrams produce typed errors with positions when Pele supplies them. Diagram parsing runs outside the main actor. Cancellation is checked before and after a synchronous render; it cannot preempt a JavaScriptCore call already in progress.

## Markdown and static MDX

`MarkupEngine.html(_:options:)` returns a complete HTML document; `fragment(_:)` returns a fragment for native transclusion and HTML blocks. Supported features include GFM tables, task lists, strikethrough, footnotes, stable heading anchors, optional table of contents, wiki links, highlight marks, GitHub/Obsidian-style callouts, highlighted code, Mermaid blocks, TeX math and static HTML. YAML frontmatter stays available in a compact Properties disclosure.

The preview is static. Document scripts, event handlers and JavaScript links are removed or shown as inert source. MDX imports/exports are shown as code. Block JSX components become labeled static sections with their text preserved. JavaScript expressions and custom React components are not evaluated. This deliberately supports useful static MDX content without granting documents access to the application.

Inline HTML formatting retains safe typography, colors, borders, spacing, dimensions and basic flex/grid declarations. Styles that load resources or position content over the interface are removed. AppKit's live HTML blocks support its native HTML-import subset; reading/export views use WebKit's broader static layout support.

HTML previews must keep `WKWebpagePreferences.allowsContentJavaScript` disabled. The HTML also carries a restrictive Content Security Policy: no scripts, network connections, frames, forms, remote images or remote fonts. KaTeX WOFF2 fonts are embedded in the CSS as data URLs. The native preview service embeds local image bytes; links retain the document base URL. `leaf://open?target=...` wiki links are handled by the native navigation delegate.

Preview/fragment rendering is limited to 2,000,000 UTF-16 units. Local preview images are embedded as data URLs so WebKit does not need directory permissions. Missing preview images have readable placeholders; document export instead reports missing assets. Individual code blocks above 100,000 characters stay legible plain code rather than entering syntax highlighting. Invalid math and Mermaid blocks retain their source and show a concise rendering error. Unsupported constructs remain visible.

## Verification

`npm run check:engines` exercises all 33 Mermaid families in light and dark themes, concrete SVG theme resolution, literal variable text, malformed and oversized diagrams, GFM/footnotes/math/highlighting, callouts, wiki links, static MDX/HTML, dangerous script and URL handling, and offline font URLs.

`npm run check:native-engines` runs a Swift 6 probe compiled with strict concurrency and the macOS 26.5 SDK verifies resource loading, both public actors, typed errors, all 66 native `NSImage` SVG decoding/drawing cases and native PDF generation. Full application editing, document lifecycle, export controls and rendered interface acceptance are verified separately by the native application owner.
