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
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    private var background = NSColor.black

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        for view in [webView, findBar, pill] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        background = theme.background.withAlphaComponent(1)
        webView.underPageBackgroundColor = background
        findBar.applyTheme(theme)
        pill.applyTheme(theme)
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
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
