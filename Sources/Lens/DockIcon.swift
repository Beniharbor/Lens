import AppKit

/// Lens's Dock tile: the system's blue folder with the Lens mark debossed
/// into it, in place of the Downloads arrow. Built at runtime from the
/// current OS folder artwork, so it matches whatever macOS version it's on.
// No Bundle.module here: Scripts/make-app-icon.sh compiles this file on its own
// to render Resources/Lens.icns.
enum DockIcon {
    static func make(mark: NSImage?) -> NSImage {
        let side: CGFloat = 1024
        let canvas = NSRect(x: 0, y: 0, width: side, height: side)
        let folder = NSWorkspace.shared.icon(for: .folder)
        guard let mark else { return folder }

        return NSImage(size: canvas.size, flipped: false) { _ in
            folder.draw(in: canvas)

            // Same placement and size as the Downloads arrow glyph. The mark's
            // artwork spans 124 of its 160-unit viewBox.
            let markSide = side * 0.453
            let markRect = NSRect(
                x: (side - markSide) / 2,
                y: side * 0.434 - markSide / 2,
                width: markSide,
                height: markSide
            )

            // Highlight just below the glyph, then the darker inset fill: the
            // same subtle "pressed into the folder" look as the system glyphs.
            tinted(mark, NSColor(white: 1, alpha: 0.22))
                .draw(in: markRect.offsetBy(dx: 0, dy: -side * 0.003))
            tinted(mark, NSColor(srgbRed: 0.05, green: 0.30, blue: 0.48, alpha: 0.30))
                .draw(in: markRect)
            return true
        }
    }

    /// Recolors a single-color (black) image, keeping its alpha.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
    }
}
