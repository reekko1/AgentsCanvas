import AppKit
import SwiftTerm

/// Coordinator: builds the canvas view tree and wires the engine (`Viewport`),
/// the model (`CardStore`), and the attention spine together. Holds no zoom math,
/// no persistence format, and no CLI knowledge — those live in their own types.
final class CanvasViewController: NSViewController {

    private var scrollView: NSScrollView!
    private var documentView: DocumentView!
    private var backdrop: VideoBackdropView!
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
    private let frameOverlayHost = FrameOverlayHost()   // floats frame labels above the canvas
    private let frameDrawOverlay = FrameDrawOverlay()   // captures drag-to-create a new frame
    private var armingFrame = false                     // Frame tool armed → next drag draws a frame
    private var lastDeletedFrame: (id: String, name: String, rect: NSRect)?   // single-level ⌘Z undo
    /// In-progress frame drag: the frame's start origin + each child's start origin,
    /// snapshotted at drag start so the group translates rigidly (membership can't churn
    /// mid-drag). Nil except while a frame label is being dragged.
    private var frameDrag: (startOrigin: NSPoint, members: [(item: CanvasItem, origin: NSPoint)])?

    private var savedViewport: (center: NSPoint, mag: CGFloat)?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?

    /// The first-run wizard, when up (also hosts the remote-access re-entry).
    private var onboarding: OnboardingOverlayView?
    /// Run once, ever: any dismissal or completion sets this; the empty state's
    /// readiness rows are the maintenance surface from then on.
    private static let onboardingDoneKey = "onboardingCompleted"

    /// Permission dialogs held open by the spine, awaiting an orbit decision
    /// (allow/deny from the panel) or a fly-in release (dialog → terminal).
    private var pendingAsks: [PermissionAsk] = []
    /// Clock for stall detection + attention-debt refresh ("blocked · 14m").
    private var heartbeat: Timer?
    /// A running card silent this long is presumed stuck (hung tool, dead network).
    private static let stallAfter: TimeInterval = 300

    // MARK: Lifecycle
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        view.wantsLayer = true

        buildViewTree()
        viewport = Viewport(scrollView: scrollView)
        viewport.onChange = { [weak self] in
            guard let self else { return }
            self.syncFrameLabels()
            self.updateCardDetail()
            self.zoomHUD?.setLevel(self.scrollView.magnification)
        }
        buildOverlays()

        spine.onUpdate = { [weak self] cardId, event in
            guard let self, let card = self.store.card(cardId) else { return }
            let previous = card.status
            let statusChanged = card.apply(event)
            if let sid = event.sessionId, card.noteSession(sid) {
                // First sighting of this session (fresh spawn, or events resuming
                // after an app restart) → pull its whole plan from the CLI's store;
                // from here on the hook deltas keep it current.
                self.hydrateTodos(card, sessionId: sid)
                self.saveWorkspace()   // the session key is persisted state
            }
            if let s = event.status, s != .blocked {
                // Any forward progress resolves the card's held asks: answered in
                // the terminal, hook timed out, or the turn moved on. Releasing an
                // already-answered ask is a harmless no-op.
                self.releaseAsks(for: cardId)
            }
            // The card always reflects every transition (it just did, via apply);
            // the feed only gets the ones worth reading later.
            if (statusChanged && Self.feedWorthy(from: previous, to: card.status)) || event.noteworthy {
                self.feed.record(id: cardId, name: card.title, status: card.status,
                                 detail: event.detail, date: Date())
            }
            if statusChanged || event.noteworthy {
                self.refreshActivity()
                self.refreshFrames()   // a member going loud (or calming) updates the frame's "needs you" tag
            }
            if statusChanged, card.status.isLoud { self.escalate() }
        }
        spine.onPermissionAsk = { [weak self] ask in
            guard let self else { return }
            guard self.store.card(ask.cardId) != nil else { ask.release(); return }
            self.pendingAsks.append(ask)
            self.refreshActivity()
            self.escalate()
        }
        // The remote panel's Allow/Deny carries the same authority as the in-app
        // activity center — both land on the same decideAsk.
        spine.remote.onDecide = { [weak self] id, allow in self?.decideAsk(id, allow: allow) }
        spine.start()

        loadWorkspace()
        installInputMonitors()

        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.heartbeatTick()
        }

        // Re-probe readiness whenever the user comes back to the app — they
        // likely just installed the missing tool, and the row dissolving on
        // return is the confirmation (no dialogs, no "setup complete").
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.refreshReadiness()
        }
    }

    /// Environment check, surfaced through the wizard while it's up, otherwise
    /// through the empty state. Only meaningful while the canvas is empty —
    /// once cards exist, the terminal itself reports reality.
    private func refreshReadiness() {
        if let onboarding {
            Readiness.check(remotePort: spine.remote.port) { [weak onboarding] report in
                onboarding?.dialog.apply(report)
            }
            return
        }
        guard store.items.isEmpty, frames.isEmpty else { return }
        Readiness.check(remotePort: spine.remote.port) { [weak self] report in
            self?.emptyView?.apply(report)
        }
    }

    // MARK: First-run wizard

    /// Present the setup wizard on a fresh machine: never seen before, nothing
    /// on the canvas. Probes first so the welcome screen can adapt (a fully
    /// equipped Mac gets the one-screen "everything's ready" path).
    private func maybePresentOnboarding() {
        guard onboarding == nil,
              !UserDefaults.standard.bool(forKey: Self.onboardingDoneKey),
              store.items.isEmpty, frames.isEmpty else { return }
        Readiness.check(remotePort: spine.remote.port) { [weak self] report in
            guard let self, self.onboarding == nil,
                  self.store.items.isEmpty, self.frames.isEmpty else { return }
            self.presentOnboarding(mode: .firstRun, report: report)
        }
    }

    private func presentOnboarding(mode: OnboardingDialogView.Mode, report: Readiness.Report) {
        let dialog = OnboardingDialogView(mode: mode, report: report,
                                          remotePort: { [spine] in spine.remote.port })
        dialog.onDismiss = { [weak self] in self?.completeOnboarding(launchCard: false) }
        dialog.onChooseFolder = { [weak self] in self?.completeOnboarding(launchCard: true) }
        // The wizard polls while an install is in flight — the user working in
        // Terminal beside the canvas never re-activates the app, so activation
        // probes alone would leave "watching for it…" blind.
        dialog.onRequestProbe = { [weak self] in self?.refreshReadiness() }
        let overlay = OnboardingOverlayView(dialog: dialog)
        view.addSubview(overlay)   // last → above every window-edge overlay
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        onboarding = overlay
        updateHintVisibility()
        overlay.present()
        canvasLog("onboarding presented (\(mode == .firstRun ? "first run" : "remote access"))")
    }

    /// One exit funnel: mark seen, fade out, land on the canvas — `launchCard`
    /// chains straight into the folder picker (the wizard's exit IS ⌘N).
    private func completeOnboarding(launchCard: Bool) {
        guard let overlay = onboarding else { return }
        onboarding = nil
        UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
        overlay.dismissAnimated { [weak self] in
            guard let self else { return }
            self.updateHintVisibility()
            self.refreshReadiness()   // whatever's still missing falls back to the readiness rows
            if launchCard { self.createCard() }
        }
    }

    /// "Run Setup…" (app menu): re-visit the whole wizard anytime — skipped a
    /// step at first run, want it enabled now. Satisfied steps skip themselves,
    /// so it only walks what's actually missing.
    @objc func runSetup(_ sender: Any?) {
        reopenOnboarding(mode: .firstRun)
    }

    /// "Set Up Remote Access…" (app menu): reopen just the tailscale chapter —
    /// its QR reward stays reachable forever after first run.
    @objc func setUpRemoteAccess(_ sender: Any?) {
        reopenOnboarding(mode: .remoteOnly)
    }

    private func reopenOnboarding(mode: OnboardingDialogView.Mode) {
        guard onboarding == nil else { return }
        Readiness.check(remotePort: spine.remote.port) { [weak self] report in
            guard let self, self.onboarding == nil else { return }
            self.presentOnboarding(mode: mode, report: report)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowChrome()
        updateZoomLimits()
        if let v = savedViewport {
            let m = max(scrollView.minMagnification, min(scrollView.maxMagnification, v.mag))
            viewport.applyZoom(center: v.center, mag: m)
        } else {
            fitAll(animated: false)
        }
        syncFrameLabels()
        updateCardDetail()
        zoomHUD.setLevel(scrollView.magnification)
        refreshActivity()
        updateHintVisibility()
        refreshReadiness()
        maybePresentOnboarding()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateZoomLimits()
        syncFrameLabels()   // window resize shifts the doc→screen mapping
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        heartbeat?.invalidate()
        pendingAsks.forEach { $0.release() }
    }

    // MARK: View tree
    private func buildViewTree() {
        backdrop = VideoBackdropView(frame: view.bounds)
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

        // Above the canvas (labels float over cards), below the window-edge overlays.
        frameOverlayHost.frame = view.bounds
        frameOverlayHost.autoresizingMask = [.width, .height]
        view.addSubview(frameOverlayHost)

        // The frame-draw capture layer sits just above the label host and below the
        // tool dock, so arming it grabs canvas drags while the dock stays clickable.
        frameDrawOverlay.frame = view.bounds
        frameDrawOverlay.autoresizingMask = [.width, .height]
        frameDrawOverlay.isHidden = true
        frameDrawOverlay.onCommit = { [weak self] localRect in self?.finishFrameDraw(localRect) }
        view.addSubview(frameDrawOverlay)
    }

    private func updateHintVisibility() {
        // The wizard owns the empty canvas while it's up (the hint would bleed
        // through the scrim); it returns on dismissal.
        emptyView?.isHidden = !(store.items.isEmpty && frames.isEmpty) || onboarding != nil
    }

    /// Create the constant-size window-edge overlays and wire them to the engine.
    private func buildOverlays() {
        zoomHUD = ZoomHUD()
        zoomHUD.onZoomIn = { [weak self] in self?.viewport.zoomBy(1.25) }
        zoomHUD.onZoomOut = { [weak self] in self?.viewport.zoomBy(0.8) }
        zoomHUD.onFit = { [weak self] in
            guard let self else { return }
            self.fitAll(animated: true)
        }
        view.addSubview(zoomHUD)

        toolDock = ToolDock()
        toolDock.onFrame = { [weak self] in self?.toggleFrameTool() }
        toolDock.onAgent = { [weak self] in self?.createCard() }
        toolDock.onTerminal = { [weak self] in self?.createShell() }
        toolDock.onDiff = { [weak self] in self?.createDiff() }
        view.addSubview(toolDock)

        notifPanel = NotificationPanel()
        notifPanel.onSelect = { [weak self] id in self?.flyToItem(id: id) }
        notifPanel.onAllow = { [weak self] id in self?.decideAsk(id, allow: true) }
        notifPanel.onDeny = { [weak self] id in self?.decideAsk(id, allow: false) }
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

    /// Rebuild the activity center from the feed + held asks, the live "needs you"
    /// count, and the dock badge (the spine's reach when the window isn't visible).
    private func refreshActivity() {
        guard notifPanel != nil else { return }
        let loud = store.items.compactMap { $0 as? Card }.filter { $0.status.isLoud }.count
        let approvals = pendingAsks.compactMap { ask -> PanelApproval? in
            guard let card = store.card(ask.cardId) else { return nil }
            return PanelApproval(id: ask.id, cardId: ask.cardId, name: card.title,
                                 detail: ask.detail, created: ask.created)
        }
        notifPanel.reload(feed, approvals: approvals, loudCount: loud)
        NSApp.dockTile.badgeLabel = loud > 0 ? "\(loud)" : ""
        publishRemoteState(loudCount: loud, approvals: approvals)
    }

    /// Mirror the attention state to the remote panel. Riding the same funnel as
    /// the in-app activity center means the two views can never disagree.
    private func publishRemoteState(loudCount: Int, approvals: [PanelApproval]) {
        let cards = store.items.compactMap { item -> RemoteState.Card? in
            guard let card = item as? Card, card.role == .agent else { return nil }
            return RemoteState.Card(id: card.id, name: card.title, status: card.status.word,
                                    loud: card.status.isLoud,
                                    since: card.statusSince.timeIntervalSince1970,
                                    task: card.taskLabel, model: card.model,
                                    permissionMode: card.permissionMode,
                                    subagents: card.subagentCount)
        }
        let asks = approvals.map {
            RemoteState.Approval(id: $0.id.uuidString, name: $0.name, detail: $0.detail,
                                 created: $0.created.timeIntervalSince1970)
        }
        let rows = feed.events.map {
            RemoteState.FeedRow(name: $0.name, status: $0.status.word, loud: $0.loud,
                                message: $0.message, date: $0.date.timeIntervalSince1970)
        }
        spine.remote.publish(RemoteState(cards: cards, approvals: asks, feed: rows,
                                         needsYou: loudCount + asks.count))
    }

    /// Pull the user back when an agent goes loud while they're elsewhere.
    private func escalate() {
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
    }

    /// Whether a status transition earns an activity row. Arrivals into `running`
    /// and `idle` are usually echoes of the user's own actions (they typed the
    /// prompt; done decayed to idle) — noise that crowds out the rows that matter.
    /// Two exceptions are kept because they're things that happened *unwatched*:
    /// a stalled card resuming on its own, and a session dying mid-work.
    private static func feedWorthy(from previous: CardStatus, to current: CardStatus) -> Bool {
        switch current {
        case .running: return previous == .stalled   // self-recovery
        case .idle:    return previous == .running   // session exited mid-work
        default:       return true
        }
    }

    /// Stall watchdog + attention-debt refresh, every 30s: a running card with no
    /// spine events for `stallAfter` is presumed stuck; loud cards update their
    /// "· 14m" suffix; the panel re-renders its relative times.
    private func heartbeatTick() {
        var flipped = false
        for case let card as Card in store.items where card.role == .agent {
            if card.status == .running, Date().timeIntervalSince(card.lastEventAt) > Self.stallAfter {
                if card.markStalled() {
                    feed.record(id: card.id, name: card.title, status: .stalled,
                                detail: "No spine events for \(Int(Self.stallAfter / 60))m — possibly stuck",
                                date: Date())
                    flipped = true
                }
            }
            card.tick()
        }
        if flipped { refreshFrames() }
        refreshActivity()
    }

    // MARK: Held permission asks (the orbit decision channel)

    /// Decide a held ask from the activity panel.
    private func decideAsk(_ id: UUID, allow: Bool) {
        guard let i = pendingAsks.firstIndex(where: { $0.id == id }) else { return }
        let ask = pendingAsks.remove(at: i)
        allow ? ask.allow() : ask.deny()
        canvasLog("ask \(allow ? "allowed" : "denied") from orbit: \(ask.cardId) — \(ask.detail)")
        refreshActivity()
    }

    /// Release a card's held asks with no decision — the CLI's native dialog then
    /// falls through to the card's terminal (the fly-in handoff).
    private func releaseAsks(for cardId: String) {
        let held = pendingAsks.filter { $0.cardId == cardId }
        guard !held.isEmpty else { return }
        pendingAsks.removeAll { $0.cardId == cardId }
        held.forEach { $0.release() }
        refreshActivity()
    }

    /// Tab: fly to the card that's needed you the longest (loud first, then stalled).
    private func flyToNeediest() {
        let agents = store.items.compactMap { $0 as? Card }.filter { $0.role == .agent }
        let target = agents.filter { $0.status.isLoud }.min(by: { $0.statusSince < $1.statusSince })
            ?? agents.filter { $0.status == .stalled }.min(by: { $0.statusSince < $1.statusSince })
        if let target { frame(target) }
    }

    /// Fly the camera to an item by id (from an activity row).
    private func flyToItem(id: String) {
        if let item = store.items.first(where: { $0.id == id }) { frame(item) }
    }

    /// Replace a card's plan with the CLI's stored list for `sessionId`. nil =
    /// this CLI keeps no task store (or none for that session yet) → leave the
    /// accumulated list alone rather than wiping it on a read miss.
    private func hydrateTodos(_ card: Card, sessionId: String) {
        spine.todos(sessionId: sessionId) { [weak card] list in
            guard let card, let list, card.sessionId == sessionId else { return }
            card.hydrateTodos(list)
        }
    }

    /// Card LOD: below `posterMagnification` a spawned agent card swaps its
    /// terminal for the poster face (big task + plan + live action), and back —
    /// the poster zoom-compensates its type so it reads at any distance.
    private func updateCardDetail() {
        let mag = scrollView.magnification
        for case let card as Card in store.items { card.updateLOD(magnification: mag) }
    }

    // MARK: Framing
    /// The canvas extent that framing + zoom-limits must cover: on-canvas items
    /// *and* frames. A frame can extend past its member cards — or be empty — and
    /// must still land on screen, so it contributes to the bounds. When only frames
    /// exist, the store's fallback box is unrelated geometry, so start from the
    /// frames instead of unioning it in.
    private var contentBounds: NSRect {
        guard let first = frames.first else { return store.bounds }   // no frames → items only
        var box = first.rect
        for f in frames.dropFirst() { box = box.union(f.rect) }
        box = box.insetBy(dx: -CanvasLayout.margin, dy: -CanvasLayout.margin)
        guard !store.items.isEmpty else { return box }                // only frames → frames only
        return store.bounds.union(box)                                // both
    }

    /// Fit the camera to all content. Single funnel so every caller uses the same
    /// bounds and none silently forgets frames.
    private func fitAll(animated: Bool) {
        viewport.fitAll(contentBounds: contentBounds, animated: animated)
    }

    /// Re-clamp the zoom-out floor to current content (items + frames).
    private func updateZoomLimits() {
        viewport.updateLimits(contentBounds: contentBounds)
    }

    // MARK: Items
    /// Wire an item's move/delete and place its view on the canvas.
    private func installItemView(_ item: CanvasItem) {
        item.containerView.onMoving = { [weak self, weak item] origin in
            guard let self, let item else { return }
            self.highlightFrameForDrag(of: item, movedOrigin: origin)   // live "drop here" cue
        }
        item.containerView.onMoved = { [weak self, weak item] origin in
            guard let self, let item else { return }
            item.frame.origin = origin
            self.clearFrameHighlights()
            self.updateZoomLimits()
            self.refreshFrames()   // a card moving in/out of a frame changes membership
            self.saveWorkspace()
        }
        item.containerView.onResized = { [weak self, weak item] frame in
            guard let self, let item else { return }
            item.frame = frame
            (item as? Card)?.noteFrameChanged()   // re-pin the poster's wrapping width
            self.updateZoomLimits()
            self.refreshFrames()        // resizing moves the item's center → membership can change
            self.saveWorkspace()
        }
        item.containerView.onDelete = { [weak self, weak item] in
            if let item { self?.deleteItem(item) }
        }
        documentView.addSubview(item.containerView)
    }

    /// Fly to an item. A card spawns its terminal (if dormant) and takes focus on
    /// arrival; a diff object is already live, so we just fly. Flying into a card
    /// hands its held permission asks back to the terminal: the release answers
    /// the hook with no decision, so the native dialog appears where you've landed.
    private func frame(_ item: CanvasItem) {
        if let card = item as? Card {
            releaseAsks(for: card.id)
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
        let t = CanvasTerminalView(frame: .zero)
        // Under tmux this runs the *client*: it creates the session or, after an
        // app relaunch, reattaches to one still running (the substrate's point).
        let launch = spine.launch(role: card.role, cardId: card.id, folder: card.folder)
        t.startProcess(executable: launch.executable, args: launch.args,
                       environment: launch.environment, currentDirectory: card.folder.path)
        card.terminal = t
        // The glowing dark screen: terminal bg matches the bezel (the inset gap) so
        // padding is seamless, with a warm-ish light foreground.
        t.nativeBackgroundColor = Theme.colors.terminalBg
        t.nativeForegroundColor = Theme.colors.termText
        card.containerView.setContent(t)
        updateCardDetail()   // spawned while zoomed out (reattach) → poster, not 5px mush
        canvasLog("spawned \(card.id) in \(card.folder.path)")
    }

    private func deleteItem(_ item: CanvasItem) {
        releaseAsks(for: item.id)                // never strand a held hook
        if let card = item as? Card {
            card.terminal?.terminate()           // the tmux client (or, sans tmux, the agent)
            spine.killSession(cardId: card.id)   // end the agent's life, not just our view of it
        }
        (item as? DiffObject)?.stop()            // stop the git watcher
        item.containerView.removeFromSuperview()
        store.remove(item)
        updateZoomLimits()
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
                if let sid = record.session { card.noteSession(sid) }
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
        reattachLiveSessions()
    }

    /// Cards whose tmux session survived a previous app run reattach immediately —
    /// work in flight should be observed, not parked behind "tap to start". Cards
    /// with no live session stay dormant placeholders exactly as before, and their
    /// status stays `idle` until real spine events say otherwise (never lies).
    private func reattachLiveSessions() {
        spine.liveSessionCardIds { [weak self] ids in
            guard let self, !ids.isEmpty else { return }
            var attached = 0
            for case let card as Card in self.store.items where card.terminal == nil && ids.contains(card.id) {
                self.spawnTerminal(card)
                attached += 1
                // The session survived the restart, so its plan is still live —
                // re-hydrate from the CLI's task store (the app's copy died with it).
                if let sid = card.sessionId { self.hydrateTodos(card, sessionId: sid) }
            }
            if attached > 0 { canvasLog("reattached \(attached) live session(s)") }
            let orphans = ids.filter { self.store.item($0) == nil }
            if !orphans.isEmpty {
                // A session whose card is gone (workspace edited or lost). Surface
                // it, never silently kill it — it may be mid-task.
                canvasLog("orphan canvas sessions (no card): \(orphans.sorted().joined(separator: ", "))")
            }
        }
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
        if armingFrame { return e }   // the draw overlay owns canvas clicks while armed
        guard e.window === view.window, e.clickCount == 2 else { return e }
        let p = documentView.convert(e.locationInWindow, from: nil)
        if let item = store.items.last(where: { $0.frame.contains(p) }) {
            frame(item)                                    // a card/diff sits above frames → fly to it
        } else if let f = frames.last(where: { $0.rect.contains(p) }) {
            viewport.frame(rect: f.rect, completion: nil)  // empty spot inside a frame → fit that frame
        } else {
            fitAll(animated: true)                         // truly empty canvas → fit everything
        }
        return nil
    }

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        if onboarding != nil {
            // The wizard is modal to the canvas: Esc dismisses, ⌘N is the exit
            // step's "Choose a folder" from anywhere, Return fires the step's
            // primary (the default-button convention).
            if e.keyCode == 53 { completeOnboarding(launchCard: false); return nil }
            if e.modifierFlags.contains(.command), e.keyCode == 45 {
                completeOnboarding(launchCard: true); return nil
            }
            if e.keyCode == 36, onboarding?.dialog.performPrimary() == true { return nil }
            return e
        }
        if armingFrame, e.keyCode == 53 { disarmFrameTool(); return nil }   // Esc cancels frame-draw
        let cmd = e.modifierFlags.contains(.command)
        if cmd {
            switch e.keyCode {
            case 45: createCard(); return nil       // ⌘N
            case 29: fitAll(animated: true); return nil // ⌘0
            default: break
            }
        }
        if terminalIsFirstResponder() { return e }  // typing in a terminal → pass through
        if cmd, e.keyCode == 6 { undoFrameDelete(); return nil }   // ⌘Z restores the last deleted frame
        switch e.keyCode {
        case 53, 49: fitAll(animated: true); return nil // esc / space
        case 48: flyToNeediest(); return nil            // tab → oldest card that needs you
        case 24, 69: viewport.zoomBy(1.25); return nil
        case 27, 78: viewport.zoomBy(0.8); return nil
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
        updateZoomLimits()
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
        updateZoomLimits()
        updateHintVisibility()
        saveWorkspace()
        canvasLog("added \(diff.id) -> \(folder.path)")
        frame(diff)
    }

    // MARK: Frames
    /// Clicking the Frame tool arms a one-shot "draw a frame" mode: the next drag on
    /// the canvas rubber-bands the rectangle that becomes the frame (Figma-style),
    /// instead of dropping a fixed box you then have to move + resize onto a cluster.
    /// Click the tool again or press Esc to disarm.
    private func toggleFrameTool() { armingFrame ? disarmFrameTool() : armFrameTool() }

    private func armFrameTool() {
        guard !armingFrame else { return }
        armingFrame = true
        frameDrawOverlay.setArmed(true)
        toolDock.setFrameToolActive(true)
        // Take over the cursor for the whole mode. Disabling the window's cursor-rect
        // machinery stops the scroll view / terminal / cards from resetting it back to
        // arrow / I-beam on every mouse-move — that reset is why a bare `set()` flickered
        // off. With rects off, the crosshair we set sticks until we hand it back.
        view.window?.disableCursorRects()
        NSCursor.crosshair.set()
        emptyView?.isHidden = true   // tuck the hint away while drawing
    }

    private func disarmFrameTool() {
        guard armingFrame else { return }
        armingFrame = false
        frameDrawOverlay.setArmed(false)
        toolDock.setFrameToolActive(false)
        view.window?.enableCursorRects()
        NSCursor.arrow.set()   // hand the cursor back; views reassert their own on next move
        updateHintVisibility()
    }

    /// Mouse-up from the draw overlay: `localRect` is the rubber-banded rectangle in
    /// the overlay's screen space (nil = too small / a bare click → just disarm).
    private func finishFrameDraw(_ localRect: NSRect?) {
        defer { disarmFrameTool() }
        guard let localRect else { return }
        var rect = documentView.convert(localRect, from: frameDrawOverlay)
        // Enforce a usable minimum, growing from the drawn rect's center.
        if rect.width < CanvasLayout.minFrameSize.width || rect.height < CanvasLayout.minFrameSize.height {
            let w = max(rect.width, CanvasLayout.minFrameSize.width)
            let h = max(rect.height, CanvasLayout.minFrameSize.height)
            rect = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        }
        let f = Frame(id: store.nextId(prefix: "frame"), name: "Untitled", rect: rect)
        frames.append(f)
        installFrame(f)
        refreshFrames()
        updateHintVisibility()
        saveWorkspace()
        canvasLog("drew frame \(f.id) [\(Int(rect.width))×\(Int(rect.height))]")
    }

    /// Place a frame's body behind the items and its label in the floating overlay
    /// host, wiring fit / move / resize / rename / delete.
    private func installFrame(_ f: Frame) {
        documentView.addSubview(f.view, positioned: .below, relativeTo: nil)  // body, behind cards/diffs

        f.label.documentView = documentView
        f.label.frameView = f.view
        f.label.onClick = { [weak self, weak f] in
            guard let self, let f else { return }
            self.viewport.frame(rect: f.rect, completion: nil)   // fit the camera to the group
        }
        f.label.onMoveBegan = { [weak self, weak f] in
            guard let self, let f else { return }
            // Snapshot the children (everything whose center sits inside) + their origins,
            // so the whole group moves rigidly with the frame and membership can't churn.
            self.frameDrag = (f.rect.origin, self.itemsInside(f).map { ($0, $0.frame.origin) })
        }
        f.label.onMoving = { [weak self] rect in
            guard let self, let drag = self.frameDrag else { return }
            let dx = rect.minX - drag.startOrigin.x, dy = rect.minY - drag.startOrigin.y
            for (item, o) in drag.members {
                let p = NSPoint(x: o.x + dx, y: o.y + dy)
                item.frame.origin = p                 // model
                item.containerView.setFrameOrigin(p)  // view
            }
        }
        f.label.onMovedEnd = { [weak self, weak f] rect in
            guard let self, let f else { return }
            f.rect = rect
            self.frameDrag = nil
            self.updateZoomLimits()   // frame + children moved → content bounds changed
            self.refreshFrames()
            self.saveWorkspace()
        }
        f.label.onRequestRename = { [weak self, weak f] in
            guard let self, let f else { return }
            self.promptFrameName(initial: f.name) { name in
                guard let name else { return }
                f.name = name              // didSet → label.setName
                f.label.syncPosition()     // width changed
                self.saveWorkspace()
            }
        }
        f.label.onDelete = { [weak self, weak f] in
            if let f { self?.deleteFrame(f) }
        }
        f.view.onResized = { [weak self, weak f] rect in
            guard let self, let f else { return }
            f.rect = rect
            f.label.syncPosition()
            self.refreshFrames()           // growing/shrinking changes which cards are inside
            self.saveWorkspace()
        }
        frameOverlayHost.addSubview(f.label)
        f.view.setScale(scrollView.magnification)
        f.label.syncPosition()
    }

    private func deleteFrame(_ f: Frame) {
        lastDeletedFrame = (f.id, f.name, f.rect)   // stash for ⌘Z — a frame is just name + rect
        f.view.removeFromSuperview()
        f.label.removeFromSuperview()
        frames.removeAll { $0 === f }
        updateHintVisibility()
        saveWorkspace()
        canvasLog("deleted frame \(f.id)")
    }

    /// Restore the most recently deleted frame (single level). Frames carry no live
    /// state, so re-creating one with its old id/name/rect is a faithful undo — unlike
    /// a card, whose agent process can't be resurrected. Delete is the one irreversible
    /// frame action, so this covers the real risk without app-wide undo machinery.
    private func undoFrameDelete() {
        guard let d = lastDeletedFrame else { return }
        lastDeletedFrame = nil
        let f = Frame(id: d.id, name: d.name, rect: d.rect)
        frames.append(f)
        installFrame(f)
        refreshFrames()
        updateHintVisibility()
        saveWorkspace()
        canvasLog("restored frame \(f.id)")
    }

    /// Keep every frame's dashed body crisp (zoom-compensated) and its floating
    /// label glued to the frame's on-screen top-left, as the camera moves.
    private func syncFrameLabels() {
        guard !frames.isEmpty else { return }
        let mag = scrollView.magnification
        for f in frames { f.view.setScale(mag); f.label.syncPosition() }
    }

    /// Recompute each frame's member count + "needs you" tag from geometry + status.
    private func refreshFrames() {
        guard !frames.isEmpty else { return }
        for f in frames {
            // A frame is a general spatial group: the badge counts *everything* inside
            // (cards of either role + diffs), so the number matches what you see and what
            // a frame-drag carries. The "needs you" flag stays agent-only — only an agent
            // has a status that can go loud (shells and diffs have no spine).
            let inside = itemsInside(f)
            let agents = inside.compactMap { $0 as? Card }.filter { $0.role == .agent }
            let loud = agents.first { $0.status == .blocked }?.status.color
                    ?? agents.first { $0.status == .error }?.status.color
            f.update(count: inside.count, loud: loud)
        }
    }

    /// While a card is dragged, light the frame it would join (its center's frame) so
    /// membership is verifiable by eye. Only *agent* cards drive it — a shell or diff
    /// never changes a frame's tally, so it shows no join cue.
    private func highlightFrameForDrag(of item: CanvasItem, movedOrigin: NSPoint) {
        let center = NSPoint(x: movedOrigin.x + item.frame.width / 2,
                             y: movedOrigin.y + item.frame.height / 2)
        let isAgent = (item as? Card)?.role == .agent
        let target = isAgent ? frames.last(where: { $0.rect.contains(center) }) : nil
        for f in frames { f.view.isHighlighted = (f === target) }
    }

    private func clearFrameHighlights() {
        for f in frames where f.view.isHighlighted { f.view.isHighlighted = false }
    }

    /// The frame's spatial children: items whose center sits inside its rect (cards of
    /// either role + diffs). Broader than the badge's agent-only tally — dragging the
    /// frame should carry everything that visually sits in the box.
    private func itemsInside(_ f: Frame) -> [CanvasItem] {
        store.items.filter { f.rect.contains(NSPoint(x: $0.frame.midX, y: $0.frame.midY)) }
    }

    private func promptFrameName(initial: String = "", _ completion: @escaping (String?) -> Void) {
        guard let window = view.window else { completion(nil); return }
        let alert = NSAlert()
        alert.messageText = initial.isEmpty ? "New frame" : "Rename frame"
        alert.informativeText = "Name this group of agents."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "e.g. checkout"
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: initial.isEmpty ? "Create" : "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { resp in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(resp == .alertFirstButtonReturn && !name.isEmpty ? name : nil)
        }
    }
}
