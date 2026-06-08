/* ============================================================
   AGENT CANVAS — god-view canvas engine
   pan / zoom / fly-to + notification center
   ============================================================ */
(function () {
  // ---------- world data ----------
  const T = (cls, txt) => `<span class="${cls}">${txt}</span>`;
  const terms = {
    running: [
      `${T('vi','claude')} ${T('muted','› implementing rate limiter')}`,
      `${T('cy','●')} Editing ${T('grn','src/middleware/limit.ts')}`,
      `  ${T('muted','+ token bucket, 60 req/min window')}`,
      `${T('cy','●')} Running ${T('muted','npm test --silent')}`,
      `  ${T('grn','✓')} 14 passing ${T('muted','· 1.2s')}`,
      `${T('cy','⠹')} ${T('muted','thinking')}<span class="cursor"></span>`,
    ],
    running2: [
      `${T('vi','claude')} ${T('muted','› wiring now-playing widget')}`,
      `${T('cy','●')} Read ${T('grn','components/Player.tsx')}`,
      `${T('cy','●')} Editing ${T('grn','hooks/useStream.ts')}`,
      `  ${T('muted','reconnect w/ exp backoff')}`,
      `${T('cy','⠼')} ${T('muted','streaming patch')}<span class="cursor"></span>`,
    ],
    blocked: [
      `${T('vi','claude')} ${T('muted','› needs to install deps')}`,
      `${T('cy','●')} Plan ready · 6 files`,
      ``,
      `${T('am','⏸  Permission required')}`,
      `   Allow ${T('am','`npm install`')} in this folder?`,
      `   ${T('grn','❯ Yes')}   ${T('muted','No   Always allow')}`,
    ],
    done: [
      `${T('vi','claude')} ${T('muted','› fix flaky checkout test')}`,
      `${T('cy','●')} Edited ${T('grn','3 files')}`,
      `${T('grn','✓')} Done. Tests green, branch clean.`,
      ``,
      `${T('muted','waiting for your next message…')}`,
      `${T('muted','›')}<span class="cursor"></span>`,
    ],
    done2: [
      `${T('vi','claude')} ${T('muted','› add stripe webhook retry')}`,
      `${T('grn','✓')} Implemented & verified.`,
      `  ${T('muted','3 files · +118 −20')}`,
      ``,
      `${T('muted','›')}<span class="cursor"></span>`,
    ],
    error: [
      `${T('vi','claude')} ${T('muted','› scrape pricing pages')}`,
      `${T('cy','●')} Running ${T('muted','node crawl.js')}`,
      `${T('rd','✗ Error')} ${T('muted','ECONNREFUSED 127.0.0.1:5432')}`,
      `   at Socket.onError ${T('muted','(db.js:41)')}`,
      `${T('rd','agent halted')} ${T('muted','· tool failed')}`,
    ],
    idle: [
      `${T('vi','claude')} ${T('muted','› last run 2h ago')}`,
      `${T('muted','session resumed · no activity')}`,
      ``,
      `${T('muted','›')}<span class="cursor dim"></span>`,
    ],
  };

  const items = [
    // ── concern: checkout (~/work) ──────────────────────────────
    { id:'auth', kind:'card', title:'auth-service', dir:'~/work/', status:'blocked', frame:{x:88,y:144,w:360,h:240}, term:terms.blocked },
    { id:'pay', kind:'card', title:'payments', dir:'~/work/', status:'done', frame:{x:476,y:144,w:360,h:240}, term:terms.done2 },
    { id:'diffauth', kind:'diff', title:'auth-service', dir:'~/work/', frame:{x:88,y:412,w:300,h:320},
      stat:{a:84,d:12}, files:[['M','src/','login.ts',31,8],['A','src/','session.ts',53,0],['D','src/','legacy.ts',0,4]] },

    // ── concern: api platform (~/work) ──────────────────────────
    { id:'api', kind:'card', title:'api-gateway', dir:'~/work/', status:'running', frame:{x:956,y:144,w:360,h:240}, term:terms.running },
    { id:'web', kind:'card', title:'web-app', dir:'~/work/', status:'done', frame:{x:1344,y:144,w:360,h:240}, term:terms.done },
    { id:'docs', kind:'card', title:'docs-site', dir:'~/work/', status:'idle', frame:{x:956,y:412,w:360,h:240}, term:terms.idle },
    { id:'diffweb', kind:'diff', title:'web-app', dir:'~/work/', frame:{x:1344,y:412,w:300,h:320},
      stat:{a:118,d:20}, files:[['M','components/','Player.tsx',12,4],['A','components/','Visualizer.tsx',86,0],['M','hooks/','useStream.ts',20,16]] },

    // ── concern: side projects (~/side) ─────────────────────────
    { id:'lofi', kind:'card', title:'lofi-radio', dir:'~/side/', status:'running', frame:{x:88,y:888,w:360,h:240}, term:terms.running2 },
    { id:'scraper', kind:'card', title:'scraper', dir:'~/side/', status:'error', frame:{x:476,y:888,w:360,h:240}, term:terms.error },
    { id:'ml', kind:'card', title:'ml-pipeline', dir:'~/side/', status:'idle', dormant:true, frame:{x:864,y:888,w:360,h:240} },
  ];

  // ---------- frames: calm boundaries grouping cards by concern ----------
  const frames = [
    { id:'checkout', name:'checkout', sub:'shipping the new flow', x:60,  y:80,  w:804,  h:680, members:['auth','pay','diffauth'] },
    { id:'platform', name:'api platform', sub:'core services',     x:928, y:80,  w:804,  h:680, members:['api','web','docs','diffweb'] },
    { id:'side',     name:'side projects', sub:'~/side',           x:60,  y:824, w:1192, h:332, members:['lofi','scraper','ml'] },
  ];

  // notification timeline (newest first)
  const notifs = [
    { id:'auth', s:'blocked', name:'auth-service', msg:'Needs permission — `npm install`', time:'now', loud:true },
    { id:'scraper', s:'error', name:'scraper', msg:'ECONNREFUSED — agent halted', time:'1m', loud:true },
    { id:'pay', s:'done', name:'payments', msg:'Finished — waiting for input', time:'4m' },
    { id:'web', s:'done', name:'web-app', msg:'Finished — tests green', time:'9m' },
    { id:'api', s:'running', name:'api-gateway', msg:'Started — implementing limiter', time:'14m' },
    { id:'lofi', s:'running', name:'lofi-radio', msg:'Started — now-playing widget', time:'22m' },
  ];

  const stColor = { idle:'var(--st-idle)', running:'var(--st-running)', done:'var(--st-done)', blocked:'var(--st-blocked)', error:'var(--st-error)' };

  const surface = document.getElementById('surface');

  // ---------- render frames (behind cards) ----------
  function frameLoud(fr) {
    let blocked = false, error = false;
    for (const id of fr.members) {
      const it = items.find(i => i.id === id);
      if (!it) continue;
      if (it.status === 'blocked') blocked = true;
      if (it.status === 'error') error = true;
    }
    return blocked ? 'blocked' : error ? 'error' : null;
  }
  for (const fr of frames) {
    const el = document.createElement('div');
    el.className = 'frame';
    el.id = 'fr-' + fr.id;
    el.style.left = fr.x + 'px';
    el.style.top = fr.y + 'px';
    el.style.width = fr.w + 'px';
    el.style.height = fr.h + 'px';
    const loud = frameLoud(fr);
    const flag = loud
      ? `<span class="frame-flag" style="--fc:var(--st-${loud})">needs you</span>`
      : '';
    el.innerHTML = `<div class="frame-head" role="button" tabindex="0" title="Fit this group">
        <span class="frame-glyph"></span>
        <span class="frame-name">${fr.name}</span>
        <span class="frame-sub">· ${fr.sub}</span>
        <span class="frame-count">${fr.members.length}</span>
        ${flag}
      </div>`;
    surface.appendChild(el);
    const head = el.querySelector('.frame-head');
    head.addEventListener('click', () => fitTo(fr, 70));
    head.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fitTo(fr, 70); } });
  }

  // ---------- render items ----------
  function cardHTML(it) {
    if (it.kind === 'diff') {
      const rows = it.files.map(([t,d,f,a,del]) =>
        `<div class="mini-row"><span class="ftype ft-${t}">${t}</span><span class="fp">${f}</span><span class="ct ${a?'':'dim'}">${a?'+'+a:''} ${del?'−'+del:''}</span></div>`).join('');
      return `<div class="item-bar"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="var(--glyph)" stroke-width="2"><circle cx="12" cy="6" r="2.4"/><circle cx="6" cy="18" r="2.4"/><circle cx="18" cy="14" r="2.4"/><path d="M12 8v4a4 4 0 0 0 4 4M6 16V8"/></svg>
        <span class="item-name"><span class="dir">${it.dir}</span>${it.title}</span>
        <span class="diffstat"><span class="add">+${it.stat.a}</span><span class="del">−${it.stat.d}</span></span></div>
        <div class="mini-files">${rows}</div>`;
    }
    const body = it.dormant
      ? `<div class="dormant"><div class="play"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M8 5v14l11-7z"/></svg></div><div class="lbl">Tap to start agent</div><div class="sub">claude · ${it.dir}${it.title}</div></div>`
      : `<div class="term">${it.term.map(l=>`<div class="ln">${l}</div>`).join('')}</div>`;
    return `<div class="item-bar"><span class="bead"></span>
      <span class="item-name"><span class="dir">${it.dir}</span>${it.title}</span>
      <span class="status-word">${it.status}</span></div>${body}`;
  }

  for (const it of items) {
    const el = document.createElement('div');
    el.className = 'item' + (it.kind==='diff' ? ' diffitem' : '');
    el.id = 'it-' + it.id;
    if (it.kind === 'card') el.dataset.status = it.status;
    el.style.left = it.frame.x + 'px';
    el.style.top = it.frame.y + 'px';
    el.style.width = it.frame.w + 'px';
    el.style.height = it.frame.h + 'px';
    el.innerHTML = cardHTML(it);
    surface.appendChild(el);
    el.addEventListener('dblclick', () => flyTo(it, 1.15));
  }

  // ---------- camera ----------
  const vp = document.getElementById('viewport');
  let scale = 1, tx = 0, ty = 0;
  const MIN = 0.18, MAX = 1.6;
  const lvl = document.getElementById('zoomLvl');

  function apply(anim) {
    surface.style.transition = anim ? `transform ${anim}ms var(--ease-fly)` : 'none';
    surface.style.transform = `translate(${tx}px,${ty}px) scale(${scale})`;
    if (lvl) lvl.textContent = Math.round(scale * 100) + '%';
  }
  function bbox() {
    let x0=1e9,y0=1e9,x1=-1e9,y1=-1e9;
    const rects = [...frames.map(f=>({x:f.x,y:f.y,w:f.w,h:f.h})), ...items.map(i=>i.frame)];
    for (const r of rects) { x0=Math.min(x0,r.x); y0=Math.min(y0,r.y);
      x1=Math.max(x1,r.x+r.w); y1=Math.max(y1,r.y+r.h); }
    return {x0,y0,x1,y1,w:x1-x0,h:y1-y0};
  }
  // fit the camera to an arbitrary world rect (used by frame headers)
  function fitTo(r, pad) {
    const vr = vp.getBoundingClientRect(); pad = pad ?? 60;
    let s = Math.min((vr.width-pad*2)/r.w, (vr.height-pad*2)/r.h);
    s = Math.max(MIN, Math.min(MAX, s));
    scale = s;
    tx = vr.width/2 - (r.x + r.w/2)*scale;
    ty = vr.height/2 - (r.y + r.h/2)*scale;
    apply(640);
  }
  function fitAll(anim) {
    const r = vp.getBoundingClientRect(); const b = bbox(); const pad = 70;
    scale = Math.min((r.width-pad*2)/b.w, (r.height-pad*2)/b.h);
    scale = Math.max(MIN, Math.min(MAX, scale));
    tx = (r.width - b.w*scale)/2 - b.x0*scale;
    ty = (r.height - b.h*scale)/2 - b.y0*scale;
    apply(anim ?? 760);
  }
  function flyTo(it, target) {
    const r = vp.getBoundingClientRect();
    scale = Math.max(MIN, Math.min(MAX, target || 1.1));
    const cx = it.frame.x + it.frame.w/2, cy = it.frame.y + it.frame.h/2;
    tx = r.width/2 - cx*scale;
    ty = r.height/2 - cy*scale;
    apply(640);
    pingItem(it);
  }
  function pingItem(it) {
    const p = document.createElement('div');
    p.className = 'ping';
    const cc = stColorFor(it);
    p.style.borderColor = cc;
    p.style.left = it.frame.x+'px'; p.style.top = it.frame.y+'px';
    p.style.width = it.frame.w+'px'; p.style.height = it.frame.h+'px';
    surface.appendChild(p);
    setTimeout(()=>p.remove(), 750);
  }
  function stColorFor(it){ return it.kind==='diff' ? 'var(--primary)' : stColor[it.status]; }

  // wheel zoom toward cursor
  vp.addEventListener('wheel', (e) => {
    e.preventDefault();
    const r = vp.getBoundingClientRect();
    const mx = e.clientX - r.left, my = e.clientY - r.top;
    const factor = Math.exp(-e.deltaY * 0.0014);
    let ns = Math.max(MIN, Math.min(MAX, scale * factor));
    const k = ns/scale;
    tx = mx - (mx - tx) * k;
    ty = my - (my - ty) * k;
    scale = ns; apply();
  }, { passive:false });

  // drag pan
  let drag=null;
  vp.addEventListener('pointerdown', (e) => {
    if (e.target.closest('.notif') || e.target.closest('.zoom-hud') || e.target.closest('.frame-head')) return;
    drag = { x:e.clientX, y:e.clientY, tx, ty };
    vp.classList.add('grabbing'); vp.setPointerCapture(e.pointerId);
  });
  vp.addEventListener('pointermove', (e) => {
    if (!drag) return;
    tx = drag.tx + (e.clientX - drag.x);
    ty = drag.ty + (e.clientY - drag.y);
    apply();
  });
  vp.addEventListener('pointerup', (e) => { drag=null; vp.classList.remove('grabbing'); });
  vp.addEventListener('dblclick', (e) => { if (e.target === vp || e.target.id === 'surface' || e.target.classList.contains('dotfield')) fitAll(); });

  // zoom buttons
  document.getElementById('zIn').onclick = () => zoomBy(1.25);
  document.getElementById('zOut').onclick = () => zoomBy(0.8);
  document.getElementById('zFit').onclick = () => fitAll();
  function zoomBy(f){ const r=vp.getBoundingClientRect(); const mx=r.width/2,my=r.height/2;
    let ns=Math.max(MIN,Math.min(MAX,scale*f)); const k=ns/scale; tx=mx-(mx-tx)*k; ty=my-(my-ty)*k; scale=ns; apply(220); }

  // ---------- notification center ----------
  const list = document.getElementById('notifList');
  if (list) {
    list.innerHTML = notifs.map(n => `
      <div class="nrow ${n.loud?'loud':''}" data-s="${n.s}" data-target="${n.id}" style="--nd:${stColor[n.s]}">
        <span class="ndot"></span>
        <div class="nbody"><div class="nname">${n.name}<span class="ntag">${n.s}</span></div>
          <div class="nmsg">${n.msg}</div></div>
        <div class="ntime">${n.time}</div>
      </div>`).join('');
    list.querySelectorAll('.nrow').forEach(row => {
      row.addEventListener('click', () => {
        const it = items.find(i => i.id === row.dataset.target);
        if (it) flyTo(it, 1.2);
      });
    });
  }
  const notif = document.getElementById('notif');
  document.getElementById('notifHead')?.addEventListener('click', () => notif.classList.toggle('collapsed'));

  // init
  requestAnimationFrame(() => fitAll(0));
  window.addEventListener('resize', () => fitAll(0));
  window.AgentCanvas = { flyTo, fitAll, fitTo, items, frames };
})();
