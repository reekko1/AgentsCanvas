/* ============================================================
   AGENT CANVAS — token spec renderer (color/type/geometry)
   Each color swatch resolves under .t-dark and .t-light so the
   two modes sit side by side.
   ============================================================ */
(function () {
  const root = document.getElementById('tokRoot');
  if (!root) return;

  const groups = [
    { title:'Surfaces', mono:'--surface-*', rows:[
      ['Canvas backdrop','--canvas'],['Centre warm glow','--canvas-warm'],['Item body','--item-body'],
      ['Title / handle bar','--item-bar'],['Terminal rectangle','--terminal-bg'],['Diff content','--diff-surface'],['File-list','--filelist-bg'],
    ]},
    { title:'Text', mono:'--text-*', rows:[
      ['Primary (titles, paths)','--text'],['Secondary / muted','--text-muted'],['Control glyph','--glyph'],['Hairline border','--border'],
    ]},
    { title:'Agent status', mono:'5 states', rows:[
      ['idle · silent','--st-idle'],['running · ambient','--st-running'],['done · noticeable','--st-done'],['blocked · LOUD','--st-blocked'],['error · LOUD','--st-error'],
    ]},
    { title:'Diff syntax', mono:'unified diff', rows:[
      ['Added line','--diff-add'],['Removed line','--diff-del'],['Hunk header','--diff-hunk'],['Meta / file header','--diff-meta'],['Context','--diff-ctx'],
    ]},
    { title:'File change types', mono:'A M D R U', rows:[
      ['Added','--ft-added'],['Modified','--ft-modified'],['Deleted','--ft-deleted'],['Renamed','--ft-renamed'],['Untracked','--ft-untracked'],
    ]},
    { title:'Accents / controls', mono:'--primary', rows:[
      ['Primary / commit','--primary'],['Primary disabled','--primary-dis'],['Pill / badge','--pill-bg'],['Selection','--sel'],['Hover','--hover'],
    ]},
  ];

  const colorCards = groups.map(g => `
    <div class="tok-card">
      <h3>${g.title}<span class="mono">${g.mono}</span></h3>
      ${g.rows.map(([role,v]) => `
        <div class="swatch-row">
          <div class="t-dark sw" style="background:var(${v})"></div>
          <div class="sw-info"><div class="role">${role}</div><div class="val">var(${v})</div></div>
          <div class="sw-modes">
            <div class="t-dark mini" style="background:var(${v})" title="dark"></div>
            <div class="t-light mini" style="background:var(${v})" title="light"></div>
          </div>
        </div>`).join('')}
    </div>`).join('');

  const typeCard = `
    <div class="tok-card">
      <h3>Type scale<span class="mono">Hanken Grotesk · IBM Plex Mono</span></h3>
      <div class="type-row"><span class="spec">display / 64 / 800</span><span class="sample" style="font-size:30px;font-weight:800;letter-spacing:-.03em">See every agent</span></div>
      <div class="type-row"><span class="spec">section / 30 / 700</span><span class="sample" style="font-size:22px;font-weight:700;letter-spacing:-.02em">The diff object</span></div>
      <div class="type-row"><span class="spec">item title / 15 / 650</span><span class="sample" style="font-size:15px;font-weight:650">auth-service</span></div>
      <div class="type-row"><span class="spec">file path / 13 / mono</span><span class="sample" style="font-family:var(--font-mono);font-size:13px">src/session.ts</span></div>
      <div class="type-row"><span class="spec">metadata / 11 / mono</span><span class="sample" style="font-family:var(--font-mono);font-size:11px">+53 −0 · BOTH</span></div>
      <div class="type-row"><span class="spec">diff body / 12.5 / mono</span><span class="sample" style="font-family:var(--font-mono);font-size:12.5px">@@ -14,7 +14,9 @@</span></div>
      <div class="type-row"><span class="spec">hint / 14 / 400</span><span class="sample" style="font-size:14px;color:var(--doc-muted)">drag to pan · scroll to zoom</span></div>
    </div>`;

  const geoCard = `
    <div class="tok-card">
      <h3>Sizing &amp; geometry<span class="mono">px</span></h3>
      <div class="geo-row"><span>Card on canvas</span><span class="v">360 × 240  (3:2)</span></div>
      <div class="geo-row"><span>Diff object on canvas</span><span class="v">424 × 540  (portrait)</span></div>
      <div class="geo-row"><span>Item corner radius</span><span class="v">16</span></div>
      <div class="geo-row"><span>Terminal / panel inner radius</span><span class="v">9</span></div>
      <div class="geo-row"><span>Hairline / status stroke</span><span class="v">1 / 1.5</span></div>
      <div class="geo-row"><span>Bar padding · body padding</span><span class="v">13 · 16</span></div>
      <div class="geo-row"><span>File-list row height</span><span class="v">34</span></div>
      <div class="geo-row"><span>Icon button · commit button</span><span class="v">28 · 38</span></div>
    </div>`;

  const iconCard = `
    <div class="tok-card">
      <h3>Iconography<span class="mono">SF Symbols</span></h3>
      <div style="padding:16px;display:grid;grid-template-columns:repeat(2,1fr);gap:10px;font-size:12.5px;color:var(--doc-muted)">
        <div>New agent — <b style="color:var(--doc-text)">plus</b></div>
        <div>Activity — <b style="color:var(--doc-text)">bell</b></div>
        <div>Diff object — <b style="color:var(--doc-text)">arrow.triangle.branch</b></div>
        <div>Stage — <b style="color:var(--doc-text)">plus</b> / Unstage — <b style="color:var(--doc-text)">minus</b></div>
        <div>Discard — <b style="color:var(--doc-text)">trash</b></div>
        <div>Commit — <b style="color:var(--doc-text)">arrow.up.circle</b></div>
        <div>Fit — <b style="color:var(--doc-text)">arrow.down.right.and.arrow.up.left</b></div>
        <div>Dormant — <b style="color:var(--doc-text)">play.circle</b></div>
      </div>
    </div>`;

  root.className = 'tok-grid';
  root.innerHTML = colorCards + typeCard + geoCard + iconCard;
})();
