// Markdown-Ansicht der Vorschau-Kachel (26.09.2026). Rendert mit marked + KaTeX (+ Mermaid bei Bedarf), merkt je Block
// die Quelltext-Zeilen (data-l … data-e) und meldet Auswahl, ⌥-Klick, Links und Scrollstand an LatexTerm.
// Mathe-Erweiterungen nach MaTex (renderer.js): KaTeX rendert innerhalb der marked-Tokenizer, Markdown sieht die Formel nie.
// Sicherheit: rohes HTML nur als kleine Tag-Liste ohne Attribute (plus <img> mit src/alt/Maßen), Links öffnet nur die App.
(function () {
  'use strict';
  if (window.__md) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.latextermMarkdown;
  const post = m => { try { handler && handler.postMessage(m); } catch (e) {} };
  window.addEventListener('error', e => post({ kind: 'log', text: (e.message || 'Fehler') + (e.lineno ? ' (Zeile ' + e.lineno + ')' : '') }));

  const md = window.__md = {};
  let state = { text: '', view: 'rendered', dark: true, accent: '#29b8db' };

  // ---------------------------------------------------------------- Hilfen

  const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const escText = s => String(s).replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const newlines = s => { let n = 0; for (let i = 0; i < s.length; i++) if (s.charCodeAt(i) === 10) n++; return n; };
  const docRect = r => ({ x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height });

  function renderKatex(text, display) {
    if (typeof katex === 'undefined') return '<code>' + esc(text) + '</code>';
    try {
      return katex.renderToString(text, {
        displayMode: !!display, throwOnError: false, errorColor: '#e5534b', strict: 'ignore',
        // \href nur für Sprungmarken im Dokument (\eqref), nie nach draußen.
        trust: ctx => ctx.command === '\\href' && /^#/.test(ctx.url || ''),
        macros: { '\\eqref': '\\href{###1}{(\\text{#1})}' }
      });
    } catch (e) {
      return '<span class="math-error" title="' + esc(e.message) + '">' + esc(text) + '</span>';
    }
  }

  const mathExtensions = [
    { name: 'mathBlockDollar', level: 'block',
      start(src) { const i = src.indexOf('$$'); return i < 0 ? undefined : i; },
      tokenizer(src) { const m = /^\$\$([\s\S]+?)\$\$[ \t]*(?:\n|$)/.exec(src); if (m) return { type: 'mathBlockDollar', raw: m[0], text: m[1].trim() }; },
      renderer(t) { return '<div class="math-block">' + renderKatex(t.text, true) + '</div>\n'; } },
    { name: 'mathBlockBracket', level: 'block',
      start(src) { const i = src.indexOf('\\['); return i < 0 ? undefined : i; },
      tokenizer(src) { const m = /^\\\[([\s\S]+?)\\\][ \t]*(?:\n|$)/.exec(src); if (m) return { type: 'mathBlockBracket', raw: m[0], text: m[1].trim() }; },
      renderer(t) { return '<div class="math-block">' + renderKatex(t.text, true) + '</div>\n'; } },
    { name: 'mathEnvironment', level: 'block',
      start(src) { const i = src.indexOf('\\begin{'); return i < 0 ? undefined : i; },
      tokenizer(src) { const m = /^\\begin\{([a-zA-Z*]+)\}([\s\S]+?)\\end\{\1\}[ \t]*(?:\n|$)/.exec(src); if (m) return { type: 'mathEnvironment', raw: m[0], text: m[0].trim() }; },
      renderer(t) { return '<div class="math-block">' + renderKatex(t.text, true) + '</div>\n'; } },
    { name: 'mathInlineDollarPair', level: 'inline',
      start(src) { const i = src.indexOf('$$'); return i < 0 ? undefined : i; },
      tokenizer(src) { const m = /^\$\$([^\n]+?)\$\$/.exec(src); if (m) return { type: 'mathInlineDollarPair', raw: m[0], text: m[1].trim() }; },
      renderer(t) { return renderKatex(t.text, true); } },
    { name: 'mathInlineParen', level: 'inline',
      start(src) { const i = src.indexOf('\\('); return i < 0 ? undefined : i; },
      tokenizer(src) { const m = /^\\\(([\s\S]+?)\\\)/.exec(src); if (m) return { type: 'mathInlineParen', raw: m[0], text: m[1].trim() }; },
      renderer(t) { return renderKatex(t.text, false); } },
    { name: 'mathInlineDollar', level: 'inline',
      start(src) {
        let i = 0;
        while (i < src.length) {
          const idx = src.indexOf('$', i);
          if (idx < 0) return undefined;
          if (idx > 0 && src[idx - 1] === '\\') { i = idx + 1; continue; }
          if (src[idx + 1] === '$') { i = idx + 2; continue; }
          return idx;
        }
      },
      // Pandoc-Regel: kein Leerzeichen innen an den Rändern, keine Ziffer direkt danach ($5 und $10 bleiben Text).
      tokenizer(src) { const m = /^\$(?!\s)((?:\\.|[^\$\n\\])+?)(?<![\s\\])\$(?!\d)/.exec(src); if (m) return { type: 'mathInlineDollar', raw: m[0], text: m[1] }; },
      renderer(t) { return renderKatex(t.text, false); } }
  ];

  // Rohes HTML: nur harmlose Tags ohne Attribute; <img> neu gebaut (src/alt/width/height); Kommentare fallen weg.
  const SAFE_TAG = /^<\/?(br|sub|sup|kbd|b|i|u|s|em|strong|mark|small|del|ins|details|summary|hr|p|div|span|center|abbr|cite|q|var|samp|code|pre|blockquote|dl|dt|dd|ul|ol|li)\s*\/?>$/i;
  function safeImg(tag) {
    try {
      const el = new DOMParser().parseFromString(tag, 'text/html').body.firstElementChild;
      if (!el || el.tagName !== 'IMG') return escText(tag);
      return imageHTML(el.getAttribute('src') || '', el.getAttribute('alt') || '', el.getAttribute('width'), el.getAttribute('height'));
    } catch (e) { return escText(tag); }
  }
  function safeHTML(html) {
    return String(html).replace(/<!--[\s\S]*?-->/g, '').split(/(<[^<>]*>)/g).map(part => {
      if (!part.startsWith('<')) return escText(part);
      if (SAFE_TAG.test(part)) return part.replace(/\s*\/>$/, '>');
      if (/^<img\s/i.test(part)) return safeImg(part);
      return escText(part);
    }).join('');
  }

  function imageHTML(src, alt, width, height) {
    src = String(src).trim();
    if (/^https?:/i.test(src)) {
      // Kein Netz in der Kachel — als Verweis zeigen statt still leer.
      return '<a class="net-img" href="' + esc(src) + '">🖼 ' + esc(alt || src) + '</a>';
    }
    if (/^file:\/\//i.test(src)) src = decodeURI(src.slice(7));
    if (!/^data:image\//i.test(src) && /^[a-z][a-z0-9+.-]*:/i.test(src)) return esc(alt);
    let size = '';
    if (width && /^\d+(%|px)?$/.test(width)) size += ' width="' + esc(width) + '"';
    if (height && /^\d+(px)?$/.test(height)) size += ' height="' + esc(height) + '"';
    return '<img src="' + esc(src) + '" alt="' + esc(alt) + '"' + size + ' onerror="this.classList.add(\'broken\')">';
  }

  const renderer = {
    html(token) { return safeHTML(token.text || token.raw || ''); },
    image(token) { return imageHTML(token.href || '', token.text || '', null, null); },
    code(token) {
      const lang = (token.lang || '').trim().split(/\s+/)[0].toLowerCase();
      if (lang === 'mermaid') return '<div class="mermaid" data-code="' + encodeURIComponent(token.text) + '"></div>';
      if (lang === 'math' || lang === 'latex' || lang === 'tex' || lang === 'katex') return '<div class="math-block">' + renderKatex(token.text, true) + '</div>';
      return '<pre><code' + (lang ? ' class="language-' + esc(lang) + '"' : '') + '>' + esc(token.text) + '</code></pre>';
    }
  };

  // Wie GitHub: weiche Umbrüche fließen (hart umbrochene Notizen lesen sich als Absatz), "  " am Zeilenende = <br>.
  const parser = new marked.Marked({ gfm: true, breaks: false });
  parser.use({ extensions: mathExtensions, renderer: renderer });

  // ---------------------------------------------------------------- Zeilen

  /// Zeile (0-basiert, ab `from`) in `lines`, deren Inhalt mit der ersten nichtleeren Zeile von `raw` übereinstimmt.
  function findLine(lines, raw, from) {
    const first = String(raw).split('\n').map(s => s.trim()).find(s => s.length);
    if (!first) return from;
    for (let i = from; i < lines.length; i++) if (lines[i].trim() === first) return i;
    for (let i = from; i < lines.length; i++) if (lines[i].includes(first)) return i;
    return from;
  }

  const span = raw => Math.max(0, newlines(String(raw).replace(/\n+$/, '')));

  /// Listenpunkte bekommen eigene Zeilen: <li> der Reihe nach ↔ token.items, verschachtelte Listen rekursiv.
  function annotateList(listEl, tok, lines, base) {
    if (!listEl) return;
    const lis = [...listEl.children].filter(c => c.tagName === 'LI');
    let cursor = base;
    tok.items.forEach((item, i) => {
      const li = lis[i];
      const at = findLine(lines, item.raw, cursor);
      const end = at + span(item.raw);
      if (li) { li.dataset.l = at + 1; li.dataset.e = end + 1; }
      cursor = at + 1;
      if (!li) return;
      const subLists = [...li.children].filter(c => c.tagName === 'UL' || c.tagName === 'OL');
      let sub = 0, subCursor = cursor;
      for (const child of item.tokens || []) {
        if (child.type !== 'list') continue;
        const subAt = findLine(lines, child.raw, subCursor);
        annotateList(subLists[sub++], child, lines, subAt);
        subCursor = subAt + span(child.raw) + 1;
      }
    });
  }

  function annotateTable(tableEl, first) {
    if (!tableEl) return;
    const head = tableEl.querySelector('thead tr');
    if (head) { head.dataset.l = first; head.dataset.e = first; }
    [...tableEl.querySelectorAll('tbody tr')].forEach((tr, i) => { tr.dataset.l = first + 2 + i; tr.dataset.e = first + 2 + i; });
  }

  // ---------------------------------------------------------------- Rendern

  function renderMarkdown(text) {
    const lines = text.split('\n');
    const out = [];
    const blocks = [];
    let body = text, offsetLines = 0;
    // Front Matter (--- … --- am Anfang) als eigener, leiser Block statt Trennlinie + Überschrift.
    const front = /^---[ \t]*\n([\s\S]*?\n)?---[ \t]*(\n|$)/.exec(text);
    if (front) {
      const n = newlines(front[0].replace(/\n$/, '')) + 1;
      out.push('<div class="blk front" data-l="1" data-e="' + n + '"><pre>' + esc(front[0].replace(/\n$/, '')) + '</pre></div>');
      body = text.slice(front[0].length);
      offsetLines = newlines(front[0]) + (front[2] ? 0 : 1);
    }
    let tokens;
    try { tokens = parser.lexer(body); } catch (e) {
      return '<div class="render-error">Markdown ließ sich nicht lesen: ' + esc(e.message) + '</div>';
    }
    let cursor = 0, line = offsetLines;
    for (const tok of tokens) {
      const found = body.indexOf(tok.raw, cursor);
      const start = found >= 0 ? found : cursor;
      line += newlines(body.slice(cursor, start));
      const lead = /^\n*/.exec(tok.raw)[0].length;
      const first = line + lead + 1;
      const last = line + lead + span(tok.raw.slice(lead)) + 1;
      cursor = start + tok.raw.length;
      line += newlines(tok.raw);
      if (tok.type === 'space' || tok.type === 'def') continue;
      const one = [tok];
      one.links = tokens.links;
      let html;
      try { html = parser.parser(one); } catch (e) { html = '<pre>' + esc(tok.raw) + '</pre>'; }
      const fenced = tok.type === 'code' && /^\s{0,3}(`{3,}|~{3,})/.test(tok.raw) ? ' data-f="1"' : '';
      out.push('<div class="blk" data-l="' + first + '" data-e="' + last + '" data-t="' + esc(tok.type) + '"' + fenced + '>' + html + '</div>');
      blocks.push({ tok, first });
    }
    return { html: out.join('\n'), blocks, lines };
  }

  function renderSource(text) {
    let inFence = false;
    const rows = text.split('\n').map((raw, i) => {
      let cls = '';
      if (/^\s{0,3}(`{3,}|~{3,})/.test(raw)) { cls = 'fence'; inFence = !inFence; }
      else if (inFence) cls = 'code';
      else if (/^\s{0,3}#{1,6}\s/.test(raw)) cls = 'h';
      else if (/^\s{0,3}>/.test(raw)) cls = 'quote';
      else if (/^\s{0,3}([-*_])(\s*\1){2,}\s*$/.test(raw)) cls = 'rule';
      let html;
      if (cls === 'code' || cls === 'fence') html = esc(raw);
      else {
        html = raw.split(/(`[^`]+`|\$\$[^$]+\$\$|\$(?!\s)[^$\n]*?[^\s\\$]\$(?!\d)|\[[^\]]*\]\([^)]*\)|^\s*(?:[-*+]|\d+[.)])\s(?:\[[ xX]\]\s)?)/).map((part, j) => {
          if (!part) return '';
          if (j % 2 === 0) return esc(part);
          if (part.startsWith('`')) return '<span class="s-code">' + esc(part) + '</span>';
          if (part.startsWith('$')) return '<span class="s-math">' + esc(part) + '</span>';
          if (part.startsWith('[')) return '<span class="s-link">' + esc(part) + '</span>';
          return '<span class="s-mark">' + esc(part) + '</span>';
        }).join('');
      }
      return '<span class="ln' + (cls ? ' s-' + cls : '') + '" data-l="' + (i + 1) + '" data-e="' + (i + 1) + '">' + (html || ' ') + '</span>';
    });
    return '<pre class="src">' + rows.join('') + '</pre>';
  }

  const slug = t => t.toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu, '').replace(/\s+/g, '-');

  function afterRender(result) {
    if (!result.blocks) return;
    const divs = [...document.querySelectorAll('#content > .blk:not(.front)')];
    result.blocks.forEach((b, i) => {
      const div = divs[i];
      if (!div) return;
      if (b.tok.type === 'list') annotateList(div.querySelector(':scope > ul, :scope > ol'), b.tok, result.lines, b.first - 1);
      if (b.tok.type === 'table') annotateTable(div.querySelector(':scope > table'), b.first);
    });
    const used = {};
    document.querySelectorAll('#content h1, #content h2, #content h3, #content h4, #content h5, #content h6').forEach(h => {
      let id = slug(h.textContent) || 'abschnitt';
      if (used[id] !== undefined) id += '-' + (++used[id]); else used[id] = 0;
      h.id = id;
    });
  }

  // ---------------------------------------------------------------- Mermaid (erst laden, wenn gebraucht)

  let mermaidLoading = null, mermaidTheme = null, mermaidBusy = false, mermaidAgain = false;
  function loadMermaid() {
    if (typeof mermaid !== 'undefined') return Promise.resolve();
    if (!mermaidLoading) {
      mermaidLoading = new Promise((ok, fail) => {
        const s = document.createElement('script');
        s.src = '/__lt/mermaid.min.js';
        s.onload = ok; s.onerror = () => fail(new Error('mermaid.min.js fehlt'));
        document.head.appendChild(s);
      });
    }
    return mermaidLoading;
  }
  async function renderMermaid() {
    const pending = [...document.querySelectorAll('.mermaid:not([data-done])')];
    if (!pending.length) return;
    if (mermaidBusy) { mermaidAgain = true; return; }
    mermaidBusy = true;
    try {
      await loadMermaid();
      const theme = state.dark ? 'dark' : 'default';
      if (mermaidTheme !== theme) {
        mermaid.initialize({ startOnLoad: false, theme, securityLevel: 'strict', fontFamily: '-apple-system, system-ui, sans-serif' });
        mermaidTheme = theme;
      }
      for (const d of document.querySelectorAll('.mermaid:not([data-done])')) {
        try {
          const { svg } = await mermaid.render('mm-' + Math.random().toString(36).slice(2, 10), decodeURIComponent(d.dataset.code || ''));
          d.innerHTML = svg;
        } catch (err) {
          d.innerHTML = '<div class="render-error">Mermaid: ' + esc(err && err.message || err) + '</div>';
          document.querySelectorAll('body > [id^="dmm-"], body > [id^="mm-"]').forEach(n => n.remove());
        }
        d.dataset.done = '1';
      }
    } catch (e) {
      post({ kind: 'log', text: String(e.message || e) });
    } finally {
      mermaidBusy = false;
      if (mermaidAgain) { mermaidAgain = false; renderMermaid(); }
    }
  }

  // ---------------------------------------------------------------- Lage und Sprünge

  const lineEls = () => [...document.querySelectorAll('#content [data-l]')];

  /// Das tiefste Element, dessen Zeilen `line` enthalten (sonst das letzte davor).
  function elementFor(line) {
    let best = null, before = null;
    for (const el of lineEls()) {
      const l = +el.dataset.l, e = +el.dataset.e || l;
      if (l <= line && line <= e) best = el;
      if (l <= line) before = el;
    }
    return best || before;
  }

  function visibleRange() {
    let first = null, last = null;
    for (const el of lineEls()) {
      if (el.children.length && el.querySelector('[data-l]')) continue;
      const r = el.getBoundingClientRect();
      if (r.bottom <= 2 || r.top >= innerHeight - 2) continue;
      const l = +el.dataset.l, e = +el.dataset.e || l;
      if (first === null || l < first) first = l;
      if (last === null || e > last) last = e;
    }
    return first === null ? null : [first, last];
  }

  function topAnchor() {
    if (scrollY < 4) return { top: true };
    for (const el of lineEls()) {
      if (el.querySelector('[data-l]')) continue;
      const r = el.getBoundingClientRect();
      if (r.bottom > 4) return { line: +el.dataset.l, offset: r.top };
    }
    return { y: scrollY };
  }

  function restoreAnchor(a) {
    if (!a) return;
    if (a.top) { scrollTo(0, 0); return; }
    if (a.line) {
      const el = elementFor(a.line);
      if (el) { scrollTo(0, el.getBoundingClientRect().top + scrollY - a.offset); return; }
    }
    if (a.y !== undefined) scrollTo(0, a.y);
  }

  function flash(el) {
    if (!el) return;
    el.classList.remove('lt-flash');
    void el.offsetWidth;
    el.classList.add('lt-flash');
    setTimeout(() => el.classList.remove('lt-flash'), 1800);
  }

  md.reveal = function (line, opts) {
    const el = elementFor(line);
    if (!el) return false;
    opts = opts || {};
    if (opts.align === 'top') scrollTo(0, el.getBoundingClientRect().top + scrollY - 12);
    else if (!opts.ifHidden || el.getBoundingClientRect().bottom < 0 || el.getBoundingClientRect().top > innerHeight) {
      el.scrollIntoView({ block: 'center' });
    }
    if (opts.flash !== false) flash(el);
    reportScroll();
    return true;
  };

  /// Zeile unter einer Textstelle: nächster Träger von data-l, dazu Zeilenumbrüche davor (weiche als \n im Text, harte als <br>).
  function lineAt(node, offset) {
    const el = node.nodeType === 1 ? node : node.parentElement;
    const holder = el && el.closest('[data-l]');
    if (!holder) return null;
    let line = +holder.dataset.l;
    const end = +holder.dataset.e || line;
    if (holder.dataset.l === holder.dataset.e) return line;
    const range = document.createRange();
    try { range.setStart(holder, 0); range.setEnd(node, offset); } catch (e) { return line; }
    const pre = el.closest('pre');
    if (pre && holder.contains(pre)) {
      const inner = document.createRange();
      try { inner.setStart(pre, 0); inner.setEnd(node, offset); } catch (e) { return line; }
      line += (holder.dataset.f ? 1 : 0) + newlines(inner.toString());
    } else {
      line += range.cloneContents().querySelectorAll('br').length + newlines(range.toString());
    }
    return Math.min(line, end);
  }

  // ---------------------------------------------------------------- Rückkanal

  let selTimer = null;
  document.addEventListener('selectionchange', () => {
    clearTimeout(selTimer);
    selTimer = setTimeout(() => {
      const s = getSelection();
      const text = s && !s.isCollapsed ? String(s).trim() : '';
      if (text.length < 1) { post({ kind: 'selection', text: '' }); return; }
      const range = s.getRangeAt(0);
      let first = lineAt(range.startContainer, range.startOffset);
      let last = lineAt(range.endContainer, range.endOffset);
      // Auswahl bis an den Anfang des nächsten Blocks (Dreifachklick) zählt nur bis zum vorigen.
      if (last !== null && first !== null && last > first && range.endOffset === 0) last -= 1;
      post({ kind: 'selection', text: text.slice(0, 4000), first, last: last === null ? first : Math.max(first || 0, last),
             rect: docRect(range.getBoundingClientRect()), lines: [...range.getClientRects()].slice(0, 80).map(docRect) });
    }, 200);
  });

  // ⌥ + Klick nimmt einen ganzen Block (Formel, Diagramm, Tabellenzeile, Listenpunkt).
  let hover = null;
  const hideHover = () => { if (hover) hover.style.display = 'none'; };
  const blockAt = (x, y) => { const el = document.elementFromPoint(x, y); return el && !el.classList.contains('lt-mark') ? el.closest('[data-l]') : null; };
  document.addEventListener('mousemove', e => {
    if (!e.altKey) { hideHover(); return; }
    const el = blockAt(e.clientX, e.clientY);
    if (!el) { hideHover(); return; }
    if (!hover) { hover = document.createElement('div'); hover.className = 'lt-hover'; document.body.appendChild(hover); }
    const r = docRect(el.getBoundingClientRect());
    Object.assign(hover.style, { display: 'block', left: r.x - 4 + 'px', top: r.y - 2 + 'px', width: r.w + 8 + 'px', height: r.h + 4 + 'px' });
  }, true);
  document.addEventListener('keyup', e => { if (e.key === 'Alt') hideHover(); }, true);
  window.addEventListener('blur', hideHover);

  document.addEventListener('click', e => {
    const a = e.target.closest && e.target.closest('a');
    if (e.altKey) {
      const el = blockAt(e.clientX, e.clientY);
      if (!el) return;
      e.preventDefault(); e.stopPropagation(); hideHover();
      getSelection().removeAllRanges();
      const r = el.getBoundingClientRect();
      post({ kind: 'element', first: +el.dataset.l, last: +el.dataset.e || +el.dataset.l,
             text: String(el.innerText || '').trim().slice(0, 1200), rect: docRect(r), lines: [docRect(r)] });
      return;
    }
    if (!a) return;
    e.preventDefault();
    const href = a.getAttribute('href') || '';
    if (href.startsWith('#')) {
      const id = decodeURIComponent(href.slice(1));
      const target = document.getElementById(id) || document.getElementById(slug(id)) || document.querySelector('[name="' + CSS.escape(id) + '"]');
      if (target) { target.scrollIntoView({ block: 'start' }); flash(target); }
      return;
    }
    post({ kind: 'link', href, url: a.href });
  }, true);

  md.showMarks = function (marks) {
    document.querySelectorAll('.lt-mark').forEach(n => n.remove());
    for (const m of marks) {
      const rects = m.lines && m.lines.length ? m.lines : [m.rect];
      rects.forEach((r, i) => {
        const d = document.createElement('div');
        d.className = 'lt-mark' + (m.pending ? ' pending' : '') + (m.kind === 'element' ? ' block' : '');
        Object.assign(d.style, { left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px' });
        document.body.appendChild(d);
        if (i === 0 && m.n) {
          const b = document.createElement('div');
          b.className = 'lt-mark lt-badge';
          b.textContent = m.n;
          Object.assign(b.style, { left: Math.max(0, r.x - 20) + 'px', top: r.y + 'px' });
          document.body.appendChild(b);
        }
      });
    }
  };

  let scrollTimer = null;
  function reportScroll() {
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => {
      const range = visibleRange();
      const a = topAnchor();
      post({ kind: 'scroll', first: range ? range[0] : null, last: range ? range[1] : null, top: a.top ? 1 : (a.line || null) });
    }, 120);
  }
  window.addEventListener('scroll', reportScroll, { passive: true });
  window.addEventListener('resize', reportScroll);

  // ---------------------------------------------------------------- Schnittstelle zur App

  /// { text, view: 'rendered'|'source', keep: bool, line: Zahl|null (Startzeile oben), reveal: Zahl|null, lines: Anzahl }
  md.render = function (o) {
    const anchor = o.keep ? topAnchor() : null;
    state.text = o.text;
    state.view = o.view === 'source' ? 'source' : 'rendered';
    const content = document.getElementById('content');
    document.body.classList.toggle('source', state.view === 'source');
    let result = {};
    if (state.view === 'source') {
      content.innerHTML = renderSource(o.text);
    } else {
      result = renderMarkdown(o.text);
      content.innerHTML = typeof result === 'string' ? result : result.html;
      afterRender(result);
    }
    if (anchor) restoreAnchor(anchor);
    else if (o.line && o.line > 1) md.reveal(o.line, { align: 'top', flash: false });
    else scrollTo(0, 0);
    if (o.reveal) md.reveal(o.reveal, { ifHidden: !!o.revealIfHidden });
    // Diagramme ändern die Höhe: danach Lage wiederherstellen — bzw. den Sprung wiederholen, nicht zurücknehmen.
    renderMermaid().then(() => {
      if (o.reveal) md.reveal(o.reveal, { ifHidden: true, flash: false });
      else if (anchor) restoreAnchor(anchor);
      reportScroll();
    });
    reportScroll();
    return true;
  };

  md.theme = function (t) {
    const root = document.documentElement.style;
    for (const [k, v] of Object.entries(t.vars || {})) root.setProperty('--' + k, v);
    state.accent = t.vars && t.vars.accent || state.accent;
    const dark = !!t.dark;
    document.documentElement.classList.toggle('dark', dark);
    if (dark !== state.dark) {
      state.dark = dark;
      document.querySelectorAll('.mermaid[data-done]').forEach(d => { d.removeAttribute('data-done'); d.innerHTML = ''; });
      renderMermaid();
    }
  };

  /// Lesbarer Text eines Blocks für Agenten: Formeln als TeX, Diagramme als Hinweis (innerText zerlegt KaTeX in Einzelzeichen).
  function plainText(el) {
    if (!el.querySelector('.katex, .mermaid')) return el.innerText;
    const copy = el.cloneNode(true);
    copy.style.cssText = 'position:absolute;left:-99999px;top:0;width:' + el.offsetWidth + 'px';
    copy.querySelectorAll('.katex').forEach(k => {
      const tex = k.querySelector('annotation[encoding="application/x-tex"]');
      const display = !!k.closest('.katex-display');
      k.replaceWith(document.createTextNode(tex ? (display ? '$$' + tex.textContent + '$$' : '$' + tex.textContent + '$') : k.textContent));
    });
    copy.querySelectorAll('.mermaid').forEach(m => m.replaceWith(document.createTextNode('[Mermaid-Diagramm]')));
    document.body.appendChild(copy);
    const text = copy.innerText;
    copy.remove();
    return text;
  }

  md.look = function () {
    const range = visibleRange();
    const parts = [];
    for (const el of document.querySelectorAll('#content > .blk, #content .ln')) {
      const r = el.getBoundingClientRect();
      if (r.bottom <= 0 || r.top >= innerHeight) continue;
      parts.push(plainText(el));
    }
    const text = parts.join('\n').slice(0, 6000);
    return JSON.stringify({ text, first: range ? range[0] : null, last: range ? range[1] : null,
      scrollY: Math.round(scrollY), height: Math.round(document.documentElement.scrollHeight), viewport: Math.round(innerHeight),
      errors: document.querySelectorAll('.render-error, .katex-error, .math-error').length });
  };

  md.scrollBy = function (dy) { scrollBy(0, dy); };
  md.lineAt = lineAt;
  post({ kind: 'ready' });
})();
