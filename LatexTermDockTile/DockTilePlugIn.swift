import AppKit
import os

private let log = Logger(subsystem: "com.mats.LatexTerm", category: "docktile")

/// Dock-Menü für die *nicht laufende* App. Der Dock-Prozess lädt dieses Bundle (Info.plist der
/// App: `NSDockTilePlugIn`) und fragt bei jedem Rechtsklick `dockMenu()`. Läuft die App, zeigt
/// macOS stattdessen deren `applicationDockMenu` — beide lesen dieselbe Liste.
///
/// Quelle: `~/.cache/projekte/quickstarts.json`, geschrieben von `projekte --json` /
/// `projekte quickstarts` (Werkstatt-Datenschicht). Hier stehen keine Pfade und keine Befehle;
/// ein Klick öffnet nur `latexterm://quickstart/<key>`, den Rest macht die App beim Start.
/// Nach jedem Build des Plugins: `killall Dock` — der Dock cacht Plugins.
@objc(DockTilePlugIn)
final class DockTilePlugIn: NSObject, NSDockTilePlugIn {
    private struct Quickstart: Decodable { var key: String; var label: String; var glyph: String; var hint: String?; var path: String; var exists: Bool }
    private struct Cache: Decodable { var quickstarts: [Quickstart] }

    private var items: [Quickstart] = []
    /// Das Menü wird ans Dock serialisiert; die Klick-Aktion kommt im Host auf *diesem* Objektgraphen
    /// zurück — ohne starke Referenz wäre das Menü samt Targets längst freigegeben.
    private var menu: NSMenu?

    /// Belt and braces neben os_log: `~/.cache/projekte/docktile.log` (Host-Prozess ist ein Dock-XPC-Dienst).
    private static func trace(_ msg: String) {
        let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/projekte/docktile.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid \(ProcessInfo.processInfo.processIdentifier) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: f, atomically: true, encoding: .utf8) }
    }

    override init() {
        super.init()
        Self.trace("init")
    }

    func setDockTile(_ dockTile: NSDockTile?) { Self.trace("setDockTile \(dockTile == nil ? "nil" : "tile")") }

    func dockMenu() -> NSMenu? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/projekte/quickstarts.json")
        items = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }?.quickstarts ?? []
        let menu = NSMenu()
        if items.isEmpty {
            let hint = NSMenuItem(title: "Keine Quickstarts (projekte quickstarts)", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        for (i, q) in items.enumerated() {
            let item = NSMenuItem(title: "\(q.glyph)  \(q.label)", action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.isEnabled = q.exists
            item.toolTip = q.hint ?? q.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let home = NSMenuItem(title: "Neue Home-Kachel", action: #selector(openHome), keyEquivalent: "")
        home.target = self
        menu.addItem(home)
        self.menu = menu
        Self.trace("dockMenu: \(items.count) Quickstarts")
        return menu
    }

    @objc private func run(_ sender: NSMenuItem) {
        Self.trace("run tag \(sender.tag)")
        guard items.indices.contains(sender.tag),
              let url = URL(string: "latexterm://quickstart/\(items[sender.tag].key)") else { return }
        open(url)
    }

    @objc private func openHome() {
        Self.trace("openHome")
        if let url = URL(string: "latexterm://home") { open(url) }
    }

    /// Die App, in der dieses Plugin steckt: …/LatexTerm.app/Contents/PlugIns/X.docktileplugin
    private var appURL: URL {
        Bundle(for: DockTilePlugIn.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Gezielt mit der eigenen App öffnen (keine Scheme-Suche über LaunchServices — mehrere Kopien
    /// der App oder ein veralteter LS-Eintrag treffen sonst die falsche). Fehler landen im Log.
    private func open(_ url: URL) {
        let app = appURL
        log.notice("Klick → \(url.absoluteString, privacy: .public) mit \(app.path, privacy: .public)")
        Self.trace("open \(url.absoluteString) mit \(app.path)")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg) { running, error in
            Self.trace("open-Ergebnis: \(error.map { "Fehler \($0.localizedDescription)" } ?? "ok pid \(running?.processIdentifier ?? -1)")")
            if let error {
                log.error("open mit App fehlgeschlagen: \(error.localizedDescription, privacy: .public) — Fallback über Scheme")
                NSWorkspace.shared.open(url, configuration: cfg) { _, e2 in
                    if let e2 { log.error("Scheme-Open fehlgeschlagen: \(e2.localizedDescription, privacy: .public)") }
                    else { log.notice("Scheme-Open ok") }
                }
            } else {
                log.notice("open ok, pid \(running?.processIdentifier ?? -1)")
            }
        }
    }
}
