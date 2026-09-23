import AppKit
import WebKit
import UniformTypeIdentifiers

/// Zweite App-Kachel (Kachel-Protokoll, Schritt 8): zeigt eine lokale HTML-Datei oder einen Dev-Server auf
/// localhost — Plots, Berichte, Mini-Apps, die ein Skript, ein Mod oder ein Agent erzeugt. `latexterm new-pane
/// --kind web --arg url=/pfad/datei.html` (oder `url=localhost:5173`); danach `send`-Aktionen (siehe `manual`).
///
/// Sicherheitsentscheid (Bauplan §6.8, erweitert 23.09.): nur lokale Dateien und `http(s)://localhost`/127.0.0.1.
/// Eine beliebige http-URL aus einem Hook-Kontext wäre ein neuer Kanal nach außen. Dateien liest die Kachel nur aus
/// dem Ordner der zuerst geöffneten Datei (`rootFolder`); Links nach draußen öffnet ein Klick im Standardbrowser.
///
/// Runde 23.09.: (1) „wie ein Browser“ — beobachtet alle geladenen Dateien, CSS ohne Neuladen, Scroll bleibt, Links,
/// Zurück/Vor, `_blank`, Dialoge, Upload, Downloads, ⌘± ⌘F ⌘R ⌘ü, Inspector. (2) Rückkanal wie die Vorschau: Text
/// markieren oder ⌥-Klick auf ein Element → ⇧⌘⏎ an die Session; lokale Seiten dürfen per `latexterm.send()` selbst
/// einen Prompt an die Eigentümer-Session schicken (`board`). (3) Agenten sehen (`web_look`, auch ganze Seite) und
/// bedienen (`web_act`) die Seite. Agenten-Teil: `WebContent+Agent.swift`.
final class WebContent: NSObject, PaneContent, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    static let kind = "web"
    static let displayName = "HTML-Datei in neuer Kachel …"
    static let manual = PaneKindManual(
        summary: "Zeigt eine lokale HTML-Datei oder einen Dev-Server auf localhost neben der Session (interaktive Plots, Berichte, "
            + "Mini-Apps, Vite/Jupyter/Streamlit). Kein Internet. Lädt von selbst neu, sobald die Seite oder eine ihrer Dateien sich "
            + "ändert (Scrollposition bleibt). Mit web_look siehst du die Seite samt Konsole, mit web_act bedienst du sie. "
            + "Eigene Seiten können per latexterm.send(\"text\") bei einem Klick einen Prompt an dich schicken "
            + "({submit: false} = nur einfügen). PDF und Bilder → open_preview.",
        args: [PaneKindArg(name: "url", summary: "absoluter Pfad der Datei (auch ~/…; Ordner = deren index.html) oder http://localhost:PORT",
                           required: true)],
        actions: [PaneKindAction(name: "reload", summary: "neu laden (passiert bei Dateiänderungen von selbst)"),
                  PaneKindAction(name: "load <pfad|localhost-url>", summary: "andere Seite in derselben Kachel zeigen"),
                  PaneKindAction(name: "back / forward", summary: "im Verlauf der Kachel zurück/vor"),
                  PaneKindAction(name: "scroll <top|bottom|px|selektor>", summary: "Ansicht verschieben (auch für den Nutzer)"),
                  PaneKindAction(name: "zoom <in|out|reset|Prozent>", summary: "Seitenzoom"),
                  PaneKindAction(name: "find <text>", summary: "auf der Seite suchen und hinspringen")])

    weak var delegate: PaneContentDelegate?
    let webView: WKWebView
    let root: WebRootView
    /// Gerade gezeigte Seite: Datei-URL (folgt lokalen Links) oder http://localhost-URL.
    private(set) var page: URL
    /// Ordner, den die Kachel lesen darf — der der zuerst geöffneten Datei; `load` setzt ihn neu.
    private(set) var rootFolder: URL
    private var titleObservation: NSKeyValueObservation?
    private let folderServer = LocalFolderServer()
    /// Seite und alle Dateien, die sie geladen hat → bei Änderung neu laden (CSS: nur austauschen).
    private var watchers: [String: FileWatcher] = [:]
    private var pendingChanges: Set<String> = []
    private var changeWork: DispatchWorkItem?
    /// localhost nicht erreichbar → alle 2 s wieder versuchen (Dev-Server startet noch).
    private var retryWork: DispatchWorkItem?
    private var waitingForServer = false
    /// Scrollposition über ein Neuladen hinweg.
    private var restoreScroll: (x: Double, y: Double)?
    /// Konsole der aktuellen Seite (für `web_look` und den Chip).
    var console: [WebConsole.Entry] = []
    /// Konsole je Seite: Zurück/Vor holt Seiten aus dem Verlaufs-Cache, ohne ihre Skripte neu laufen zu lassen.
    private var consoleByPage: [String: [WebConsole.Entry]] = [:]
    private var historyStep = false
    private var dialogsThisPage = 0
    private var findText = ""
    private var loadedOnce = false
    // Rückkanal (WebContent+Agent.swift)
    var marks: [WebMark] = []
    var pendingMark: WebMark?
    var sending = false
    var boardTimes: [Date] = []
    /// Läuft gerade `web_act`: `latexterm.send` geht dann nicht an die Session, sondern ins Ergebnis (sonst schriebe
    /// sich der Agent per Klick selbst Prompts — WebKit zählt App-Skripte als Nutzergeste).
    var acting = false
    var actSends: [String] = []

    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    required init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, allowed: ["url", "root", "zoom"], kind: Self.kind)
        guard let raw = args["url"] else {
            throw PaneArgsError("web braucht --arg url=/pfad/datei.html oder url=http://localhost:PORT")
        }
        page = try Self.resolve(raw)
        rootFolder = page.isFileURL ? page.deletingLastPathComponent() : URL(fileURLWithPath: NSHomeDirectory())
        if page.isFileURL, let rawRoot = args["root"] {
            let folder = URL(fileURLWithPath: (rawRoot as NSString).expandingTildeInPath).standardizedFileURL
            if page.path.hasPrefix(folder.path + "/") { rootFolder = folder }
        }
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.setURLSchemeHandler(folderServer, forURLScheme: LocalFolderServer.scheme)
        config.userContentController.addUserScript(
            WKUserScript(source: WebConsole.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(
            WKUserScript(source: WebPageKit.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Bis zum ersten Laden durchsichtig: kein weißes Aufblitzen vor dunklem Grund.
        webView.setValue(false, forKey: "drawsBackground")
        if let zoom = args["zoom"].flatMap(Double.init), zoom >= 0.3, zoom <= 5 { webView.pageZoom = zoom }
        root = WebRootView(webView: webView)
        super.init()
        let handler = WeakScriptHandler(self)
        config.userContentController.add(handler, name: WebConsole.handlerName)
        config.userContentController.add(handler, name: WebPageKit.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            self?.delegate?.contentStyleChanged()
        }
        folderServer.onServe = { [weak self] url in DispatchQueue.main.async { self?.watch(url) } }
        folderServer.onMissing = { [weak self] text in DispatchQueue.main.async { self?.log("resource", text) } }
        root.onKeyEquivalent = { [weak self] event in self?.keyEquivalent(event) ?? false }
        root.findBar.onSearch = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        root.findBar.onClose = { [weak self] in self?.closeFind() }
        root.markBar.onKeep = { [weak self] note in self?.keepPending(note: note) }
        root.markBar.onSend = { [weak self] note in self?.send(note: note, choose: NSEvent.modifierFlags.contains(.option)) }
        root.markBar.onDiscard = { [weak self] in self?.discardPending() }
        root.markBar.onClear = { [weak self] in self?.clearMarks() }
        load(page)
    }

    /// Menü „Kachel → HTML-Datei in neuer Kachel …“: Datei wählen, dann wie `--arg url=…`. Abbrechen = nil.
    static func menuArgs() -> [String: String]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.message = "HTML-Datei für die neue Kachel"
        return panel.runModal() == .OK ? panel.url.map { ["url": $0.path] } : nil
    }

    static func isLocalHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host) || host.hasSuffix(".localhost")
    }

    static func isLocalWeb(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        return isLocalHost(url.host)
    }

    /// Absoluter Pfad, `~/…`, `file://…` (Ordner → deren index.html) oder `http(s)://localhost…`
    /// (auch kurz `localhost:5173`). Relative Pfade nicht: die App kennt das Verzeichnis des Aufrufers nicht.
    static func resolve(_ raw: String) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.range(of: #"^(localhost|127\.0\.0\.1|0\.0\.0\.0)(:\d+)?(/|$)"#, options: .regularExpression) != nil {
            path = "http://" + path
        }
        if let url = URL(string: path), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                guard isLocalHost(url.host) else {
                    throw PaneArgsError("web zeigt nur localhost, nicht \(url.host ?? path) — Seiten aus dem Netz gehören in den Browser")
                }
                return url
            }
            guard scheme == "file" else {
                throw PaneArgsError("web lädt nur lokale Dateien und http://localhost, keine \(scheme)-Adressen")
            }
            path = url.path
        }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw PaneArgsError("web braucht einen absoluten Pfad (z. B. \"$PWD/\(raw)\") oder http://localhost:PORT, bekam „\(raw)“")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            throw PaneArgsError("Datei nicht gefunden: \(path)")
        }
        if isDir.boolValue {
            let index = (path as NSString).appendingPathComponent("index.html")
            guard FileManager.default.fileExists(atPath: index) else {
                throw PaneArgsError("Ordner ohne index.html: \(path)")
            }
            path = index
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    static func isHTML(_ url: URL) -> Bool { ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased()) }

    /// Anzeigename der Seite: Pfad mit ~ bzw. host:port/pfad.
    var pageLabel: String {
        if page.isFileURL { return (page.path as NSString).abbreviatingWithTildeInPath }
        var label = (page.host ?? "localhost") + (page.port.map { ":\($0)" } ?? "")
        if page.path.count > 1 { label += page.path }
        return label
    }

    /// Gerade eine lokale Datei über den Ordner-Server (nur dort gibt es `latexterm.send`).
    var showsLocalFile: Bool { webView.url?.scheme == LocalFolderServer.scheme }

    /// HTML läuft über `LocalFolderServer` (eigenes Schema): WebKit rät bei file:// ohne Zeichensatz-Angabe
    /// Latin-1 — aus „€“ wird „â‚¬“. Der Server liefert HTML ohne Angabe als UTF-8 und alles aus dem Ordner
    /// (Bilder, Skripte, CSS, fetch-Daten) mit und meldet jede Datei zum Beobachten. Andere Dateien über
    /// file://, localhost direkt.
    private func load(_ url: URL) {
        retryWork?.cancel()
        retryWork = nil
        page = url
        if url.isFileURL, !url.path.hasPrefix(rootFolder.path + "/") { rootFolder = url.deletingLastPathComponent() }
        resetWatchers()
        if url.isFileURL, Self.isHTML(url) {
            folderServer.root = rootFolder
            webView.load(URLRequest(url: LocalFolderServer.url(for: url)))
        } else if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: rootFolder)
        } else if let shown = webView.url, Self.sameServerPage(shown, url) {
            // Neu laden derselben Server-Seite: die Cache-Policy des Requests gilt nur fürs Dokument,
            // CSS/JS kämen weiter aus WebKits Speicher-Cache (Befund 23.09., http.server ohne Cache-Control).
            webView.reloadFromOrigin()
        } else {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
        delegate?.contentStyleChanged()
    }

    // MARK: Beobachten und Neuladen

    private func resetWatchers() {
        watchers.values.forEach { $0.stop() }
        watchers = [:]
        pendingChanges = []
        if page.isFileURL { watch(page) }
    }

    private func watch(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard watchers[path] == nil else { return }
        watchers[path] = FileWatcher(url: url) { [weak self] event in
            if event == .changed { self?.changed(path) }
        }
    }

    /// Änderungen kurz sammeln (ein Agent schreibt HTML, JS und CSS kurz nacheinander), dann einmal reagieren.
    private func changed(_ path: String) {
        pendingChanges.insert(path)
        changeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyChanges() }
        changeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func applyChanges() {
        let paths = pendingChanges
        pendingChanges = []
        guard !paths.isEmpty else { return }
        delegate?.contentHasNews()
        let names = paths.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ", ")
        if paths.allSatisfy({ $0.lowercased().hasSuffix(".css") }), showsLocalFile {
            webView.evaluateJavaScript("""
            document.querySelectorAll('link[rel~="stylesheet"]').forEach(l => {
              const u = new URL(l.href); u.searchParams.set('latexterm', Date.now()); l.href = u.toString(); });
            """)
            root.pill.flash("↻ " + names + " · " + Self.clock.string(from: Date()))
            return
        }
        reloadKeepingScroll(announce: "↻ " + names + " · " + Self.clock.string(from: Date()))
    }

    /// `http://localhost:8000` und `…:8000/` sind dieselbe Seite (WebKit hängt den Slash an).
    private static func sameServerPage(_ a: URL, _ b: URL) -> Bool {
        func key(_ u: URL) -> String { var s = u.absoluteString; while s.hasSuffix("/") { s.removeLast() }; return s }
        return key(a) == key(b)
    }

    /// Neu laden, Scrollposition bleibt (bei HTML; PDF/Bild über file:// fangen oben an).
    func reloadKeepingScroll(announce: String? = nil) {
        webView.evaluateJavaScript("[window.scrollX, window.scrollY]") { [weak self] result, _ in
            guard let self else { return }
            if let xy = result as? [NSNumber], xy.count == 2, xy[0].doubleValue != 0 || xy[1].doubleValue != 0 {
                self.restoreScroll = (xy[0].doubleValue, xy[1].doubleValue)
            }
            self.load(self.page)
            if let announce { self.root.pill.flash(announce) }
        }
    }

    // MARK: PaneContent

    var view: NSView { root }
    var keyView: NSView { webView }
    /// Web-Seiten brauchen Breite (Layouts brechen unter ~360 pt um), ein Format haben sie nicht.
    var layoutPreference: LayoutPreference {
        LayoutPreference(aspect: nil, minWidth: 360, minHeight: 240, comfortWidth: nil)
    }

    var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        return page.isFileURL ? page.lastPathComponent : pageLabel
    }
    var chip: StatusChip? {
        let errors = console.filter { $0.level == "error" || $0.level == "resource" }.count
        if waitingForServer {
            return StatusChip(short: "wartet", tone: ThemeStore.shared.theme.yellow, pulsing: true,
                              tooltip: "\(pageLabel) — Server antwortet noch nicht, die Kachel versucht es alle 2 s")
        }
        guard errors == 0 else {
            return StatusChip(short: "\(errors) ⚠", tone: ThemeStore.shared.theme.red,
                              tooltip: "\(pageLabel) — \(errors) Fehler in der Konsole (Agenten sehen sie per web_look)")
        }
        return StatusChip(tone: ThemeStore.shared.accentColor, tooltip: pageLabel)
    }
    var directory: String? { page.isFileURL ? page.deletingLastPathComponent().path : nil }

    func applyTheme(_ theme: TerminalTheme) {
        root.applyTheme(theme)
        showMarksInPage()
    }

    func receive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let (command, rest) = Self.split(trimmed)
        switch command {
        case "reload": reloadKeepingScroll()
        case "back": webView.goBack()
        case "forward": webView.goForward()
        case "load":
            guard let url = try? Self.resolve(rest) else { return false }
            if url.isFileURL { rootFolder = url.deletingLastPathComponent() }
            load(url)
        case "scroll":
            guard !rest.isEmpty else { return false }
            scroll(to: rest)
        case "zoom":
            switch rest {
            case "in", "+": zoomStep(1)
            case "out", "-": zoomStep(-1)
            case "reset", "0", "100": zoomStep(0)
            default:
                guard let percent = Double(rest.replacingOccurrences(of: "%", with: "")), percent >= 30, percent <= 500 else { return false }
                setZoom(percent / 100)
            }
        case "find":
            guard !rest.isEmpty else { return false }
            root.findBar.show(text: rest)
            find(rest)
        default: return false
        }
        return true
    }

    static func split(_ text: String) -> (String, String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), text[space...].trimmingCharacters(in: .whitespaces))
    }

    /// `state` sofort; `look <png> [full]` und `act <png> <json>` asynchron: erst Bild(er), dann `<png>.json`.
    func call(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let (command, rest) = Self.split(trimmed)
        var reply: [String: Any]
        switch command {
        case "state":
            reply = state()
        case "look":
            let (path, options) = Self.split(rest)
            guard path.hasPrefix("/") else { throw PaneArgsError("look braucht einen absoluten PNG-Pfad") }
            look(writingTo: path, started: Date(), full: options.contains("full"))
            reply = ["pending": true, "meta": path + ".json"]
        case "act":
            let (path, json) = Self.split(rest)
            guard path.hasPrefix("/") else { throw PaneArgsError("act braucht einen absoluten PNG-Pfad") }
            guard let data = json.data(using: .utf8), let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let steps = spec["steps"] as? [[String: Any]], !steps.isEmpty else {
                throw PaneArgsError("act braucht JSON {\"steps\": [{\"do\": \"click\", \"selector\": \"#knopf\"}, …]}")
            }
            act(writingTo: path, steps: steps, look: spec["look"] as? Bool ?? true, full: spec["full"] as? Bool ?? false)
            reply = ["pending": true, "meta": path + ".json"]
        default:
            throw PaneArgsError("web versteht call state, look <png> [full], act <png> <json>")
        }
        let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func state() -> [String: Any] {
        var state: [String: Any] = ["file": page.isFileURL ? page.path : page.absoluteString,
                                    "zoom": Int((webView.pageZoom * 100).rounded()),
                                    "loading": webView.isLoading, "canGoBack": webView.canGoBack,
                                    "console": console.count, "marks": marks.count,
                                    "errors": console.filter { $0.level == "error" || $0.level == "resource" }.count]
        if page.isFileURL { state["root"] = rootFolder.path }
        if waitingForServer { state["waiting"] = true }
        if let title = webView.title, !title.isEmpty { state["title"] = title }
        return state
    }

    func handle(_ command: PaneCommand) -> Bool {
        guard command == .find else { return false }
        root.findBar.show(text: findText)
        root.window?.makeFirstResponder(root.findBar.field)
        return true
    }

    func willClose() {
        changeWork?.cancel()
        retryWork?.cancel()
        watchers.values.forEach { $0.stop() }
        watchers = [:]
        titleObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    /// Nach ⌥⌘R kommt die Kachel mit derselben Seite, demselben Lese-Ordner und Zoom wieder.
    func snapshotArgs() -> [String: String]? {
        var args = ["url": page.isFileURL ? page.path : page.absoluteString]
        if page.isFileURL, rootFolder != page.deletingLastPathComponent() { args["root"] = rootFolder.path }
        if abs(webView.pageZoom - 1) > 0.01 { args["zoom"] = String(format: "%.2f", webView.pageZoom) }
        return args
    }

    // MARK: Bedienung

    /// Kürzel der Web-Kachel (die Hülle hat ⌘T/⌘W/⌘1–9 vorher verteilt, ⌘⏎ fällt zu ihr durch).
    private func keyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers ?? ""
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        switch mods {
        case .command:
            switch key {
            case "+", "=": zoomStep(1)
            case "-": zoomStep(-1)
            case "0": zoomStep(0)
            case "r": reloadKeepingScroll(announce: "↻ neu geladen")
            case "g":
                guard root.findBar.isVisible else { return false }
                find(root.findBar.field.stringValue)
            case "[": webView.goBack()
            case "]": webView.goForward()
            default:
                // Deutsche Tastatur: [ liegt auf ⌥ — ⌘ü (Taste rechts neben P) geht auch zurück.
                // Vor: ⌘] bzw. Wischen; die Taste daneben ist auf Deutsch „+“ = Zoom.
                guard event.keyCode == 33 else { return false }
                webView.goBack()
            }
        case [.command, .shift]:
            if isReturn { send(note: root.markBar.note.stringValue, choose: false); return true }
            switch key.lowercased() {
            case "+", "=": zoomStep(1)
            case "g":
                guard root.findBar.isVisible else { return false }
                find(root.findBar.field.stringValue, backwards: true)
            default: return false
            }
        case [.command, .shift, .option]:
            guard isReturn else { return false }
            send(note: root.markBar.note.stringValue, choose: true)
        default: return false
        }
        return true
    }

    private func zoomStep(_ direction: Int) {
        let current = webView.pageZoom
        let target: CGFloat
        switch direction {
        case 0: target = 1
        case 1: target = Self.zoomSteps.first { $0 > current + 0.01 } ?? Self.zoomSteps.last!
        default: target = Self.zoomSteps.last { $0 < current - 0.01 } ?? Self.zoomSteps.first!
        }
        setZoom(target)
    }

    private func setZoom(_ zoom: CGFloat) {
        webView.pageZoom = zoom
        root.pill.flash("\(Int((zoom * 100).rounded())) %")
    }

    private func scroll(to spec: String) {
        let js: String
        switch spec {
        case "top": js = "window.scrollTo(0, 0)"
        case "bottom": js = "window.scrollTo(0, document.documentElement.scrollHeight)"
        default:
            if let y = Double(spec) {
                js = "window.scrollTo(window.scrollX, \(y))"
            } else {
                let selector = String(decoding: try! JSONSerialization.data(withJSONObject: [spec]), as: UTF8.self)
                js = "(function(){ try { const e = document.querySelector(\(selector)[0]); if (e) e.scrollIntoView({block: 'start'}); } catch (_) {} })()"
            }
        }
        webView.evaluateJavaScript(js)
    }

    private func find(_ text: String, backwards: Bool = false) {
        findText = text
        guard !text.isEmpty else { root.findBar.setCount(""); return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            guard let self else { return }
            guard result.matchFound else { self.root.findBar.setCount("keine Treffer"); return }
            let needle = String(decoding: try! JSONSerialization.data(withJSONObject: [text.lowercased()]), as: UTF8.self)
            let count = "(function(n){ const t = document.body ? document.body.innerText.toLowerCase() : ''; let c = 0, i = 0; "
                + "while ((i = t.indexOf(n, i)) >= 0) { c++; i += n.length; } return c; })(\(needle)[0])"
            self.webView.evaluateJavaScript(count) { value, _ in
                let total = (value as? Int) ?? 0
                self.root.findBar.setCount(total > 0 ? "\(total) Treffer" : "gefunden")
            }
        }
    }

    private func closeFind() {
        root.findBar.hide()
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
        root.window?.makeFirstResponder(webView)
    }

    // MARK: Nachrichten aus der Seite

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == WebConsole.handlerName, let level = body["level"] as? String, let text = body["text"] as? String {
            log(level, text)
        } else if message.name == WebPageKit.handlerName, message.frameInfo.isMainFrame {
            pageMessage(body)
        }
    }

    func log(_ level: String, _ text: String) {
        // Fehlende Datei aus dem Ordner meldet schon der Server — die Browser-Meldung dazu wäre doppelt.
        if level == "error", text.hasPrefix("Laden fehlgeschlagen: \(LocalFolderServer.scheme):") { return }
        let wasClean = !console.contains { $0.level == "error" || $0.level == "resource" }
        console.append(WebConsole.Entry(level: level, text: String(text.prefix(2000)), time: Date()))
        if console.count > 200 { console.removeFirst(console.count - 200) }
        if wasClean, level == "error" || level == "resource" { delegate?.contentStyleChanged() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        consoleByPage[page.absoluteString] = console
        console = []
        dialogsThisPage = 0
        pendingMark = nil
    }

    /// Link zu einer anderen Seite: Titel, Beobachter und Wiederherstellung folgen ihr.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let shown: URL
        if url.scheme == LocalFolderServer.scheme { shown = URL(fileURLWithPath: url.path).standardizedFileURL }
        else if url.isFileURL { shown = url.standardizedFileURL }
        else if Self.isLocalWeb(url) { shown = url }
        else { return }
        if shown != page {
            if page.isFileURL { watchers.removeValue(forKey: page.path)?.stop() }
            if shown.isFileURL != page.isFileURL || shown.host != page.host { marks = [] }
            page = shown
            if shown.isFileURL { watch(shown) }
        }
        if historyStep, console.isEmpty { console = consoleByPage[shown.absoluteString] ?? [] }
        historyStep = false
        if waitingForServer { waitingForServer = false }
        delegate?.contentStyleChanged()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !loadedOnce, webView.url?.scheme != "about" {
            loadedOnce = true
            // Ab jetzt wie ein Browser: Seiten ohne eigenen Hintergrund sind weiß, nicht durchsichtig.
            webView.setValue(true, forKey: "drawsBackground")
        }
        delegate?.contentStyleChanged()
        showMarksInPage()
        updateMarkUI()
        guard let scroll = restoreScroll else { return }
        restoreScroll = nil
        // Seiten, die per JS aufbauen, sind bei didFinish oft noch zu kurz — ein paar Frames lang nachsetzen.
        webView.evaluateJavaScript("""
        (function (x, y) { let n = 0;
          (function again() { window.scrollTo(x, y);
            if (Math.abs(window.scrollY - y) > 2 && n++ < 60) requestAnimationFrame(again); })();
          setTimeout(() => { if (Math.abs(window.scrollY - y) > 2) window.scrollTo(x, y); }, 600);
        })(\(scroll.x), \(scroll.y))
        """)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        // Abgelöst (neue Navigation) oder zum Download geworden: kein Fehler.
        if code == NSURLErrorCancelled || code == 102 { return }
        if !page.isFileURL {
            // Dev-Server startet noch oder ist weg: warten und es alle 2 s wieder versuchen.
            if !waitingForServer {
                waitingForServer = true
                log("resource", "\(pageLabel) nicht erreichbar: \(error.localizedDescription)")
                delegate?.contentStyleChanged()
            }
            showProblem("Warte auf \(pageLabel) …", detail: "Läuft der Server? Die Kachel versucht es alle 2 s von selbst.", logIt: false)
            let work = DispatchWorkItem { [weak self] in guard let self else { return }; self.load(self.page) }
            retryWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
            return
        }
        showProblem("„\(page.lastPathComponent)“ lässt sich nicht laden", detail: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let code = (error as NSError).code
        if code == NSURLErrorCancelled || code == 102 { return }
        log("error", "Laden abgebrochen: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("error", "WebKit-Prozess abgestürzt — neu geladen")
        load(page)
    }

    /// Fehlerseite im Theme; die Kachel beobachtet die Datei weiter und lädt, sobald sie wieder da ist.
    private func showProblem(_ title: String, detail: String, logIt: Bool = true) {
        let theme = ThemeStore.shared.theme
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let html = """
        <meta charset="utf-8"><body style="margin:0;height:100vh;display:grid;place-items:center;background:\(Self.css(theme.background));\
        color:\(Self.css(theme.foreground));font:13px 'JetBrains Mono NL',ui-monospace,monospace;text-align:center">\
        <div><div style="font-size:15px;margin-bottom:6px">\(esc(title))</div>\
        <div style="opacity:.6">\(esc(detail))<br>\(esc(pageLabel))</div></div>
        """
        webView.loadHTMLString(html, baseURL: nil)
        if logIt { log("resource", "\(title): \(detail)") }
    }

    static func css(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == true { historyStep = action.navigationType == .backForward }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if url.scheme == LocalFolderServer.scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data"
            || Self.isLocalWeb(url) {
            decisionHandler(.allow); return
        }
        if url.isFileURL {
            // Absoluter file://-Link auf eine HTML-Datei im Ordner: über den Server (UTF-8, Beobachten).
            let local = url.standardizedFileURL
            if action.targetFrame?.isMainFrame != false, Self.isHTML(local), local.path.hasPrefix(rootFolder.path + "/") {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: LocalFolderServer.url(for: local)))
                return
            }
            decisionHandler(.allow); return
        }
        // Geklickter Link nach draußen: Standardbrowser, die Kachel bleibt lokal.
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKDownloadDelegate — Downloads der Seite landen in ~/Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let name = suggestedFilename.isEmpty ? "download" : (suggestedFilename as NSString).lastPathComponent
        var target = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            target = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        completionHandler(target)
        root.pill.flash("⬇ " + target.lastPathComponent + " → Downloads", hold: 2.5)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        root.pill.flash("⚠ Download fehlgeschlagen", hold: 2.5)
        log("error", "Download fehlgeschlagen: \(error.localizedDescription)")
    }

    // MARK: WKUIDelegate — neue Fenster, Dialoge, Datei-Upload

    /// `target=_blank` / `window.open`: Lokales in derselben Kachel, Links nach draußen im Standardbrowser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = action.request.url else { return nil }
        if url.scheme == LocalFolderServer.scheme || url.isFileURL || Self.isLocalWeb(url) {
            webView.load(action.request)
        } else if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    /// Dialoge als Blatt am Fenster; eine Seite, die in Schleife fragt, bekommt nach fünf Stück keine mehr.
    private func dialog(_ message: String, buttons: [String], field: NSTextField? = nil, done: @escaping (Bool) -> Void) {
        dialogsThisPage += 1
        guard let window = root.window, dialogsThisPage <= 5 else {
            log("warn", "Dialog unterdrückt: \(message)")
            done(false)
            return
        }
        let alert = NSAlert()
        alert.messageText = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? page.lastPathComponent
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        if let field { alert.accessoryView = field; alert.window.initialFirstResponder = field }
        alert.beginSheetModal(for: window) { response in done(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        dialog(message, buttons: ["OK"]) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        dialog(message, buttons: ["OK", "Abbrechen"], done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        dialog(prompt, buttons: ["OK", "Abbrechen"], field: field) { ok in completionHandler(ok ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = root.window else { completionHandler(nil); return }
        panel.beginSheetModal(for: window) { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
}
