import AppKit
import WebKit
import UniformTypeIdentifiers

/// Liefert Dateien EINES Ordners (samt Unterordnern) an die Web-Kachel aus — `latexterm-file:///abs/pfad`.
/// Außerhalb von `root` gibt es nichts (wie `allowingReadAccessTo`), kein Netz. HTML ohne eigene
/// Zeichensatz-Angabe (BOM oder `charset` in den ersten 1024 Bytes) geht als UTF-8 raus.
/// Jede ausgelieferte Datei meldet `onServe` (die Kachel beobachtet sie dann), jede fehlende `onMissing`
/// (landet im Konsolen-Protokoll für `web_look`). Kein Cache: nach einer Änderung kommt der neue Stand.
final class LocalFolderServer: NSObject, WKURLSchemeHandler {
    static let scheme = "latexterm-file"
    var root: URL?
    var onServe: ((URL) -> Void)?
    var onMissing: ((String) -> Void)?

    static func url(for file: URL) -> URL {
        var c = URLComponents(); c.scheme = scheme; c.host = ""; c.path = file.path
        return c.url!
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requested = task.request.url, let root else { return fail(task) }
        let file = URL(fileURLWithPath: requested.path).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard file.path == base || file.path.hasPrefix(base + "/") else {
            onMissing?("außerhalb des Kachel-Ordners gesperrt: \(file.path)")
            return fail(task)
        }
        guard let data = try? Data(contentsOf: file) else {
            onMissing?("Datei fehlt: \(file.path)")
            return fail(task)
        }
        let type = UTType(filenameExtension: file.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let isHTML = type?.conforms(to: .html) ?? false
        var headers = ["Content-Type": mime + (isHTML && !Self.declaresCharset(data) ? "; charset=utf-8" : ""),
                       "Content-Length": "\(data.count)",
                       "Cache-Control": "no-store"]
        // fetch()/ES-Module aus demselben Ordner brauchen CORS-Freigabe (eigenes Schema = eigener Ursprung je Datei).
        headers["Access-Control-Allow-Origin"] = "*"
        let response = HTTPURLResponse(url: requested, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
        onServe?(file)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }

    /// BOM oder `charset` in den ersten 1024 Bytes — dort muss die Angabe laut HTML-Standard stehen.
    static func declaresCharset(_ data: Data) -> Bool {
        let head = data.prefix(1024)
        if head.starts(with: [0xEF, 0xBB, 0xBF]) || head.starts(with: [0xFE, 0xFF]) || head.starts(with: [0xFF, 0xFE]) {
            return true
        }
        return String(decoding: head, as: UTF8.self).lowercased().contains("charset")
    }
}

/// Konsole der Seite für Agenten (`web_look`): console.*, Skriptfehler, abgelehnte Promises, nicht ladbare
/// Ressourcen. Läuft vor jedem Seiten-Skript; die Seite kann nur Text in dieses Protokoll schreiben, sonst nichts.
enum WebConsole {
    static let handlerName = "latextermConsole"

    static let script = """
    (function () {
      if (window.__latextermConsole) return; window.__latextermConsole = true;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) return;
      const show = a => {
        try {
          if (typeof a === 'string') return a;
          if (a instanceof Error) return a.stack ? a.message + '\\n' + a.stack : String(a);
          return JSON.stringify(a);
        } catch (e) { return String(a); }
      };
      const post = (level, args) => {
        try { handler.postMessage({ level: level, text: Array.from(args).map(show).join(' ').slice(0, 2000) }); } catch (e) {}
      };
      ['log', 'info', 'warn', 'error', 'debug'].forEach(level => {
        const original = console[level];
        console[level] = function () { post(level, arguments); return original.apply(console, arguments); };
      });
      window.addEventListener('error', e => {
        const t = e.target;
        if (t && t !== window && (t.src || t.href)) { post('error', ['Laden fehlgeschlagen: ' + (t.src || t.href)]); return; }
        const where = (e.filename || '').split('/').pop();
        post('error', [(e.message || 'Fehler') + (where ? ' (' + where + ':' + e.lineno + ')' : '')]);
      }, true);
      window.addEventListener('unhandledrejection', e => {
        const r = e.reason; post('error', ['Unbehandelte Promise-Ablehnung: ' + (r && (r.stack || r.message) || r)]);
      });
    })();
    """

    struct Entry {
        let level: String
        let text: String
        let time: Date
    }
}

/// Seitenskript der Web-Kachel (nur Hauptframe): meldet Textauswahl und ⌥-Klick auf ein Element (Rückkanal
/// „Stelle an die Session“), zeichnet gemerkte Stellen über die Seite und bietet lokalen Seiten (`latexterm-file:`)
/// `latexterm.send(text, {submit})` — ein Klick auf der Seite wird zum Prompt an die Session, der die Kachel gehört.
enum WebPageKit {
    static let handlerName = "latextermPage"

    static let script = """
    (function () {
      if (window.top !== window || window.__lt) return;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
      if (!handler) return;
      const lt = window.__lt = { accent: '#29b8db' };
      const post = m => { try { handler.postMessage(m); } catch (e) {} };
      const isOurs = n => n && n.nodeType === 1 && String(n.className || '').startsWith('__lt');
      const docRect = r => ({ x: r.left + scrollX, y: r.top + scrollY, w: r.width, h: r.height });
      const unique = s => { try { return document.querySelectorAll(s).length === 1; } catch (e) { return false; } };
      lt.selector = function (el) {
        if (el && el.nodeType !== 1) el = el.parentElement;
        const parts = [];
        while (el && el.nodeType === 1 && el !== document.documentElement) {
          if (el.id && unique('#' + CSS.escape(el.id))) { parts.unshift('#' + CSS.escape(el.id)); break; }
          let part = el.tagName.toLowerCase();
          const classes = [...el.classList].filter(c => !c.startsWith('__lt')).slice(0, 2);
          if (classes.length) part += '.' + classes.map(c => CSS.escape(c)).join('.');
          const parent = el.parentElement;
          if (parent) {
            const same = [...parent.children].filter(c => c.tagName === el.tagName);
            if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
          }
          parts.unshift(part);
          if (unique(parts.join(' > '))) break;
          el = parent;
        }
        return parts.join(' > ');
      };
      let timer = null;
      document.addEventListener('selectionchange', () => {
        clearTimeout(timer);
        timer = setTimeout(() => {
          const s = getSelection();
          const text = s && !s.isCollapsed ? String(s).trim() : '';
          if (text.length < 2) { post({ kind: 'selection', text: '' }); return; }
          const range = s.getRangeAt(0);
          const node = range.commonAncestorContainer;
          const el = node.nodeType === 1 ? node : node.parentElement;
          post({ kind: 'selection', text: text.slice(0, 2000), selector: lt.selector(el), tag: el ? el.tagName.toLowerCase() : '',
                 rect: docRect(range.getBoundingClientRect()), lines: [...range.getClientRects()].slice(0, 60).map(docRect) });
        }, 220);
      });
      let box = null;
      const hoverBox = () => {
        if (!box) {
          box = document.createElement('div');
          box.className = '__lt-hover';
          document.documentElement.appendChild(box);
        }
        box.style.cssText = 'position:absolute;pointer-events:none;z-index:2147483647;border-radius:3px;border:2px solid ' + lt.accent + ';background:' + lt.accent + '22';
        return box;
      };
      const hideBox = () => { if (box) box.style.display = 'none'; };
      document.addEventListener('mousemove', e => {
        if (!e.altKey) { hideBox(); return; }
        const el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || isOurs(el)) return;
        const r = docRect(el.getBoundingClientRect());
        Object.assign(hoverBox().style, { display: 'block', left: r.x + 'px', top: r.y + 'px', width: r.w + 'px', height: r.h + 'px' });
      }, true);
      document.addEventListener('keyup', e => { if (e.key === 'Alt') hideBox(); }, true);
      window.addEventListener('blur', hideBox);
      document.addEventListener('click', e => {
        if (!e.altKey) return;
        const el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || isOurs(el)) return;
        e.preventDefault(); e.stopPropagation(); hideBox();
        post({ kind: 'element', selector: lt.selector(el), tag: el.tagName.toLowerCase(),
               text: String(el.innerText || el.value || el.alt || el.title || '').trim().slice(0, 600),
               rect: docRect(el.getBoundingClientRect()), html: el.outerHTML.slice(0, 400) });
      }, true);
      lt.showMarks = function (marks) {
        document.querySelectorAll('.__lt-mark').forEach(n => n.remove());
        const a = lt.accent;
        for (const m of marks) {
          const rects = m.lines && m.lines.length ? m.lines : [m.rect];
          rects.forEach((r, i) => {
            const d = document.createElement('div');
            d.className = '__lt-mark';
            d.style.cssText = 'position:absolute;pointer-events:none;z-index:2147483646;border-radius:2px;left:' + r.x + 'px;top:' + r.y
              + 'px;width:' + r.w + 'px;height:' + r.h + 'px;background:' + a + (m.pending ? '26' : '40')
              + (m.kind === 'element' ? ';outline:2px ' + (m.pending ? 'dashed ' : 'solid ') + a : '');
            document.documentElement.appendChild(d);
            if (i === 0 && m.n) {
              const b = document.createElement('div');
              b.className = '__lt-mark';
              b.textContent = m.n;
              b.style.cssText = 'position:absolute;pointer-events:none;z-index:2147483647;left:' + Math.max(0, r.x - 19) + 'px;top:' + r.y
                + 'px;min-width:15px;height:15px;font:bold 10px -apple-system,sans-serif;line-height:15px;text-align:center;color:#000;border-radius:3px;background:' + a;
              document.documentElement.appendChild(b);
            }
          });
        }
      };
      if (location.protocol === 'latexterm-file:') {
        window.latexterm = Object.freeze({
          send: (text, options) => {
            // Nur als Folge eines echten Klicks/Tastendrucks — ein Skript allein darf der Session nichts schreiben.
            if (navigator.userActivation && !navigator.userActivation.isActive) {
              console.warn('latexterm.send ignoriert: nur direkt aus einem Klick oder Tastendruck erlaubt'); return false;
            }
            post({ kind: 'prompt', text: String(text).slice(0, 4000), submit: !(options && options.submit === false) });
            return true;
          }
        });
      }
    })();
    """
}

/// Seite bedienen für Agenten (`call act`, MCP `web_act`): Schritte nacheinander in der Seite, Ergebnis je Schritt.
/// Läuft per `callAsyncJavaScript` in der Welt der Seite (eval sieht deren Variablen).
enum WebActions {
    static let body = """
    const out = [];
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const find = s => { const e = document.querySelector(s); if (!e) throw new Error('kein Element für ' + s); return e; };
    const center = el => { el.scrollIntoView({ block: 'center', inline: 'center' }); const r = el.getBoundingClientRect();
      return { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, bubbles: true, cancelable: true, view: window, button: 0 }; };
    const mouse = (el, types) => { const init = center(el); for (const t of types)
      el.dispatchEvent(t.startsWith('pointer') ? new PointerEvent(t, Object.assign({ pointerType: 'mouse', isPrimary: true }, init)) : new MouseEvent(t, init)); };
    const setValue = (el, value) => {
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
        : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const show = v => { try { const j = JSON.stringify(v); return j === undefined ? String(v) : j.slice(0, 4000); } catch (e) { return String(v).slice(0, 4000); } };
    for (const step of steps) {
      const what = step.do;
      try {
        let note = '';
        if (what === 'click') { const el = find(step.selector); mouse(el, ['pointerover', 'mouseover', 'pointerdown', 'mousedown']); el.focus && el.focus();
          mouse(el, ['pointerup', 'mouseup']); el.click(); note = (el.innerText || el.value || el.tagName).toString().trim().slice(0, 60); }
        else if (what === 'hover') { mouse(find(step.selector), ['pointerover', 'mouseover', 'pointerenter', 'mouseenter', 'pointermove', 'mousemove']); }
        else if (what === 'type') { const el = step.selector ? find(step.selector) : document.activeElement;
          if (!el) throw new Error('kein Eingabefeld (selector angeben)'); el.focus();
          if (el.isContentEditable) { if (!step.append) el.textContent = ''; document.execCommand('insertText', false, step.text || ''); }
          else setValue(el, (step.append ? el.value : '') + (step.text || '')); }
        else if (what === 'press') { const el = step.selector ? find(step.selector) : (document.activeElement || document.body); const key = step.key || 'Enter';
          for (const t of ['keydown', 'keypress', 'keyup']) el.dispatchEvent(new KeyboardEvent(t, { key, code: key, bubbles: true, cancelable: true }));
          if (key === 'Enter' && el.form && el.tagName !== 'TEXTAREA') el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
        else if (what === 'select') { const el = find(step.selector); setValue(el, step.value); }
        else if (what === 'check') { const el = find(step.selector); const want = step.value === undefined ? true : !!step.value;
          if (el.checked !== want) el.click(); }
        else if (what === 'wait') { await sleep(Math.min(step.ms || 500, 10000)); }
        else if (what === 'wait_for') { const until = Date.now() + Math.min(step.ms || 5000, 15000); let el = null;
          while (Date.now() < until) { el = document.querySelector(step.selector);
            if (el && (!step.text || (el.innerText || '').includes(step.text))) break; el = null; await sleep(100); }
          if (!el) throw new Error('nicht erschienen: ' + step.selector + (step.text ? ' mit „' + step.text + '“' : '')); }
        else if (what === 'scroll') { if (step.selector) find(step.selector).scrollIntoView({ block: 'start' });
          else window.scrollTo(window.scrollX, step.y === 'bottom' ? document.documentElement.scrollHeight : (+step.y || 0)); }
        else if (what === 'eval') { const src = String(step.js || '');
          const fn = new Function('return (async () => {' + (/\\breturn\\b/.test(src) ? src : 'return (' + src + ')') + '})()');
          note = show(await fn()); }
        else throw new Error('unbekannter Schritt „' + what + '“');
        out.push({ ok: true, do: what, target: step.selector || '', note });
        await sleep(step.do === 'wait' ? 0 : 60);
      } catch (e) {
        out.push({ ok: false, do: what, target: step.selector || '', note: String(e && e.message || e) });
        break;
      }
    }
    return JSON.stringify(out);
    """
}

/// `WKScriptMessageHandler` hält sein Ziel stark — der Umweg vermeidet den Kreis WebView → Handler → Inhalt.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Wurzel der Web-Kachel: WebView, Suchleiste und Hinweis-Pille, Grund in Theme-Farbe (kein weißes
/// Aufblitzen beim Laden). Eigene Kürzel laufen über `onKeyEquivalent`, nur wenn der Fokus hier drin ist.
final class WebRootView: NSView {
    let webView: WKWebView
    let findBar = PreviewFindBar(placeholder: "Auf der Seite suchen")
    let pill = PreviewPill()
    let markBar = PreviewMarkBar()
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    private var background = NSColor.black

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        for view in [webView, markBar, findBar, pill] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        background = theme.background.withAlphaComponent(1)
        webView.underPageBackgroundColor = background
        findBar.applyTheme(theme)
        pill.applyTheme(theme)
        markBar.applyTheme(theme)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        findBar.layoutIn(bounds)
        pill.layoutIn(bounds)
        markBar.layoutIn(bounds)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
