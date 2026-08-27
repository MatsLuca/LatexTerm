import AppKit

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

    func setDockTile(_ dockTile: NSDockTile?) {}

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
        return menu
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag),
              let url = URL(string: "latexterm://quickstart/\(items[sender.tag].key)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openHome() {
        if let url = URL(string: "latexterm://home") { NSWorkspace.shared.open(url) }
    }
}
