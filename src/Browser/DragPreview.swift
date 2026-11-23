import AppKit

extension NSView {
    func dragPreview(size: NSSize? = nil, radius: CGFloat, background: NSColor? = nil) -> NSImage? {
        layoutSubtreeIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        let snapshot = NSImage(size: bounds.size)
        snapshot.addRepresentation(bitmap)
        let size = size ?? bounds.size
        let card = NSImage(size: size, flipped: isFlipped) { rect in
            background?.setFill()
            if background != nil { rect.fill() }
            snapshot.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
            return true
        }
        let accent = PerchTheme.shared.selection.accent
        return NSImage(size: size, flipped: isFlipped) { rect in
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            // Apply opacity once to the complete card, including its background.
            card.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.88,
                      respectFlipped: true, hints: nil)
            accent.withAlphaComponent(0.38).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                         xRadius: radius, yRadius: radius).stroke()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }
}
