import AppKit
@preconcurrency import Quartz
import QuickLookThumbnailing

/// One file in ~/Downloads, as shown in the grid.
struct DownloadsEntry: Equatable {
    let url: URL
    let name: String
    let dateAdded: Date
    let modified: Date

    /// Newest first by Date Added — the Dock's default order for the Downloads stack.
    static func load(from folder: URL) -> [DownloadsEntry] {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return DownloadsEntry(
                url: url,
                name: FileManager.default.displayName(atPath: url.path),
                dateAdded: values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast,
                modified: values?.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.dateAdded > $1.dateAdded }
    }
}

/// Quick Look thumbnails (the same previews Finder and the Dock show), cached
/// in memory and keyed by path + modification date so edited files refresh.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    /// Keyed by size too, so switching icon sizes renders sharp thumbnails.
    private func key(for entry: DownloadsEntry, side: CGFloat) -> NSString {
        "\(entry.url.path)|\(entry.modified.timeIntervalSinceReferenceDate)|\(Int(side))" as NSString
    }

    func cached(_ entry: DownloadsEntry, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(for: entry, side: side))
    }

    func load(_ entry: DownloadsEntry, size: CGSize, scale: CGFloat, completion: @escaping @MainActor (NSImage) -> Void) {
        let key = key(for: entry, side: size.width) as String
        let request = QLThumbnailGenerator.Request(
            fileAt: entry.url,
            size: size,
            scale: scale,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in
                ThumbnailLoader.shared.cache.setObject(image, forKey: key as NSString)
                completion(image)
            }
        }
    }
}

/// Rounded highlight behind a selected tile. Drawn (not layer-backed colors)
/// so it follows light/dark mode and accent color changes automatically.
final class TileBackdropView: NSView {
    var isHighlighted = false {
        didSet { if oldValue != isHighlighted { needsDisplay = true } }
    }

    /// Soft hover glow, like the native grid stack.
    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        if isHighlighted {
            color = NSColor.controlAccentColor.withAlphaComponent(0.35)
        } else if isHovered {
            color = NSColor.labelColor.withAlphaComponent(0.08)
        } else {
            return
        }
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
    }
}

/// Icon size choice for the grid (Small / Medium / Large), remembered across launches.
enum TileSize: Int, CaseIterable {
    case small, medium, large

    private static let defaultsKey = "downloadsTileSize"

    static var current: TileSize {
        get { TileSize(rawValue: UserDefaults.standard.object(forKey: defaultsKey) as? Int ?? 1) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var tile: NSSize {
        switch self {
        case .small: return NSSize(width: 76, height: 82)
        case .medium: return NSSize(width: 92, height: 100)
        case .large: return NSSize(width: 124, height: 136)
        }
    }

    var icon: CGFloat {
        switch self {
        case .small: return 44
        case .medium: return 60
        case .large: return 88
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: return 10
        case .medium: return 11
        case .large: return 12
        }
    }

    var smaller: TileSize? { TileSize(rawValue: rawValue - 1) }
    var larger: TileSize? { TileSize(rawValue: rawValue + 1) }
}

final class DownloadsTile: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("DownloadsTile")

    private let backdrop = TileBackdropView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var entry: DownloadsEntry?
    private var tileSize: TileSize = .medium
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!

    override func loadView() {
        view = backdrop

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false

        backdrop.addSubview(icon)
        backdrop.addSubview(label)
        iconWidth = icon.widthAnchor.constraint(equalToConstant: tileSize.icon)
        iconHeight = icon.heightAnchor.constraint(equalToConstant: tileSize.icon)
        apply(tileSize)
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 6),
            icon.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            iconWidth,
            iconHeight,
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
            label.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -4),
        ])

        // NSCollectionView builds the drag image from these two outlets.
        imageView = icon
        textField = label
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        backdrop.isHovered = false
    }

    private func apply(_ size: TileSize) {
        tileSize = size
        iconWidth.constant = size.icon
        iconHeight.constant = size.icon
        label.font = .systemFont(ofSize: size.fontSize)
        label.preferredMaxLayoutWidth = size.tile.width - 8
    }

    func configure(with entry: DownloadsEntry, size: TileSize, scale: CGFloat) {
        _ = view // make sure loadView has run before touching constraints
        if size != tileSize { apply(size) }
        self.entry = entry
        label.stringValue = entry.name
        view.toolTip = entry.name

        let side = size.icon
        if let cached = ThumbnailLoader.shared.cached(entry, side: side) {
            icon.image = cached
            return
        }
        icon.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        ThumbnailLoader.shared.load(entry, size: CGSize(width: side, height: side), scale: scale) { [weak self] image in
            guard let self, self.entry == entry else { return } // tile was reused
            self.icon.image = image
        }
    }

    override var isSelected: Bool {
        didSet { refreshHighlight() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { refreshHighlight() }
    }

    private func refreshHighlight() {
        // highlightState previews rubber-band / Cmd-click changes before they commit.
        switch highlightState {
        case .forSelection: backdrop.isHighlighted = true
        case .forDeselection: backdrop.isHighlighted = false
        default: backdrop.isHighlighted = isSelected
        }
    }
}

/// NSCollectionView already provides Cmd-click, Shift-click, rubber-band
/// selection, arrow keys and multi-item dragging. This subclass adds the
/// Finder-style extras: double-click / Return to open, Space for Quick Look,
/// Esc to close, ⌘A to select all.
final class DownloadsCollectionView: NSCollectionView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var selectedURLs: () -> [URL] = { [] }
    var onOpen: (() -> Void)?
    var onCancel: (() -> Void)?
    var onBack: (() -> Void)?
    var onResizeIcons: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 36, 76: // Return, Enter
            onOpen?()
        case 49: // Space
            toggleQuickLook()
        case 125 where flags.contains(.command): // ⌘↓, like Finder
            onOpen?()
        case 126 where flags.contains(.command), 33 where flags == .command, 51: // ⌘↑, ⌘[, Delete
            onBack?()
        case 0 where flags == .command: // ⌘A (Lens has no Edit menu to route it)
            selectAll(nil)
        case 24 where flags.contains(.command): // ⌘= / ⌘+ — bigger icons, like Finder
            onResizeIcons?(+1)
        case 27 where flags.contains(.command): // ⌘- — smaller icons
            onResizeIcons?(-1)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2,
           let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
            }
            onOpen?()
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else if !selectedURLs().isEmpty {
            QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
        }
    }

    func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        QLPreviewPanel.shared().reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedURLs().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = selectedURLs()
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    /// Arrow keys and Space typed while the Quick Look panel is key still drive the grid.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [49, 123, 124, 125, 126].contains(event.keyCode) else { return false }
        keyDown(with: event)
        return true
    }
}
