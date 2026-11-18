import AppKit
@preconcurrency import Quartz

/// Grid window. Titled (with the title bar hidden) so it gets native edge
/// resizing, rounded corners and shadow; still takes keyboard focus.
final class DownloadsPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// A Dock-launched replacement for the Downloads stack: clicking Lens's Dock
/// icon pops up a grid of a folder (Downloads by default) that supports
/// multi-selection and dragging several files out at once, which the native
/// stack can't do — plus search, sorting, a Finder-style context menu, a
/// pin to keep it open, and new-download dots with a Dock badge.
@MainActor
final class DownloadsStackController: NSObject, ObservableObject, DownloadsGridActions,
    NSCollectionViewDataSource, NSCollectionViewDelegate, NSWindowDelegate, NSSearchFieldDelegate {

    static let shared = DownloadsStackController()

    // MARK: Which folder

    static let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    private static let rootFolderKey = "gridFolderPath"

    /// The folder the grid opens on (Downloads unless changed from the menu).
    @Published private(set) var rootFolder: URL

    /// Subfolders opened inside the grid, innermost last.
    private var folderStack: [URL] = []
    private var currentFolder: URL { folderStack.last ?? rootFolder }

    private var allEntries: [DownloadsEntry] = [] // current folder, sorted
    private var entries: [DownloadsEntry] = []    // what's shown (after search)
    private var searchText = ""

    /// Pointer position at the Dock click; the panel stays anchored to it.
    private var anchor: NSPoint = .zero
    private var isPinned = false

    // MARK: New-download tracking

    private static let lastSeenKey = "gridLastOpened"

    /// When the grid was last open; anything added after it is "new".
    private var lastSeen: Date {
        get { UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date ?? Date() }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSeenKey) }
    }

    /// `lastSeen` as it was when this grid session opened (drives the dots).
    private var newSince: Date = .distantFuture
    private var badgeWatcher: DispatchSourceFileSystemObject?
    private var badgeWorkItem: DispatchWorkItem?

    // MARK: UI

    private var panel: DownloadsPanel?
    private var collectionView: DownloadsCollectionView!
    private var flowLayout: NSCollectionViewFlowLayout!
    private var scrollView: NSScrollView!
    private var emptyLabel: NSTextField!
    private var titleLabel: NSTextField!
    private var backButton: NSButton!
    private var searchField: NSSearchField!
    private var pinButton: NSButton!
    private var sizePicker: NSSegmentedControl!
    private var sortPopUp: NSPopUpButton!

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    private let spacing: CGFloat = 6
    private let inset: CGFloat = 12
    private let headerHeight: CGFloat = 38
    private let footerHeight: CGFloat = 36

    private override init() {
        let saved = UserDefaults.standard.string(forKey: Self.rootFolderKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        var isDirectory: ObjCBool = false
        if let saved, FileManager.default.fileExists(atPath: saved.path, isDirectory: &isDirectory), isDirectory.boolValue {
            rootFolder = saved
        } else {
            rootFolder = Self.downloadsFolder
        }
        super.init()

        if UserDefaults.standard.object(forKey: Self.lastSeenKey) == nil {
            lastSeen = Date() // first launch: nothing counts as new yet
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let controller = DownloadsStackController.shared
                if !controller.isPinned { controller.dismiss(restoreFocus: false) }
            }
        }
    }

    /// Called at launch: Dock tile artwork + the new-downloads badge.
    func start() {
        NSApp.applicationIconImage = DockIcon.make(mark: MenuBarIcon.markSVG())
        startBadgeWatcher()
        updateBadge()
    }

    func toggle() {
        if panel?.isVisible == true, !isClosing {
            dismiss(restoreFocus: true)
        } else {
            show()
        }
    }

    // MARK: Choosing the folder (from the menu-bar menu)

    var rootFolderName: String { FileManager.default.displayName(atPath: rootFolder.path) }

    func isRootFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.path == rootFolder.standardizedFileURL.path
    }

    func setRootFolder(_ url: URL) {
        if url.standardizedFileURL.path == Self.downloadsFolder.standardizedFileURL.path {
            UserDefaults.standard.removeObject(forKey: Self.rootFolderKey)
        } else {
            UserDefaults.standard.set(url.path, forKey: Self.rootFolderKey)
        }
        rootFolder = url
        lastSeen = Date()
        newSince = .distantFuture
        folderStack = []
        startBadgeWatcher()
        updateBadge()
        if panel?.isVisible == true {
            clearSearch()
            loadCurrentFolder(select: nil)
            resizeForCurrentFolder()
        }
    }

    func chooseRootFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Show in Grid"
        openPanel.message = "Choose the folder Lens's Dock grid shows."
        openPanel.directoryURL = rootFolder
        NSApp.activate()
        openPanel.begin { response in
            guard response == .OK, let url = openPanel.url else { return }
            MainActor.assumeIsolated { DownloadsStackController.shared.setRootFolder(url) }
        }
    }

    // MARK: Showing / hiding

    private func show() {
        let panel = self.panel ?? makePanel()
        anchor = NSEvent.mouseLocation
        folderStack = []
        newSince = lastSeen
        lastSeen = Date()
        setPinned(false)
        clearSearch()
        loadCurrentFolder(select: nil)
        panel.setFrame(frame(for: preferredSize()), display: true)
        updateBadge()

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
        lastSeen = Date() // everything that was on screen has been seen
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        animateOut(panel) {
            MainActor.assumeIsolated {
                let controller = DownloadsStackController.shared
                controller.setPinned(false)
                controller.updateBadge()
            }
            if restoreFocus {
                NSApp.hide(nil)
            }
        }
    }

    // MARK: Layout

    private func columns() -> Int {
        let n = Double(max(allEntries.count, 1))
        return min(7, max(4, Int(n.squareRoot().rounded(.up)) + 1))
    }

    private func preferredSize() -> NSSize {
        if let savedSize {
            let visible = screenUnderAnchor()?.visibleFrame.size ?? savedSize
            return NSSize(width: min(savedSize.width, visible.width - 16), height: min(savedSize.height, visible.height - 16))
        }
        let cols = columns()
        let rows = max(1, Int((Double(allEntries.count) / Double(cols)).rounded(.up)))
        // Show a partial fifth row when there's more, as a hint that it scrolls.
        let visibleRows = rows > 4 ? 4.45 : CGFloat(rows)
        let tile = TileSize.current.tile

        let width = max(minimumSize.width, CGFloat(cols) * tile.width + CGFloat(cols - 1) * spacing + inset * 2)
        var gridHeight = visibleRows * tile.height + (visibleRows.rounded(.up) - 1) * spacing + inset * 2
        let screenHeight = (screenUnderAnchor()?.visibleFrame.height ?? 800) - 60
        gridHeight = min(gridHeight, screenHeight - headerHeight - footerHeight)
        return NSSize(width: width, height: max(minimumSize.height, headerHeight + gridHeight + footerHeight))
    }

    private func screenUnderAnchor() -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
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
        panel.hidesOnDeactivate = false // handled via didResignActive (respects the pin)
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.onCancel = { [weak self] in self?.dismiss(restoreFocus: true) }
        panel.delegate = self

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true // layer-backed subtree for the animations
        panel.contentView = background

        // Header: ‹ back · title · search · pin
        let title = NSTextField(labelWithString: "Downloads")
        title.lineBreakMode = .byTruncatingMiddle
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel = title

        let backButton = NSButton(
            image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")!,
            target: self, action: #selector(goBack)
        )
        backButton.bezelStyle = .accessoryBarAction
        backButton.toolTip = "Back (⌘↑)"
        backButton.isHidden = true
        self.backButton = backButton

        let searchField = NSSearchField()
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        self.searchField = searchField

        let pinButton = NSButton(
            image: NSImage(systemSymbolName: "pin", accessibilityDescription: "Keep open")!,
            target: self, action: #selector(togglePin)
        )
        pinButton.bezelStyle = .accessoryBarAction
        pinButton.toolTip = "Keep the grid open while you work in other apps"
        self.pinButton = pinButton

        // Grid
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = TileSize.current.tile
        layout.minimumInteritemSpacing = spacing
        layout.minimumLineSpacing = spacing
        layout.sectionInset = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        flowLayout = layout

        let collectionView = DownloadsCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.actions = self
        collectionView.register(DownloadsTile.self, forItemWithIdentifier: DownloadsTile.identifier)
        // Copy/move/link/alias out to any app; nothing can be dropped back in.
        collectionView.setDraggingSourceOperationMask(.every, forLocal: false)
        collectionView.setDraggingSourceOperationMask([], forLocal: true)
        self.collectionView = collectionView

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        self.scrollView = scrollView

        let emptyLabel = NSTextField(labelWithString: "No downloads")
        emptyLabel.textColor = .secondaryLabelColor
        self.emptyLabel = emptyLabel

        // Footer: icon size · Open in Finder · sort
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
            sizePicker.setToolTip("\(size.title) icons (⌘- / ⌘+)", forSegment: size.rawValue)
        }
        sizePicker.controlSize = .small
        sizePicker.selectedSegment = TileSize.current.rawValue
        self.sizePicker = sizePicker

        let finderButton = NSButton(title: "Open in Finder", target: self, action: #selector(openInFinder))
        finderButton.bezelStyle = .inline
        finderButton.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil)
        finderButton.imagePosition = .imageTrailing
        finderButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let sortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        sortPopUp.addItems(withTitles: GridSortOrder.allCases.map(\.title))
        sortPopUp.selectItem(at: GridSortOrder.current.rawValue)
        sortPopUp.controlSize = .small
        sortPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sortPopUp.isBordered = false
        sortPopUp.toolTip = "Sort by"
        sortPopUp.target = self
        sortPopUp.action = #selector(sortPopUpChanged(_:))
        self.sortPopUp = sortPopUp

        let divider = NSBox()
        divider.boxType = .separator

        let views: [NSView] = [title, backButton, searchField, pinButton, scrollView, emptyLabel,
                               divider, sizePicker, finderButton, sortPopUp]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }

        let titleCenter = title.centerXAnchor.constraint(equalTo: background.centerXAnchor)
        titleCenter.priority = .defaultHigh - 1 // gives way to the search field when narrow
        let finderCenter = finderButton.centerXAnchor.constraint(equalTo: background.centerXAnchor)
        finderCenter.priority = .defaultHigh - 1

        NSLayoutConstraint.activate([
            title.centerYAnchor.constraint(equalTo: background.topAnchor, constant: headerHeight / 2 + 1),
            titleCenter,
            title.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: searchField.leadingAnchor, constant: -8),
            backButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            backButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            pinButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -6),
            searchField.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 140),

            scrollView.topAnchor.constraint(equalTo: background.topAnchor, constant: headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -footerHeight),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            divider.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            divider.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -footerHeight),

            sizePicker.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            sizePicker.centerYAnchor.constraint(equalTo: background.bottomAnchor, constant: -footerHeight / 2),
            finderCenter,
            finderButton.centerYAnchor.constraint(equalTo: sizePicker.centerYAnchor),
            finderButton.leadingAnchor.constraint(greaterThanOrEqualTo: sizePicker.trailingAnchor, constant: 8),
            finderButton.trailingAnchor.constraint(lessThanOrEqualTo: sortPopUp.leadingAnchor, constant: -8),
            sortPopUp.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            sortPopUp.centerYAnchor.constraint(equalTo: sizePicker.centerYAnchor),
        ])

        self.panel = panel
        return panel
    }

    // MARK: User-chosen size

    private let minimumSize = NSSize(width: 400, height: 260)
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

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        savedSize = panel.frame.size
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
        let duration = 0.15

        if let layer = panel.contentView?.layer, !reduceMotion {
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

    /// Soft cross-fade for in-place changes (sorting, icon size).
    private func crossFadeGrid() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = reduceMotion ? 0.15 : 0.22
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scrollView.layer?.add(fade, forKey: "lens.crossfade")
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

    // MARK: Loading, filtering, selection

    private func selectedURLs() -> [URL] {
        selectedEntries().map(\.url)
    }

    private func selectedEntries() -> [DownloadsEntry] {
        collectionView.selectionIndexPaths
            .map(\.item)
            .sorted()
            .filter { entries.indices.contains($0) }
            .map { entries[$0] }
    }

    private func filtered(_ entries: [DownloadsEntry]) -> [DownloadsEntry] {
        searchText.isEmpty ? entries : entries.filter { $0.name.localizedStandardContains(searchText) }
    }

    private func loadCurrentFolder(select: URL?) {
        allEntries = GridSortOrder.current.sorted(DownloadsEntry.load(from: currentFolder))
        entries = filtered(allEntries)
        collectionView.reloadData()
        collectionView.deselectAll(nil)
        titleLabel.stringValue = FileManager.default.displayName(atPath: currentFolder.path)
        backButton.isHidden = folderStack.isEmpty
        updateEmptyLabel()

        if let select, let index = entries.firstIndex(where: { $0.url.path == select.path }) {
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

    /// Re-reads the folder, keeping (or setting) the selection. When nothing
    /// selected survives — e.g. after moving files to the Trash — selects the
    /// item now at `fallbackIndex`, like Finder.
    private func reload(selecting paths: Set<String>? = nil, fallbackIndex: Int? = nil) {
        let wanted = paths ?? Set(selectedURLs().map(\.path))
        allEntries = GridSortOrder.current.sorted(DownloadsEntry.load(from: currentFolder))
        entries = filtered(allEntries)
        collectionView.reloadData()

        var selection = Set(entries.indices.filter { wanted.contains(entries[$0].url.path) }.map { IndexPath(item: $0, section: 0) })
        if selection.isEmpty, let fallbackIndex, !entries.isEmpty {
            selection = [IndexPath(item: min(fallbackIndex, entries.count - 1), section: 0)]
        }
        collectionView.selectionIndexPaths = selection
        if let first = selection.min() {
            collectionView.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
        }
        updateEmptyLabel()
        collectionView.refreshQuickLook()
    }

    private func updateEmptyLabel() {
        if !searchText.isEmpty {
            emptyLabel.stringValue = "No matches"
        } else if folderStack.isEmpty, isRootFolder(Self.downloadsFolder) {
            emptyLabel.stringValue = "No downloads"
        } else {
            emptyLabel.stringValue = "Folder is empty"
        }
        emptyLabel.isHidden = !entries.isEmpty
    }

    // MARK: Search

    @objc private func searchChanged(_ sender: NSSearchField) {
        applySearch(sender.stringValue)
    }

    private func applySearch(_ text: String) {
        searchText = text.trimmingCharacters(in: .whitespaces)
        entries = filtered(allEntries)
        collectionView.reloadData()
        // While searching, the top match is selected so Return opens it.
        collectionView.selectionIndexPaths = !searchText.isEmpty && !entries.isEmpty ? [IndexPath(item: 0, section: 0)] : []
        collectionView.scroll(.zero)
        updateEmptyLabel()
        collectionView.refreshQuickLook()
    }

    private func clearSearch() {
        searchText = ""
        searchField?.stringValue = ""
    }

    /// Esc clears the search (then closes); Return / ↓ jump into the results.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                dismiss(restoreFocus: true)
            } else {
                searchField.stringValue = ""
                applySearch("")
                panel?.makeFirstResponder(collectionView)
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            panel?.makeFirstResponder(collectionView)
            gridOpen()
            return true
        case #selector(NSResponder.moveDown(_:)):
            panel?.makeFirstResponder(collectionView)
            if collectionView.selectionIndexPaths.isEmpty, !entries.isEmpty {
                collectionView.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
            }
            return true
        default:
            return false
        }
    }

    // MARK: Sorting

    @objc private func sortPopUpChanged(_ sender: NSPopUpButton) {
        guard let order = GridSortOrder(rawValue: sender.indexOfSelectedItem) else { return }
        setSortOrder(order)
    }

    @objc private func sortMenuChosen(_ sender: NSMenuItem) {
        guard let order = GridSortOrder(rawValue: sender.tag) else { return }
        setSortOrder(order)
    }

    private func setSortOrder(_ order: GridSortOrder) {
        GridSortOrder.current = order
        sortPopUp.selectItem(at: order.rawValue)
        crossFadeGrid()
        reload()
        if collectionView.selectionIndexPaths.isEmpty {
            collectionView.scroll(.zero)
        }
    }

    // MARK: Pin

    @objc private func togglePin() {
        setPinned(!isPinned)
    }

    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        guard let pinButton else { return }
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: pinned ? "Unpin" : "Keep open"
        )
        pinButton.contentTintColor = pinned ? .controlAccentColor : nil
        pinButton.toolTip = pinned
            ? "Pinned: stays open in other apps. Click again, press Esc or click the Dock icon to close."
            : "Keep the grid open while you work in other apps"
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
        crossFadeGrid()
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

    // MARK: Folder navigation

    /// Real folders only: apps and other bundles still open normally.
    private static func isBrowsableFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    private func navigate(into folder: URL) {
        folderStack.append(folder)
        clearSearch()
        animateFolderChange(forward: true)
        loadCurrentFolder(select: nil)
        resizeForCurrentFolder()
    }

    @objc private func goBack() {
        guard let leaving = folderStack.popLast() else { return }
        clearSearch()
        animateFolderChange(forward: false)
        loadCurrentFolder(select: leaving) // re-select the folder we came out of
        resizeForCurrentFolder()
    }

    /// Auto-sized grids grow/shrink to fit each folder; a size you dragged to stays put.
    private func resizeForCurrentFolder() {
        guard savedSize == nil else { return }
        animateFrame(to: frame(for: preferredSize()))
    }

    // MARK: DownloadsGridActions (keyboard, double-click, context menu)

    func gridSelectedURLs() -> [URL] { selectedURLs() }

    func gridOpen() {
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

    func gridCancel() { dismiss(restoreFocus: true) }

    func gridBack() { goBack() }

    func gridResizeIcons(_ step: Int) {
        let current = TileSize.current
        if let next = step > 0 ? current.larger : current.smaller {
            setTileSize(next)
        }
    }

    func gridFocusSearch(typing text: String?) {
        guard let panel else { return }
        panel.makeFirstResponder(searchField)
        if let text {
            searchField.stringValue += text
            applySearch(searchField.stringValue)
        }
        let end = (searchField.stringValue as NSString).length
        searchField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    func gridTrash() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let firstIndex = collectionView.selectionIndexPaths.map(\.item).min() ?? 0
        NSWorkspace.shared.recycle(urls) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let controller = DownloadsStackController.shared
                    if let error {
                        controller.present(error)
                        return
                    }
                    Self.playTrashSound()
                    controller.reload(selecting: [], fallbackIndex: firstIndex)
                }
            }
        }
    }

    func gridCopyFiles() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        let message = urls.count == 1 ? "Copied" : "Copied \(urls.count) Items"
        ToastPresenter.shared.show(systemImage: "doc.on.doc", message: message)
    }

    func gridCopyText() {
        let urls = selectedEntries().filter(\.supportsTextExtraction).map(\.url)
        guard !urls.isEmpty else {
            NSSound.beep()
            return
        }
        OCRController.shared.copyText(fromFilesAt: urls)
    }

    func gridContextMenu() -> NSMenu? {
        let selection = selectedEntries()
        let menu = NSMenu()

        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            menu.addItem(item)
        }

        guard !selection.isEmpty else {
            // Right-click on empty space: folder-level actions.
            add("Open in Finder", #selector(openInFinder))
            let sortItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
            sortItem.submenu = sortMenu()
            menu.addItem(sortItem)
            return menu
        }

        add("Open", #selector(openSelectionAction))
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        openWith.submenu = openWithMenu(for: selection.map(\.url))
        menu.addItem(openWith)
        menu.addItem(.separator())
        add("Quick Look", #selector(quickLookAction), key: " ")
        add("Show in Finder", #selector(showInFinder))
        menu.addItem(.separator())
        add(selection.count == 1 ? "Copy" : "Copy \(selection.count) Items", #selector(copyFilesAction), key: "c", modifiers: .command)
        if selection.contains(where: \.supportsTextExtraction) {
            add("Copy Text", #selector(copyTextAction), key: "c", modifiers: [.command, .shift])
        }
        if selection.count == 1 {
            add("Rename…", #selector(renameSelection))
        }
        add(selection.count == 1 ? "Compress “\(selection[0].name)”" : "Compress \(selection.count) Items", #selector(compressSelection))
        menu.addItem(.separator())
        add("Move to Trash", #selector(trashAction), key: "\u{8}", modifiers: .command)
        return menu
    }

    private func sortMenu() -> NSMenu {
        let menu = NSMenu()
        for order in GridSortOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(sortMenuChosen(_:)), keyEquivalent: "")
            item.tag = order.rawValue
            item.state = order == GridSortOrder.current ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    private func openWithMenu(for urls: [URL]) -> NSMenu {
        let menu = NSMenu()
        guard let first = urls.first else { return menu }
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: first)
        var apps: [URL] = []
        for app in [defaultApp].compactMap({ $0 }) + NSWorkspace.shared.urlsForApplications(toOpen: first)
        where !apps.contains(where: { $0.path == app.path }) {
            apps.append(app)
        }
        guard !apps.isEmpty else {
            let none = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return menu
        }
        for (index, app) in apps.prefix(25).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path)
            let isDefault = index == 0 && defaultApp != nil
            let item = NSMenuItem(title: isDefault ? "\(name) (default)" : name, action: #selector(openWith(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
            if isDefault, apps.count > 1 { menu.addItem(.separator()) }
        }
        return menu
    }

    // MARK: Menu actions

    @objc private func openSelectionAction() { gridOpen() }
    @objc private func quickLookAction() { collectionView.toggleQuickLook() }
    @objc private func copyFilesAction() { gridCopyFiles() }
    @objc private func copyTextAction() { gridCopyText() }
    @objc private func trashAction() { gridTrash() }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        let urls = selectedURLs()
        dismiss(restoreFocus: false)
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func showInFinder() {
        let urls = selectedURLs()
        dismiss(restoreFocus: false)
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc private func openInFinder() {
        dismiss(restoreFocus: false)
        NSWorkspace.shared.open(currentFolder)
    }

    @objc private func renameSelection() {
        guard let panel, let url = selectedURLs().first, selectedURLs().count == 1 else { return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name for “\(url.lastPathComponent)”."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: url.lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: panel) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name != url.lastPathComponent, !name.contains("/") else { return }
                let destination = url.deletingLastPathComponent().appendingPathComponent(name)
                do {
                    try FileManager.default.moveItem(at: url, to: destination)
                    DownloadsStackController.shared.reload(selecting: [destination.path])
                } catch {
                    DownloadsStackController.shared.present(error)
                }
            }
        }
        // Like Finder: select the name without the extension.
        DispatchQueue.main.async {
            let base = (url.lastPathComponent as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    /// Finder-style: one item → "Name.zip", several → "Archive.zip".
    @objc private func compressSelection() {
        let urls = selectedURLs()
        guard !urls.isEmpty else { return }
        let folder = currentFolder
        let baseName = urls.count == 1 ? urls[0].lastPathComponent : "Archive"
        let destination = Self.uniqueURL(in: folder, baseName: baseName, extension: "zip")

        let process = Process()
        if urls.count == 1 {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, destination.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = folder
            process.arguments = ["-r", "-y", "-q", destination.lastPathComponent] + urls.map(\.lastPathComponent)
        }
        process.terminationHandler = { finished in
            let succeeded = finished.terminationStatus == 0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if succeeded {
                        DownloadsStackController.shared.reload(selecting: [destination.path])
                    } else {
                        NSSound.beep()
                    }
                }
            }
        }
        do {
            try process.run()
        } catch {
            present(error)
        }
    }

    private static func uniqueURL(in folder: URL, baseName: String, extension ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(baseName).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private static func playTrashSound() {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/move to trash.aif"
        NSSound(contentsOf: URL(fileURLWithPath: path), byReference: true)?.play()
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let panel, panel.isVisible {
            alert.beginSheetModal(for: panel)
        } else {
            alert.runModal()
        }
    }

    // MARK: Live updates of the open grid

    private func startWatching() {
        stopWatching()
        watcher = Self.watch(currentFolder) {
            DownloadsStackController.shared.scheduleReload()
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        reloadWorkItem?.cancel()
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated { DownloadsStackController.shared.reload() }
        }
        reloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    /// kqueue watch on a folder (no polling; idle until something changes).
    private static func watch(_ folder: URL, onChange: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    // MARK: Dock badge (new downloads since the grid was last opened)

    private func startBadgeWatcher() {
        badgeWatcher?.cancel()
        badgeWatcher = Self.watch(rootFolder) {
            DownloadsStackController.shared.scheduleBadgeUpdate()
        }
    }

    private func scheduleBadgeUpdate() {
        badgeWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated { DownloadsStackController.shared.updateBadge() }
        }
        badgeWorkItem = workItem
        // Downloads write in bursts; settle before re-counting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: workItem)
    }

    private func updateBadge() {
        if let panel, panel.isVisible, !isClosing {
            NSApp.dockTile.badgeLabel = nil // you're looking at them
            return
        }
        let since = lastSeen
        let count = DownloadsEntry.load(from: rootFolder).filter { $0.dateAdded > since }.count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: DownloadsTile.identifier, for: indexPath)
        if let tile = item as? DownloadsTile {
            let entry = entries[indexPath.item]
            tile.configure(
                with: entry,
                size: TileSize.current,
                scale: panel?.backingScaleFactor ?? 2,
                isNew: folderStack.isEmpty && entry.dateAdded > newSince
            )
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
