import AppKit

/// The idle-state menu-bar glyph: Lens's brand mark (crop marks + caret),
/// loaded from Resources/LensMark.svg and rendered as a monochrome template
/// image. Template rendering lets macOS tint it white/black to match the
/// menu bar, like the built-in status icons.
enum MenuBarIcon {
    static let mark: NSImage = {
        guard let url = Bundle.module.url(forResource: "LensMark", withExtension: "svg"),
              let svg = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Lens")!
        }

        let canvas = NSSize(width: 18, height: 18)
        let image = NSImage(size: canvas, flipped: false) { rect in
            svg.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        image.isTemplate = true
        return image
    }()
}
