import Foundation

/// Antwort aus der Übersicht an eine Agenten-Kachel — derselbe Weg wie MCP `ask_session` (LatexTermCLI
/// `MCPServer.deliver`), nur in der App: Claude bekommt einen Brief in den Briefkasten, den der Mod in der Session
/// einreicht, sobald sie ruht; holt ihn niemand ab, obwohl sie ruht, fällt es auf Tippen + Enter zurück. Codex wird
/// direkt getippt, wenn es nicht arbeitet. Alles über den Router — die Kachel darf auf jedem Brett und Fenster stehen.
enum AgentDelivery {
    /// So lange darf eine ruhende Claude-Session den Brief liegen lassen, bevor getippt wird (Mod pollt alle 2 s).
    private static let pickupWait: TimeInterval = 6

    /// `done` bekommt einen kurzen Satz fürs Band („eingereicht“, „liegt im Briefkasten …“) oder den Fehler.
    static func deliver(_ text: String, toPane paneID: String, agent: String, done: @escaping (String, Bool) -> Void) {
        guard let pane = info(paneID) else { done("Kachel ist zu", false); return }
        if agent == "claude" {
            let file: String
            do { file = try post(text, pane: paneID) } catch { done("Briefkasten: \(error.localizedDescription)", false); return }
            if pane.state == "working" { done("liegt im Briefkasten — wird eingereicht, sobald die Session ruht", true) }
            watch(file: file, text: text, paneID: paneID, idleSince: nil, started: Date(), done: pane.state == "working" ? nil : done)
        } else {
            guard pane.state != "working" else { done("\(agent.capitalized) arbeitet gerade — später nochmal", false); return }
            type(text, into: paneID)
            done("eingetippt", true)
        }
    }

    /// Freigabe-Rückfrage beantworten: ⏎ nimmt die vorgewählte Zustimmung, Esc lehnt ab.
    static func answerPermission(_ allow: Bool, toPane paneID: String) -> Bool {
        var request = ControlRequest(cmd: "send", pane: paneID)
        request.text = allow ? "\r" : "\u{1b}"
        request.enter = false
        return ControlServer.shared.router.route(request).ok
    }

    // MARK: Briefkasten

    private static func post(_ text: String, pane: String) throws -> String {
        let dir = ControlProtocol.mailboxPath(forPane: pane)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss-SSS"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let name = "\(stamp.string(from: Date()))-home.md"
        let temp = (dir as NSString).appendingPathComponent(".\(name).tmp")
        let file = (dir as NSString).appendingPathComponent(name)
        try (text + "\n").write(toFile: temp, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(atPath: temp, toPath: file)
        return file
    }

    /// Jede Sekunde nachsehen: abgeholt → fertig; Session ruht seit `pickupWait` und holt nicht ab → tippen.
    /// Arbeitet sie, bleibt der Brief liegen (der Mod reicht ihn nach dem Turn ein) — dann ohne Meldung.
    private static func watch(file: String, text: String, paneID: String, idleSince: Date?, started: Date,
                              done: ((String, Bool) -> Void)?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if !FileManager.default.fileExists(atPath: file) { done?("eingereicht", true); return }
            guard let pane = info(paneID) else {
                try? FileManager.default.removeItem(atPath: file)
                done?("Kachel ist inzwischen zu — nicht zugestellt", false)
                return
            }
            if pane.state == "working" {
                if Date().timeIntervalSince(started) > 3600 { try? FileManager.default.removeItem(atPath: file) }
                else { watch(file: file, text: text, paneID: paneID, idleSince: nil, started: started, done: done) }
                return
            }
            let idle = idleSince ?? Date()
            guard Date().timeIntervalSince(idle) >= pickupWait else {
                watch(file: file, text: text, paneID: paneID, idleSince: idle, started: started, done: done)
                return
            }
            try? FileManager.default.removeItem(atPath: file)
            type(text, into: paneID)
            done?("eingetippt (kein Briefkasten-Empfänger)", true)
        }
    }

    // MARK: Tippen

    /// Wie `MCPServer.paste`: Text ohne Enter (die TUI schluckt ein mitgeschicktes), eine Sekunde später ⏎.
    /// Zeilenumbrüche würden vorzeitig abschicken — sie werden zu Leerzeichen.
    private static func type(_ text: String, into paneID: String) {
        var request = ControlRequest(cmd: "send", pane: paneID)
        request.text = text.replacingOccurrences(of: "\n", with: " ")
        request.enter = false
        _ = ControlServer.shared.router.route(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            var enter = ControlRequest(cmd: "send", pane: paneID)
            enter.text = " "
            enter.enter = true
            _ = ControlServer.shared.router.route(enter)
        }
    }

    private static func info(_ paneID: String) -> PaneInfo? {
        ControlServer.shared.router.panes.first { $0.id.uppercased() == paneID.uppercased() }
    }
}
