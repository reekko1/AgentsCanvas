/* ============================================================
   AGENT CANVAS — doc glue: theme toggle + section nav
   ============================================================ */
(function () {
  const body = document.body;
  const pinned = ['heroWindow', 'diffWindow', 'stateStageDark', 'emptyDark'];

  function setTheme(mode) {
    body.classList.toggle('light', mode === 'light');
    body.classList.toggle('dark', mode === 'dark');
    // hero + diff windows follow the global theme so they can be seen in both
    document.querySelectorAll('[data-follow-theme]').forEach(el => {
      el.classList.toggle('t-light', mode === 'light');
      el.classList.toggle('t-dark', mode === 'dark');
    });
    document.querySelectorAll('.theme-toggle button').forEach(b =>
      b.setAttribute('aria-pressed', b.dataset.mode === mode));
    try { localStorage.setItem('ac-theme', mode); } catch (e) {}
    // canvas may need a refit after surface metrics settle
    if (window.AgentCanvas) requestAnimationFrame(() => window.AgentCanvas.fitAll(0));
  }

  document.querySelectorAll('.theme-toggle button').forEach(b =>
    b.addEventListener('click', () => setTheme(b.dataset.mode)));

  let saved = 'dark';
  try { saved = localStorage.getItem('ac-theme') || 'dark'; } catch (e) {}
  setTheme(saved);

  // active section in nav
  const links = [...document.querySelectorAll('.topnav a')];
  const map = new Map(links.map(l => [l.getAttribute('href').slice(1), l]));
  const io = new IntersectionObserver((ents) => {
    ents.forEach(e => {
      if (e.isIntersecting) {
        links.forEach(l => l.style.color = '');
        const l = map.get(e.target.id);
        if (l) l.style.color = 'var(--doc-text)';
      }
    });
  }, { rootMargin: '-45% 0px -50% 0px' });
  document.querySelectorAll('section.block').forEach(s => io.observe(s));

  // floating tool dock — single active tool (Photoshop-style)
  const dock = document.getElementById('tooldock');
  if (dock) {
    dock.addEventListener('click', (e) => {
      const btn = e.target.closest('.tool');
      if (!btn) return;
      dock.querySelectorAll('.tool').forEach(t => t.classList.remove('active'));
      btn.classList.add('active');
    });
  }
})();
