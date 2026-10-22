// Leaf extension to SwiftMarkdownEngine. Copyright 2026 Leaf contributors.
// Apache-2.0, matching the upstream engine.
import AppKit

/// An already-rendered, source-preserving standalone block. Expensive work belongs
/// to the host's owned background renderer; this synchronous seam only reads a cache.
public struct RenderedMarkdownBlock: Sendable {
    public let range: NSRange
    public let image: NSImage
    public let accessibilityLabel: String
    public init(range: NSRange, image: NSImage, accessibilityLabel: String) {
        self.range = range; self.image = image; self.accessibilityLabel = accessibilityLabel
    }
}

public protocol RenderedBlockProvider: Sendable {
    func blocks(in source: String) -> [RenderedMarkdownBlock]
}
public struct NoOpRenderedBlockProvider: RenderedBlockProvider {
    public init() {}
    public func blocks(in source: String) -> [RenderedMarkdownBlock] { [] }
}
