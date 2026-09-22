import AppKit
import WebKit
import UniformTypeIdentifiers

/// Zweite App-Kachel (Kachel-Protokoll, Schritt 8): zeigt eine lokale HTML-Datei — Plots,
/// Berichte, Mini-Apps, die ein Skript, ein Mod oder ein Agent erzeugt. `latexterm new-pane --kind web
/// --arg url=/pfad/datei.html`; danach `send --pane N 'load /anderer/pfad.html'`, `reload`, `back` …
///
/// Sicherheitsentscheid (Bauplan §6.8): nur lokale Dateien. Der Steuerkanal ist 0600 + Peer-Check,
/// aber Claude schreibt die Aufrufe — eine http-URL aus einem Hook-Kontext wäre ein neuer Kanal nach
/// außen. Gelesen werden darf nur der Ordner der zuerst geöffneten Datei (`root`); Links nach draußen
/// öffnet ein Klick im Standardbrowser, nie in der Kachel.
///
/// Runde 23.09. („wie ein Browser“): lädt neu, sobald sich die Seite ODER eine ihrer Dateien ändert (CSS
/// ohne Neuladen), Scrollposition bleibt auch bei Seiten, die per JS rendern; lokale Links, Zurück/Vor,
/// `target=_blank`, alert/confirm/prompt, Datei-Upload und Downloads gehen; ⌘± Zoom, ⌘F Suchen, ⌘R, Element
/// untersuchen. Agenten sehen die Seite per `call look` (MCP `web_look`): Bild, Text, Konsole.
final class WebContent: NSObject, PaneContent, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    static let kind = "web"
    static let displayName = "HTML-Datei in neuer Kachel …"
    static let manual = PaneKindManual(
        summary: "Zeigt eine lokale HTML-Datei neben der Session (interaktive Plots, Berichte, Mini-Apps). Nur Dateien auf dem Mac, "
            + "kein http; Skripte/CSS/Daten aus demselben Ordner gehen. Lädt von selbst neu, sobald die Seite oder eine ihrer Dateien "
            + "sich ändert (Scrollposition bleibt). Mit web_look siehst du die Seite samt Konsolenfehlern. PDF und Bilder → open_preview.",
        args: [PaneKindArg(name: "url", summary: "absoluter Pfad der Datei (auch ~/…); Ordner = deren index.html", required: true)],
        actions: [PaneKindAction(name: "reload", summary: "neu laden (passiert bei Änderungen von selbst)"),
                  PaneKindAction(name: "load <pfad>", summary: "andere lokale Datei in derselben Kachel zeigen"),
                  PaneKindAction(name: "back / forward", summary: "im Verlauf der Kachel zurück/vor"),
                  PaneKindAction(name: "scroll <top|bottom|px|#id>", summary: "Ansicht verschieben (auch für den Nutzer)"),
                  PaneKindAction(name: "zoom <in|out|reset|Prozent>", summary: "Seitenzoom"),
                  PaneKindAction(name: "find <text>", summary: "auf der Seite suchen und hinspringen")])

    weak var delegate: PaneContentDelegate?
    private let webView: WKWebView
    private let root: WebRootView
    /// Gerade gezeigte Seite (folgt lokalen Links).
    private(set) var file: URL
    /// Ordner, den die Kachel lesen darf — der der zuerst geöffneten Datei; `load` setzt ihn neu.
    private var rootFolder: URL
    private var titleObservation: NSKeyValueObservation?
    private let folderServer = LocalFolderServer()
    /// Seite und alle Dateien, die sie geladen hat → bei Änderung neu laden (CSS: nur austauschen).
    private var watchers: [String: FileWatcher] = [:]
    private var pendingChanges: Set<String> = []
    private var changeWork: DispatchWorkItem?
    /// Scrollposition über ein Neuladen hinweg.
    private var restoreScroll: (x: Double, y: Double)?
    /// Konsole der aktuellen Seite (für `web_look` und den Chip).
    private var console: [WebConsole.Entry] = []
    /// Konsole je Seite: Zurück/Vor holt Seiten aus dem Verlaufs-Cache, ohne ihre Skripte neu laufen zu lassen.
    private var consoleByPage: [String: [WebConsole.Entry]] = [:]
    private var historyStep = false
    private var dialogsThisPage = 0
    private var findText = ""
    private var loadedOnce = false
    private static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    required init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, allowed: ["url", "root", "zoom"], kind: Self.kind)
        guard let raw = args["url"] else {
            throw PaneArgsError("web braucht --arg url=/pfad/datei.html")
        }
        file = try Self.resolve(raw)
        rootFolder = file.deletingLastPathComponent()
        if let rawRoot = args["root"] {
            let folder = URL(fileURLWithPath: (rawRoot as NSString).expandingTildeInPath).standardizedFileURL
            if file.path.hasPrefix(folder.path + "/") { rootFolder = folder }
        }
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.setURLSchemeHandler(folderServer, forURLScheme: LocalFolderServer.scheme)
        config.userContentController.addUserScript(
            WKUserScript(source: WebConsole.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // Bis zum ersten Laden durchsichtig: kein weißes Aufblitzen vor dunklem Grund.
        webView.setValue(false, forKey: "drawsBackground")
        if let zoom = args["zoom"].flatMap(Double.init), zoom >= 0.3, zoom <= 5 { webView.pageZoom = zoom }
        root = WebRootView(webView: webView)
        super.init()
        config.userContentController.add(WeakScriptHandler(self), name: WebConsole.handlerName)
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
        load(file)
    }

    /// Menü „Kachel → HTML-Datei in neuer Kachel …“: Datei wählen, dann wie `--arg url=…`. Abbrechen = nil.
    static func menuArgs() -> [String: String]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.message = "HTML-Datei für die neue Kachel"
        return panel.runModal() == .OK ? panel.url.map { ["url": $0.path] } : nil
    }

    /// Absoluter Pfad, `~/…` oder `file://…` auf eine existierende Datei (Ordner → deren index.html).
    /// Relative Pfade nicht: die App kennt das Verzeichnis des Aufrufers nicht.
    static func resolve(_ raw: String) throws -> URL {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: path), let scheme = url.scheme?.lowercased() {
            guard scheme == "file" else {
                throw PaneArgsError("web lädt nur lokale Dateien, keine \(scheme)-Adressen")
            }
            path = url.path
        }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else {
            throw PaneArgsError("web braucht einen absoluten Pfad (z. B. \"$PWD/\(raw)\"), bekam „\(raw)“")
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

    private static func isHTML(_ url: URL) -> Bool { ["html", "htm", "xhtml"].contains(url.pathExtension.lowercased()) }

    /// HTML läuft über `LocalFolderServer` (eigenes Schema): WebKit rät bei file:// ohne Zeichensatz-Angabe
    /// Latin-1 — aus „€“ wird „â‚¬“. Der Server liefert HTML ohne Angabe als UTF-8 und alles aus dem Ordner
    /// (Bilder, Skripte, CSS, fetch-Daten) mit und meldet jede Datei zum Beobachten. Anderes über file://.
    private func load(_ url: URL) {
        file = url
        if !url.path.hasPrefix(rootFolder.path + "/") { rootFolder = url.deletingLastPathComponent() }
        resetWatchers()
        if Self.isHTML(url) {
            folderServer.root = rootFolder
            webView.load(URLRequest(url: LocalFolderServer.url(for: url)))
        } else {
            webView.loadFileURL(url, allowingReadAccessTo: rootFolder)
        }
        delegate?.contentStyleChanged()
    }

    // MARK: Beobachten und Neuladen

    private func resetWatchers() {
        watchers.values.forEach { $0.stop() }
        watchers = [:]
        pendingChanges = []
        watch(file)
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
        let names = paths.map { ($0 as NSString).lastPathComponent }.sorted().joined(separator: ", ")
        if paths.allSatisfy({ $0.lowercased().hasSuffix(".css") }), Self.isHTML(file) {
            webView.evaluateJavaScript("""
            document.querySelectorAll('link[rel~="stylesheet"]').forEach(l => {
              const u = new URL(l.href); u.searchParams.set('latexterm', Date.now()); l.href = u.toString(); });
            """)
            root.pill.flash("↻ " + names + " · " + Self.clock.string(from: Date()))
            return
        }
        reloadKeepingScroll(announce: "↻ " + names + " · " + Self.clock.string(from: Date()))
    }

    /// Neu von der Platte, Scrollposition bleibt (bei HTML; PDF/Bild über file:// fangen oben an).
    private func reloadKeepingScroll(announce: String? = nil) {
        webView.evaluateJavaScript("[window.scrollX, window.scrollY]") { [weak self] result, _ in
            guard let self else { return }
            if let xy = result as? [NSNumber], xy.count == 2, xy[0].doubleValue != 0 || xy[1].doubleValue != 0 {
                self.restoreScroll = (xy[0].doubleValue, xy[1].doubleValue)
            }
            self.load(self.file)
            if let announce { self.root.pill.flash(announce) }
        }
    }

    // MARK: PaneContent

    var view: NSView { root }
    var keyView: NSView { webView }
    var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        return file.lastPathComponent
    }
    var chip: StatusChip? {
        let path = (file.path as NSString).abbreviatingWithTildeInPath
        let errors = console.filter { $0.level == "error" || $0.level == "resource" }.count
        guard errors == 0 else {
            return StatusChip(short: "\(errors) ⚠", tone: ThemeStore.shared.theme.red,
                              tooltip: "\(path) — \(errors) Fehler in der Konsole (Agenten sehen sie per web_look)")
        }
        return StatusChip(tone: ThemeStore.shared.accentColor, tooltip: path)
    }
    var directory: String? { file.deletingLastPathComponent().path }

    func applyTheme(_ theme: TerminalTheme) {
        root.applyTheme(theme)
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
            rootFolder = url.deletingLastPathComponent()
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

    private static func split(_ text: String) -> (String, String) {
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), text[space...].trimmingCharacters(in: .whitespaces))
    }

    /// `state` sofort; `look <png>` asynchron: schreibt zuerst das Bild, dann `<png>.json` mit allem Übrigen.
    func call(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var reply: [String: Any]
        if trimmed == "state" {
            reply = state()
        } else if trimmed.hasPrefix("look ") {
            let path = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { throw PaneArgsError("look braucht einen absoluten PNG-Pfad") }
            look(writingTo: path, started: Date())
            reply = ["pending": true, "meta": path + ".json"]
        } else {
            throw PaneArgsError("web versteht call state, look <png>")
        }
        let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func state() -> [String: Any] {
        var state: [String: Any] = ["file": file.path, "root": rootFolder.path, "zoom": Int((webView.pageZoom * 100).rounded()),
                                    "loading": webView.isLoading, "canGoBack": webView.canGoBack,
                                    "console": console.count,
                                    "errors": console.filter { $0.level == "error" || $0.level == "resource" }.count]
        if let title = webView.title, !title.isEmpty { state["title"] = title }
        return state
    }

    /// Wartet, bis die Seite geladen ist und kurz geruht hat (Diagramme rendern per JS nach), dann Bild + Daten.
    private func look(writingTo path: String, started: Date) {
        if webView.isLoading, Date().timeIntervalSince(started) < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.look(writingTo: path, started: started) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let js = """
            JSON.stringify({x: scrollX, y: scrollY, w: innerWidth, h: innerHeight,
              sw: document.documentElement.scrollWidth, sh: document.documentElement.scrollHeight,
              text: document.body ? document.body.innerText.slice(0, 6000) : ''})
            """
            self.webView.evaluateJavaScript(js) { result, _ in
                var meta = self.state()
                if let json = result as? String, let data = json.data(using: .utf8),
                   let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    meta["page"] = page
                }
                meta["log"] = self.console.suffix(40).map { ["level": $0.level, "text": $0.text] }
                self.webView.takeSnapshot(with: nil) { image, error in
                    if let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                       let png = PreviewRender.scaled(cg, maxPixels: 1600) {
                        try? png.write(to: URL(fileURLWithPath: path), options: .atomic)
                        meta["image"] = path
                    } else {
                        meta["problem"] = "kein Bild: " + (error?.localizedDescription ?? "Kachel nicht sichtbar?")
                    }
                    Self.writeMeta(meta, to: path + ".json")
                }
            }
        }
    }

    private static func writeMeta(_ meta: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func handle(_ command: PaneCommand) -> Bool {
        guard command == .find else { return false }
        root.findBar.show(text: findText)
        root.window?.makeFirstResponder(root.findBar.field)
        return true
    }

    func willClose() {
        changeWork?.cancel()
        watchers.values.forEach { $0.stop() }
        watchers = [:]
        titleObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: WebConsole.handlerName)
    }

    /// Nach ⌥⌘R kommt die Kachel mit derselben Seite, demselben Lese-Ordner und Zoom wieder.
    func snapshotArgs() -> [String: String]? {
        var args = ["url": file.path]
        if rootFolder != file.deletingLastPathComponent() { args["root"] = rootFolder.path }
        if abs(webView.pageZoom - 1) > 0.01 { args["zoom"] = String(format: "%.2f", webView.pageZoom) }
        return args
    }

    // MARK: Bedienung

    /// Kürzel der Web-Kachel (die Hülle hat ⌘T/⌘W/⌘1–9 vorher verteilt, ⌘⏎ fällt zu ihr durch).
    private func keyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers ?? ""
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
            switch key.lowercased() {
            case "+", "=": zoomStep(1)
            case "g":
                guard root.findBar.isVisible else { return false }
                find(root.findBar.field.stringValue, backwards: true)
            default: return false
            }
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

    // MARK: Konsole

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == WebConsole.handlerName, let body = message.body as? [String: Any],
              let level = body["level"] as? String, let text = body["text"] as? String else { return }
        log(level, text)
    }

    private func log(_ level: String, _ text: String) {
        // Fehlende Datei aus dem Ordner meldet schon der Server — die Browser-Meldung dazu wäre doppelt.
        if level == "error", text.hasPrefix("Laden fehlgeschlagen: \(LocalFolderServer.scheme):") { return }
        let wasClean = !console.contains { $0.level == "error" || $0.level == "resource" }
        console.append(WebConsole.Entry(level: level, text: String(text.prefix(2000)), time: Date()))
        if console.count > 200 { console.removeFirst(console.count - 200) }
        if wasClean, level == "error" || level == "resource" { delegate?.contentStyleChanged() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        consoleByPage[file.path] = console
        console = []
        dialogsThisPage = 0
    }

    /// Lokaler Link zu einer anderen Seite: Titel, Beobachter und Wiederherstellung folgen ihr.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let shown: URL
        if url.scheme == LocalFolderServer.scheme { shown = URL(fileURLWithPath: url.path).standardizedFileURL }
        else if url.isFileURL { shown = url.standardizedFileURL }
        else { return }
        if shown != file {
            watchers.removeValue(forKey: file.path)?.stop()
            file = shown
            watch(shown)
        }
        if historyStep, console.isEmpty { console = consoleByPage[shown.path] ?? [] }
        historyStep = false
        delegate?.contentStyleChanged()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !loadedOnce {
            loadedOnce = true
            // Ab jetzt wie ein Browser: Seiten ohne eigenen Hintergrund sind weiß, nicht durchsichtig.
            webView.setValue(true, forKey: "drawsBackground")
        }
        delegate?.contentStyleChanged()
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
        showProblem("„\(file.lastPathComponent)“ lässt sich nicht laden", detail: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("error", "Laden abgebrochen: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("error", "WebKit-Prozess abgestürzt — neu geladen")
        load(file)
    }

    /// Fehlerseite im Theme; die Kachel beobachtet die Datei weiter und lädt, sobald sie wieder da ist.
    private func showProblem(_ title: String, detail: String) {
        let theme = ThemeStore.shared.theme
        let esc = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let html = """
        <meta charset="utf-8"><body style="margin:0;height:100vh;display:grid;place-items:center;background:\(Self.css(theme.background));\
        color:\(Self.css(theme.foreground));font:13px -apple-system,sans-serif;text-align:center">\
        <div><div style="font-size:15px;margin-bottom:6px">\(esc(title))</div>\
        <div style="opacity:.6">\(esc(detail))<br>\(esc((file.path as NSString).abbreviatingWithTildeInPath))</div></div>
        """
        webView.loadHTMLString(html, baseURL: nil)
        log("resource", "\(title): \(detail)")
    }

    private static func css(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame == true { historyStep = action.navigationType == .backForward }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if url.scheme == LocalFolderServer.scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
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
        if url.scheme == LocalFolderServer.scheme || url.isFileURL {
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
        alert.messageText = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? file.lastPathComponent
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
