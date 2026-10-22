# Leaf integration changes

Based on nodes-app/swift-markdown-engine revision `3d3636a0cc850927609ad95e112ac886e5afa47a`, Apache-2.0. Original notices and source headers retained.

- Expose a host NSTextView setup callback.
- Add a cached standalone-block service for source-preserving diagrams, HTML and transclusions. Uses the upstream collapsed-source layout and caret-reveal machinery.
- Trim demo/test targets from the vendored package manifest; upstream test sources are not distributed with this focused copy.

- Preserve portable `[[target|alias]]` source, display the alias, and route local/relative/fragment links through Leaf's navigation handler.
- Synchronize committed native text immediately, guard presentation rebuilds, and bridge native Undo/Redo notifications where AppKit does not send the normal delegate callback.
- Retain Undo across source/live/reading transitions. Commit active IME composition before intentional mode/font changes; skip unrelated presentation refreshes during composition.
- Add separate secondary selections, rectangular selection, batch replacement and exact Undo. Reuse CotEditor's Apache-2.0 insertion model with native TextKit 2 geometry; reveal syntax independently at every caret.
- Add native image drag/drop through the existing host paste hook. The host persists an asset before inserting its relative Markdown reference.
- Add configurable heading/code fonts, heading color, focus presentation and custom-caret visibility. Synchronize reading-column width at runtime.
- Load code-highlighter resources from standard sealed-app bundle locations. Make debug performance tracing opt-in and remove unused-variable/selector warnings.

Leaf's integration and native regression checks live in `Sources/Leaf/LeafNativeChecks*.swift`. The primary text storage retains original characters; presentation is derived styling, native images and layout attributes.
