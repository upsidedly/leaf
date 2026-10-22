import AppKit
import LeafCore

/// Presentation follows the real native caret. It never edits selection, marked
/// text or candidate-window geometry. Input remains owned by NSTextView.
@MainActor final class EditorEnhancements: NSObject {
    weak var textView: NSTextView?
    weak var model: DocumentModel?
    private let overlay = CaretTrailView()
    private var timer: Timer?
    private var ticker: WeakCaretTicker?
    private var previousSelection = NSRange(location: NSNotFound, length: 0)
    init(textView: NSTextView, model: DocumentModel) {
        self.textView = textView; self.model = model
        super.init()
        overlay.frame = textView.bounds; overlay.autoresizingMask = [.width, .height]
        textView.addSubview(overlay)
        let target = WeakCaretTicker(owner: self); ticker = target
        let timer = Timer(timeInterval: 1.0 / 60, target: target, selector: #selector(WeakCaretTicker.tick), userInfo: nil, repeats: true)
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        refreshSettings()
    }
    func stop() { timer?.invalidate(); timer = nil; overlay.removeFromSuperview() }
    func refreshSettings() { if let model { overlay.settings = model.settings.caret; overlay.accent = LeafStyle.accent(model.settings) } }
    fileprivate func tick() {
        guard let textView, let model, let window = textView.window else { overlay.isHidden = true; return }
        let selection = textView.selectedRange()
        guard selection.location != NSNotFound, selection.location <= (textView.string as NSString).length else { overlay.isHidden = true; return }
        let active = window.isKeyWindow && window.firstResponder === textView && textView.isEditable
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let enabled = model.settings.caret.animated && !reduced && !textView.hasMarkedText()
        overlay.isHidden = !active || (!enabled && textView.leafAdditionalSelections.isEmpty)
        if !overlay.isHidden {
            let rect = caretRect(for: NSRange(location: selection.location, length: 0), in: textView)
            overlay.move(to: rect, visible: enabled && selection.length == 0)
            overlay.extraRects = textView.leafAdditionalSelections.flatMap { range in
                if range.length == 0 { return [caretRect(for: range, in: textView)] }
                return selectionRects(for: range, in: textView)
            }
            overlay.advance()
        }
        if selection != previousSelection {
            previousSelection = selection
            if model.typewriterMode, selection.length == 0, active {
                let rect = caretRect(for: selection, in: textView)
                if let scroll = textView.enclosingScrollView {
                    let containerPoint = textView.convert(rect.origin, to: scroll.documentView)
                    let y = max(0, containerPoint.y - scroll.contentView.bounds.height * 0.48)
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }
    }
    private func caretRect(for range: NSRange, in view: NSTextView) -> NSRect {
        guard let window = view.window else { return .zero }
        let rect = view.firstRect(forCharacterRange: range, actualRange: nil)
        return view.convert(window.convertFromScreen(rect), from: nil)
    }
    private func selectionRects(for range: NSRange, in view: NSTextView) -> [NSRect] {
        guard let manager = view.textLayoutManager, let storage = manager.textContentManager,
              let start = storage.location(storage.documentRange.location, offsetBy: range.location),
              let end = storage.location(start, offsetBy: range.length), let textRange = NSTextRange(location: start, end: end) else { return [] }
        var result: [NSRect] = []
        manager.enumerateTextSegments(in: textRange, type: .selection, options: [.rangeNotRequired]) { _, rect, _, _ in
            result.append(rect.offsetBy(dx: view.textContainerInset.width, dy: view.textContainerInset.height)); return true
        }
        return result
    }
}

@MainActor private final class WeakCaretTicker: NSObject {
    weak var owner: EditorEnhancements?
    init(owner: EditorEnhancements) { self.owner = owner }
    // HTML import can run a nested AppKit loop while a Swift task is active.
    // The Objective-C timer entry must establish a fresh main-actor task rather
    // than inheriting that loop's executor context (Golden Gate runtime).
    @objc nonisolated func tick() { Task { @MainActor [weak self] in self?.owner?.tick() } }
}

@MainActor private final class CaretTrailView: NSView {
    var settings = CaretSettings()
    var accent = NSColor.controlAccentColor
    var extraRects: [NSRect] = []
    private var target = NSRect.zero
    private var current = [CGPoint](repeating: .zero, count: 4)
    private var history: [[CGPoint]] = []
    private var lastMove = Date.timeIntervalSinceReferenceDate
    private var lastTick = Date.timeIntervalSinceReferenceDate
    private var initialized = false
    private var caretVisible = true
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func move(to rect: NSRect, visible: Bool) {
        caretVisible = visible
        var rect = rect
        rect.size.width = settings.shape == "block" ? max(8, rect.height * 0.5) : settings.width
        if settings.shape == "underline" { rect.origin.y += rect.height - settings.width; rect.size.height = settings.width; rect.size.width = 9 }
        if rect != target {
            target = rect; lastMove = Date.timeIntervalSinceReferenceDate
            if !initialized || hypot(current[0].x - rect.minX, current[0].y - rect.minY) > 1600 {
                current = corners(rect); initialized = true; history.removeAll()
            }
        }
    }
    func advance() {
        let now = Date.timeIntervalSinceReferenceDate
        let dt = min(0.05, max(1.0 / 240, now - lastTick)); lastTick = now
        let destination = corners(target)
        let dx = target.midX - (current[0].x + current[2].x) / 2
        let dy = target.midY - (current[0].y + current[2].y) / 2
        var moving = false
        for index in 0..<4 {
            let leading = (destination[index].x - target.midX) * dx + (destination[index].y - target.midY) * dy >= 0
            let duration = settings.duration * (leading ? 0.5 : 0.65 + settings.trail * 2)
            let alpha = 1 - exp(-dt * 8 / max(0.025, duration))
            current[index].x += (destination[index].x - current[index].x) * alpha
            current[index].y += (destination[index].y - current[index].y) * alpha
            if hypot(current[index].x - destination[index].x, current[index].y - destination[index].y) > 0.1 { moving = true }
        }
        if moving { history.append(current); if history.count > 6 { history.removeFirst() } }
        else { history.removeAll(); current = destination }
        needsDisplay = true
    }
    private func corners(_ rect: NSRect) -> [CGPoint] { [CGPoint(x: rect.minX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.minY),CGPoint(x: rect.maxX,y: rect.maxY),CGPoint(x: rect.minX,y: rect.maxY)] }
    private var color: NSColor {
        switch settings.color { case "text": .labelColor; case "blue": .systemBlue; case "orange": .systemOrange; default: accent }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard initialized else { return }
        for rect in extraRects { color.withAlphaComponent(rect.width > 3 ? 0.22 : 0.85).setFill(); rect.fill() }
        guard caretVisible else { return }
        let elapsed = Date.timeIntervalSinceReferenceDate - lastMove
        if settings.blink, elapsed > 0.7, Int((elapsed - 0.7) * 2) % 2 == 1 { return }
        if settings.blur > 0 {
            for (index, points) in history.enumerated() {
                draw(points, alpha: CGFloat(index + 1) / CGFloat(max(1, history.count)) * settings.blur * 0.12, blur: settings.blur * 3)
            }
        }
        draw(current, alpha: settings.shape == "block" ? 0.5 : 0.95, blur: 0)
    }
    private func draw(_ points: [CGPoint], alpha: CGFloat, blur: CGFloat) {
        guard let first = points.first else { return }
        NSGraphicsContext.saveGraphicsState()
        if blur > 0 { let shadow = NSShadow(); shadow.shadowColor = color.withAlphaComponent(alpha); shadow.shadowBlurRadius = blur; shadow.set() }
        let path = NSBezierPath(); path.move(to: first); points.dropFirst().forEach { path.line(to: $0) }; path.close()
        color.withAlphaComponent(alpha).setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
