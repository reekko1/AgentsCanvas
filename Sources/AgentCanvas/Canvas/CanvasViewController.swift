import AppKit
import SwiftTerm

/// Coordinator: builds the canvas view tree and wires the engine (`Viewport`),
/// the model (`CardStore`), and the attention spine together. Holds no zoom math,
/// no persistence format, and no CLI knowledge — those live in their own types.
final class CanvasViewController: NSViewController {

    private var scrollView: NSScrollView!
    private var documentView: DocumentView!
    private var backdrop: GridBackdropView!
    private var emptyView: EmptyStateView!

    private var viewport: Viewport!
    private let store = ItemStore()
    private let spine = Spine()

    // Window-edge overlays (constant-size chrome, not on the magnified canvas).
    private var zoomHUD: ZoomHUD!
    private var toolDock: ToolDock!
    private var notifPanel: NotificationPanel!
    private let feed = ActivityFeed()
    private var frames: [Frame] = []

    private var savedViewport: (center: NSPoint, mag: CGFloat)?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    // MARK: Lifecycle
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        view.wantsLayer = true

        buildViewTree()
        viewport = Viewport(scrollView: scrollView)
        viewport.onChange = { [weak self] in
            guard let self else { return }
            self.updateBackdrop()
            self.updateItemDetail()
            self.zoomHUD?.setLevel(self.scrollView.magnification)
        }
        buildOverlays()

        spine.onStatus = { [weak self] cardId, status in
            guard let self, let card = self.store.card(cardId) else { return }
            let changed = card.status != status
            card.apply(status)
            if changed {
                self.feed.record(id: cardId, name: card.title, status: status, date: Date())
                self.refreshActivity()
                self.refreshFrames()   // a member going loud lights the frame's "needs you" tag
            }
        }
        spine.start()

        loadWorkspace()
        installInputMonitors()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowChrome()
        viewport.updateLimits(contentBounds: store.bounds)
        if let v = savedViewport {
            let m = max(scrollView.minMagnification, min(scrollView.maxMagnification, v.mag))
            viewport.applyZoom(center: v.center, mag: m)
        } else {
            viewport.fitAll(contentBounds: store.bounds, animated: false)
        }
        updateBackdrop()
        updateItemDetail()
        zoomHUD.setLevel(scrollView.magnification)
        refreshActivity()
        updateHintVisibility()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        viewport.updateLimits(contentBounds: store.bounds)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    // MARK: View tree
    private func buildViewTree() {
        backdrop = GridBackdropView(frame: view.bounds)
        backdrop.autoresizingMask = [.width, .height]
        view.addSubview(backdrop)

        scrollView = NSScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.04
        scrollView.maxMagnification = 4.0
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        documentView = DocumentView(frame: NSRect(origin: .zero, size: NSSize(width: CanvasLayout.canvasSize,
                                                                              height: CanvasLayout.canvasSize)))
        documentView.wantsLayer = true
        scrollView.documentView = documentView
        view.addSubview(scrollView)

        emptyView = EmptyStateView()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func updateHintVisibility() { emptyView?.isHidden = !(store.items.isEmpty && frames.isEmpty) }

    /// Create the constant-size window-edge overlays and wire them to the engine.
    private func buildOverlays() {
        zoomHUD = ZoomHUD()
        zoomHUD.onZoomIn = { [weak self] in self?.viewport.zoomBy(1.25) }
        zoomHUD.onZoomOut = { [weak self] in self?.viewport.zoomBy(0.8) }
        zoomHUD.onFit = { [weak self] in
            guard let self else { return }
            self.viewport.fitAll(contentBounds: self.store.bounds, animated: true)
        }
        view.addSubview(zoomHUD)

        toolDock = ToolDock()
        toolDock.onFrame = { [weak self] in self?.createFrame() }
        toolDock.onAgent = { [weak self] in self?.createCard() }
        toolDock.onTerminal = { [weak self] in self?.createShell() }
        toolDock.onDiff = { [weak self] in self?.createDiff() }
        view.addSubview(toolDock)

        notifPanel = NotificationPanel()
        notifPanel.onSelect = { [weak self] id in self?.flyToItem(id: id) }
        view.addSubview(notifPanel)

        NSLayoutConstraint.activate([
            zoomHUD.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            zoomHUD.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),

            toolDock.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            toolDock.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            notifPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            notifPanel.topAnchor.constraint(equalTo: view.topAnchor, constant: 38), // clear the title bar
        ])
    }

    /// A chromeless, transparent title bar so the canvas bleeds to the top edge
    /// (the dock replaces the old create-action toolbar). Traffic lights stay.
    private func configureWindowChrome() {
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
    }

    /// Rebuild the activity center from the feed, with the live "needs you" count.
    private func refreshActivity() {
        guard notifPanel != nil else { return }
        let loud = store.items.compactMap { $0 as? Card }.filter { $0.status.isLoud }.count
        notifPanel.reload(feed, loudCount: loud)
    }

    /// Fly the camera to an item by id (from an activity row).
    private func flyToItem(id: String) {
        if let item = store.items.first(where: { $0.id == id }) { frame(item) }
    }

    private func updateBackdrop() {
        guard backdrop != nil else { return }
        backdrop.offset = scrollView.contentView.bounds.origin
        backdrop.scale = scrollView.magnification
    }

    /// Diff objects swap to their full two-pane tool once big enough on screen,
    /// and to a compact file list when far (the decided LOD for diffs).
    private func updateItemDetail() {
        let mag = scrollView.magnification
        for case let diff as DiffObject in store.items {
            diff.setDetail(full: diff.frame.width * mag >= 520)
        }
    }

    // MARK: Items
    /// Wire an item's move/delete and place its view on the canvas.
    private func installItemView(_ item: CanvasItem) {
        item.containerView.onMoved = { [weak self, weak item] origin in
            guard let self, let item else { return }
            item.frame.origin = origin
            self.viewport.updateLimits(contentBounds: self.store.bounds)
            self.refreshFrames()   // a card moving in/out of a frame changes membership
            self.saveWorkspace()
        }
        item.containerView.onDelete = { [weak self, weak item] in
            if let item { self?.deleteItem(item) }
        }
        documentView.addSubview(item.containerView)
    }

    /// Fly to an item. A card spawns its terminal (if dormant) and takes focus on
    /// arrival; a diff object is already live, so we just fly.
    private func frame(_ item: CanvasItem) {
        if let card = item as? Card {
            if card.terminal == nil { spawnTerminal(card) }
            viewport.frame(rect: card.frame) { [weak self, weak card] in
                if let t = card?.terminal { self?.view.window?.makeFirstResponder(t) }
            }
        } else {
            viewport.frame(rect: item.frame, completion: nil)
        }
    }

    private func spawnTerminal(_ card: Card) {
        guard card.terminal == nil else { return }
        let t = LocalProcessTerminalView(frame: .zero)
        switch card.role {
        case .agent:
            let (exe, args) = spine.launchCommand(folder: card.folder)
            t.startProcess(executable: exe, args: args, environment: spine.env(cardId: card.id),
                           currentDirectory: card.folder.path)
        case .shell:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            t.startProcess(executable: shell, args: ["-l"], environment: spine.plainEnv(),
                           currentDirectory: card.folder.path)
        }
        card.terminal = t
        // The glowing dark screen: terminal bg matches the bezel (the inset gap) so
        // padding is seamless, with a warm-ish light foreground.
        t.nativeBackgroundColor = Theme.colors.terminalBg
        t.nativeForegroundColor = Theme.colors.termText
        card.containerView.setContent(t)
        canvasLog("spawned \(card.id) in \(card.folder.path)")
    }

    private func deleteItem(_ item: CanvasItem) {
        (item as? Card)?.terminal?.terminate()   // SIGTERM the agent
        (item as? DiffObject)?.stop()            // stop the git watcher
        item.containerView.removeFromSuperview()
        store.remove(item)
        viewport.updateLimits(contentBounds: store.bounds)
        refreshFrames()
        updateHintVisibility()
        saveWorkspace()
        canvasLog("deleted \(item.id)")
    }

    // MARK: Persistence
    private func loadWorkspace() {
        guard let ws = Workspace.load() else {
            canvasLog("no saved workspace — starting empty")
            return
        }
        store.restore(seq: ws.seq)
        for record in ws.items {
            let frameRect = NSRect(x: record.x, y: record.y, width: record.w, height: record.h)
            switch record.kind {
            case "card", "shell":
                guard let folder = record.folder else { continue }
                let card = Card(id: record.id, title: record.title, frame: frameRect,
                                folder: URL(fileURLWithPath: folder),
                                role: record.kind == "shell" ? .shell : .agent)
                store.add(card)
                installItemView(card)
            case "diff":
                guard let folder = record.folder else { continue }
                let diff = DiffObject(id: record.id, frame: frameRect, folder: URL(fileURLWithPath: folder))
                store.add(diff)
                installItemView(diff)
                diff.start()
            case "frame":
                let frame = Frame(id: record.id, name: record.title, rect: frameRect)
                frames.append(frame)
                installFrame(frame)
            default:
                canvasLog("skipping unknown item kind: \(record.kind)")
            }
        }
        if let v = ws.viewport { savedViewport = (NSPoint(x: v.cx, y: v.cy), CGFloat(v.mag)) }
        refreshFrames()   // members exist now → fill counts + needs-you tags
        canvasLog("restored \(store.items.count) item(s), \(frames.count) frame(s)")
    }

    func saveWorkspace() {
        guard viewport != nil else { return }
        let vp = Workspace.Viewport(cx: viewport.center.x, cy: viewport.center.y, mag: viewport.magnification)
        var ws = store.workspace(viewport: vp)
        ws.items += frames.map { $0.record() }   // frames share the id sequence, persisted alongside items
        ws.save()
    }

    // MARK: Input
    private func installInputMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handleKey(e) ?? e
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
            self?.handleMouse(e) ?? e
        }
    }

    private func handleMouse(_ e: NSEvent) -> NSEvent? {
        guard e.window === view.window, e.clickCount == 2 else { return e }
        let p = documentView.convert(e.locationInWindow, from: nil)
        if let item = store.items.last(where: { $0.frame.contains(p) }) {
            frame(item)
        } else {
            viewport.fitAll(contentBounds: store.bounds, animated: true)
        }
        return nil
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        let cmd = e.modifierFlags.contains(.command)
        if cmd {
            switch e.keyCode {
            case 45: createCard(); return nil       // ⌘N
            case 29: viewport.fitAll(contentBounds: store.bounds, animated: true); return nil // ⌘0
            default: break
            }
        }
        if terminalIsFirstResponder() { return e }  // typing in a terminal → pass through
        switch e.keyCode {
        case 53, 49: viewport.fitAll(contentBounds: store.bounds, animated: true); return nil // esc / space
        case 24, 69: viewport.zoomBy(1.25); return nil
        case 27, 78: viewport.zoomBy(0.8); return nil
        case 45: createCard(); return nil           // n
        default: return e
        }
    }

    /// True when focus is inside any on-canvas item — typing/scrolling there should
    /// reach the item (a card's terminal, a diff's list) instead of panning the canvas.
    private func terminalIsFirstResponder() -> Bool {
        guard let fr = view.window?.firstResponder as? NSView else { return false }
        return store.items.contains { fr.isDescendant(of: $0.containerView) }
    }

    // MARK: Create
    private func createCard() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open as Agent Card"
        panel.message = "Pick a folder to run a Claude Code agent in."
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            self.addCard(folder: url)
        }
    }

    private func createDiff() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch as Diff"
        panel.message = "Pick a git working tree to show its uncommitted changes."
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            self.addDiff(folder: url)
        }
    }

    /// The rect centered in the current viewport for a newly created item of `size`.
    private func centeredFrame(_ size: NSSize) -> NSRect {
        let cb = scrollView.contentView.bounds
        return NSRect(x: cb.midX - size.width / 2, y: cb.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func createShell() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open as Terminal"
        panel.message = "Pick a folder to open a plain shell in."
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            self.addCard(folder: url, role: .shell)
        }
    }

    private func addCard(folder: URL, role: CardRole = .agent) {
        let card = Card(id: store.nextId(prefix: role == .shell ? "shell" : "card"),
                        title: folder.lastPathComponent,
                        frame: centeredFrame(CanvasLayout.cardSize), folder: folder, role: role)
        store.add(card)
        installItemView(card)
        viewport.updateLimits(contentBounds: store.bounds)
        refreshFrames()
        updateHintVisibility()
        saveWorkspace()
        canvasLog("added \(card.id) [\(role)] -> \(folder.path)")
        frame(card)
    }

    private func addDiff(folder: URL) {
        let diff = DiffObject(id: store.nextId(prefix: "diff"),
                              frame: centeredFrame(CanvasLayout.diffSize), folder: folder)
        store.add(diff)
        installItemView(diff)
        diff.start()
        viewport.updateLimits(contentBounds: store.bounds)
        updateHintVisibility()
        saveWorkspace()
        canvasLog("added \(diff.id) -> \(folder.path)")
        frame(diff)
    }

    // MARK: Frames
    private func createFrame() {
        promptFrameName { [weak self] name in
            guard let self, let name else { return }
            let f = Frame(id: self.store.nextId(prefix: "frame"), name: name,
                          rect: self.centeredFrame(CanvasLayout.frameSize))
            self.frames.append(f)
            self.installFrame(f)
            self.refreshFrames()
            self.updateHintVisibility()
            self.saveWorkspace()
            self.viewport.frame(rect: f.rect, completion: nil)
        }
    }

    /// Place a frame's view behind the items and wire its label (fit / move / delete).
    private func installFrame(_ f: Frame) {
        f.view.label.onClick = { [weak self, weak f] in
            guard let self, let f else { return }
            self.viewport.frame(rect: f.rect, completion: nil)   // fit the camera to the group
        }
        f.view.label.onMovedEnd = { [weak self, weak f] origin in
            guard let self, let f else { return }
            f.rect.origin = origin
            self.refreshFrames()
            self.saveWorkspace()
        }
        f.view.label.onDelete = { [weak self, weak f] in
            if let f { self?.deleteFrame(f) }
        }
        documentView.addSubview(f.view, positioned: .below, relativeTo: nil)  // always behind cards/diffs
    }

    private func deleteFrame(_ f: Frame) {
        f.view.removeFromSuperview()
        frames.removeAll { $0 === f }
        updateHintVisibility()
        saveWorkspace()
        canvasLog("deleted frame \(f.id)")
    }

    /// Recompute each frame's member count + "needs you" tag from geometry + status.
    private func refreshFrames() {
        guard !frames.isEmpty else { return }
        let cards = store.items.compactMap { $0 as? Card }
        for f in frames {
            let members = f.members(in: cards)
            let loud = members.first { $0.status == .blocked }?.status.color
                    ?? members.first { $0.status == .error }?.status.color
            f.view.update(count: members.count, loud: loud)
        }
    }

    private func promptFrameName(_ completion: @escaping (String?) -> Void) {
        guard let window = view.window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = "New frame"
        alert.informativeText = "Name this group of agents."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. checkout"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { resp in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(resp == .alertFirstButtonReturn && !name.isEmpty ? name : nil)
        }
    }
}
