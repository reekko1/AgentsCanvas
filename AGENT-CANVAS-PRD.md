# PRD — Agent Canvas (working title)

> A native macOS app: an infinite spatial canvas for supervising many coding agents across many projects at once.
> Status: concept / pre-build. This document is the product spec; it is intentionally separate from any other codebase.

---

## 1. One-line definition

An infinite, zoomable canvas where each card is a coding-agent session — you spawn a CLI agent in it, the app passively watches its working directory and reports its live state — and the killer view is **zooming out to see every agent at once**.

It is a **telescope, not a cockpit**: the app *observes and arranges*; it never orchestrates or acts on your behalf. You are the only actor. The canvas's job is to point your attention — and your feet — to the agent that needs you.

---

## 2. Why this, why now

The bottleneck in agentic coding has moved from the model to the human. One person can productively run 5+ agents in parallel, but every existing tool assumes **one human ↔ one terminal ↔ one project**. The real job is no longer typing — it's **watching, triaging, and unblocking** parallel work.

This product is a **supervision interface**. It bets on human spatial memory as the cheapest way to track "which agent is which" without reading labels, and on the agents' own hooks as a trustworthy, structured signal of *who needs you right now*.

---

## 3. Design DNA (non-negotiable principles)

These principles were chosen deliberately; every feature decision must defend them.

1. **Observe, don't orchestrate (agents).** The app never owns the *agent* lifecycle, never creates worktrees, never sends commands to an agent on your behalf, and never acts autonomously. It spawns a shell, watches the filesystem, and listens for hook events. *Scoped exception (added intentionally):* the Diff Object lets **you** perform explicit git actions (stage/unstage/discard/commit) on a working tree you're looking at — this is direct user manipulation of files (like a git GUI or your editor), not the app orchestrating agents, and destructive actions are gated by confirmation. The card god-view stays read-only.
2. **One actor — you.** No broadcast input, no fan-out commands, no inline "approve for me." God-view is read-only triage; you act by walking over (zooming in) to the agent.
3. **Cards are independent worlds.** No cross-card actions. The canvas is a room of separate agents, not a fleet you pilot from a console.
4. **Spatial memory is the index.** Location = meaning. "Auth refactor lives top-left; bug hunt bottom-right." You should rarely need to read a label.
5. **Calm by default, loud only when it matters.** A card pulls your eye **only** when it genuinely needs you (blocked / errored). Everything else stays quiet.
6. **Beautiful is part of the product.** Buttery zoom/pan and trustworthy state animation are not polish-for-later; the god-view's credibility depends on them.

---

## 4. Core concepts

### 4.1 The atom: an Agent Card
A card is deliberately **light**:
- **A terminal** (PTY) cwd'd to a folder you picked.
- **A hook-driven status glyph** (running / blocked / done / error / idle).
- A **name/label** (spatially placed, user-set or inferred from the folder).

That's it. The card does *not* bundle the diff/tree (see 4.2). It is "a terminal with a trustworthy state light."

### 4.2 The Diff Object (separate, floating)
The git diff + uncommitted-file tree is **its own movable canvas object**, not bolted to a card. You point it at a folder/working tree and place it wherever you want — typically near the agent that's editing that repo. This keeps the card minimal.

It also supports **explicit, user-initiated git actions**: stage/unstage and discard per file (hover the row), plus Stage All / Discard All and a commit footer. Destructive actions (discard, discard all) require a confirmation; commit requires a message. These act only on the working tree you wired the object to — see the scoped exception in §3.1.

### 4.3 The Canvas
An infinite, zoomable, pannable surface. Two primary altitudes:
- **God-view (zoomed out):** the point of the product. Each card renders as a **status glyph + name** (+ optional small diffstat). Terminal text is unreadable at this scale and is not rendered live — see LOD (§7.1).
- **Focus (zoomed in):** a card becomes a live, interactive terminal you drive normally. You act here, then zoom back out.

---

## 5. Key product decisions (locked)

| Decision | Choice | Notes |
|---|---|---|
| Atom on canvas | **Agent-session card** (terminal + status glyph) | Diff lives separately. |
| App ownership | **Pure viewport** + passive filesystem/git watch | Never owns worktrees or agent lifecycle. |
| Agent runtime | **Spawn CLI agents** (Claude Code, Codex, aider, …) | App renders the PTY; agent is a subprocess. |
| Moment of delight | **God-view zoom-out** | "I see all my parallel work at once." |
| Attention signal | **Agent CLI hooks** → local event sink | Structured events, not PTY scraping. |
| Card at distance | **Status glyph + name** | Optimized for triage speed. |
| Card creation | **Pick a folder → terminal opens there** | App stamps correlation env at spawn. |
| Persistence | **Layout persists; agents respawn on reopen** | See open question on resume-vs-respawn (§9.1). |
| Act from god-view | **No — zoom to act** | God-view is read-only triage. |
| Diff placement | **Separate canvas object** | Wired to a folder, freely placed. |
| Multi-agent commands | **None — fully independent cards** | No broadcast, no group actions. |
| Polish bar | **Genuinely beautiful** | LOD rendering makes this feasible. |

---

## 6. The attention architecture (the spine)

The make-or-break feature is **attention routing**: when zoomed out and a card is too small to read, the app must reliably tell you *which agent needs you*.

### 6.1 Hooks as the event source
Coding-agent CLIs expose lifecycle hooks. The app uses them as a structured, trustworthy signal instead of scraping terminal output.

- **Claude Code:** `SessionStart`, `Notification` (needs permission / waiting on you), `Stop` (turn finished), `PreToolUse`/`PostToolUse`, `SubagentStop`, etc. Each hook receives a JSON payload on stdin (`session_id`, `cwd`, `hook_event_name`, …).
- **Codex:** `notify` program invoked on events.
- **aider / others:** shimmed via wrapper.

### 6.2 The local event sink
- The app runs a tiny **local sink** — a Unix domain socket (preferred) or `127.0.0.1` HTTP endpoint.
- Each installed hook is a one-liner that POSTs its JSON payload (plus the card id) to the sink.
- The sink updates the card's **glyph state machine**:
  - `SessionStart` → **running**
  - `Notification` (permission) → **blocked (needs you)**
  - `Stop` → **done / waiting**
  - tool error → **error**
  - no events for N minutes → **idle**

### 6.3 Correlation: which card does an event belong to?
The PTY and the hook process are decoupled, so events must be bound back to a card.

- **Chosen mechanism — env-var injection:** at spawn, the app sets `CANVAS_CARD_ID=<id>` and `CANVAS_SOCK=<path>` in that card's terminal environment. The installed hook command echoes `$CANVAS_CARD_ID` in its POST. Bulletproof 1:1 mapping; survives multiple cards on the same folder. Pairs naturally with the "folder → terminal" flow, since the app is already the spawner.
- Rejected: cwd-matching (breaks with two cards on one repo), PID-tree (fragile).

### 6.4 Scoped hook install (don't clobber user config)
Hooks must exist **only inside cards**, never by rewriting the user's global `~/.claude/settings.json`.
- Prefer launching each agent against an **app-managed settings layer** (project-local `.claude/settings.json` the app owns, a `--settings` flag, or env-scoped config).
- Per-agent **adapters** normalize each CLI's events into the shared glyph state machine.
- Degradation: if an agent can't be cleanly hook-instrumented, its card falls back to coarse **process idle/busy** detection.

### 6.5 State disambiguation (refinement)
`Notification`-style events can mean *blocked on permission* **or** *idle, waiting for your next instruction*. The adapter must distinguish **blocked** (loud, pulls your eye) from **done-and-waiting** (calm). Use the more specific event (e.g. permission/PreToolUse vs idle-timeout) where the CLI exposes it.

---

## 7. Technical risks & how they're addressed

### 7.1 Level-of-detail (LOD) rendering — the hardest part
You cannot run N live terminal emulators while smoothly pan/zooming an infinite canvas at 60fps.
- **Zoomed out:** a card is a cheap snapshot/glyph. No live PTY rendering work.
- **Focused / near:** only that card runs a live, interactive terminal view.
- Off-screen and far cards are "asleep" (process keeps running; rendering does not).
- **This should be prototyped first** — the whole "beautiful god-view" promise depends on it.

### 7.2 Respawn ≠ resume
On reopen, the folder and on-disk git changes persist, but a freshly spawned agent has **no memory** of the prior conversation unless launched with `--continue` / `--resume`. See open question §9.1.

### 7.3 Per-agent hook adapters
Each supported CLI needs a small adapter (event names → glyph states) and a scoped-install strategy. Start with one (Claude Code), design the adapter interface to add others.

### 7.4 Diff object working-tree selection
A diff object watches a path. If multiple agents share a repo via worktrees, the diff object targets a specific worktree path. Pure-viewport: it just watches a folder; the user wires it.

---

## 8. MVP — the thinnest slice that proves the idea

**Goal:** validate that the god-view glyph genuinely pulls your eye and that zoom-in-to-act feels right. If this loop feels good, everything else is worth building.

In scope:
1. One canvas; create cards via **pick folder → spawned terminal**.
2. Env stamping: `CANVAS_CARD_ID` + `CANVAS_SOCK` per card.
3. Local **socket sink**.
4. **Claude Code** hooks (scoped install) POSTing events → cards turn **running / blocked / done / error**.
5. **Zoom out → glyphs; zoom in → live terminal** (basic LOD).

Explicitly out of scope for MVP:
- Diff object, persistence, multi-agent CLIs, beauty pass, idle detection.

Success signal: a red "blocked" glyph reliably draws your attention from across the canvas, and zooming in to clear it feels natural.

---

## 9. Open questions

1. **Respawn vs resume (§7.2):** on reopen, should a card start a *fresh* agent in the same folder, or *reattach to the prior conversation* (`--continue`/`--resume`)? Resume is more "my workspace came back" and is likely the real want. Decide before persistence work.
2. **Idle vs done glyph semantics:** exact rule for when a calm "done/waiting" becomes a louder "you've ignored this for a while."
3. **Diff object auto-pairing:** should diff objects auto-suggest a working tree based on nearby cards, or always be manually wired (more pure-viewport)?
4. **Background sessions later?** MVP keeps agents tied to the app. A future option: detached/tmux-backed sessions that survive app close and re-attach on reopen (the stronger "reconnect to live sessions" model).

---

## 10. Non-goals (to protect the philosophy)

- Not a tiling terminal (iTerm/tmux) and not an IDE.
- No orchestration *of agents*: no broadcast input, no group commands, no app-initiated or autonomous agent actions. (The Diff Object's git actions are user-initiated working-tree edits, not agent orchestration — §3.1, §4.2.)
- No worktree management or project management by the app.
- No acting on agents from god-view.
- No cloud, no account, no telemetry required to use it.

---

## 11. Suggested tech direction (for the build pass, not yet decided)

- **Canvas/UI:** SwiftUI or AppKit for the zoomable surface; LOD rendering as in §7.1.
- **Terminals:** `SwiftTerm` for the live PTY views.
- **Event sink:** Unix domain socket + a tiny local listener in-process.
- **Hook adapters:** per-CLI normalizers behind a shared `AgentAdapter` interface.

*(This section is intentionally light — feasibility/stack is the next deep-dive.)*
