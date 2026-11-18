import AppKit
@preconcurrency import Quartz
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// One file in the grid's folder.
struct DownloadsEntry: Equatable {
    let url: URL
    let name: String
    let kind: String
    let size: Int64? // nil for folders
    let dateAdded: Date
    let modified: Date

    /// Images and PDFs can be run through Lens's text recognition.
    var supportsTextExtraction: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    /// Unsorted; the grid applies `GridSortOrder`.
    static func load(from folder: URL) -> [DownloadsEntry] {
        let keys: [URLResourceKey] = [
            .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey,
            .localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey,
        ]
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
                kind: values?.localizedTypeDescription ?? "",
                size: values?.isDirectory == true ? nil : values?.fileSize.map(Int64.init),
                dateAdded: values?.addedToDirectoryDate ?? values?.creationDate ?? .distantPast,
                modified: values?.contentModificationDate ?? .distantPast
            )
        }
    }
}

/// Sort order for the grid, remembered across launches. Date Added (newest
/// first) is the Dock's default for the Downloads stack.
enum GridSortOrder: Int, CaseIterable {
    case dateAdded, dateModified, name, kind, size

    private static let defaultsKey = "gridSortOrder"

    static var current: GridSortOrder {
        get { GridSortOrder(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .dateAdded }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var title: String {
        switch self {
        case .dateAdded: return "Date Added"
        case .dateModified: return "Date Modified"
        case .name: return "Name"
        case .kind: return "Kind"
        case .size: return "Size"
        }
    }

    func sorted(_ entries: [DownloadsEntry]) -> [DownloadsEntry] {
        let byName: (DownloadsEntry, DownloadsEntry) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        switch self {
        case .dateAdded: return entries.sorted { $0.dateAdded > $1.dateAdded }
        case .dateModified: return entries.sorted { $0.modified > $1.modified }
        case .name: return entries.sorted(by: byName)
        case .kind:
            return entries.sorted {
                $0.kind == $1.kind ? byName($0, $1) : $0.kind.localizedStandardCompare($1.kind) == .orderedAscending
            }
        case .size: return entries.sorted { ($0.size ?? -1) > ($1.size ?? -1) } // largest first, folders last
        }
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

    /// Blue dot on the icon's top-right corner for files added since the
    /// grid was last opened.
    var showsNewDot = false {
        didSet { if oldValue != showsNewDot { needsDisplay = true } }
    }
    var iconSide: CGFloat = 60
    var iconTopInset: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor?
        if isHighlighted {
            color = NSColor.controlAccentColor.withAlphaComponent(0.35)
        } else if isHovered {
            color = NSColor.labelColor.withAlphaComponent(0.08)
        } else {
            color = nil
        }
        if let color {
            color.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }

        if showsNewDot {
            let diameter: CGFloat = 10
            let center = NSPoint(x: bounds.midX + iconSide / 2 - 3, y: bounds.maxY - iconTopInset - 3)
            let dot = NSBezierPath(ovalIn: NSRect(
                x: center.x - diameter / 2, y: center.y - diameter / 2,
                width: diameter, height: diameter
            ))
            NSColor.controlAccentColor.setFill()
            dot.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
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

    func configure(with entry: DownloadsEntry, size: TileSize, scale: CGFloat, isNew: Bool) {
        _ = view // make sure loadView has run before touching constraints
        if size != tileSize { apply(size) }
        backdrop.iconSide = size.icon
        backdrop.showsNewDot = isNew
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

/// Everything the grid can ask its controller to do.
@MainActor
protocol DownloadsGridActions: AnyObject {
    func gridSelectedURLs() -> [URL]
    func gridOpen()
    func gridCancel()
    func gridBack()
    func gridTrash()
    func gridCopyFiles()
    func gridCopyText()
    func gridResizeIcons(_ step: Int)
    /// Focus the search field, optionally typing `text` into it (type-to-search).
    func gridFocusSearch(typing text: String?)
    func gridContextMenu() -> NSMenu?
}

/// NSCollectionView already provides Cmd-click, Shift-click, rubber-band
/// selection, arrow keys and multi-item dragging. This subclass adds the
/// Finder-style extras: keyboard shortcuts, type-to-search, double-click to
/// open, right-click menu and Quick Look.
final class DownloadsCollectionView: NSCollectionView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    weak var actions: DownloadsGridActions?

    override var acceptsFirstResponder: Bool { true }

    /// Lets a drag start on the first click even when Lens isn't the active
    /// app (e.g. a pinned grid while you work in another app).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let actions else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let plain = flags.isEmpty
        let cmd = flags == .command
        let cmdShift = flags == [.command, .shift]

        switch event.keyCode {
        case 53 where plain: actions.gridCancel()                    // Esc
        case 36 where plain, 76 where plain: actions.gridOpen()       // Return, Enter
        case 125 where cmd: actions.gridOpen()                        // ⌘↓, like Finder
        case 49 where plain: toggleQuickLook()                        // Space
        case 51 where cmd: actions.gridTrash()                        // ⌘⌫
        case 126 where cmd, 33 where cmd, 51 where plain: actions.gridBack() // ⌘↑, ⌘[, Delete
        case 0 where cmd: selectAll(nil)                              // ⌘A (no Edit menu to route it)
        case 8 where cmd: actions.gridCopyFiles()                     // ⌘C
        case 8 where cmdShift: actions.gridCopyText()                 // ⌘⇧C
        case 3 where cmd: actions.gridFocusSearch(typing: nil)        // ⌘F
        case 24 where cmd || cmdShift: actions.gridResizeIcons(+1)    // ⌘= / ⌘+
        case 27 where cmd: actions.gridResizeIcons(-1)                // ⌘-
        default:
            if flags.isDisjoint(with: [.command, .control, .option]),
               let characters = event.characters, Self.isTypeable(characters) {
                actions.gridFocusSearch(typing: characters)
            } else {
                super.keyDown(with: event) // arrow keys etc.
            }
        }
    }

    /// Printable text only — not arrows/function keys (U+F700…) or controls.
    private static func isTypeable(_ characters: String) -> Bool {
        !characters.isEmpty && characters.unicodeScalars.allSatisfy {
            $0.value < 0xF700 && !CharacterSet.controlCharacters.contains($0)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2,
           let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
            }
            actions?.gridOpen()
            return
        }
        super.mouseDown(with: event)
    }

    /// Right-click acts on the clicked item (selecting it first if needed),
    /// or on the folder when clicking empty space — as in Finder.
    override func menu(for event: NSEvent) -> NSMenu? {
        if let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            if !selectionIndexPaths.contains(indexPath) {
                selectionIndexPaths = [indexPath]
            }
        } else {
            deselectAll(nil)
        }
        return actions?.gridContextMenu()
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else if !(actions?.gridSelectedURLs() ?? []).isEmpty {
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
        actions?.gridSelectedURLs().count ?? 0
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let urls = actions?.gridSelectedURLs() ?? []
        return urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    /// Arrow keys and Space typed while the Quick Look panel is key still drive the grid.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, [49, 123, 124, 125, 126].contains(event.keyCode) else { return false }
        keyDown(with: event)
        return true
    }
}
