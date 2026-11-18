import SwiftUI
import KeyboardShortcuts

/// The Dock grid's help popover: every shortcut and gesture, grouped.
/// Opened from the ? button in the grid's header, ⌘/ or ⌘?, or right-click.
struct ShortcutsHelpView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let keys: [String] // alternatives, shown as separate key caps
        let action: String
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let symbol: String
        let items: [Item]
    }

    private var captureShortcut: String {
        KeyboardShortcuts.getShortcut(for: .captureText)?.description ?? "Not set"
    }

    private var leftColumn: [Group] {
        [
            Group(title: "Select & Drag", symbol: "cursorarrow.rays", items: [
                Item(keys: ["Click"], action: "Select a file"),
                Item(keys: ["⌘ Click"], action: "Add to or remove from selection"),
                Item(keys: ["⇧ Click"], action: "Select a range"),
                Item(keys: ["Drag on empty space"], action: "Select with a box"),
                Item(keys: ["⌘A"], action: "Select all"),
                Item(keys: ["← → ↑ ↓"], action: "Move the selection"),
                Item(keys: ["Drag files"], action: "Drop them into any app or folder"),
            ]),
            Group(title: "Open & Browse", symbol: "folder", items: [
                Item(keys: ["Return", "⌘↓"], action: "Open (folders open inside the grid)"),
                Item(keys: ["Double-click"], action: "Open"),
                Item(keys: ["⌘↑", "Delete"], action: "Back to the parent folder"),
                Item(keys: ["Space"], action: "Quick Look"),
                Item(keys: ["Right-click"], action: "Open With, Rename, Compress…"),
            ]),
        ]
    }

    private var rightColumn: [Group] {
        [
            Group(title: "Files", symbol: "doc.on.doc", items: [
                Item(keys: ["⌘C"], action: "Copy the files"),
                Item(keys: ["⌘⇧C"], action: "Copy the text in images & PDFs"),
                Item(keys: ["⌘⌫"], action: "Move to Trash"),
            ]),
            Group(title: "Search & View", symbol: "magnifyingglass", items: [
                Item(keys: ["Type", "⌘F"], action: "Search by name"),
                Item(keys: ["Return"], action: "In search: open the top match"),
                Item(keys: ["↓"], action: "In search: jump to the results"),
                Item(keys: ["⌘+", "⌘-"], action: "Larger / smaller icons"),
                Item(keys: ["⌘/"], action: "Show this help"),
            ]),
            Group(title: "Window", symbol: "macwindow", items: [
                Item(keys: ["Esc"], action: "Clear the search, then close"),
                Item(keys: ["Dock icon"], action: "Open or close the grid"),
                Item(keys: ["Pin button"], action: "Keep open while using other apps"),
                Item(keys: ["Drag an edge"], action: "Resize (remembered)"),
            ]),
            Group(title: "Anywhere", symbol: "text.viewfinder", items: [
                Item(keys: [captureShortcut], action: "Copy text from part of the screen"),
            ]),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dock Grid Shortcuts")
                .font(.system(size: 15, weight: .semibold))
            HStack(alignment: .top, spacing: 28) {
                column(leftColumn)
                column(rightColumn)
            }
        }
        .padding(18)
        .fixedSize()
    }

    private func column(_ groups: [Group]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Label(group.title, systemImage: group.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(group.items) { item in
                        row(item)
                    }
                }
            }
        }
        .frame(width: 290, alignment: .leading)
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(item.keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 {
                        Text("or").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    KeyCap(text: key)
                }
            }
            .frame(width: 136, alignment: .trailing)
            Text(item.action)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}
