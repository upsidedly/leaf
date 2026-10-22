# Leaf progress

## Current state

Implementation, integration repairs, rendered inspection and local release installation are complete. GitHub publication to Upsidedly/leaf is the final delivery step. Native verdict: ACCEPT for the evidence scope in Docs/verification.md.

## Delivered

- Native TextKit 2 live/source editing, static reading/split views, tables/tasks/math/code/HTML/footnotes and lossless MDX source.
- Offline Pele diagrams with native vector canvas, pan/zoom/fit, themes, errors and SVG/PNG/PDF exports.
- Folders/tabs, Quick Open, full-text search, wiki links/backlinks, diagnostics, templates, focus/typewriter and configurable motion caret.
- Multiple carets/rectangle selection, regex replacement previews, link-aware file/heading renames, durable workspace Undo and synchronized note/heading/block embeds.
- Asset usage/duplicate tools, descriptions, relative image paste/drop and JPEG preparation. Failed writes preserve source/files.
- Global/folder preferences, fonts/colors/spacing/shortcuts, native saves/autosaves/recovery/conflicts and HTML/PDF/DOCX/EPUB publication.
- Original monochrome app icon, concise README, dependency notices and reproducible build/install/check scripts.

## Verified

- Core/settings/EPUB checks pass.
- All 33 diagram families pass light/dark engine and native SVG probes (66 cases).
- The installed release passes 27 native workflow checks with .build temporarily unavailable. The development folder was restored afterward.
- Actual native wide/compact, light/dark, settings, reading/split and diagram views inspected. A reading-view local-image placeholder found during rendered inspection was repaired by embedding image bytes; the strengthened snapshot check and actual image now pass.
- AppKit coordinated save/autosave, IME, Undo, rectangle edits, workspace transactions/dependency refresh and export failure preservation pass.
- Strict signature verification and Info.plist validation pass. No compiler warnings in the release build.

The external computer-use helper could not start. The in-app checks exercise real native APIs and render real views; external pointer/hardware-keyboard automation and VoiceOver navigation are not claimed. Older macOS runtimes are not claimed as tested. The local package uses ad hoc signing.

## Location

Source: ~/Desktop/Projects/Toybox/QOL/Leaf

Installed app: /Applications/Leaf.app

## Next project

Sapling is separately authorized and queued after Leaf is finished and published. Its brief is kept in the thread continuity note; no Sapling implementation was started during Leaf's release work.
