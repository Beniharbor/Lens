import AppKit
@preconcurrency import Quartz

/// Borderless panel that can still take keyboard focus (Esc, arrows, Space).
final class DownloadsPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// A Dock-launched replacement for the Downloads stack: clicking Lens's Dock
/// icon pops up a grid of ~/Downloads that supports multi-selection and
/// dragging several files out at once, which the native stack can't do.
@MainActor
final class DownloadsStackController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, NSWindowDelegate {
    static let shared = DownloadsStackController()

    private let rootFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    /// Subfolders opened inside the grid, innermost last (empty = Downloads).
    private var folderStack: [URL] = []
    private var currentFolder: URL { folderStack.last ?? rootFolder }
    private var entries: [DownloadsEntry] = []
    /// Pointer position at the Dock click; the panel stays anchored to it
    /// while it resizes for subfolders.
    private var anchor: NSPoint = .zero

    private var panel: DownloadsPanel?
    private var collectionView: DownloadsCollectionView!
    private var flowLayout: NSCollectionViewFlowLayout!
    private var sizePicker: NSSegmentedControl!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var backButton: NSButton!

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    private let spacing: CGFloat = 6
    private let inset: CGFloat = 12
    private let headerHeight: CGFloat = 34
    private let footerHeight: CGFloat = 36

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { DownloadsStackController.shared.dismiss(restoreFocus: false) }
        }
    }

    /// While Lens runs, its Dock tile is the blue folder with the Lens mark.
    func applyDockIcon() {
        NSApp.applicationIconImage = DockIcon.make()
    }

    func toggle() {
        if panel?.isVisible == true, !isClosing {
            dismiss(restoreFocus: true)
        } else {
            show()
        }
    }

    // MARK: Showing / hiding

    private func show() {
        let panel = self.panel ?? makePanel()
        anchor = NSEvent.mouseLocation
        folderStack = []
        loadCurrentFolder(select: nil)
        panel.setFrame(frame(for: preferredSize()), display: true)

        NSApp.activate()
        if !isClosing { panel.alphaValue = 0 } // reopening mid-close continues from current opacity
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(collectionView)
        animateIn(panel)
        startWatching()
    }

    /// `restoreFocus` hides Lens so the previously active app gets focus back
    /// (Esc / Dock click). Not needed when another app is already taking over.
    func dismiss(restoreFocus: Bool) {
        guard let panel, panel.isVisible, !isClosing else { return }
        stopWatching()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        animateOut(panel) {
            if restoreFocus {
                NSApp.hide(nil)
            }
        }
    }

    // MARK: Layout

    private func columns() -> Int {
        let n = Double(max(entries.count, 1))
        return min(7, max(4, Int(n.squareRoot().rounded(.up)) + 1))
    }

    private func preferredSize() -> NSSize {
        if let savedSize {
            let visible = screenUnderAnchor()?.visibleFrame.size ?? savedSize
            return NSSize(width: min(savedSize.width, visible.width - 16), height: min(savedSize.height, visible.height - 16))
        }
        let cols = columns()
        let rows = max(1, Int((Double(entries.count) / Double(cols)).rounded(.up)))
        // Show a partial fifth row when there's more, as a hint that it scrolls.
        let visibleRows = rows > 4 ? 4.45 : CGFloat(rows)
        let tile = TileSize.current.tile

        let width = CGFloat(cols) * tile.width + CGFloat(cols - 1) * spacing + inset * 2
        var gridHeight = visibleRows * tile.height + (visibleRows.rounded(.up) - 1) * spacing + inset * 2
        let screenHeight = (screenUnderAnchor()?.visibleFrame.height ?? 800) - 60
        gridHeight = min(gridHeight, screenHeight - headerHeight - footerHeight)
        return NSSize(width: width, height: headerHeight + gridHeight + footerHeight)
    }

    private func screenUnderAnchor() -> NSScreen? {
        let mouse = anchor
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Anchors the panel next to the Dock, centered on the pointer — which,
    /// right after a Dock click, is over Lens's Dock icon. macOS doesn't
    /// expose the icon's exact frame, so this is the closest public option.
    private func frame(for size: NSSize) -> NSRect {
        let mouse = anchor
        guard let screen = screenUnderAnchor() else { return NSRect(origin: .zero, size: size) }
        let full = screen.frame
        let visible = screen.visibleFrame
        let gap: CGFloat = 8

        // Read the Dock's side from its prefs: with auto-hide on, visibleFrame
        // doesn't reveal it. The pointer is over the (revealed) Dock icon, so
        // offset from it by roughly half a Dock tile.
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        let clearance: CGFloat = 40
        var origin: NSPoint
        switch orientation {
        case "left":
            let edge = max(visible.minX, min(mouse.x + clearance, full.minX + 140))
            origin = NSPoint(x: edge + gap, y: mouse.y - size.height / 2)
        case "right":
            let edge = min(visible.maxX, max(mouse.x - clearance, full.maxX - 140))
            origin = NSPoint(x: edge - gap - size.width, y: mouse.y - size.height / 2)
        default:
            let edge = max(visible.minY, min(mouse.y + clearance, full.minY + 140))
            origin = NSPoint(x: mouse.x - size.width / 2, y: edge + gap)
        }

        let bounds = visible.insetBy(dx: gap, dy: gap)
        origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    // MARK: Panel construction

    private func makePanel() -> DownloadsPanel {
        // A titled window with its title bar hidden, rather than a borderless
        // one: that's what gets native edge/corner resizing and the system's
        // rounded corners and shadow.
        let panel = DownloadsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovable = false // stays anchored to the Dock, like the native stack
        panel.contentMinSize = minimumSize
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false // handled via didResignActive so the watcher stops too
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.dismiss(restoreFocus: true) }
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true // layer-backed subtree for the open/close and folder animations
        panel.contentView = background

        let title = NSTextField(labelWithString: "Downloads")
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        titleLabel = title

        let backButton = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!, target: self, action: #selector(goBack))
        backButton.bezelStyle = .accessoryBarAction
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false
        self.backButton = backButton

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = TileSize.current.tile
        flowLayout = layout
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        layout.sectionInset = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)

        let collectionView = DownloadsCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(DownloadsTile.self, forItemWithIdentifier: DownloadsTile.identifier)
        // Copy/move/link/alias out to any app; nothing can be dropped back in.
        collectionView.setDraggingSourceOperationMask(.every, forLocal: false)
        collectionView.setDraggingSourceOperationMask([], forLocal: true)
        collectionView.selectedURLs = { [weak self] in self?.selectedURLs() ?? [] }
        collectionView.onOpen = { [weak self] in self?.openSelection() }
        collectionView.onCancel = { [weak self] in self?.dismiss(restoreFocus: true) }
        collectionView.onBack = { [weak self] in self?.goBack() }
        collectionView.onResizeIcons = { [weak self] step in
            guard let self else { return }
            let current = TileSize.current
            if let next = step > 0 ? current.larger : current.smaller { self.setTileSize(next) }
        }
        self.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scrollView

        let emptyLabel = NSTextField(labelWithString: "No downloads")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        self.emptyLabel = emptyLabel

        let finderButton = NSButton(title: "Open in Finder", target: self, action: #selector(openInFinder))
        finderButton.bezelStyle = .inline
        finderButton.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil)
        finderButton.imagePosition = .imageTrailing
        finderButton.translatesAutoresizingMaskIntoConstraints = false

        // Small / Medium / Large icons (also ⌘- and ⌘+ while the grid is open).
        let sizePicker = NSSegmentedControl(
            images: [
                NSImage(systemSymbolName: "square.grid.4x3.fill", accessibilityDescription: "Small icons")!,
                NSImage(systemSymbolName: "square.grid.3x2.fill", accessibilityDescription: "Medium icons")!,
                NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Large icons")!,
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(sizePickerChanged(_:))
        )
        for size in TileSize.allCases {
            sizePicker.setToolTip("\(size.title) icons", forSegment: size.rawValue)
        }
        sizePicker.controlSize = .small
        sizePicker.selectedSegment = TileSize.current.rawValue
        sizePicker.translatesAutoresizingMaskIntoConstraints = false
        self.sizePicker = sizePicker

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for view in [title, backButton, scrollView, emptyLabel, divider, finderButton, sizePicker] {
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            title.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            backButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            backButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -footerHeight),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            divider.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -footerHeight),

            finderButton.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            finderButton.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -footerHeight / 2),
            sizePicker.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            sizePicker.centerYAnchor.constraint(equalTo: finderButton.centerYAnchor),
            finderButton.leadingAnchor.constraint(greaterThanOrEqualTo: sizePicker.trailingAnchor, constant: 8),
        ])

        self.panel = panel
        return panel
    }

    // MARK: User-chosen size

    private let minimumSize = NSSize(width: 320, height: 260)
    private let savedSizeKey = "downloadsPanelSize"

    /// Set once you drag an edge; from then on the grid always opens at that
    /// size (in every folder) until reset from the menu-bar menu.
    private var savedSize: NSSize? {
        get {
            guard let string = UserDefaults.standard.string(forKey: savedSizeKey) else { return nil }
            let size = NSSizeFromString(string)
            return size.width > 0 && size.height > 0 ? size : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(NSStringFromSize(newValue), forKey: savedSizeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: savedSizeKey)
            }
        }
    }

    func resetSize() {
        savedSize = nil
        if let panel, panel.isVisible {
            animateFrame(to: frame(for: preferredSize()))
        }
    }

    // MARK: Animations

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Bumped on every show/hide so a stale close animation can't hide a
    /// panel that was reopened mid-animation.
    private var animationGeneration = 0
    private var isClosing = false

    /// Scale about `point` (in the layer's own coordinates), independent of
    /// the anchorPoint AppKit chose for the view's layer.
    private func scale(_ factor: CGFloat, about point: CGPoint, in layer: CALayer) -> CATransform3D {
        let pivot = CGPoint(
            x: point.x - layer.anchorPoint.x * layer.bounds.width,
            y: point.y - layer.anchorPoint.y * layer.bounds.height
        )
        var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        return CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
    }

    /// The point of the panel closest to the Dock icon that was clicked, so
    /// the grid grows out of (and shrinks back into) the icon.
    private func dockPivot(for panel: NSWindow, layer: CALayer) -> CGPoint {
        let frame = panel.frame
        return CGPoint(
            x: min(max(anchor.x - frame.minX, 0), layer.bounds.width),
            y: min(max(anchor.y - frame.minY, 0), layer.bounds.height)
        )
    }

    private func animateIn(_ panel: NSWindow) {
        animationGeneration += 1
        isClosing = false
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 1
            return
        }
        layer.removeAllAnimations()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        guard !reduceMotion else { return }

        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = scale(0.82, about: dockPivot(for: panel, layer: layer), in: layer)
        spring.toValue = CATransform3DIdentity
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 26
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "lens.open")
    }

    private func animateOut(_ panel: NSWindow, completion: @escaping () -> Void) {
        animationGeneration += 1
        let generation = animationGeneration
        isClosing = true
        let layer = panel.contentView?.layer
        let duration = 0.15

        if let layer, !reduceMotion {
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = CATransform3DIdentity
            shrink.toValue = scale(0.9, about: dockPivot(for: panel, layer: layer), in: layer)
            shrink.duration = duration
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "lens.close")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                let controller = DownloadsStackController.shared
                guard controller.animationGeneration == generation else { return } // reopened meanwhile
                controller.isClosing = false
                panel.orderOut(nil)
                panel.contentView?.layer?.removeAllAnimations()
                completion()
            }
        }
    }

    /// Folder changes slide sideways like the Dock's own stacks: deeper
    /// folders come in from the right, going back comes in from the left.
    private func animateFolderChange(forward: Bool) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        titleLabel.layer?.add(fade, forKey: "lens.title")
        backButton.layer?.add(fade, forKey: "lens.back")

        let slide = CATransition()
        if reduceMotion {
            slide.type = .fade
            slide.duration = 0.2
        } else {
            slide.type = .push
            slide.subtype = forward ? .fromRight : .fromLeft
            slide.duration = 0.32
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        }
        scrollView.layer?.add(slide, forKey: "lens.slide")
    }

    private func animateFrame(to frame: NSRect) {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: Actions

    private func selectedURLs() -> [URL] {
        collectionView.selectionIndexPaths
            .map(\.item)
            .sorted()
            .filter { entries.indices.contains($0) }
            .map { entries[$0].url }
    }

    private func openSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        // A single folder opens inside the grid, like the Dock's own stacks.
        if urls.count == 1, Self.isBrowsableFolder(urls[0]) {
            navigate(into: urls[0])
            return
        }
        dismiss(restoreFocus: false)
        urls.forEach { NSWorkspace.shared.open($0) }
    }

    /// Real folders only: apps and other bundles still open normally.
    private static func isBrowsableFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    // MARK: Folder navigation

    private func navigate(into folder: URL) {
        folderStack.append(folder)
        animateFolderChange(forward: true)
        loadCurrentFolder(select: nil)
        resizeForCurrentFolder()
    }

    @objc private func goBack() {
        guard let leaving = folderStack.popLast() else { return }
        animateFolderChange(forward: false)
        loadCurrentFolder(select: leaving) // re-select the folder we came out of
        resizeForCurrentFolder()
    }

    private func loadCurrentFolder(select: URL?) {
        entries = DownloadsEntry.load(from: currentFolder)
        collectionView.reloadData()
        collectionView.deselectAll(nil)
        emptyLabel.stringValue = folderStack.isEmpty ? "No downloads" : "Folder is empty"
        emptyLabel.isHidden = !entries.isEmpty
        titleLabel.stringValue = FileManager.default.displayName(atPath: currentFolder.path)
        backButton.isHidden = folderStack.isEmpty

        if let select, let index = entries.firstIndex(where: { $0.url == select }) {
            let indexPath = IndexPath(item: index, section: 0)
            collectionView.selectionIndexPaths = [indexPath]
            collectionView.scrollToItems(at: [indexPath], scrollPosition: .centeredVertically)
        } else {
            collectionView.scroll(.zero)
        }
        collectionView.refreshQuickLook()
        if panel?.isVisible == true {
            startWatching() // follow the folder now on screen
        }
    }

    /// Auto-sized grids grow/shrink to fit each folder; a size you dragged to stays put.
    private func resizeForCurrentFolder() {
        guard savedSize == nil else { return }
        animateFrame(to: frame(for: preferredSize()))
    }

    // MARK: Icon size

    @objc private func sizePickerChanged(_ sender: NSSegmentedControl) {
        guard let size = TileSize(rawValue: sender.selectedSegment) else { return }
        setTileSize(size)
    }

    private func setTileSize(_ size: TileSize) {
        guard size != TileSize.current else { return }
        TileSize.current = size
        sizePicker.selectedSegment = size.rawValue

        let selection = collectionView.selectionIndexPaths
        let fade = CATransition()
        fade.type = .fade
        fade.duration = reduceMotion ? 0.15 : 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scrollView.layer?.add(fade, forKey: "lens.iconSize")

        flowLayout.itemSize = size.tile
        collectionView.reloadData()
        collectionView.selectionIndexPaths = selection
        if let first = selection.min() {
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
        // An auto-sized grid grows or shrinks with the icons; a size you
        // dragged to stays, and the tiles reflow inside it.
        resizeForCurrentFolder()
    }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        savedSize = panel.frame.size
    }

    @objc private func openInFinder() {
        dismiss(restoreFocus: false)
        NSWorkspace.shared.open(currentFolder)
    }

    // MARK: Live updates (only while the panel is open)

    private func startWatching() {
        stopWatching()
        let fd = open(currentFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { DownloadsStackController.shared.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        reloadWorkItem?.cancel()
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated { DownloadsStackController.shared.reloadKeepingSelection() }
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func reloadKeepingSelection() {
        let selected = Set(selectedURLs())
        entries = DownloadsEntry.load(from: currentFolder)
        collectionView.reloadData()
        collectionView.selectionIndexPaths = Set(
            entries.indices
                .filter { selected.contains(entries[$0].url) }
                .map { IndexPath(item: $0, section: 0) }
        )
        emptyLabel.isHidden = !entries.isEmpty
        collectionView.refreshQuickLook()
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: DownloadsTile.identifier, for: indexPath)
        if let tile = item as? DownloadsTile {
            tile.configure(with: entries[indexPath.item], size: TileSize.current, scale: panel?.backingScaleFactor ?? 2)
        }
        return item
    }

    // MARK: NSCollectionViewDelegate — selection & dragging out

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        self.collectionView.refreshQuickLook()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        self.collectionView.refreshQuickLook()
    }

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        true
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        entries[indexPath.item].url as NSURL
    }
}
