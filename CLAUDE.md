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
```

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
- **Cards/** — `Card.swift` (a `CanvasItem`; owns the terminal + `apply(CardEvent)` and the accumulated spine state: status+since, task label, model, permission mode, subagent count), `CardStatus.swift` (7-state enum + color/isLoud), `ItemStore.swift` (registry over **all** `CanvasItem`s — id sequence, `bounds`, Workspace (de)serialize — pure data, no views; `card(id)` is a typed convenience for the spine).
- **Diff/** — the diff object (PRD §4.2). `DiffObject.swift` (a `CanvasItem`; owns the diff view + watcher, neutral border, diffstat in its title bar), `GitDiff.swift` (**read-only** git invocation + porcelain/numstat parsing — never mutates; `GitChange` carries `hasStaged`/`hasUnstaged`), `GitActions.swift` (the **mutating** counterpart — stage/unstage/discard/stageAll/discardAll/commit; shared `Git.run` runner used by both), `DiffWatcher.swift` (debounced background poll + `poke()` for immediate post-action refresh), `DiffContentView.swift` (two-pane file-list + colored diff, per-row hover Stage/Unstage/Discard buttons, commit/bulk footer; destructive actions confirmed via `NSAlert` sheets). Read path and write path are deliberately separate files.
- **Spine/** — the attention spine (see below). `Spine.swift` (owns sink + adapter; exposes `onUpdate:(cardId, CardEvent)` + `onPermissionAsk:(PermissionAsk)` — the held allow/deny/release handle), `HookSink.swift` (minimal HTTP server, deferrable responses), `AgentAdapter.swift` (protocol + `CardEvent`), `ClaudeCodeAdapter.swift`.
- **Persistence/** — `Workspace.swift` (Codable, heterogeneous `items[]` keyed by `kind`).
- **Support/** — `Theme.swift` (all colors + fonts, role-named; `Theme.colors.x` / `Theme.fonts.x`, swappable via `Theme.current` — **no color/font literals belong anywhere else**), `CanvasLayout.swift` (size/margin constants — geometry stays here, not in the theme), `Log.swift` (`canvasLog`).

### Two seams designed for extension
- **`CanvasItem` + `ItemContainerView`** — to add a new on-canvas object, make a new `CanvasItem` (implement `kind` + `record()`), reuse the chrome, and add a load case in `CanvasViewController.loadWorkspace`. The **diff object** is the worked example of this seam; `ItemStore` is kind-agnostic so it needs no change.
- **`AgentAdapter`** — to add another CLI (Codex, aider, etc.), write a new adapter (install/launch/status) and inject via `Spine(adapter:)`. Nothing else changes. v1 ships Claude Code only.

## The attention spine (how card status works)

`HookSink` is a minimal **HTTP server** on an ephemeral loopback port. Once the port binds, the spine writes `~/.agentcanvas/hooks.json` full of **`type: "http"` hooks** pointing at it (so config is written in the sink's `onReady`, never before), then each card's `claude` spawns via `claude --settings <hooks.json>` with env `CANVAS_CARD_ID`. The `--settings` flag **merges** hooks for that session only — it never touches `~/.claude` or project settings. Card correlation rides the `X-Canvas-Card` header, env-interpolated per session (`allowedEnvVars`). There is **no bash sender and no process fork per event** (the old `canvas-send.sh` raw-TCP transport is gone; the spine sweeps the stale script on start).

`ClaudeCodeAdapter.event(_:payload:)` maps each hook payload to a rich `CardEvent` (status + detail line + task label + final-message summary + model + permission mode + subagent delta) — not just a status. Statuses: `idle / running / waiting / done / stalled / blocked / error` (`waiting` = Stop with live `background_tasks`; `stalled` = rate-limited or running-but-silent ≥5 min via the controller's 30s heartbeat). Key facts (empirically verified — trust these over guesses):
- **`PermissionRequest`** is the blocked/"needs you" trigger AND the **orbit decision channel**: its HTTP response is *held open* (`PermissionAsk`); the activity panel's Allow/Deny answers it (`decision.behavior`), and flying into the card **releases** it with no decision so the native dialog falls through to the terminal. While held, the terminal shows no dialog — that's why fly-in must release. Telemetry hooks get `timeout: 5`; the held one gets 600.
- `Notification` is kept only for `idle_prompt`→idle and as a permission/elicitation fallback (it's the *delayed* desktop nudge — made red lag ~6s when used as primary).
- **`StopFailure`** is the API-death signal (`Stop` does NOT fire on API errors — without it a dead card glows "running" forever). `rate_limit|overloaded` → stalled; everything else → error.
- **`PostToolUseFailure`** stays `.running` (tool failures are routine agentic life; the agent sees them and continues) — it's feed-worthy (`noteworthy`), not card-worthy. `is_interrupt` events are ignored.
- **`Elicitation`** (MCP server waiting on user input) → blocked; acked instantly — we never answer elicitations from orbit.
- **SubagentStart/Stop drive the `✦N` counter ONLY, never status** — they fire out-of-sync (~1.5s after the main `Stop`) and would flip a finished card back to running.
- `Stop` carries `last_assistant_message` (the done summary — no transcript parsing) and `background_tasks` (→ `waiting`). `UserPromptSubmit` carries the prompt (→ task label). `permission_mode` is captured opportunistically from any payload (BYPASS/DON'T-ASK chip — an unguarded card can never go loud, which is itself supervision-critical).

Attention reach: dock badge = loud count; `requestUserAttention` when a card goes loud while the app is inactive; Tab flies to the oldest loud (then stalled) card.

## Behavior decisions (intentional, don't "fix")

- **Reopen = fresh agent, not resume.** Layout, folder paths, and names persist to `~/.agentcanvas/workspace.json` + camera viewport; conversation does not. Resume is a future feature, not a v1 fork.
- **Lazy spawn.** A restored card is a dormant placeholder; `claude` spawns only on first double-click (frame it). This avoids N sessions + token burn at launch.
- **Status is never persisted** — a restored card is `idle`, never lies.
- **No backward-compat in `Workspace`.** Schema changes are clean breaking changes by design — prefer direct code over migration shims.
- **Empty first run** shows a "Press N" hint, not demo cards.

### Input map (in `CanvasViewController`)
Toolbar **New Agent** / **New Diff** = create (folder picker) · N / ⌘N = new card · double-click item = frame it (a card spawns if dormant; a diff just flies — diffs are live, never lazy; flying into a card releases its held permission asks to the terminal dialog) · Tab = fly to the oldest card that needs you · double-click empty / esc / space / ⌘0 = fit all · click/type in a card = interact with its terminal · +/− = zoom · ✕ on title bar = delete (card → SIGTERM; diff → stop watcher). All single-knob tunables (magnifications, sizes incl. `diffSize`) live in `Viewport` / `CanvasLayout`; the stall threshold lives in `CanvasViewController.stallAfter`.

## Open risk to watch

Performance with many *live* terminals during zoom is unverified at scale. The bet is fine for a handful; if it janks, the planned fallback is gesture-only freeze (snapshot during active pinch, restore on end) — not a return to the old always-snapshot model.
