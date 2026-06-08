# Window Title Bar

_Started 2026-06-08 18:45 UTC_

---

## User

so here's the thing. im not sure how i can describe what i want but i will try my best.

you see the window bar where we show the 'new agent button' ? whats that called ?

## Assistant

_[tool: grep]_

Let me look at your file to see exactly what you're referring to.

_[tool: read_file]_

That bar at the very top of the window — the strip holding the traffic-light dots on the left, the centered title, and your "New agent" button on the right — has a few names depending on which part you mean:

**The whole strip** is the **title bar** (in your code it's `.mac-bar`). On macOS specifically, Apple calls it the **window title bar**.

**The button area** — the cluster on the right with "New agent" and the search icon — is a **toolbar**. When the title bar and the toolbar are fused into one row like yours is (buttons living *in* the title bar rather than on a separate row below it), the common terms are:

- **Unified title bar / toolbar** — Apple's own term for this merged single-row treatment
- **Title bar actions** or **window actions** — generic UI term for buttons docked in the title bar
- **Header bar** — the cross-platform/Linux (GNOME) word for this exact thing: one bar that combines title + controls + primary actions

So if you're describing it to me or anyone else, the most precise phrase for what you've built is a **unified toolbar** (or **header bar**) — a title bar with the primary action ("New agent") promoted into it.

Is there something you want to *do* with it — restyle it, add controls, change how the "New agent" button sits in there? Tell me the goal and I'll take it from there.

## User

ok. the window title bar.

can we make it invisible ? meaning, we dont want it to have a bg color. the app bg should bleed fully. with out showing the "Agent Canvas — 7 agents · 2 diffs · 3 frames" line.

makes sense?

## Assistant

_[tool: grep]_

Makes total sense. Let me find the relevant CSS.

_[tool: grep]_

_[tool: grep]_

Now let me find the CSS rules for these classes.

_[tool: grep]_

The CSS must define these elsewhere. Let me search the stylesheet.

_[tool: list_files]_

The CSS isn't inline. Let me check the project files for a stylesheet.

_[tool: list_files]_

_[tool: grep]_

_[tool: read_file]_

_[tool: str_replace_edit]_

Got it — completely clear. You want the hero window's title bar to be chromeless: drop its background and divider so the canvas bleeds straight up through it, and hide the "Agent Canvas — 7 agents..." title text — while keeping the traffic lights and the New agent button floating on top.

I'll scope it to just the hero window so the diff window and focus cards keep their labels.

_[tool: show_html]_

_[tool: show_html]_

Done. The hero window's title bar is now chromeless — the title text is gone, the background and divider are removed, and the canvas surface bleeds straight up through it. The traffic-light dots, search icon, and **New agent** button now float directly on the canvas with no bar behind them.

The other windows (diff tool, focus cards, first-run states) keep their solid title bars and labels, since those carry useful info like `+84 −12` and repo names.

## User

there is still seperation visible. looking at the gradient in the bg of the app. it doesnt bleed into the bar

## Assistant

_[tool: grep]_

Right — the bar area shows the `.mac` base color while the viewport below has the gradient. Let me look at how the viewport/canvas background is built.

_[tool: str_replace_edit]_

Found it. The warm radial gradient lives on `.viewport`, and it's anchored relative to the viewport box — which starts *below* the 40px bar. So the bar never gets any gradient, creating that seam.

The fix: move the gradient up onto the whole hero window so it's one continuous wash spanning the (now transparent) bar and the viewport, and make the viewport transparent so it shows through.

_[tool: show_html]_

The seam is gone now — the warm gradient washes continuously from the top edge of the window, straight through the bar area and down into the canvas, with no break where the title bar used to be. The traffic lights and New agent button sit cleanly on top of one unbroken surface.

## User

nice. now remove the search and 'new agent' buttons.

here's my vision. we need a floating tool bar on the left side. kind of like photoshop, but following our design. we have frame tool, agent tool, terminal tool and diff tool

## Assistant

_[tool: read_file]_

Love it — a Photoshop-style vertical tool dock on the left, in our visual language. Let me study the existing floating chrome (zoom HUD, canvas hint, notif panel) so the toolbar matches its blur/border/radius treatment.Now let me look at the zoom-hud and notif CSS to match the styling vocabulary.

_[tool: grep]_

_[tool: read_file]_

Let me check the active/solid button treatment and the primary token so the active tool matches the design.

_[tool: grep]_

_[tool: list_files]_

Good — I have the full design vocabulary. Now let me check the JS structure and the end of the HTML.

_[tool: read_file]_

_[tool: str_replace_edit]_

Now I'll make all the changes. First, remove the search + New agent buttons and add the tool dock to the viewport:Now add the toolbar CSS to panels.css (where the other floating chrome lives):

_[tool: read_file]_

_[tool: str_replace_edit]_

_[tool: read_file]_

Let me verify I didn't break the next section's comment header:

_[tool: str_replace_edit]_

I broke the next comment header. Let me fix it:Now the small JS to switch the active tool. Let me add it to main.js — checking its end first:

_[tool: read_file]_

_[tool: str_replace_edit]_

_[tool: show_html]_

_[tool: save_screenshot]_

The toolbar is vertically centered, so it's below the fold. Let me scroll to it:

_[tool: save_screenshot]_

_[tool: eval_js]_

_[tool: eval_js]_

The document isn't scrolling in this context. Let me temporarily pin the dock near the top to verify its appearance, then it reverts on reload:

_[tool: save_screenshot]_

_[tool: done]_

The dock looks great — there it is on the left edge: the **Frame** tool active (purple highlight, dashed-square icon), then the **Agent** bead-and-halo glyph, **Terminal** window with `>_`, and **Diff** below the fold. It uses the same blurred-glass panel treatment as the zoom HUD and Activity panel, so it reads as part of the same floating chrome family. In its real position it sits vertically centered on the left edge.

Let me reload to clear my temporary tweak and hand off.Done. Here's what changed:

- **Removed** the search and New agent buttons from the hero window's title bar.
- **Added** a Photoshop-style floating tool dock on the left edge with your four tools, top to bottom: **Frame** (dashed square), **Agent** (bead + glow halo — the app's core status metaphor), **Terminal** (`>_` window), **Diff** (+/−). Frame is active by default.
- It matches the existing floating chrome — same blurred glass, border, and shadow as the zoom HUD and Activity panel — with hover labels that slide out to the right, and a purple active state that glows like the primary accent.
- Clicking a tool switches the active one (single-select).

Two things you might want to weigh in on:
- **Default tool** — I made Frame active. Want Agent active instead, since it echoes the old primary button?
- **Vertical position** — it's centered on the left edge. I could anchor it to the top-left instead if you want it closer to true Photoshop placement.

## User

now back to the window bar again. i think your faking its transparency. it should have real transparency. stop working around it.

## Assistant

_[tool: read_file]_

You're right — I painted a matching gradient onto the window to *simulate* the bar being see-through. That's a fake. Let me look at what I did and rip it out.

_[tool: str_replace_edit]_

The honest fix: the bar shouldn't have *any* background — it should physically overlay the canvas, so the viewport's real, single gradient sits behind it. No second background painted anywhere.

_[tool: show_html]_

_[tool: done]_

Now it's *real* transparency. The bar is lifted out of the layout entirely and overlaid on the canvas, so the macOS window controls float directly over the content — there's no bar background at all to seam against, because there's no bar background anymore. The viewport's own single gradient is the only thing painted, and it now genuinely fills the whole window including up behind the lights. The canvas content rises all the way to the top edge, and I nudged the "drag to pan" hint down so it clears the floating controls.Fixed properly this time. No painted fake-background — the title bar is pulled out of layout flow and floats over the canvas, so the lights sit directly on the content and the viewport's one real gradient is the only background. It's actually transparent, not faked to look that way. I also set the bar to pass clicks through so you can still drag-pan the canvas under the controls.

