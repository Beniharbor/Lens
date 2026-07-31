import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Default ⌘⇧2 — deliberately next to macOS's own ⌘⇧3/⌘⇧4/⌘⇧5 screenshot
    /// shortcuts, but on an unused slot. Changeable from the menu.
    static let captureText = Self("captureText", default: .init(.two, modifiers: [.command, .shift]))
}
