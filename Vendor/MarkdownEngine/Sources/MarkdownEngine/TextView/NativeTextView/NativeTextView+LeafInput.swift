// Leaf TextKit 2 adaptation of the secondary-insertion model used by CotEditor.
// Model and batch ordering reference: © 2018–2026 1024jp, Apache-2.0.
// https://github.com/coteditor/CotEditor/blob/main/CotEditor/Sources/Document%20Window/Text%20View/NSTextView%2BMultiCursor.swift
// Native geometry and host integration: Copyright 2026 Leaf contributors.
import AppKit

public extension NSTextView {
    var leafAdditionalSelections: [NSRange] { (self as? NativeTextView)?.leafExtraSelections ?? [] }
    /// Text-view coordinates, used by the rectangular-selection gesture.
    func leafSelectRectangle(from start: NSPoint, to end: NSPoint) {
        guard let view = self as? NativeTextView else { return }
        view.leafSetSelections(view.leafRectangle(from:start,to:end))
    }
    @discardableResult func leafDropImage(from pasteboard: NSPasteboard, at point: NSPoint) -> Bool {
        (self as? NativeTextView)?.leafInsertDroppedImage(from:pasteboard,at:point) ?? false
    }
}

extension NativeTextView {
    @objc func leafClearCarets(_ sender: Any?) { leafExtraSelections = []; leafRefreshSelections() }
    @objc func leafAddNextOccurrence(_ sender: Any?) {
        let ns = string as NSString
        var primary = selectedRange()
        if primary.length == 0 {
            guard primary.location < ns.length else { return }
            let word = selectionRange(forProposedRange: primary, granularity: .selectByWord)
            guard word.length > 0 else { return }
            setSelectedRange(word); primary = word
        }
        let value = ns.substring(with: primary)
        let all = [primary] + leafExtraSelections
        let last = all.map(NSMaxRange).max() ?? NSMaxRange(primary)
        let found = ns.range(of: value, options: [], range: NSRange(location: min(last, ns.length), length: ns.length - min(last, ns.length)))
        if found.location != NSNotFound { leafExtraSelections.append(found); leafRefreshSelections(); scrollRangeToVisible(found) }
    }
    @objc func leafAddCaretBelow(_ sender: Any?) {
        let last = leafExtraSelections.last ?? selectedRange()
        guard let rect = leafCaretRect(last.location) else { return }
        let index = characterIndexForInsertion(at: NSPoint(x: rect.minX, y: rect.maxY + 4))
        guard index != last.location, index <= (string as NSString).length else { return }
        leafExtraSelections.append(NSRange(location: index, length: 0)); leafRefreshSelections(); scrollRangeToVisible(.init(location: index,length: 0))
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard !leafExtraSelections.isEmpty, !hasMarkedText(), !leafBatchEditing else { super.insertText(insertString, replacementRange: replacementRange); return }
        let value = (insertString as? NSAttributedString)?.string ?? (insertString as? String ?? "")
        leafReplace(value, ranges: [selectedRange()] + leafExtraSelections)
    }
    func leafHandleCommand(_ selector: Selector) -> Bool {
        guard !leafExtraSelections.isEmpty, !hasMarkedText() else { return false }
        switch NSStringFromSelector(selector) {
        case "cancelOperation:": leafClearCarets(nil); return true
        case "insertNewline:": leafReplace("\n", ranges: [selectedRange()] + leafExtraSelections); return true
        case "insertTab:": leafReplace("\t", ranges: [selectedRange()] + leafExtraSelections); return true
        case "deleteBackward:", "deleteForward:":
            let ns = string as NSString, forward = NSStringFromSelector(selector) == "deleteForward:"
            let ranges = ([selectedRange()] + leafExtraSelections).map { range -> NSRange in
                guard range.length == 0 else { return range }
                let location = forward ? range.location : range.location - 1
                guard location >= 0, location < ns.length else { return range }
                return ns.rangeOfComposedCharacterSequence(at: location)
            }
            leafReplace("", ranges: ranges); return true
        case "moveLeft:", "moveRight:", "moveUp:", "moveDown:":
            let ns = string as NSString
            let next = ([selectedRange()] + leafExtraSelections).map { range -> NSRange in
                var location = range.location
                switch NSStringFromSelector(selector) {
                case "moveLeft:": if location > 0 { location = ns.rangeOfComposedCharacterSequence(at: location - 1).location }
                case "moveRight:": if NSMaxRange(range) < ns.length { location = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: NSMaxRange(range))) }
                default:
                    if let rect = leafCaretRect(location) { location = characterIndexForInsertion(at: NSPoint(x: rect.minX, y: rect.midY + (NSStringFromSelector(selector) == "moveUp:" ? -rect.height - 3 : rect.height + 3))) }
                }
                return NSRange(location: min(ns.length, max(0, location)),length: 0)
            }
            leafSetSelections(next); return true
        default: return false
        }
    }
    fileprivate func leafSetSelections(_ ranges: [NSRange]) {
        guard let first = ranges.first else { return }
        setSelectedRange(first); leafExtraSelections = Array(ranges.dropFirst()); leafRefreshSelections()
    }
    private func leafRefreshSelections() {
        guard !leafBatchEditing, !hasMarkedText() else { return }
        needsDisplay = true
        // Secondary selections can reveal syntax in disconnected paragraphs.
        // This command-level refresh also collapses their previous locations.
        (delegate as? NativeTextViewCoordinator)?.restyleParagraphs([NSRange(location:0,length:(string as NSString).length)],in:self)
    }
    private func leafReplace(_ value: String, ranges: [NSRange]) {
        let ns = string as NSString
        var unique: [NSRange] = []
        for range in ranges.sorted(by: { ($0.location, $0.length) < ($1.location, $1.length) }) {
            guard range.location >= 0, NSMaxRange(range) <= ns.length else { continue }
            if let previous = unique.last, range.location < NSMaxRange(previous) || range == previous { continue }
            unique.append(range)
        }
        guard !unique.isEmpty else { return }
        let before = string, beforeSelections = [selectedRange()] + leafExtraSelections
        let mutable = NSMutableString(string: before)
        for range in unique.reversed() { mutable.replaceCharacters(in: range, with: value) }
        var delta = 0
        let selections = unique.map { range -> NSRange in
            let location = range.location + delta + (value as NSString).length
            delta += (value as NSString).length - range.length
            return NSRange(location: location, length: 0)
        }
        leafRestore(mutable as String, selections: selections, action: "Edit at Multiple Carets", undoSource: before, undoSelections: beforeSelections)
    }
    private func leafRestore(_ source: String, selections: [NSRange], action: String, undoSource: String? = nil, undoSelections: [NSRange]? = nil) {
        let oldSource = undoSource ?? string, oldSelections = undoSelections ?? ([selectedRange()] + leafExtraSelections)
        let full = NSRange(location: 0, length: (string as NSString).length)
        let coordinator = delegate as? NativeTextViewCoordinator
        let priorProgrammatic = coordinator?.isProgrammaticEdit ?? false
        coordinator?.isProgrammaticEdit = true; leafBatchEditing = true
        breakUndoCoalescing()
        let manager = undoManager
        let opensGroup = manager?.isUndoing != true && manager?.isRedoing != true
        if opensGroup { manager?.beginUndoGrouping() }
        // shouldChangeText itself registers native text undo. The batch owns one
        // snapshot action, so registration is suspended BEFORE validation too.
        manager?.disableUndoRegistration()
        guard shouldChangeText(in: full, replacementString: source) else {
            manager?.enableUndoRegistration(); if opensGroup { manager?.endUndoGrouping() }
            leafBatchEditing = false; coordinator?.isProgrammaticEdit = priorProgrammatic; return
        }
        textStorage?.replaceCharacters(in: full, with: NSAttributedString(string: source, attributes: typingAttributes))
        leafSetSelections(selections); didChangeText()
        undoManager?.enableUndoRegistration()
        undoManager?.registerUndo(withTarget: self) { target in target.leafRestore(oldSource, selections: oldSelections, action: action) }
        undoManager?.setActionName(action)
        if opensGroup { manager?.endUndoGrouping() }
        breakUndoCoalescing()
        leafBatchEditing = false; coordinator?.isProgrammaticEdit = priorProgrammatic
    }
    func leafHandleMouse(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains([.command,.option]) {
            let location = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            let range = NSRange(location: location,length: 0)
            if let index = leafExtraSelections.firstIndex(of:range) { leafExtraSelections.remove(at:index) }
            else if range != selectedRange() { leafExtraSelections.append(range) }
            leafRefreshSelections(); return true
        }
        guard mods == .option, let window else { if !leafExtraSelections.isEmpty { leafClearCarets(nil) }; return false }
        let start = convert(event.locationInWindow, from: nil)
        while let next = window.nextEvent(matching: [.leftMouseDragged,.leftMouseUp]) {
            let end = convert(next.locationInWindow, from: nil)
            leafSetSelections(leafRectangle(from: start, to: end))
            if next.type == .leftMouseUp { break }
        }
        return true
    }
    fileprivate func leafRectangle(from start: CGPoint, to end: CGPoint) -> [NSRange] {
        guard let manager = textLayoutManager else { return [] }
        var ranges: [NSRange] = []
        let low = min(start.y,end.y), high = max(start.y,end.y)
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for line in fragment.textLineFragments {
                let y = fragment.layoutFragmentFrame.minY + line.typographicBounds.midY + self.textContainerInset.height
                guard y >= low - 2, y <= high + 2 else { continue }
                let a = self.characterIndexForInsertion(at: CGPoint(x: start.x,y: y)), b = self.characterIndexForInsertion(at: CGPoint(x: end.x,y: y))
                ranges.append(NSRange(location: min(a,b),length: abs(a-b)))
            }
            return fragment.layoutFragmentFrame.minY < high + 100
        }
        if ranges.isEmpty { ranges = [NSRange(location: characterIndexForInsertion(at: end),length: 0)] }
        return ranges
    }
    private func leafCaretRect(_ location: Int) -> NSRect? {
        guard let window else { return nil }
        return convert(window.convertFromScreen(firstRect(forCharacterRange: NSRange(location: location,length: 0), actualRange: nil)), from: nil)
    }
}
