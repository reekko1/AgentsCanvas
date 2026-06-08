/* ============================================================
   AGENT CANVAS — full diff object (the one interactive tool)
   ============================================================ */
(function () {
  const root = document.getElementById('difftool');
  if (!root) return;

  // ---------- working-tree model ----------
  // a file can appear in BOTH staged & unstaged (partial staging)
  let files = [
    { path:'src/login.ts', status:'modified', added:31, removed:8, hasStaged:true, hasUnstaged:true, stagedStatus:'modified', unstagedStatus:'modified' },
    { path:'src/session.ts', status:'added', added:53, removed:0, hasStaged:true, hasUnstaged:false, stagedStatus:'added' },
    { path:'src/utils/jwt.ts', oldPath:'src/jwt.ts', status:'renamed', added:9, removed:3, hasStaged:true, hasUnstaged:false, stagedStatus:'renamed' },
    { path:'src/legacy.ts', status:'deleted', added:0, removed:4, hasStaged:false, hasUnstaged:true, unstagedStatus:'deleted' },
    { path:'README.md', status:'modified', added:6, removed:2, hasStaged:false, hasUnstaged:true, unstagedStatus:'modified' },
    { path:'.env.local', status:'untracked', added:4, removed:0, hasStaged:false, hasUnstaged:true, unstagedStatus:'untracked' },
  ];

  const diffs = {
    'src/login.ts': [
      ['meta','','diff --git a/src/login.ts b/src/login.ts'],
      ['meta','','index 8c1f2a3..b9e44d1 100644'],
      ['hunk','','@@ -14,7 +14,9 @@ export async function login(req) {'],
      ['ctx','14','  const { email, password } = req.body'],
      ['del','15','  const user = await db.user.find(email)'],
      ['add','14','  const user = await db.user.findByEmail(email)'],
      ['add','15','  if (!user) throw new AuthError("no such user")'],
      ['ctx','16','  const ok = await verify(password, user.hash)'],
      ['hunk','','@@ -28,4 +30,8 @@ export async function login(req) {'],
      ['ctx','30','  const token = sign({ uid: user.id })'],
      ['del','31','  return { token }'],
      ['add','33','  const session = await Session.create(user.id)'],
      ['add','34','  return { token, session: session.id }'],
      ['ctx','35','}'],
    ],
    'src/session.ts': [
      ['meta','','diff --git a/src/session.ts b/src/session.ts'],
      ['meta','','new file mode 100644'],
      ['hunk','','@@ -0,0 +1,12 @@'],
      ['add','1','import { randomUUID } from "crypto"'],
      ['add','2',''],
      ['add','3','export class Session {'],
      ['add','4','  static async create(uid: string) {'],
      ['add','5','    const id = randomUUID()'],
      ['add','6','    await redis.set(`s:${id}`, uid, "EX", 86400)'],
      ['add','7','    return { id, uid }'],
      ['add','8','  }'],
      ['add','9','}'],
    ],
  };
  function genericDiff(f) {
    const out = [['meta','',`diff --git a/${f.path} b/${f.path}`]];
    if (f.status==='renamed') out.push(['meta','',`rename from ${f.oldPath}`],['meta','',`rename to ${f.path}`]);
    if (f.status==='deleted') out.push(['meta','','deleted file mode 100644']);
    if (f.status==='untracked') out.push(['meta','','new file (untracked)']);
    out.push(['hunk','',`@@ -1,${Math.max(1,f.removed)} +1,${Math.max(1,f.added)} @@`]);
    for (let i=0;i<f.removed;i++) out.push(['del', String(i+1), '  // removed line '+(i+1)]);
    for (let i=0;i<Math.min(f.added,6);i++) out.push(['add', String(i+1), '  // added line '+(i+1)]);
    return out;
  }

  const FT = { added:'A', modified:'M', deleted:'D', renamed:'R', untracked:'U' };
  let selected = 'src/login.ts';
  let view = 'diff'; // diff | clean | norepo | loading
  let committed = false;

  function splitPath(p){ const i=p.lastIndexOf('/'); return i<0?['',p]:[p.slice(0,i+1),p.slice(i+1)]; }
  function totals(){ let a=0,d=0; files.forEach(f=>{a+=f.added;d+=f.removed;}); return {a,d}; }

  function fileRow(f, side) {
    const st = side==='staged' ? f.stagedStatus : f.unstagedStatus;
    const [dir,name] = splitPath(f.path);
    const both = f.hasStaged && f.hasUnstaged;
    const ren = f.status==='renamed' ? `<span class="renamed-from">${splitPath(f.oldPath)[1]} → </span>` : '';
    const act = side==='staged'
      ? `<button data-act="unstage" title="Unstage"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"><path d="M5 12h14"/></svg></button>`
      : `<button data-act="stage" title="Stage"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4"><path d="M12 5v14M5 12h14"/></svg></button>
         <button data-act="discard" class="danger" title="Discard"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14"/></svg></button>`;
    return `<div class="frow ${selected===f.path?'sel':''}" data-path="${f.path}" data-side="${side}">
      <span class="ft ft-${FT[st]}">${FT[st]}</span>
      <span class="path">${ren}<span class="dir">${dir}</span>${name}</span>
      ${both?'<span class="both-pill">BOTH</span>':''}
      <span class="counts">${f.added?`<span class="a">+${f.added}</span>`:''}${f.removed?`<span class="d">−${f.removed}</span>`:''}</span>
      <span class="facts">${act}</span>
    </div>`;
  }

  function diffPane() {
    if (view==='loading') return `<div class="dt-edge"><div class="spin"></div><h4>Loading diff…</h4><p>Reading the working tree for this file.</p></div>`;
    const f = files.find(x=>x.path===selected);
    if (!f) return `<div class="dt-edge"><svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><path d="M9 11l3 3 8-8"/><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/></svg><h4>Select a file</h4><p>Pick a changed file on the left to see its unified diff.</p></div>`;
    const lines = (diffs[selected] || genericDiff(f)).map(([t,g,s]) =>
      `<div class="dl ${t}"><span class="gut">${g}</span><span class="txt">${escapeHtml(s)||' '}</span></div>`).join('');
    const [dir,name] = splitPath(f.path);
    return `<div class="dt-difhead">
        <span class="ft ft-${FT[f.status]}">${FT[f.status]}</span>
        <span class="fpath"><span class="dir">${dir}</span>${name}</span>
        <span class="chip">+${f.added} −${f.removed}</span>
        <span class="chip">${f.status}</span>
        <span class="right"></span>
      </div><div class="diffbody">${lines}</div>`;
  }

  function render() {
    const t = totals();
    if (view==='norepo') { root.innerHTML = edge('norepo'); return; }
    if (view==='clean')  { root.innerHTML = edge('clean'); return; }

    const staged = files.filter(f=>f.hasStaged);
    const unstaged = files.filter(f=>f.hasUnstaged);
    const stagedCount = staged.length;
    const msg = (document.getElementById('commitMsg')?.value || '').trim();
    const canCommit = stagedCount>0 && msg.length>0;

    root.innerHTML = `
      <div class="dt-left">
        <div class="dt-files" id="fileScroll">
          <div class="dt-grouphead">Staged <span class="gcount">${stagedCount}</span>
            <span class="bulk"><button data-bulk="unstageAll">Unstage all</button></span></div>
          ${staged.length? staged.map(f=>fileRow(f,'staged')).join('') : '<div class="frow" style="color:var(--text-muted);cursor:default;font-family:var(--font-mono);font-size:12px">— nothing staged —</div>'}
          <div class="dt-grouphead">Unstaged <span class="gcount">${unstaged.length}</span>
            <span class="bulk"><button data-bulk="stageAll">Stage all</button><button data-bulk="discardAll" class="danger">Discard all</button></span></div>
          ${unstaged.map(f=>fileRow(f,'unstaged')).join('')}
        </div>
        <div class="dt-commit">
          <textarea id="commitMsg" placeholder="Commit message…">${msg}</textarea>
          <div class="commit-row">
            <button class="commit-btn" id="commitBtn" ${canCommit?'':'disabled'}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3.2"/><path d="M12 3v6M12 15v6"/></svg>
              Commit ${stagedCount?`${stagedCount} file${stagedCount>1?'s':''}`:''}
            </button>
          </div>
          <div class="commit-hint" style="margin-top:7px">${canCommit?`+${t.a} −${t.d} ready on <b style="color:var(--text)">main</b>`:(stagedCount===0?'Stage at least one change to commit':'Enter a message to commit')}</div>
        </div>
      </div>
      <div class="dt-right">${diffPane()}</div>`;

    wire();
  }

  function edge(kind) {
    if (kind==='norepo') return `<div class="dt-edge" style="grid-column:1/-1"><svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="12" cy="12" r="9"/><path d="M12 8v4M12 16h.01"/></svg><h4>Not a git repository</h4><p>This folder isn’t tracked by git. Run <code style="font-family:var(--font-mono)">git init</code> to start versioning it.</p></div>`;
    return `<div class="dt-edge" style="grid-column:1/-1"><svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M20 6L9 17l-5-5"/></svg><h4>No changes</h4><p>Clean working tree — every file matches the last commit.</p></div>`;
  }

  function wire() {
    root.querySelectorAll('.frow[data-path]').forEach(r => {
      r.addEventListener('click', (e) => {
        if (e.target.closest('.facts')) return;
        selected = r.dataset.path; render();
      });
    });
    root.querySelectorAll('.facts button').forEach(b => {
      b.addEventListener('click', (e) => {
        e.stopPropagation();
        const row = b.closest('.frow'); const path = row.dataset.path; const act = b.dataset.act;
        const f = files.find(x=>x.path===path);
        if (act==='stage') { f.hasStaged=true; f.stagedStatus=f.status; f.hasUnstaged=false; }
        else if (act==='unstage') { f.hasUnstaged=true; f.unstagedStatus=f.status; f.hasStaged=false; }
        else if (act==='discard') { confirmDiscard(`Discard changes in ${path}?`, ()=>{ files=files.filter(x=>x.path!==path); if(selected===path)selected=files[0]?.path; afterMutate(); }); return; }
        afterMutate();
      });
    });
    root.querySelectorAll('[data-bulk]').forEach(b => {
      b.addEventListener('click', () => {
        const k=b.dataset.bulk;
        if (k==='stageAll') files.forEach(f=>{if(f.hasUnstaged){f.hasStaged=true;f.stagedStatus=f.status;f.hasUnstaged=false;}});
        else if (k==='unstageAll') files.forEach(f=>{if(f.hasStaged){f.hasUnstaged=true;f.unstagedStatus=f.status;f.hasStaged=false;}});
        else if (k==='discardAll') { confirmDiscard('Discard all changes in the working tree?', ()=>{ view='clean'; afterMutate(); }); return; }
        afterMutate();
      });
    });
    const ta = document.getElementById('commitMsg');
    if (ta) ta.addEventListener('input', () => {
      const t = totals(); const staged = files.filter(f=>f.hasStaged).length;
      const can = staged>0 && ta.value.trim().length>0;
      const btn = document.getElementById('commitBtn'); btn.disabled = !can;
      const hint = root.querySelector('.commit-hint');
      hint.innerHTML = can?`+${t.a} −${t.d} ready on <b style="color:var(--text)">main</b>`:(staged===0?'Stage at least one change to commit':'Enter a message to commit');
    });
    document.getElementById('commitBtn')?.addEventListener('click', () => {
      if (document.getElementById('commitBtn').disabled) return;
      files = files.filter(f=>!f.hasStaged || (f.hasStaged=false, f.hasUnstaged));
      files = files.filter(f=>f.hasUnstaged);
      if (files.length===0) view='clean';
      selected = files[0]?.path; render();
      flash('Committed ✓');
    });
  }
  function afterMutate(){ if (files.length===0 && view==='diff') view='clean'; render(); }

  function escapeHtml(s){ return s.replace(/[&<>]/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c])); }

  // confirmation sheet
  function confirmDiscard(title, onYes) {
    const host = document.getElementById('diffWindow') || root.closest('.mac') || root.parentElement;
    const wrap = document.createElement('div'); wrap.className='sheet-wrap';
    const target = title.toLowerCase().includes('all') ? 'every change in this working tree' : title.replace('Discard changes in ','').replace('?','');
    wrap.innerHTML = `<div class="sheet-scrim"></div>
      <div class="sheet">
        <div class="sicon"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4M12 17h.01"/></svg></div>
        <h3>Discard changes?</h3>
        <p>This permanently reverts <code>${escapeHtml(target)}</code>. This can’t be undone.</p>
        <div class="sheet-btns"><button class="cancel">Cancel</button><button class="destroy">Discard</button></div>
      </div>`;
    host.appendChild(wrap);
    wrap.querySelector('.cancel').onclick = ()=>wrap.remove();
    wrap.querySelector('.sheet-scrim').onclick = ()=>wrap.remove();
    wrap.querySelector('.destroy').onclick = ()=>{ wrap.remove(); onYes(); };
  }

  function flash(t) {
    const f = document.createElement('div'); f.textContent=t;
    f.style.cssText='position:absolute;left:50%;bottom:18px;transform:translateX(-50%);background:var(--st-done);color:oklch(0.2 0.04 150);font-weight:700;font-size:12px;padding:7px 14px;border-radius:999px;z-index:95;font-family:var(--font-ui);box-shadow:var(--shadow)';
    (document.getElementById('diffWindow')||root.parentElement).appendChild(f);
    setTimeout(()=>f.remove(), 1600);
  }

  // edge-state switcher (doc control)
  document.querySelectorAll('[data-diffview]').forEach(b => {
    b.addEventListener('click', () => {
      document.querySelectorAll('[data-diffview]').forEach(x=>x.setAttribute('aria-pressed','false'));
      b.setAttribute('aria-pressed','true');
      view = b.dataset.diffview;
      if (view==='loading') { render(); /* stays in loading on right via diffPane */ }
      render();
    });
  });

  render();
  window.DiffTool = { render };
})();
