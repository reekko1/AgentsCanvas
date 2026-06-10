# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Agent Canvas — a native macOS infinite-canvas app for supervising many coding agents at once ("telescope, not cockpit"; **observe, don't orchestrate** *agents*). The card god-view is read-only: the only verb is *click a card → fly in*. **Scoped exception:** the Diff Object permits explicit, user-initiated git actions (stage/unstage/discard/commit) on its working tree, with destructive ones confirmed — direct working-tree manipulation, not agent orchestration (PRD §3.1/§4.2). Full product spec in `AGENT-CANVAS-PRD.md`.

## Build & run

SPM executable, no Xcode project (it's gitignored — open via `Package.swift` if you want the IDE).

```sh
swift build              # build
swift run                # build + launch the app (this is how you run it)
swift build -c release   # optimized build
Packaging/package.sh     # → dist/Agent Canvas.app + zip (ad-hoc signed; see Releasing)
```

Run **one canvas instance at a time**: a second instance loses the port race, falls back to ephemeral, and rewrites `spine.json`/`hooks.json` out from under the first. The app icon and DMG background regenerate via `swift Packaging/make-icon.swift` / `make-dmg-background.swift` (outputs are committed so packaging never depends on the generators).

## Releasing

```sh
DMG=1 NOTARY_PROFILE=canvas-notary VERSION=x.y.z \
CODESIGN_IDENTITY="Developer ID Application: Rakan ALYahya (HS29478CLK)" \
Packaging/package.sh     # build → sign → notarize+staple app zip → DMG → notarize+staple DMG
Packaging/appcast.sh     # EdDSA-sign the zip, prepend an item to docs/appcast.xml
# then: commit docs/appcast.xml; gh release create vx.y.z dist/AgentCanvas-x.y.z.{zip,dmg}
```

Facts that keep this working:
- **Artifacts have roles:** the DMG is the first-install/download artifact (drag-to-Applications teaches correct install and avoids App Translocation); the **zip is the Sparkle update artifact** — the appcast enclosure must point at it.
- **Sparkle** comes via SPM (binary xcframework + CLI tools under `.build/artifacts/sparkle/Sparkle/bin/`). `App/Updater.swift` arms only when `SUFeedURL` exists in Info.plist — `swift run` dev builds have no bundle, so the updater stays dormant and the menu item self-disables. `package.sh` embeds `Sparkle.framework` into `Contents/Frameworks`, adds that rpath, strips build-machine rpaths, and re-signs the framework under our identity (hardened-runtime library validation rejects other teams' signatures).
- **Versioning:** `CFBundleShortVersionString` = `VERSION`; `CFBundleVersion` = git commit count (monotonic — Sparkle compares this). Never reuse a version; `appcast.sh` refuses duplicates.
- **Keys/credentials:** Sparkle EdDSA private key lives in the login keychain ("Private key for signing Sparkle updates"); the public key is pinned in `package.sh` (`ED_PUBLIC_KEY`). Notary credentials = keychain profile `canvas-notary`; Developer ID team is **HS29478CLK**.
- **Feed:** `https://raw.githubusercontent.com/reekko1/AgentsCanvas/main/docs/appcast.xml` (raw URL works with zero Pages setup; switch `SU_FEED_URL` + re-release to migrate).
- Universal (x86_64) builds need the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain` — SwiftTerm ships Metal shaders); the script falls back to native arm64.
- **Mac App Store is permanently out** — the App Sandbox forbids everything this app is (PTYs, tmux, loopback servers, arbitrary-folder git).

There is no test target. The spine has been verified end-to-end manually with a real `claude` session, not by automated tests. To smoke-test the hook pipeline headlessly, the sink port is written to `/tmp/agentcanvas.port`.

Toolchain: Swift 6.3.x / macOS 13+ target. Sole dependency is **SwiftTerm** (terminal emulator, runs the real `claude` CLI inside each card).

## Architecture

The app is one window holding an `NSScrollView` (the pan/zoom engine) over a fixed 16000×16000 flipped `DocumentView`. Each agent is a **Card**: a real `LocalProcessTerminalView` living as a subview *inside* the document, so it pans/zooms with the canvas via the GPU layer transform — **no re-render on zoom**, only on content change. This is the validated pattern; don't reintroduce snapshots/offscreen-hosting/focus-overlays (that earlier design was removed as over-engineered).

### Layout discipline inside canvas items (LOAD-BEARING — caused repeated crashes)
The document view is GPU-**magnified** (a layer transform). Inside that transform, **never manually lay out AppKit controls**: no `override func layout()` setting subview `.frame`, no `sizeToFit()`, no `setPosition` on a split view, no per-pass `needsLayout`, and don't wrap the terminal in an extra custom-layout container. Manually framing constraint-backed controls (NSButton/NSTextField/NSTableView/NSSplitView/SwiftTerm's caret) inside the transform repeatedly invalidates the window's constraint engine mid-pass → AppKit aborts with *"more Layout Window passes than there are views in the window."* **Rule:** a canvas item's *outer* container is positioned by the canvas via `.frame`; **everything inside it is Auto Layout (constraints) only.** Use `NSStackView` for show/hide rows. `ItemContainerView` and `DiffContentView` follow this.

Source layout under `Sources/AgentCanvas/` (SPM globs subfolders automatically — adding folders needs no `Package.swift` change):

- **App/** — `main.swift`, `AppDelegate.swift` (window, save-on-terminate).
- **Canvas/** — `CanvasViewController.swift` is a slim **coordinator**: it wires everything and owns *no* zoom math, persistence format, or CLI knowledge — keep those out of it.
  - `Viewport.swift` — the zoom/pan engine (fly-to, fitAll, size-aware framing — fills the viewport to `framingFill`, capped at `framingMaxMagnification` for crispness, zoom-out floor). Emits `onChange` to refresh the backdrop.
  - `GridBackdropView.swift` — edgeless dot grid that tracks scroll offset+zoom and draws only ~200 visible dots (never back a 16000px surface with `drawRect`).
  - `ItemContainerView.swift` — reusable "OS-window" chrome (title-bar drag + ✕ delete + status-colored border + content). `DragBarView.swift` is the title bar.
  - `CanvasItem.swift` — protocol (`id`/`frame`/`containerView`/`kind`/`record()`) any on-canvas object implements.
  - `CanvasToolbar.swift` — the window's unified `NSToolbar`; holds the create actions (new agent card, new diff object) and is where future toolbar actions go.
  - `DocumentView.swift` — the flipped document surface.
- **Cards/** — `Card.swift` (a `CanvasItem`; owns the terminal + `apply(CardEvent)` and the accumulated spine state: status+since, task label, model, permission mode, subagent count, last action line, last summary, todos), `CardStatus.swift` (7-state enum + color/isLoud), `CardPosterView.swift` (the **poster face** — the card's far-zoom LOD: big status word + attention debt, the task in poster type, the agent's plan as a titled ✓/▸/○ checklist (collapsing to "✓ n done / … n more" past its row budget), and a state-shaped body line: live action when running, `last_assistant_message` when done, what-it-wants when blocked). `Card.setDetail(full:)` swaps terminal ↔ poster; the controller drives it from magnification alone (`CanvasLayout.posterMagnification`, 0.55) so a fly-in (capped at mag 1.0) always lands on the terminal no matter how small the card was resized. Detaching the off-LOD terminal also stops it compositing — a perf win at god view. `ItemStore.swift` (registry over **all** `CanvasItem`s — id sequence, `bounds`, Workspace (de)serialize — pure data, no views; `card(id)` is a typed convenience for the spine).
- **Diff/** — the diff object (PRD §4.2). `DiffObject.swift` (a `CanvasItem`; owns the diff view + watcher, neutral border, diffstat in its title bar), `GitDiff.swift` (**read-only** git invocation + porcelain/numstat parsing — never mutates; `GitChange` carries `hasStaged`/`hasUnstaged`), `GitActions.swift` (the **mutating** counterpart — stage/unstage/discard/stageAll/discardAll/commit; shared `Git.run` runner used by both), `DiffWatcher.swift` (debounced background poll + `poke()` for immediate post-action refresh), `DiffContentView.swift` (two-pane file-list + colored diff, per-row hover Stage/Unstage/Discard buttons, commit/bulk footer; destructive actions confirmed via `NSAlert` sheets). Read path and write path are deliberately separate files.
- **Spine/** — the attention spine (see below). `Spine.swift` (owns sink + remote server + adapter + the tmux launch path; exposes `onUpdate:(cardId, CardEvent)` + `onPermissionAsk:(PermissionAsk)` — the held allow/deny/release handle — plus `launch(role:cardId:folder:)` / `killSession` / `liveSessionCardIds`), `HTTPServer.swift` (shared minimal loopback HTTP/1.1 listener — preferred-port binding with ephemeral fallback, deferrable responses; both servers ride it), `HookSink.swift` (hook semantics over `HTTPServer`: token auth, card correlation, deferred `respond`), `SpineConfig.swift` (persisted token + ports, `~/.agentcanvas/spine.json`, 0600), `Tmux.swift` (the session substrate — see below), `AgentAdapter.swift` (protocol + `CardEvent`), `ClaudeCodeAdapter.swift`.
- **Remote/** — `RemoteServer.swift` (the remote supervision panel: `GET /` self-contained page, `GET /state` JSON, `POST /decide`; plus `RemoteState`, the JSON projection the controller publishes).
- **Persistence/** — `Workspace.swift` (Codable, heterogeneous `items[]` keyed by `kind`).
- **Support/** — `Theme.swift` (all colors + fonts, role-named; `Theme.colors.x` / `Theme.fonts.x`, swappable via `Theme.current` — **no color/font literals belong anywhere else**), `CanvasLayout.swift` (size/margin constants — geometry stays here, not in the theme), `Log.swift` (`canvasLog`).

### Two seams designed for extension
- **`CanvasItem` + `ItemContainerView`** — to add a new on-canvas object, make a new `CanvasItem` (implement `kind` + `record()`), reuse the chrome, and add a load case in `CanvasViewController.loadWorkspace`. The **diff object** is the worked example of this seam; `ItemStore` is kind-agnostic so it needs no change.
- **`AgentAdapter`** — to add another CLI (Codex, aider, etc.), write a new adapter (install/launch/status) and inject via `Spine(adapter:)`. Nothing else changes. v1 ships Claude Code only.

## The attention spine (how card status works)

`HookSink` is a minimal **HTTP server** on a loopback port. Once the port binds, the spine writes `~/.agentcanvas/hooks.json` full of **`type: "http"` hooks** pointing at it (so config is written in the sink's `onReady`, never before), then each card's `claude` spawns via `claude --settings <hooks.json>` with env `CANVAS_CARD_ID`. The `--settings` flag **merges** hooks for that session only — it never touches `~/.claude` or project settings. Card correlation rides the `X-Canvas-Card` header, env-interpolated per session (`allowedEnvVars`). There is **no bash sender and no process fork per event** (the old `canvas-send.sh` raw-TCP transport is gone).

**Spine identity is persistent** (`SpineConfig`, `~/.agentcanvas/spine.json`): the sink token and both listener ports survive app restarts. This is load-bearing for tmux: sessions outlive the app, and a running `claude` read its hook URL + token once at launch — a fresh ephemeral port or fresh token after relaunch would leave every surviving session posting into the void (or dropped as unauthenticated) and its card silent. If the preferred port is taken, `HTTPServer` falls back to ephemeral and persists the new one; pre-existing sessions then degrade gracefully (telemetry fails fast, non-blocking).

## The session substrate (tmux)

Cards don't run their process as a child of the app: `Spine.launch` wraps it in a **tmux session** on a canvas-owned server — socket `agentcanvas`, config `~/.agentcanvas/tmux.conf` (status off, `escape-time 0` because Esc = interrupt in the claude TUI; the user's own tmux server and `~/.tmux.conf` are never touched). The card's terminal runs the tmux *client* via `new-session -A -s canvas-<cardId>`: create on first spawn, **reattach** after an app relaunch. Quitting/crashing the canvas only detaches — the fleet keeps working (the app is a pure observer; this was the single-point-of-failure fix).

Substrate facts (verified against tmux 3.6):
- `CANVAS_CARD_ID` is stamped into the **session** env with `new-session -e` (tmux ≥ 3.2) — the client env is *not* enough, and sessions inherit the *server's* env (which belongs to whichever card started the server), so shell cards explicitly blank it (`-e CANVAS_CARD_ID=`).
- Kill uses `-t '=name'` — a bare `-t` prefix-matches, so `card-1` would kill `card-10`.
- The agent runs under the user's login shell *inside* the session (`$SHELL -lc 'exec claude …'`) so `claude` resolves from their real PATH; the tmux binary itself is probed at fixed install locations (`Tmux.probePaths`) because a GUI app's PATH has none of them.
- **No tmux installed → graceful fallback to direct spawn** (cards die with the app, the old behavior); the canvas never refuses to work.
- Remote terminal access falls out for free: `ssh <mac> -t tmux -L agentcanvas attach -t canvas-card-3`.
- At restore, `reattachLiveSessions` auto-attaches cards whose session survived (work in flight should be observed, not parked behind "tap to start"); orphan `canvas-*` sessions with no card are logged, never killed.

## The remote panel

`RemoteServer` (owned by `Spine`, wired by the controller) serves a phone-first supervision page: fleet statuses, the feed, and live **Allow/Deny** for held asks — `onDecide` routes into the same `decideAsk` as the in-app activity center, and the controller publishes `RemoteState` from the same `refreshActivity` funnel, so the two views can never disagree. It binds **loopback only**; expose it with `tailscale serve --bg localhost:<port>` (TLS + tailnet identity). **Never expose it publicly** (Funnel/port-forward): the Allow button approves arbitrary tool calls on this machine. The page's colors mirror `Theme`'s dark palette by hand — keep in sync when retheming.

`ClaudeCodeAdapter.event(_:payload:)` maps each hook payload to a rich `CardEvent` (status + detail line + task label + final-message summary + model + permission mode + subagent delta) — not just a status. Statuses: `idle / running / waiting / done / stalled / blocked / error` (`waiting` = Stop with live `background_tasks`; `stalled` = rate-limited or running-but-silent ≥5 min via the controller's 30s heartbeat). Key facts (empirically verified — trust these over guesses):
- **`PermissionRequest`** is the blocked/"needs you" trigger AND the **orbit decision channel**: its HTTP response is *held open* (`PermissionAsk`); the activity panel's Allow/Deny answers it (`decision.behavior`), and flying into the card **releases** it with no decision so the native dialog falls through to the terminal. While held, the terminal shows no dialog — that's why fly-in must release. Telemetry hooks get `timeout: 5`; the held one gets 600.
- `Notification` is kept only for `idle_prompt`→idle and as a permission/elicitation fallback (it's the *delayed* desktop nudge — made red lag ~6s when used as primary).
- **`StopFailure`** is the API-death signal (`Stop` does NOT fire on API errors — without it a dead card glows "running" forever). `rate_limit|overloaded` → stalled; everything else → error.
- **`PostToolUseFailure`** stays `.running` (tool failures are routine agentic life; the agent sees them and continues) — it's feed-worthy (`noteworthy`), not card-worthy. `is_interrupt` events are ignored.
- **`Elicitation`** (MCP server waiting on user input) → blocked; acked instantly — we never answer elicitations from orbit.
- **SubagentStart/Stop drive the `✦N` counter ONLY, never status** — they fire out-of-sync (~1.5s after the main `Stop`) and would flip a finished card back to running.
- `Stop` carries `last_assistant_message` (the done summary — no transcript parsing) and `background_tasks` (→ `waiting`). `UserPromptSubmit` carries the prompt (→ task label). `permission_mode` is captured opportunistically from any payload (BYPASS/DON'T-ASK chip — an unguarded card can never go loud, which is itself supervision-critical).
- **The plan tools are the agent publishing its own checklist** (the poster's todo rows). Claude Code ≥2.1 streams it *incrementally* — `TaskCreate` (`tool_input {subject, description, activeForm}`; the assigned id arrives in the **PostToolUse** `tool_response.task.id`) and `TaskUpdate` (`tool_input {taskId, status}` incl. `"deleted"`; `tool_response.statusChange.to` confirms). These were **empirically captured from real hook payloads** (claude 2.1.168) — the published hooks docs still describe only `TodoWrite`, which modern CLIs no longer call. The adapter maps them to `CardEvent.todoChange` deltas (`.add`/`.update`/`.replace`/`.clear`); `Card.applyTodoChange` owns the accumulated list. `TodoWrite` (older CLIs, full-list replace) is still handled. The list outlives a turn, so `.clear` fires only at session boundaries — never on prompt/stop.
- **The plan survives app restarts via the CLI's own task store**: `~/.claude/tasks/<session-id>/<taskId>.json` (one file per task, `{id, subject, description, activeForm, status, …}` — empirically verified) is the ground truth that outlives both the app and the hook stream. The card persists its `session_id` (in `Workspace.Item.session` — a session *key*, not status, so it doesn't violate "status is never persisted") and re-hydrates via `adapter.currentTodos(sessionId:)` on reattach and on first sighting of a session id in any event. Hook deltas keep it current from there; a nil store read leaves the accumulated list alone.

Attention reach: dock badge = loud count; `requestUserAttention` when a card goes loud while the app is inactive; Tab flies to the oldest loud (then stalled) card.

## Behavior decisions (intentional, don't "fix")

- **Reopen = fresh conversation, but never kill work in flight.** The app never *resumes* a conversation you walked away from — but a tmux session still running from a previous app run **reattaches** (the app surviving its own restart must not cost the fleet). No live session → dormant placeholder, exactly as before.
- **Lazy spawn.** A restored card with no live session is a dormant placeholder; `claude` spawns only on first double-click (frame it). This avoids N sessions + token burn at launch.
- **✕ kills the session, not just the view.** Deleting a card runs `tmux kill-session` — a detached-but-running agent nobody is watching is exactly the unsupervised state the canvas exists to prevent. Quitting the *app*, by contrast, leaves all sessions running.
- **Status is never persisted** — a restored card is `idle` until real spine events say otherwise, never lies.
- **No backward-compat in `Workspace`.** Schema changes are clean breaking changes by design — prefer direct code over migration shims.
- **Empty first run** shows a "Press N" hint, not demo cards.

### Input map (in `CanvasViewController`)
Toolbar **New Agent** / **New Diff** = create (folder picker) · N / ⌘N = new card · double-click item = frame it (a card spawns if dormant; a diff just flies — diffs are live, never lazy; flying into a card releases its held permission asks to the terminal dialog) · Tab = fly to the oldest card that needs you · double-click empty / esc / space / ⌘0 = fit all · click/type in a card = interact with its terminal · +/− = zoom · ✕ on title bar = delete (card → kills its tmux session; diff → stop watcher). All single-knob tunables (magnifications, sizes incl. `diffSize`, the poster LOD threshold `posterMagnification`) live in `Viewport` / `CanvasLayout`; the stall threshold lives in `CanvasViewController.stallAfter`.

## Open risk to watch

Performance with many *live* terminals during zoom is unverified at scale. The bet is fine for a handful; if it janks, the planned fallback is gesture-only freeze (snapshot during active pinch, restore on end) — not a return to the old always-snapshot model.
