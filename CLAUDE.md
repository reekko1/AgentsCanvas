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

Source layout under `Sources/AgentCanvas/` (SPM globs subfolders automatically — adding folders needs no `Package.swift` change):

- **App/** — `main.swift`, `AppDelegate.swift` (window, save-on-terminate).
- **Canvas/** — `CanvasViewController.swift` is a slim **coordinator**: it wires everything and owns *no* zoom math, persistence format, or CLI knowledge — keep those out of it.
  - `Viewport.swift` — the zoom/pan engine (fly-to, fitAll, size-aware framing — fills the viewport to `framingFill`, capped at `framingMaxMagnification` for crispness, zoom-out floor). Emits `onChange` to refresh the backdrop.
  - `GridBackdropView.swift` — edgeless dot grid that tracks scroll offset+zoom and draws only ~200 visible dots (never back a 16000px surface with `drawRect`).
  - `ItemContainerView.swift` — reusable "OS-window" chrome (title-bar drag + ✕ delete + status-colored border + content). `DragBarView.swift` is the title bar.
  - `CanvasItem.swift` — protocol (`id`/`frame`/`containerView`/`kind`/`record()`) any on-canvas object implements.
  - `CanvasToolbar.swift` — the window's unified `NSToolbar`; holds the create actions (new agent card, new diff object) and is where future toolbar actions go.
  - `DocumentView.swift` — the flipped document surface.
- **Cards/** — `Card.swift` (a `CanvasItem`; owns the terminal + `apply(status)`), `CardStatus.swift` (enum + color/isLoud), `ItemStore.swift` (registry over **all** `CanvasItem`s — id sequence, `bounds`, Workspace (de)serialize — pure data, no views; `card(id)` is a typed convenience for the spine).
- **Diff/** — the diff object (PRD §4.2). `DiffObject.swift` (a `CanvasItem`; owns the diff view + watcher, neutral border, diffstat in its title bar), `GitDiff.swift` (**read-only** git invocation + porcelain/numstat parsing — never mutates; `GitChange` carries `hasStaged`/`hasUnstaged`), `GitActions.swift` (the **mutating** counterpart — stage/unstage/discard/stageAll/discardAll/commit; shared `Git.run` runner used by both), `DiffWatcher.swift` (debounced background poll + `poke()` for immediate post-action refresh), `DiffContentView.swift` (two-pane file-list + colored diff, per-row hover Stage/Unstage/Discard buttons, commit/bulk footer; destructive actions confirmed via `NSAlert` sheets). Read path and write path are deliberately separate files.
- **Spine/** — the attention spine (see below). `Spine.swift` (owns sink + sender script + adapter; exposes `onStatus:(cardId, CardStatus)`), `HookSink.swift` (loopback TCP listener), `AgentAdapter.swift` (protocol), `ClaudeCodeAdapter.swift`.
- **Persistence/** — `Workspace.swift` (Codable, heterogeneous `items[]` keyed by `kind`).
- **Support/** — `Theme.swift` (all colors + fonts, role-named; `Theme.colors.x` / `Theme.fonts.x`, swappable via `Theme.current` — **no color/font literals belong anywhere else**), `CanvasLayout.swift` (size/margin constants — geometry stays here, not in the theme), `Log.swift` (`canvasLog`).

### Two seams designed for extension
- **`CanvasItem` + `ItemContainerView`** — to add a new on-canvas object, make a new `CanvasItem` (implement `kind` + `record()`), reuse the chrome, and add a load case in `CanvasViewController.loadWorkspace`. The **diff object** is the worked example of this seam; `ItemStore` is kind-agnostic so it needs no change.
- **`AgentAdapter`** — to add another CLI (Codex, aider, etc.), write a new adapter (install/launch/status) and inject via `Spine(adapter:)`. Nothing else changes. v1 ships Claude Code only.

## The attention spine (how card status works)

On launch the app writes `~/.agentcanvas/canvas-send.sh` + `hooks.json`, then spawns each card's `claude` session via `claude --settings <hooks.json>` with env `CANVAS_CARD_ID` + `CANVAS_PORT`. The `--settings` flag **merges** hooks for that session only — it never touches `~/.claude` or project settings. Every hook runs `canvas-send.sh`, which sends `"<card_id>\n<json>"` over loopback TCP to the in-process `HookSink`. The sink maps `hook_event_name` → `CardStatus` and re-renders the card's border (status = always-on colored border; pulsing glow when "loud"/blocked).

Event→status mapping lives in `ClaudeCodeAdapter.status(event:payload:)`. Key facts (empirically verified against claude 2.1.168 + official hooks docs — trust these over guesses):
- **`PermissionRequest`** is the blocked/"needs you" trigger — it fires immediately when the dialog appears. Do **not** use `Notification(permission_prompt)` for this; that's the *delayed* desktop nudge (held for seconds) and made red lag ~6s.
- `Notification` is kept only for `idle_prompt`→idle (calm) and as a permission fallback.
- **SubagentStart/SubagentStop are intentionally NOT installed** — they fire out-of-sync (~1.5s after the main `Stop`) and would flip a finished card back to running.
- Loop order is `PreToolUse → PermissionRequest → PostToolUse`. Hook command is ONE shell string. Hook subprocesses inherit the spawner's env, so `CANVAS_CARD_ID` correlation is reliable.

## Behavior decisions (intentional, don't "fix")

- **Reopen = fresh agent, not resume.** Layout, folder paths, and names persist to `~/.agentcanvas/workspace.json` + camera viewport; conversation does not. Resume is a future feature, not a v1 fork.
- **Lazy spawn.** A restored card is a dormant placeholder; `claude` spawns only on first double-click (frame it). This avoids N sessions + token burn at launch.
- **Status is never persisted** — a restored card is `idle`, never lies.
- **No backward-compat in `Workspace`.** Schema changes are clean breaking changes by design — prefer direct code over migration shims.
- **Empty first run** shows a "Press N" hint, not demo cards.

### Input map (in `CanvasViewController`)
Toolbar **New Agent** / **New Diff** = create (folder picker) · N / ⌘N = new card · double-click item = frame it (a card spawns if dormant; a diff just flies — diffs are live, never lazy) · double-click empty / esc / space / ⌘0 = fit all · click/type in a card = interact with its terminal · +/− = zoom · ✕ on title bar = delete (card → SIGTERM; diff → stop watcher). All single-knob tunables (magnifications, sizes incl. `diffSize`) live in `Viewport` / `CanvasLayout`.

## Open risk to watch

Performance with many *live* terminals during zoom is unverified at scale. The bet is fine for a handful; if it janks, the planned fallback is gesture-only freeze (snapshot during active pinch, restore on end) — not a return to the old always-snapshot model.
