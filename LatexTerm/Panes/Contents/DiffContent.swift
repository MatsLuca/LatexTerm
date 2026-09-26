import AppKit
import WebKit
import CoreServices

/// Kachelart `diff` — der „Beifahrer“ (26.09.2026, Plan claude-werkstatt `plans/kacheln-runde-2_2026-09-22.md` Top 2):
/// live `git diff` eines Repos neben einer Agenten-Kachel. Zeigt alle Änderungen gegen `base` (Default HEAD, also
/// gestaged + ungestaged) samt neuer, noch nicht versionierter Dateien; der Chip trägt „+42 −7“. Aktualisiert sich über
/// FSEvents auf dem Repo (entprellt), Git läuft mit `GIT_OPTIONAL_LOCKS=0` — die Kachel schreibt nie in den Index und
/// stört den Agenten nicht. Rückkanal wie Vorschau/Web: Zeilen markieren → ⇧⌘⏎ / ➤ fügt `datei:zeile` samt Auszug in
/// die Session ein. Nur lesen: kein Stagen, kein Verwerfen.
final class DiffContent: NSObject, PaneContent, WKNavigationDelegate, WKScriptMessageHandler {
    static let kind = "diff"
    static let displayName = "Git-Diff eines Ordners …"
    static let manual = PaneKindManual(
        summary: "Live-git-diff eines Repos neben der Session (Beifahrer): alle Änderungen gegen HEAD (oder base) samt neuer, "
            + "unversionierter Dateien, mit Zeilennummern; aktualisiert sich bei jeder Dateiänderung, Chip „+42 −7“. Zum "
            + "Mitlesen, was ein Agent gerade ändert, und für Reviews. Der Nutzer markiert Zeilen und schickt sie dir als "
            + "datei:zeile samt Auszug. Nur lesen — nie stagen/verwerfen.",
        args: [PaneKindArg(name: "dir", summary: "Ordner im Repo (absolut, ~ oder relativ zu deinem)", required: true),
               PaneKindArg(name: "base", summary: "Vergleich gegen diesen Stand: HEAD (Default), main, HEAD~3, Commit …", required: false)],
        actions: [PaneKindAction(name: "reload", summary: "sofort neu vergleichen (sonst automatisch)"),
                  PaneKindAction(name: "base <ref>", summary: "anderen Vergleichsstand zeigen (HEAD, main, HEAD~1 …)"),
                  PaneKindAction(name: "file <pfad>", summary: "zu dieser Datei springen"),
                  PaneKindAction(name: "fold / unfold", summary: "alle Dateien zu- bzw. aufklappen"),
                  PaneKindAction(name: "load <ordner>", summary: "anderes Repo in derselben Kachel")])

    weak var delegate: PaneContentDelegate?
    private let root: DiffRootView
    private var webView: WKWebView { root.webView }
    /// Wurzel des Repos (`git rev-parse --show-toplevel`).
    private(set) var repo: URL
    private(set) var base: String
    private var watcher: DirectoryWatcher?
    private var ready = false
    private var pendingPayload: [String: Any]?
    private var themeJSON: String?
    /// Zuletzt gezeigter Stand (Hash der Git-Ausgabe) — gleicher Stand, kein neues Rendern.
    private var lastSignature: Int?
    private var files: [DiffModel.File] = []
    private var problem: String?
    private var refreshing = false
    private var refreshAgain = false
    private var refreshWork: DispatchWorkItem?
    private var lastRefresh = Date.distantPast
    private var fallbackTimer: Timer?
    /// Markierte Zeilen aus der Seite (für ⇧⌘⏎).
    private var selection: [[String: Any]] = []
    private var sending = false
    private static let queue = DispatchQueue(label: "LatexTerm.diff", qos: .userInitiated)

    required init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, allowed: ["dir", "base"], kind: Self.kind)
        guard let raw = args["dir"], !raw.isEmpty else { throw PaneArgsError("diff braucht --arg dir=/pfad/im/repo") }
        repo = try Self.repoRoot(raw)
        base = try Self.checkedBase(args["base"])
        root = DiffRootView()
        super.init()
        let controller = webView.configuration.userContentController
        controller.add(WeakScriptHandler(self), name: DiffPage.handlerName)
        webView.navigationDelegate = self
        webView.loadHTMLString(DiffPage.html, baseURL: nil)
        root.onKeyEquivalent = { [weak self] event in self?.keyEquivalent(event) ?? false }
        root.onSend = { [weak self] in self?.send(choose: NSEvent.modifierFlags.contains(.option)) }
        startWatching()
        refresh()
    }

    static func menuArgs() -> [String: String]? { menuArgs(in: nil) }

    /// Dialog startet im Ordner, der die Projekte nebeneinander hält: steht die bestellende Kachel in einem Repo, dessen
    /// Elternordner (Nachbar-Projekte, eins davon ist das aktuelle), sonst ihr Ordner selbst (26.09., Mats).
    static func menuArgs(in directory: String?) -> [String: String]? {
        let panel = NSOpenPanel()
        if let start = startFolder(for: directory) { panel.directoryURL = start }
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Ordner in einem Git-Repo — die Kachel zeigt seine Änderungen live"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return ["dir": url.path]
    }

    static func startFolder(for directory: String?) -> URL? {
        guard let directory, !directory.isEmpty else { return nil }
        let out = git(["rev-parse", "--show-toplevel"], in: directory)
        if out.status == 0, let top = String(data: out.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty {
            return URL(fileURLWithPath: top, isDirectory: true).deletingLastPathComponent()
        }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    // MARK: PaneContent

    var view: NSView { root }
    var keyView: NSView { webView }
    var title: String {
        let (added, removed) = DiffModel.totals(files)
        return "Diff · \(repo.lastPathComponent)" + (problem == nil ? " · \(DiffModel.label(added: added, removed: removed))" : "")
    }
    var chip: StatusChip? {
        let theme = ThemeStore.shared.theme
        if let problem { return StatusChip(short: "⚠", tone: theme.red, tooltip: problem) }
        let (added, removed) = DiffModel.totals(files)
        let label = DiffModel.label(added: added, removed: removed)
        let count = files.count
        return StatusChip(long: "\(label) · \(count) Datei\(count == 1 ? "" : "en")", short: label,
                          tone: ThemeStore.shared.accentColor,
                          tooltip: "\(repo.path) gegen \(base) — \(count) geänderte Datei\(count == 1 ? "" : "en")")
    }
    var directory: String? { repo.path }
    var layoutPreference: LayoutPreference {
        LayoutPreference(aspect: nil, minWidth: 340, minHeight: 220, comfortWidth: 560)
    }

    func applyTheme(_ theme: TerminalTheme) {
        root.applyTheme(theme)
        let bg = theme.background.usingColorSpace(.sRGB) ?? theme.background
        let dark = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent < 0.5
        let css = MarkdownPreviewView.css
        let vars: [String: String] = [
            "bg": css(theme.background, 1), "fg": css(theme.foreground, 1), "dim": css(theme.foreground, 0.5),
            "faint": css(theme.foreground, 0.14), "ground": css(theme.foreground, dark ? 0.05 : 0.04),
            "add": css(theme.green, 1), "addbg": css(theme.green, dark ? 0.13 : 0.16),
            "del": css(theme.red, 1), "delbg": css(theme.red, dark ? 0.13 : 0.14),
            "accent": css(ThemeStore.shared.accentColor, 1), "mark": css(ThemeStore.shared.accentColor, 0.28),
            "font": AppFonts.mono(size: 12).familyName ?? "Menlo"]
        themeJSON = MarkdownPreviewView.json(["vars": vars])
        if ready, let themeJSON { webView.evaluateJavaScript("window.__diff && __diff.theme(\(themeJSON))") }
    }

    func receive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        let rest = trimmed.dropFirst(command.count).trimmingCharacters(in: .whitespaces)
        switch command {
        case "reload":
            lastSignature = nil
            refresh()
        case "base":
            guard let checked = try? Self.checkedBase(rest.isEmpty ? nil : rest) else { return false }
            base = checked
            lastSignature = nil
            refresh()
        case "file":
            guard !rest.isEmpty else { return false }
            page("reveal", rest)
        case "fold": page("foldAll", true)
        case "unfold": page("foldAll", false)
        case "load":
            guard let url = try? Self.repoRoot(rest) else { return false }
            repo = url
            lastSignature = nil
            files = []
            startWatching()
            refresh()
            delegate?.contentStyleChanged()
        default: return false
        }
        return true
    }

    /// `call state` (CLI/Tests): Repo, Stand, Summen je Datei als JSON.
    func call(_ text: String) throws -> String {
        guard text.trimmingCharacters(in: .whitespaces) == "state" else { throw PaneArgsError("diff versteht per call nur state") }
        let (added, removed) = DiffModel.totals(files)
        var state: [String: Any] = ["repo": repo.path, "base": base, "added": added, "removed": removed,
                                    "files": files.map { ["path": $0.path, "status": $0.status.rawValue,
                                                          "added": $0.added, "removed": $0.removed] }]
        if let problem { state["problem"] = problem }
        return MarkdownPreviewView.json(state)
    }

    func willClose() {
        refreshWork?.cancel()
        fallbackTimer?.invalidate()
        watcher = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    func snapshotArgs() -> [String: String]? {
        var args = ["dir": repo.path]
        if base != "HEAD" { args["base"] = base }
        return args
    }

    // MARK: Git

    /// Ordner → Wurzel seines Repos; kein Repo = Fehler mit Grund.
    static func repoRoot(_ raw: String) throws -> URL {
        let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { throw PaneArgsError("Ordner gibt es nicht: \(path)") }
        let folder = isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
        let out = git(["rev-parse", "--show-toplevel"], in: folder)
        guard out.status == 0, let top = String(data: out.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty else {
            throw PaneArgsError("\((folder as NSString).abbreviatingWithTildeInPath) liegt in keinem Git-Repo — die Diff-Kachel zeigt Änderungen gegenüber dem letzten Commit und braucht dafür ein Repo (git init).")
        }
        return URL(fileURLWithPath: top, isDirectory: true)
    }

    /// Nur Ref-Namen, keine Optionen (ein „--output=…“ als base wäre sonst ein Schreibzugriff).
    static func checkedBase(_ raw: String?) throws -> String {
        let value = (raw ?? "HEAD").trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.hasPrefix("-"), value.range(of: #"^[A-Za-z0-9._/@{}~^:+-]+$"#, options: .regularExpression) != nil else {
            throw PaneArgsError("base „\(value)“ ist kein Git-Stand (z. B. HEAD, main, HEAD~2, ein Commit)")
        }
        return value
    }

    nonisolated struct GitOutput { var status: Int32; var data: Data; var error: String }

    /// Git ohne Sperren (liest nur, schreibt den Index nicht), Pfade unverändert, keine Farben/externen Diff-Tools.
    nonisolated static func git(_ arguments: [String], in folder: String, limit: Int = 16_000_000) -> GitOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder, "-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return GitOutput(status: -1, data: Data(), error: error.localizedDescription) }
        var data = Data()
        // Lesen, bevor gewartet wird — sonst hängt Git an der vollen Pipe.
        while true {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if data.count < limit { data.append(chunk) }
        }
        let errorText = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return GitOutput(status: process.terminationStatus, data: data.prefix(limit), error: errorText)
    }

    nonisolated private struct Snapshot {
        var files: [DiffModel.File]
        var signature: Int
        var problem: String?
    }

    /// Diff gegen `base` + unversionierte Dateien. Läuft abseits des Main-Threads.
    nonisolated private static func compute(repo: String, base: String) -> Snapshot {
        var diffBase = base
        if base == "HEAD", git(["rev-parse", "--verify", "-q", "HEAD"], in: repo).status != 0 {
            diffBase = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"   // leerer Baum: Repo ohne ersten Commit
        }
        let diff = git(["diff", "--no-color", "--no-ext-diff", "-M", "--src-prefix=a/", "--dst-prefix=b/", diffBase, "--"], in: repo)
        guard diff.status == 0 else {
            let reason = diff.error.split(separator: "\n").first.map(String.init) ?? "git diff scheiterte"
            return Snapshot(files: [], signature: reason.hashValue, problem: reason)
        }
        var hasher = Hasher()
        hasher.combine(diff.data)
        var files = DiffModel.parse(String(decoding: diff.data, as: UTF8.self))
        let others = git(["ls-files", "--others", "--exclude-standard", "-z"], in: repo)
        let names = others.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
        for name in names.prefix(200) {
            let url = URL(fileURLWithPath: repo).appendingPathComponent(name)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let data = size <= 1_000_000 ? ((try? Data(contentsOf: url)) ?? Data()) : Data([0])
            hasher.combine(name)
            hasher.combine(data)
            files.append(DiffModel.untracked(path: name, data: data))
        }
        return Snapshot(files: files, signature: hasher.finalize(), problem: nil)
    }

    // MARK: Aktualisieren

    private func startWatching() {
        watcher = DirectoryWatcher(path: repo.path) { [weak self] in self?.scheduleRefresh() }
        fallbackTimer?.invalidate()
        // Sicherheitsnetz, falls FSEvents etwas verschluckt (Netzlaufwerk, Syncthing …).
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Entprellt: höchstens etwa einmal pro Sekunde, 0,4 s nach der letzten Änderung.
    private func scheduleRefresh() {
        refreshWork?.cancel()
        let wait = max(0.4, 1.0 - Date().timeIntervalSince(lastRefresh))
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private func refresh() {
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        lastRefresh = Date()
        let repoPath = repo.path, base = base
        Self.queue.async { [weak self] in
            let snapshot = Self.compute(repo: repoPath, base: base)
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                if repoPath == self.repo.path, base == self.base { self.apply(snapshot) }
                if self.refreshAgain { self.refreshAgain = false; self.scheduleRefresh() }
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        guard snapshot.signature != lastSignature else { return }
        let first = lastSignature == nil
        lastSignature = snapshot.signature
        files = snapshot.files
        problem = snapshot.problem
        let (added, removed) = DiffModel.totals(files)
        let payload: [String: Any] = ["repo": repo.lastPathComponent, "path": (repo.path as NSString).abbreviatingWithTildeInPath,
                                      "base": base, "added": added, "removed": removed, "problem": problem ?? NSNull(),
                                      "files": DiffModel.payload(files)]
        if ready { page("render", payload) } else { pendingPayload = payload }
        delegate?.contentStyleChanged()
        if !first { delegate?.contentHasNews() }
    }

    // MARK: Seite

    private func page(_ function: String, _ args: Any...) {
        guard ready else { return }
        let list = args.map { MarkdownPreviewView.json($0) }.joined(separator: ",")
        webView.evaluateJavaScript("window.__diff && __diff.\(function)(\(list))")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "ready":
            ready = true
            if let themeJSON { webView.evaluateJavaScript("__diff.theme(\(themeJSON))") }
            if let payload = pendingPayload { pendingPayload = nil; page("render", payload) }
        case "selection":
            selection = body["lines"] as? [[String: Any]] ?? []
            root.showSend(!selection.isEmpty)
        default: break
        }
    }

    /// Nur die eigene Seite; Links aus Dateiinhalten gibt es nicht (Text wird nie als HTML gesetzt).
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        lastSignature = nil
        webView.loadHTMLString(DiffPage.html, baseURL: nil)
        refresh()
    }

    // MARK: Rückkanal

    private func keyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if mods == [.command, .shift], isReturn { send(choose: false); return true }
        if mods == [.command, .shift, .option], isReturn { send(choose: true); return true }
        if mods == .command, event.charactersIgnoringModifiers == "r" { _ = receive("reload"); return true }
        return false
    }

    /// Markierte Zeilen als `datei:zeile` samt Auszug in die Agenten-Kachel einfügen (Enter drückt der Nutzer).
    private func send(choose: Bool) {
        guard !sending else { return }
        guard !selection.isEmpty else {
            NSSound.beep()
            root.pill.flash("Erst Zeilen markieren, dann ⇧⌘⏎", hold: 2)
            return
        }
        switch AgentHandoff.target(delegate, choose: choose) {
        case .none(let reason):
            NSSound.beep()
            root.pill.flash(reason, hold: 2.5)
        case .direct(let pane):
            deliver(to: pane)
        case .choose(let agents):
            let menu = AgentHandoff.menu(agents, header: "Diff-Stellen senden an …", opener: delegate?.contentOpener) { [weak self] pane in
                self?.deliver(to: pane)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: root.bounds.midX - 120, y: root.bounds.midY), in: root)
        }
    }

    private func deliver(to pane: PaneInfo) {
        let text = DiffHandoff.compose(selection, repo: repo, base: base)
        guard delegate?.contentPaste(text, intoPaneID: pane.id) == true else {
            NSSound.beep()
            root.pill.flash("Kachel \(pane.index) nimmt nichts an", hold: 3)
            return
        }
        selection = []
        root.showSend(false)
        webView.evaluateJavaScript("getSelection().removeAllRanges()")
        root.pill.flash("➤ Stelle liegt in Kachel \(pane.index)", hold: 2.5)
    }
}

/// Text der Übergabe: Kopf mit Repo/Stand, je Datei ein Bereich `pfad:12–14` (neue Zeilennummern, bei reinen
/// Löschungen die alten mit „(alt)“) und der Auszug mit +/−.
enum DiffHandoff {
    static func compose(_ lines: [[String: Any]], repo: URL, base: String) -> String {
        let tilde = (repo.path as NSString).abbreviatingWithTildeInPath
        var out = ["Aus dem Diff \(tilde) (gegen \(base)):"]
        var byFile: [(String, [[String: Any]])] = []
        for line in lines {
            let path = line["path"] as? String ?? "?"
            if let index = byFile.firstIndex(where: { $0.0 == path }) { byFile[index].1.append(line) }
            else { byFile.append((path, [line])) }
        }
        for (path, rows) in byFile {
            let news = rows.compactMap { $0["new"] as? Int }
            let olds = rows.compactMap { $0["old"] as? Int }
            let place: String
            if let lo = news.min(), let hi = news.max() { place = lo == hi ? "\(path):\(lo)" : "\(path):\(lo)–\(hi)" }
            else if let lo = olds.min(), let hi = olds.max() { place = (lo == hi ? "\(path):\(lo)" : "\(path):\(lo)–\(hi)") + " (alt, gelöscht)" }
            else { place = path }
            out.append(place)
            for row in rows.prefix(24) {
                let sign = ["add": "+", "del": "−"][row["kind"] as? String ?? ""] ?? " "
                let text = (row["text"] as? String ?? "")
                out.append("   │ \(sign) " + (text.count > 160 ? String(text.prefix(160)) + "…" : text))
            }
            if rows.count > 24 { out.append("   │ … (+\(rows.count - 24) Zeilen)") }
        }
        return out.joined(separator: "\n")
    }
}

/// Wurzel: WebView, darüber die Hinweis-Pille und der ➤-Knopf bei Auswahl.
final class DiffRootView: NSView {
    let webView: WKWebView
    let pill = PreviewPill()
    private let sendButton = NSButton(title: "➤ an die Session  ⇧⌘⏎", target: nil, action: nil)
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onSend: (() -> Void)?
    private var background = NSColor.black

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init(frame: frame)
        addSubview(webView)
        sendButton.bezelStyle = .recessed
        sendButton.isHidden = true
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        addSubview(sendButton)
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        background = theme.background.withAlphaComponent(1)
        webView.underPageBackgroundColor = background
        pill.applyTheme(theme)
        needsDisplay = true
    }

    func showSend(_ visible: Bool) {
        sendButton.isHidden = !visible
        needsLayout = true
    }

    @objc private func sendClicked() { onSend?() }

    override func layout() {
        super.layout()
        webView.frame = bounds
        sendButton.sizeToFit()
        sendButton.frame.origin = NSPoint(x: bounds.maxX - sendButton.frame.width - 12, y: 10)
        pill.layoutIn(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        dirtyRect.fill()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// FSEvents auf einem Ordner (rekursiv, ohne Datei-Einzelereignisse): ruft `onChange` auf dem Main-Thread.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(path: String, latency: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            // Die Queue ist .main (FSEventStreamSetDispatchQueue unten).
            MainActor.assumeIsolated { Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange() }
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}

/// Die Seite: rendert die Nutzlast per DOM (Texte nur als textContent), meldet Auswahl und Bereitschaft.
enum DiffPage {
    static let handlerName = "latextermDiff"

    static let html = """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
    <style>
    :root { --bg:#1e1e1e; --fg:#ddd; --dim:#888; --faint:#333; --ground:#262626; --add:#4c4; --addbg:#1f3a1f; --del:#e55;
            --delbg:#3a1f1f; --accent:#6af; --mark:rgba(100,160,255,.3); --font:Menlo; }
    * { box-sizing: border-box; }
    html, body { margin:0; background:var(--bg); color:var(--fg); font:12px var(--font), Menlo, monospace; }
    ::selection { background: var(--mark); }
    header { position:sticky; top:0; z-index:3; background:var(--bg); padding:10px 14px 8px; border-bottom:1px solid var(--faint); }
    header .sum { display:flex; gap:12px; align-items:baseline; flex-wrap:wrap; }
    header .repo { font-weight:600; }
    header .dim, .dim { color:var(--dim); }
    .add { color:var(--add); } .del { color:var(--del); }
    nav { margin-top:6px; display:flex; flex-wrap:wrap; gap:4px 14px; }
    nav a { color:var(--fg); text-decoration:none; cursor:pointer; opacity:.85; white-space:nowrap; }
    nav a:hover { opacity:1; text-decoration:underline; }
    section { margin:10px 0 0; border-top:1px solid var(--faint); }
    section h2 { position:sticky; top:var(--head,58px); z-index:2; margin:0; padding:6px 14px; font-size:12px; font-weight:600;
                 background:var(--bg); display:flex; gap:10px; align-items:baseline; cursor:pointer; user-select:none;
                 border-left:3px solid transparent; }
    section.fresh h2 { border-left-color:var(--accent); }
    section h2 .tag { font-weight:400; color:var(--dim); }
    section h2 .fold { color:var(--dim); width:1em; }
    section.folded .body { display:none; }
    .body { overflow-x:auto; }
    table { border-collapse:collapse; width:100%; }
    td { padding:0 8px; white-space:pre; vertical-align:top; line-height:1.45; tab-size:4; }
    td.n { color:var(--dim); text-align:right; user-select:none; width:1%; opacity:.7; }
    td.s { user-select:none; width:1%; padding:0 4px; color:var(--dim); }
    tr.add td.t { background:var(--addbg); } tr.add td.s { color:var(--add); }
    tr.del td.t { background:var(--delbg); } tr.del td.s { color:var(--del); }
    tr.hunk td { color:var(--dim); background:var(--ground); padding-top:3px; padding-bottom:3px; }
    tr.note td.t { color:var(--dim); font-style:italic; }
    .msg { padding:18px 14px; color:var(--dim); }
    .flash td.t { animation: fl 1.2s ease-out; }
    @keyframes fl { from { background: var(--mark); } }
    </style></head><body>
    <header id="head"></header><main id="files"></main>
    <script>
    (function(){
      const post = m => window.webkit.messageHandlers.\(handlerName).postMessage(m);
      const folded = new Map(); let sig = new Map(); let firstRender = true;
      const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
      function signature(f) { return f.added + '/' + f.removed + '/' + f.hunks.map(h => h.header + h.lines.length).join('|'); }
      function render(p) {
        const head = document.getElementById('head'), main = document.getElementById('files');
        const y = window.scrollY;
        head.replaceChildren(); main.replaceChildren();
        const sum = el('div', 'sum');
        sum.append(el('span', 'repo', p.repo), el('span', 'dim', 'gegen ' + p.base));
        if (p.problem) { sum.append(el('span', 'del', p.problem)); head.append(sum); return; }
        const n = p.files.length;
        sum.append(el('span', 'add', '+' + p.added), el('span', 'del', '−' + p.removed),
                   el('span', 'dim', n + (n === 1 ? ' Datei' : ' Dateien')));
        head.append(sum);
        if (!n) { main.append(el('div', 'msg', 'Keine Änderungen gegen ' + p.base + '.')); return; }
        const nav = el('nav'); head.append(nav);
        const next = new Map();
        p.files.forEach((f, i) => {
          const s = signature(f); next.set(f.path, s);
          const fresh = !firstRender && sig.get(f.path) !== s;
          const a = el('a'); a.append(el('span', 'add', f.added ? '+' + f.added : ''), ' ', el('span', 'del', f.removed ? '−' + f.removed : ''), ' ', f.path);
          a.onclick = () => reveal(f.path); nav.append(a);
          const sec = el('section'); sec.dataset.path = f.path;
          if (fresh) sec.classList.add('fresh');
          const auto = f.added + f.removed > 400 && !fresh;
          if (folded.has(f.path) ? folded.get(f.path) : auto) sec.classList.add('folded');
          const h = el('h2'); const fold = el('span', 'fold', sec.classList.contains('folded') ? '▸' : '▾');
          const tag = { added:'neu', deleted:'gelöscht', renamed:'umbenannt', untracked:'unversioniert', modified:'' }[f.status] || '';
          h.append(fold, el('span', null, f.oldPath ? f.oldPath + ' → ' + f.path : f.path), el('span', 'add', f.added ? '+' + f.added : ''),
                   el('span', 'del', f.removed ? '−' + f.removed : ''), el('span', 'tag', tag));
          h.onclick = () => { const on = !sec.classList.contains('folded'); sec.classList.toggle('folded', on); folded.set(f.path, on); fold.textContent = on ? '▸' : '▾'; };
          sec.append(h);
          const body = el('div', 'body'); const t = el('table'); body.append(t); sec.append(body);
          if (f.binary) t.append(row('note', null, null, '', 'Binärdatei — kein Textvergleich', f.path));
          else if (!f.hunks.length) t.append(row('note', null, null, '', f.status === 'renamed' ? 'nur umbenannt' : 'nur Modus geändert', f.path));
          f.hunks.forEach(hk => {
            const tr = el('tr', 'hunk'); const td = el('td', null, hk.header); td.colSpan = 4; tr.append(td); t.append(tr);
            hk.lines.forEach(l => t.append(row(l[0], l[1], l[2], l[0] === 'add' ? '+' : l[0] === 'del' ? '−' : ' ', l[3], f.path)));
          });
          if (f.truncated) t.append(row('note', null, null, '', '… gekürzt (zu viele Zeilen für die Kachel)', f.path));
          if (fresh && !sec.classList.contains('folded')) body.classList.add('flash');
          main.append(sec);
        });
        sig = next; firstRender = false;
        document.documentElement.style.setProperty('--head', head.offsetHeight + 'px');
        window.scrollTo(0, y);
      }
      function row(kind, o, n, sign, text, path) {
        const tr = el('tr', kind); tr.dataset.path = path; tr.dataset.kind = kind;
        if (o != null) tr.dataset.old = o; if (n != null) tr.dataset.new = n;
        tr.append(el('td', 'n', o == null ? '' : o), el('td', 'n', n == null ? '' : n), el('td', 's', sign), el('td', 't', text));
        return tr;
      }
      function reveal(path) {
        const sec = [...document.querySelectorAll('section')].find(s => s.dataset.path === path || s.dataset.path.endsWith('/' + path));
        if (!sec) return;
        sec.classList.remove('folded'); folded.set(sec.dataset.path, false);
        const head = document.getElementById('head').offsetHeight;
        window.scrollTo(0, sec.getBoundingClientRect().top + window.scrollY - head + 1);
      }
      function foldAll(on) {
        document.querySelectorAll('section').forEach(s => { s.classList.toggle('folded', on); folded.set(s.dataset.path, on);
          const f = s.querySelector('.fold'); if (f) f.textContent = on ? '▸' : '▾'; });
      }
      function theme(t) { for (const [k, v] of Object.entries(t.vars)) document.documentElement.style.setProperty('--' + k, v); }
      function selection() {
        const sel = getSelection(); const lines = [];
        if (sel && !sel.isCollapsed) {
          document.querySelectorAll('tr[data-kind]').forEach(tr => {
            if (tr.dataset.kind === 'note' || !sel.containsNode(tr, true)) return;
            lines.push({ path: tr.dataset.path, kind: tr.dataset.kind, old: tr.dataset.old ? +tr.dataset.old : null,
                         new: tr.dataset.new ? +tr.dataset.new : null, text: tr.lastChild.textContent });
          });
        }
        post({ kind: 'selection', lines: lines.slice(0, 400) });
      }
      document.addEventListener('selectionchange', () => { clearTimeout(window.__selT); window.__selT = setTimeout(selection, 150); });
      window.__diff = { render, reveal, foldAll, theme };
      post({ kind: 'ready' });
    })();
    </script></body></html>
    """
}
