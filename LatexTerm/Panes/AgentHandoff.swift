import AppKit

/// Übergabe von App-Kacheln an eine Claude-/Codex-Kachel (Scratchpad ➤, Vorschau ➤): Ziel finden,
/// Bilder ablegen, Auswahlmenü. Der Text selbst geht über `PaneContentDelegate.contentPaste` als
/// bracketed paste hinein — eingefügte Bildpfade macht Claude Code zu Anhängen, Enter drückt der Nutzer.
enum AgentHandoff {
    enum Target {
        case direct(PaneInfo)
        case choose([PaneInfo])
        case none(String)
    }

    /// Die Kachel des Öffners, wenn dort ein Agent läuft (und nicht gewählt werden soll), sonst Auswahl.
    static func target(_ delegate: PaneContentDelegate?, choose: Bool) -> Target {
        let agents = delegate?.contentAgentPanes() ?? []
        guard !agents.isEmpty else { return .none("Keine Claude- oder Codex-Kachel offen") }
        if !choose, let opener = delegate?.contentOpener,
           let owner = agents.first(where: { $0.id.caseInsensitiveCompare(opener) == .orderedSame }) {
            return .direct(owner)
        }
        if !choose, agents.count == 1 { return .direct(agents[0]) }
        return .choose(agents)
    }

    /// Menü „<Kopf> …“ mit einer Zeile je Agenten-Kachel, 1–9 als Kürzel.
    static func menu(_ agents: [PaneInfo], header: String, opener: String?, pick: @escaping (PaneInfo) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        for (position, pane) in agents.enumerated() {
            let agent = pane.runningAgent == "codex" ? "Codex" : "Claude"
            let folder = pane.cwd.map { ($0 as NSString).lastPathComponent } ?? "?"
            let state = ["working": "arbeitet", "awaitingInput": "wartet auf dich", "ready": "bereit"][pane.state]
            var title = "Kachel \(pane.index) · \(agent) · \(folder)"
            if let state { title += " — \(state)" }
            if let opener, pane.id.caseInsensitiveCompare(opener) == .orderedSame { title += " (hat es geöffnet)" }
            let item = ClosureMenuItem(title: title, keyEquivalent: position < 9 ? "\(position + 1)" : "") { pick(pane) }
            item.keyEquivalentModifierMask = []
            menu.addItem(item)
        }
        return menu
    }

    /// Ablage für übergebene Bilder: Cache (Pfad ohne Leerzeichen, nicht im Documents-Spiegel), nach 7 Tagen weg.
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LatexTerm/sends", isDirectory: true)
    }

    static func writePNG(_ png: Data, prefix: String) throws -> URL {
        let folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [] {
            if let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(prefix)-\(stamp.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base)-\(n).png")
            n += 1
        }
        try png.write(to: url, options: .atomic)
        return url
    }
}

/// Menüeintrag mit Closure statt Target/Action.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    @objc private func run() { handler() }
}
