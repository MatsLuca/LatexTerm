import AppKit
import WebKit

/// Zweite App-Kachel (Kachel-Protokoll, Schritt 8): zeigt eine lokale HTML-Datei — Plots,
/// Berichte, Mini-Apps, die ein Skript oder ein Mod erzeugt. `latexterm new-pane --kind web
/// --arg url=/pfad/datei.html`; danach `send --pane N 'load /anderer/pfad.html'` oder `reload`.
///
/// Sicherheitsentscheid (Bauplan §6.8): nur lokale Dateien. Der Steuerkanal ist 0600 + Peer-Check,
/// aber Claude schreibt die Aufrufe — eine http-URL aus einem Hook-Kontext wäre ein neuer Kanal nach
/// außen. Gelesen werden darf nur der Ordner der Datei; Links nach draußen öffnet ein Klick im
/// Standardbrowser, nie in der Kachel. Später gezielt öffnen, wenn ein Fall es braucht.
final class WebContent: NSObject, PaneContent, WKNavigationDelegate {
    static let kind = "web"
    static let displayName = "HTML-Datei in neuer Kachel …"

    weak var delegate: PaneContentDelegate?
    private let webView: WKWebView
    private(set) var file: URL
    private var titleObservation: NSKeyValueObservation?

    required init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, allowed: ["url"], kind: Self.kind)
        guard let raw = args["url"] else {
            throw PaneArgsError("web braucht --arg url=/pfad/datei.html")
        }
        file = try Self.resolve(raw)
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        titleObservation = webView.observe(\.title) { [weak self] _, _ in
            self?.delegate?.contentStyleChanged()
        }
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

    private func load(_ url: URL) {
        file = url
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        delegate?.contentStyleChanged()
    }

    // MARK: PaneContent

    var view: NSView { webView }
    var title: String {
        if let t = webView.title, !t.isEmpty { return t }
        return file.lastPathComponent
    }
    var chip: StatusChip? {
        StatusChip(tone: ThemeStore.shared.accentColor, tooltip: (file.path as NSString).abbreviatingWithTildeInPath)
    }
    var directory: String? { file.deletingLastPathComponent().path }

    func applyTheme(_ theme: TerminalTheme) {
        webView.underPageBackgroundColor = theme.background.withAlphaComponent(1)
    }

    /// `reload` lädt neu (nach dem Überschreiben der Datei), `load <pfad>` zeigt eine andere Datei.
    func receive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "reload" { webView.reloadFromOrigin(); return true }
        guard trimmed.hasPrefix("load "), let url = try? Self.resolve(String(trimmed.dropFirst(5))) else { return false }
        load(url)
        return true
    }

    func willClose() {
        titleObservation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    /// Nach ⌥⌘R kommt die Kachel mit derselben Datei wieder.
    func snapshotArgs() -> [String: String]? { ["url": file.path] }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.isFileURL || url.scheme == "about" { decisionHandler(.allow); return }
        // Geklickter Link nach draußen: Standardbrowser, die Kachel bleibt lokal.
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
