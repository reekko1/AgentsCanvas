# Agent Canvas — Design Brief

> **For:** the designer creating the visual design.
> **What this is:** everything you need to design Agent Canvas *correctly* —
> what the product is, the objects in it, the **states** each object can be in, the
> **exact data** each one binds to, and the **platform constraints** that decide
> what's buildable.
> **What this is NOT:** a visual direction. There is already a rough working
> prototype; **ignore how it looks entirely** — it's a placeholder, not a
> reference. The look, layout, color, type, motion, and personality are yours to
> invent. This doc tells you the *rules of the world*, not how to draw it.
>
> Read §1 for the feel, §2 for how the app behaves, §3 for the objects + their
> states, §4 for the **data schema** (the binding contract — design only what data
> exists), §5 for the **token/sizing slots** you must deliver, §6 for **hard
> platform constraints**, and §7 for **what's fixed vs. wide open**.

---

## 1. What the product is

**Agent Canvas is an infinite, zoomable canvas where each card is a live
coding-agent terminal.** You spawn CLI coding agents (Claude Code today) into
cards, arrange them in space, and the signature move is **zooming out to see every
agent at once** and instantly knowing *which one needs you*.

It is a **telescope, not a cockpit**: the app *observes and arranges*; it never
drives the agents for you. You are the only actor. The canvas's job is to point
your attention to the agent that needs you.

### Design DNA (principles — these constrain the *feel*, not the *form*)
You have total freedom on form; these five are the soul and shouldn't be violated:

1. **Calm by default, loud only when it matters.** Most of the time, most cards
   should recede. A card earns attention *only* when it genuinely needs the human.
   The product lives or dies on this contrast — the "needs you" signal must cut
   through a busy canvas, and everything else must stay quiet.
2. **Spatial memory is the index.** Users navigate by *where* things are, not by
   reading labels. Don't bury that under chrome.
3. **Observe, don't orchestrate.** Zoomed out, the canvas is read-only triage —
   no action buttons on agents. The one exception is the Diff Object (§3.3), which
   is an explicit, user-driven git tool.
4. **Beautiful and fluid is the product.** Smooth zoom/pan and trustworthy state
   changes aren't polish — they're the pitch. This should feel genuinely crafted.
5. **Restraint.** Not an IDE, not a tiling terminal, no settings sprawl, no
   accounts. Calm, focused, few elements.

> Within those five, go anywhere. Maximal, minimal, playful, severe — your call.

---

## 2. How the app behaves (so your design matches reality)

- **One window.** A single macOS window holding one **infinite, pannable, zoomable
  surface** with floating **items** (cards and diff objects) on it.
- **Two zoom altitudes** are the heart of the UX:
  - **Zoomed out ("god-view")** — many items visible at once; the triage view.
  - **Zoomed in ("focus")** — one item fills the view; you work in it.
- **⚠️ Architectural fact that shapes the design — there is NO separate "far"
  rendering.** A card is *one always-live terminal view that is simply scaled by
  the GPU* as you zoom. Zoomed out, you're looking at a tiny, real, scaled-down
  terminal; zoomed in, the same view at full size. It is **not** swapped for a
  cheaper glyph/summary when far away (an earlier design did that and was removed).
  Consequences you must design around:
  - The **same artwork** is what's seen at every zoom — it must read both at full
    size *and* shrunk to a thumbnail. The status signal especially must survive
    being scaled down.
  - Terminal *text* becomes unreadably small when zoomed out — that's expected and
    fine. So at god-view, the only things doing triage work are whatever **chrome**
    you put around the terminal (frame, status signal, name), also scaled down.
  - If you want anything (e.g. a name or status label) to stay a **constant,
    readable size regardless of zoom**, that's *new overlay chrome* we'd add on top
    — call it out explicitly so we can decide to build it; it isn't free.
- **The flow:** create an item → pick a folder → it appears wired to that folder.
  Double-click an item → smooth camera "fly-to" into it. Double-click empty space →
  zoom out to fit everything. Drag an item's handle to move it; delete to remove.
- **Empty first run:** no demo content — just an empty canvas with a quiet "how to
  start" hint. (Design this; it's the first thing every user sees.)

---

## 3. The objects and the states they can be in

There are exactly two kinds of object on the canvas. Design each, and **every state
each one can be in** (states are listed exhaustively — these are what the UI must
make distinguishable; how is yours).

### 3.1 The Canvas (the surface itself)
An infinite pannable/zoomable plane the items float on. It needs a backdrop that
communicates "this is a vast space you move through" without competing with the
items. (Today it's a dot grid; you're free to do anything — or nothing.)

### 3.2 The Agent Card (the atom)
One coding-agent session: a live terminal running in a folder, plus a trustworthy
**status**. Deliberately minimal — "a terminal with a state light." It does **not**
contain a file tree or diff (that's a separate object). It carries a **name**
(folder-derived) and one **status**.

**Status — the core visual vocabulary (5 mutually-exclusive states):**

| State     | Meaning                                          | Attention level         |
|-----------|--------------------------------------------------|-------------------------|
| `idle`    | dormant / not started / no recent activity       | **silent** (recede)     |
| `running` | the agent is actively working                    | calm / ambient          |
| `done`    | finished a turn, waiting for the human's input   | calm, but noticeable    |
| `blocked` | **needs the human now** (hit a permission prompt)| **LOUD — must dominate**|
| `error`   | a tool/agent error occurred                       | **LOUD — must dominate**|

Rules (semantic — the *how* is open):
- These five must be **instantly distinguishable**, including when the card is
  scaled down to a thumbnail at god-view.
- `blocked` and `error` are the only "loud" states: they must **pull the eye
  across a zoomed-out canvas** of many cards. The other three must stay quiet and
  must not compete with loud ones. Preserve that hierarchy however you express it
  (color, motion, halo, weight, badge — your toolkit).
- Don't assume a specific encoding. The prototype uses a colored border + pulse;
  you are free to throw that out entirely.
- **Status is never persisted** — a reopened card always starts `idle` until its
  agent emits an event. The UI must never show a stale or invented status.

**Card content states to design:**
1. **Live terminal** — a real terminal emulator rectangle (the CLI owns its text;
   you own the frame/chrome around it and how it's presented). *Reminder: this same
   view is also what god-view shows, just scaled.*
2. **Dormant placeholder** — a restored-but-not-yet-started card (agents spawn
   lazily, so a freshly reopened card shows a "tap to start" affordance, not a
   terminal).
3. **God-view appearance** — not a separate rendering, but the moment to make sure
   your card design still does its triage job when shrunk.

### 3.3 The Diff Object (the one interactive tool)
A **separate floating object** the user points at a folder's git working tree and
places near the relevant agent. It is the **only object with controls** — an
explicit, user-driven git tool (like a small source-control panel). It is always
live. It carries a **name** (folder) and a **diffstat** (total `+added / −removed`).

**What it must let the user do / see** (functional + data requirements — the
*layout is entirely open*; do not assume any existing source-control UI):

- **See every changed file**, each with its **change type** — added, modified,
  deleted, renamed, or untracked — and its **per-file line counts** (`+added`,
  `−removed`).
- **Understand staged vs. unstaged.** Changes are grouped into **"staged"** and
  **"unstaged"**. ⚠️ **A single file can be in *both* at once** (e.g. partially
  staged) with a different change type on each side — your design must allow a file
  to appear in both groups.
- **Select a file → view its diff:** a **unified diff** of that file with visibly
  distinct **added lines**, **removed lines**, **unchanged/context lines**, and
  **section ("hunk") headers**.
- **Act on files** (these are real, mutating git actions):
  - Per file: **stage**, **unstage**, **discard**.
  - Bulk: **stage all**, **unstage all**, **discard all**.
  - **Commit:** a message field + commit action. Commit is only possible when there
    is **≥1 staged change AND a non-empty message** — design the enabled/disabled
    states for the commit affordance.
  - **Destructive actions** (discard, discard-all) must route through a
    **confirmation** before running. (A standard macOS confirmation sheet is fine;
    you can style the trigger, the sheet is mostly native.)
- **Empty / edge states to design:** "not a git repository," "no changes — clean
  working tree," and "loading a diff."

> The diff object has the most elements of anything in the app. It's where you
> balance "calm, restrained product" against "dense, functional tool." How you
> arrange file list, diff view, and actions — split panes, stacked, drill-in,
> inline, on-hover — is completely your call.

---

## 4. The data schema (design only data that exists)

This is the binding contract between design and code. The UI can surface a
*subset* of these fields, but it **cannot show data that isn't here** — if a mockup
needs a field not listed, flag it so we can decide to add it.

```
Item (everything on the canvas shares this)
├── kind      : "card" | "diff"
├── id        : string
├── title     : string            // folder-derived, user-visible name
└── frame     : { x, y, w, h }    // position + size on the canvas

Card (kind = "card")  — an agent session
├── folder    : path              // the directory the agent runs in
├── status    : idle | running | done | blocked | error   // runtime only, never saved
└── (a live terminal, when started)

DiffObject (kind = "diff")  — a git working-tree tool
├── folder    : path              // the working tree it watches
└── renders a GitSnapshot ↓

GitSnapshot — point-in-time view of the working tree
├── isRepo        : bool          // false → "not a git repository"
├── changes       : GitChange[]   // empty + isRepo → "clean working tree"
├── totalAdded    : int           // → diffstat "+N" in the title
└── totalRemoved  : int           // → diffstat "−N" in the title

GitChange — one changed file
├── path           : string       // e.g. "Sources/App/main.swift"
├── oldPath        : string?       // previous path, for renames
├── status         : added | modified | deleted | renamed | untracked
├── added, removed : int          // per-file line counts
├── hasStaged      : bool          // appears in the "staged" group
├── hasUnstaged    : bool          // appears in the "unstaged" group
├── stagedStatus   : (change type shown on the staged side)    // may differ…
└── unstagedStatus : (change type shown on the unstaged side)  // …from each other
```

A unified file diff (the right-hand content) is plain text whose lines are one of:
**added** (`+…`), **removed** (`−…`), **hunk header** (`@@…`), file/meta header, or
**context** (unchanged). You decide how each line type looks.

---

## 5. What to deliver as a design system (the slots, not the values)

So the design maps 1:1 to code, please deliver a **complete token set** covering
the *roles* below. The values are entirely yours — we just need every role filled,
in **both light and dark** (the app supports both and switches with the OS).

**Color roles to define (×2 for light/dark):**
- *Surfaces:* the canvas backdrop; an item's body; an item's title/handle area; the
  diff content surface; the file-list surface.
- *Text:* primary (titles, file paths); secondary/muted (hints, metadata, empty
  states); a control-glyph tint.
- *Agent status:* the 5 states (`idle`, `running`, `done`, `blocked`, `error`) —
  preserving the calm-vs-loud hierarchy and staying colorblind-distinguishable.
- *Diff syntax:* added line, removed line, hunk header, meta/header, context line.
- *File change types:* added, modified, deleted, renamed, untracked (must read at
  small size in a list, in both modes).
- *Accents/controls:* the commit / primary-action color (enabled + disabled), any
  badge/pill, hover/selection highlights.

**Type roles to define:** item title/name · terminal-adjacent labels · file paths
in a list · small metadata (line counts, badges) · the unified-diff body
(monospaced) · empty-state / hint text.

**Sizing/geometry to specify (give us numbers):**
- The **on-canvas size of each item type** (card and diff) — a tunable width×height.
  Cards hold a terminal, so a roughly landscape proportion reads best, but the exact
  numbers are yours.
- Corner radii, border/stroke weights, internal padding/spacing, control sizes,
  list row height. (All open — we just need values to implement.)

**Motion to specify (timing + easing):** the camera fly-to (zoom into/out of an
item) and the status-change transition (e.g. how a card becomes "blocked"). These
two carry the "trustworthy + beautiful" promise — please storyboard them.

---

## 6. Hard platform constraints (design within these to avoid a rebuild)

Native **macOS / AppKit** app (not web, not Electron). A few realities are
non-negotiable; everything else is open:

1. **Native macOS shell.** Standard window + traffic lights, a top toolbar, native
   confirmation sheets. Lean into native materials (vibrancy/blur) if you want — or
   don't — but the frame is a real macOS window.
2. **Light + dark, automatic.** Every color needs both values; no fixed-mode-only
   designs.
3. **The terminal area is a "given" rectangle.** Inside a card is a real terminal
   emulator. You design the frame, padding, and presentation around it; you do not
   restyle its internal text grid beyond the font/colors the CLI permits.
4. **One live view per item, GPU-scaled, no level-of-detail swap** (see §2). Your
   artwork is magnified, not re-rendered, across zoom — so favor designs that stay
   clean *scaled to any size*. Very fine hairlines, tiny text, and delicate shadows
   can blur when enlarged; bold, scalable forms hold up.
5. **Controls are standard AppKit components** (buttons, text fields, lists/outline
   views, icons — SF Symbols are free and native). Custom-drawn treatments are fine
   for surfaces, borders, status signals, badges, backdrops, and item chrome.
   Heavily custom-rendered *controls* are costly — if you design an ambitious
   custom control, flag it so we can budget it.
6. **Motion we do well:** camera fly-to/zoom, status-change transitions, hover/
   selection feedback, glow/pulse effects. Specify these; we implement them.

None of the above dictates how anything *looks* — only what substrate you're
designing on.

---

## 7. Fixed vs. wide-open (so you know the playground)

**FIXED — must hold (from §1–§6):**
- Native macOS app, light + dark, one window, infinite zoom/pan canvas.
- Two object types (card, diff) + their listed **states** and **data fields** — all
  must be expressible; nothing invented beyond §4 without flagging.
- The **5 card states** are distinguishable, and **blocked/error are loud** while
  the rest stay calm.
- The diff object exposes the listed git **actions**, with **destructive ones
  confirmed** and **commit gated** on message + staged change.
- The card holds a **real terminal rectangle**; the same view is what's seen at
  every zoom (no separate far rendering).
- Calm-by-default / loud-when-it-matters is preserved.

**WIDE OPEN — entirely yours:**
- All color, typography, spacing, shape, iconography, materials, depth, texture.
- **How status is expressed** (border? halo? fill? motion? badge? something new).
- **The entire layout of the diff object** — panels, order, inline vs. drill-in.
- Item **chrome**: title/handle treatment, delete affordance, how the name reads.
- The **canvas backdrop**, the **empty first-run** state, and all empty/edge states.
- The **god-view look** and whether to propose constant-size overlay chrome (§2).
- The **camera and status motion** language.
- Overall mood and personality — bold or minimal, as long as the DNA (§1) holds.

---

## 8. Deliverables

1. **God-view (the hero):** a realistic canvas — several cards across *all five*
   states (at least one loud `blocked`), a couple of diff objects, on the backdrop.
   This shot must sell "I see all my work and I instantly know which one needs me."
2. **Focused card:** one card zoomed in with its live terminal + chrome.
3. **Card state set:** all five statuses (calm + loud) + the dormant placeholder,
   as a small spec sheet.
4. **Diff object:** the full tool — file list (including a file shown in *both*
   staged and unstaged), the per-file + bulk actions, the commit area (enabled and
   disabled), the unified-diff view, and the three empty/edge states.
5. **Empty first-run** state.
6. **A destructive-action confirmation** (light — mostly native).
7. **Design tokens:** the complete §5 set — light + dark color roles, type scale,
   sizing/geometry numbers, icon choices.
8. **Motion notes:** timing + easing for the camera fly-to and the status-change
   transition.

**Format:** Figma preferred — component-ize the item chrome and the status as
*variants*, with light/dark modes, so each token/variant maps straight to code.
Organize around the *roles and states* in this doc; that's what makes it
implementable.

---

## 9. Glossary

- **Canvas** — the infinite zoom/pan surface everything floats on.
- **Item** — anything on the canvas; either a card or a diff object.
- **Card** — one agent session: a live terminal + a status. The atom.
- **Diff object** — a separate, interactive git source-control tool wired to a
  folder; the only object with actions.
- **Status** — a card's 5-state light (`idle`/`running`/`done`/`blocked`/`error`);
  `blocked` & `error` are "loud" (allowed to grab attention).
- **God-view / focus** — zoomed-out triage altitude vs. zoomed-in work altitude;
  the *same* live views at different scale (no separate rendering).
- **Diffstat** — the `+added / −removed` totals shown on a diff object.
