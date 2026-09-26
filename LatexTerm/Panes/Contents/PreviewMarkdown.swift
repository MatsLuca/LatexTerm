import AppKit
import WebKit
import UniformTypeIdentifiers

/// Markdown in der Vorschau-Kachel (26.09.2026, Plan claude-werkstatt `plans/preview-markdown_2026-09-26.md`): gerendert
/// wie MaTex (marked, KaTeX, Mermaid) oder als Quelltext mit Zeilennummern, nur lesen. Jeder Block kennt seine
/// Quelltext-Zeilen — Markieren schickt `plan.md:12–14` samt Auszug an die Session, `sync plan.md:42` springt hin.
/// Seite und Skripte: `markdown/` im Bundle; Logik der Kachel bleibt in `PreviewContent`.
nonisolated enum MarkdownView: String {
    case rendered, source

    init?(arg raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "rendered", "gerendert", "ansicht", "preview", "render": self = .rendered
        case "source", "quelle", "quelltext", "text", "raw", "roh": self = .source
        default: return nil
        }
    }

    var label: String { self == .rendered ? "gerendert" : "Quelle" }
}

nonisolated enum MarkdownFile {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    static func matches(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// Wie `\r\n`/`\r` → `\n` im Renderer; Zeilennummern zählen danach.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Erste geänderte Zeile (1-basiert) zwischen zwei Ständen, nil = gleich.
    static func firstChangedLine(_ old: String, _ new: String) -> Int? {
        guard old != new else { return nil }
        let a = old.split(separator: "\n", omittingEmptySubsequences: false)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 0..<min(a.count, b.count) where a[index] != b[index] { return index + 1 }
        return max(1, min(a.count, b.count) + (b.count > a.count ? 1 : 0))
    }

    /// Bilder dürfen aus dem Projekt kommen: nächster Ordner mit `.git` über der Datei (höchstens bis ~), sonst ihr Ordner.
    static func imageRoot(for file: URL) -> URL {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        var probe = folder
        while probe.path.hasPrefix(home + "/") {
            if FileManager.default.fileExists(atPath: probe.appendingPathComponent(".git").path) { return probe }
            probe = probe.deletingLastPathComponent()
        }
        return folder
    }

    /// Zeilen `first…last` als eingerückter Auszug (höchstens `limit` Zeilen, lange gekürzt).
    static func excerpt(_ text: String, first: Int, last: Int, limit: Int = 12) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard first >= 1, first <= lines.count else { return nil }
        let upper = min(max(last, first), lines.count)
        var rows = lines[(first - 1)..<min(upper, first - 1 + limit)].map { row -> String in
            row.count > 160 ? String(row.prefix(160)) + "…" : String(row)
        }
        while rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { rows.removeLast() }
        guard !rows.isEmpty else { return nil }
        if upper - first + 1 > limit { rows.append("… (+\(upper - first + 1 - limit) Zeilen)") }
        return rows.map { "   │ " + $0 }.joined(separator: "\n")
    }
}

/// Liefert die Markdown-Seite aus, ohne Netz: `…/<ordner>/.latexterm-markdown.html` = Hülle (Basis für relative Bilder),
/// `/__lt/<name>` = Skripte, Stile, Schriften aus dem Bundle, sonst Dateien unter `root` (Bilder des Projekts).
final class MarkdownServer: NSObject, WKURLSchemeHandler {
    static let scheme = "latexterm-md"
    static let shellName = ".latexterm-markdown.html"
    private static let assetPrefix = "/__lt/"
    private static let assetTypes: Set<String> = ["js", "css", "woff2", "ttf"]
    var root: URL

    init(root: URL) {
        self.root = root
    }

    static func shellURL(folder: URL) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = ""
        c.path = folder.standardizedFileURL.path + "/" + shellName
        return c.url!
    }

    static func isShell(_ url: URL?) -> Bool {
        url?.scheme == scheme && url?.lastPathComponent == shellName
    }

    static let shell = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src \(scheme): 'unsafe-inline'; \
    style-src \(scheme): 'unsafe-inline'; img-src \(scheme): data:; font-src \(scheme): data:">
    <link rel="stylesheet" href="/__lt/katex.min.css">
    <link rel="stylesheet" href="/__lt/markdown.css">
    <script src="/__lt/katex.min.js"></script>
    <script src="/__lt/marked.min.js"></script>
    </head><body><main id="content"></main>
    <script src="/__lt/markdown.js"></script>
    </body></html>
    """

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task) }
        let path = url.path
        if path.hasPrefix(Self.assetPrefix) {
            let name = String(path.dropFirst(Self.assetPrefix.count))
            guard !name.contains("/"), !name.hasPrefix("."), Self.assetTypes.contains((name as NSString).pathExtension.lowercased()),
                  let file = Bundle.main.url(forResource: name, withExtension: nil), let data = try? Data(contentsOf: file) else {
                return fail(task)
            }
            return serve(task, url: url, data: data, mime: Self.mime(for: file), cache: true)
        }
        if url.lastPathComponent == Self.shellName {
            return serve(task, url: url, data: Data(Self.shell.utf8), mime: "text/html; charset=utf-8", cache: false)
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard file.path.hasPrefix(base + "/"), let data = try? Data(contentsOf: file) else { return fail(task) }
        serve(task, url: url, data: data, mime: Self.mime(for: file), cache: false)
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mime(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    private func serve(_ task: WKURLSchemeTask, url: URL, data: Data, mime: String, cache: Bool) {
        let headers = ["Content-Type": mime, "Content-Length": "\(data.count)", "Cache-Control": cache ? "max-age=86400" : "no-store"]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}

/// Die WebView der Markdown-Ansicht samt Brücke: rendert, springt, zeigt Marken, meldet Auswahl/Links/Scrollstand.
final class MarkdownPreviewView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    static let handlerName = "latextermMarkdown"

    let webView: WKWebView
    private let server = MarkdownServer(root: URL(fileURLWithPath: NSHomeDirectory()))
    private var folder: URL?
    private var ready = false
    /// Was als Nächstes zu rendern ist, solange die Seite noch lädt.
    private var pending: [String: Any]?
    /// Letzter Auftrag — nach Absturz des Web-Prozesses oder Neuladen der Hülle wiederholen.
    private var last: [String: Any]?
    private var themeJSON: String?
    private(set) var hasContent = false
    var onSelection: (([String: Any]) -> Void)?
    var onElement: (([String: Any]) -> Void)?
    var onLink: ((String, URL?) -> Void)?
    var onScroll: ((Int?, Int?, Int?) -> Void)?
    var onLog: ((String) -> Void)?

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(server, forURLScheme: MarkdownServer.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init(frame: frame)
        config.userContentController.add(WeakScriptHandler(self), name: Self.handlerName)
        webView.navigationDelegate = self
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// Datei zeigen: Hülle nur neu laden, wenn der Ordner wechselt (relative Bilder), sonst nur neu rendern.
    func show(text: String, file: URL, view: MarkdownView, keep: Bool, line: Int? = nil, reveal: Int? = nil, revealIfHidden: Bool = false) {
        var job: [String: Any] = ["text": text, "view": view.rawValue, "keep": keep]
        if let line { job["line"] = line }
        if let reveal { job["reveal"] = reveal; job["revealIfHidden"] = revealIfHidden }
        let dir = file.deletingLastPathComponent().standardizedFileURL
        hasContent = true
        server.root = MarkdownFile.imageRoot(for: file)
        if dir != folder || !ready {
            if dir != folder {
                folder = dir
                ready = false
                webView.load(URLRequest(url: MarkdownServer.shellURL(folder: dir)))
            }
            job["keep"] = false
            pending = job
            return
        }
        run(job)
    }

    private func run(_ job: [String: Any]) {
        last = job
        call("render", job)
        hasContent = true
    }

    func reveal(line: Int, flash: Bool = true, top: Bool = false) {
        guard ready else { return }
        var options: [String: Any] = ["flash": flash]
        if top { options["align"] = "top" }
        call("reveal", line, options)
    }

    func clearSelection() {
        guard ready else { return }
        webView.evaluateJavaScript("getSelection().removeAllRanges()")
    }

    func showMarks(_ marks: [[String: Any]]) {
        guard ready else { return }
        call("showMarks", marks)
    }

    func scroll(by dy: Double) {
        guard ready else { return }
        call("scrollBy", dy)
    }

    func applyTheme(_ theme: TerminalTheme, accent: NSColor) {
        let bg = theme.background.usingColorSpace(.sRGB) ?? theme.background
        let luminance = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
        let dark = luminance < 0.5
        let fg = theme.foreground
        let vars: [String: String] = [
            "bg": Self.css(theme.background), "fg": Self.css(fg),
            "dim": Self.css(fg, alpha: 0.58), "faint": Self.css(fg, alpha: 0.2), "ground": Self.css(fg, alpha: dark ? 0.06 : 0.05),
            "heading": Self.css(fg.blended(withFraction: dark ? 0.25 : 0, of: .white) ?? fg),
            "accent": Self.css(accent), "link": Self.css(theme.blue), "code": Self.css(dark ? theme.yellow : theme.ansi[3]),
            "mark": Self.css(accent, alpha: 0.3)]
        let payload: [String: Any] = ["vars": vars, "dark": dark]
        themeJSON = Self.json(payload)
        webView.underPageBackgroundColor = theme.background.withAlphaComponent(1)
        if ready, let themeJSON { webView.evaluateJavaScript("window.__md && __md.theme(\(themeJSON))") }
    }

    /// Sichtbarer Text, Zeilenbereich, Seitenhöhe (für `preview_look`).
    func lookInfo(_ done: @escaping ([String: Any]) -> Void) {
        guard ready else { return done([:]) }
        webView.evaluateJavaScript("__md.look()") { value, _ in
            let info = (value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            done(info)
        }
    }

    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        webView.takeSnapshot(with: config) { image, _ in done(image) }
    }

    func teardown() {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
    }

    // MARK: Brücke

    private func call(_ function: String, _ args: Any...) {
        let list = args.map { Self.json($0) }.joined(separator: ",")
        webView.evaluateJavaScript("window.__md && __md.\(function)(\(list))") { [weak self] _, error in
            if let error { self?.onLog?("\(function): \(error.localizedDescription)") }
        }
    }

    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func css(_ color: NSColor, alpha: CGFloat = 1) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let (r, g, b) = (Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
        return alpha >= 1 ? String(format: "#%02x%02x%02x", r, g, b) : "rgba(\(r),\(g),\(b),\(String(format: "%.2f", Double(alpha))))"
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            ready = true
            if let themeJSON { webView.evaluateJavaScript("__md.theme(\(themeJSON))") }
            if let job = pending ?? last { pending = nil; run(job) }
        case "selection": onSelection?(body)
        case "element": onElement?(body)
        case "link": onLink?(body["href"] as? String ?? "", (body["url"] as? String).flatMap(URL.init(string:)))
        case "scroll": onScroll?(body["first"] as? Int, body["last"] as? Int, body["top"] as? Int)
        case "log": onLog?(body["text"] as? String ?? "")
        default: break
        }
    }

    // MARK: WKNavigationDelegate

    /// Nur die eigene Hülle lädt; Links behandelt die Kachel (Klick-Meldung aus der Seite), alles andere bleibt zu.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.targetFrame?.isMainFrame == true, MarkdownServer.isShell(action.request.url) {
            if action.navigationType == .reload { ready = false }
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated, let url = action.request.url {
            onLink?(url.absoluteString, url)
        }
        decisionHandler(.cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        pending = last
        if let folder { webView.load(URLRequest(url: MarkdownServer.shellURL(folder: folder))) }
    }
}
