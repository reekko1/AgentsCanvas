import AppKit
import SwiftTerm

/// Coordinator: builds the canvas view tree and wires the engine (`Viewport`),
/// the model (`CardStore`), and the attention spine together. Holds no zoom math,
/// no persistence format, and no CLI knowledge — those live in their own types.
final class CanvasViewController: NSViewController {

    private var scrollView: NSScrollView!
    private var documentView: DocumentView!
    private var backdrop: GridBackdropView!
    private var hintLabel: NSTextField!

    private var viewport: Viewport!
    private let store = ItemStore()
    private let spine = Spine()
    private let toolbar = CanvasToolbar()

    private var savedViewport: (center: NSPoint, mag: CGFloat)?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    // MARK: Lifecycle
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        view.wantsLayer = true

        buildViewTree()
        viewport = Viewport(scrollView: scrollView)
        viewport.onChange = { [weak self] in self?.updateBackdrop() }

        spine.onStatus = { [weak self] cardId, status in self?.store.card(cardId)?.apply(status) }
        spine.start()

        loadWorkspace()
        installInputMonitors()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installToolbar()
        viewport.updateLimits(contentBounds: store.bounds)
        if let v = savedViewport {
            let m = max(scrollView.minMagnification, min(scrollView.maxMagnification, v.mag))
            viewport.applyZoom(center: v.center, mag: m)
        } else {
            viewport.fitAll(contentBounds: store.bounds, animated: false)
        }
        updateBackdrop()
        updateHintVisibility()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        viewport.updateLimits(contentBounds: store.bounds)
        positionHint()
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

        hintLabel = NSTextField(labelWithString: "Press  N  to add an agent")
        hintLabel.font = Theme.fonts.hint
        hintLabel.textColor = Theme.colors.textMuted
        hintLabel.alignment = .center
        view.addSubview(hintLabel)
        positionHint()
    }

    private func positionHint() {
        guard hintLabel != nil else { return }
        hintLabel.sizeToFit()
        hintLabel.frame.origin = NSPoint(x: (view.bounds.width - hintLabel.frame.width) / 2,
                                         y: (view.bounds.height - hintLabel.frame.height) / 2)
    }

    private func updateHintVisibility() { hintLabel?.isHidden = !store.items.isEmpty }

    private func installToolbar() {
        guard let window = view.window, window.toolbar == nil else { return }
        toolbar.onNewCard = { [weak self] in self?.createCard() }
        toolbar.onNewDiff = { [weak self] in self?.createDiff() }
        window.toolbar = toolbar.make()
        window.toolbarStyle = .unified
    }

    private func updateBackdrop() {
        guard backdrop != nil else { return }
        backdrop.offset = scrollView.contentView.bounds.origin
        backdrop.scale = scrollView.magnification
    }

    // MARK: Items
    /// Wire an item's move/delete and place its view on the canvas.
    private func installItemView(_ item: CanvasItem) {
        item.containerView.onMoved = { [weak self, weak item] origin in
            guard let self, let item else { return }
            item.frame.origin = origin
            self.viewport.updateLimits(contentBounds: self.store.bounds)
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
        let (exe, args) = spine.launchCommand(folder: card.folder)
        t.startProcess(executable: exe, args: args, environment: spine.env(cardId: card.id),
                       currentDirectory: card.folder.path)
        card.terminal = t
        t.nativeBackgroundColor = Theme.colors.itemChrome  // match the inset gap → seamless padding
        card.containerView.setContent(t)
        canvasLog("spawned \(card.id) in \(card.folder.path)")
    }

    private func deleteItem(_ item: CanvasItem) {
        (item as? Card)?.terminal?.terminate()   // SIGTERM the agent
        (item as? DiffObject)?.stop()            // stop the git watcher
        item.containerView.removeFromSuperview()
        store.remove(item)
        viewport.updateLimits(contentBounds: store.bounds)
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
            case "card":
                guard let folder = record.folder else { continue }
                let card = Card(id: record.id, title: record.title, frame: frameRect,
                                folder: URL(fileURLWithPath: folder))
                store.add(card)
                installItemView(card)
            case "diff":
                guard let folder = record.folder else { continue }
                let diff = DiffObject(id: record.id, frame: frameRect, folder: URL(fileURLWithPath: folder))
                store.add(diff)
                installItemView(diff)
                diff.start()
            default:
                canvasLog("skipping unknown item kind: \(record.kind)")
            }
        }
        if let v = ws.viewport { savedViewport = (NSPoint(x: v.cx, y: v.cy), CGFloat(v.mag)) }
        canvasLog("restored \(store.items.count) item(s)")
    }

    func saveWorkspace() {
        guard viewport != nil else { return }
        let vp = Workspace.Viewport(cx: viewport.center.x, cy: viewport.center.y, mag: viewport.magnification)
        store.workspace(viewport: vp).save()
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

    private func addCard(folder: URL) {
        let card = Card(id: store.nextId(prefix: "card"), title: folder.lastPathComponent,
                        frame: centeredFrame(CanvasLayout.cardSize), folder: folder)
        store.add(card)
        installItemView(card)
        viewport.updateLimits(contentBounds: store.bounds)
        updateHintVisibility()
        saveWorkspace()
        canvasLog("added \(card.id) -> \(folder.path)")
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
}
