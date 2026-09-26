import Foundation

// Hilfen: Steuerkanal-Roundtrip, Ziel-Kachel auflösen, Pfade, Anzeige.

extension MCPServer {
    // MARK: - Hilfen

    func listPanes() throws -> [PaneInfo] {
        try checked(ControlRequest(cmd: "list-panes")).panes ?? []
    }

    /// Roundtrip; `ok: false` der App wird zur Werkzeug-Fehlermeldung mit ihrem Grund.
    @discardableResult
    func checked(_ request: ControlRequest) throws -> ControlResponse {
        var request = request
        request.paneID = paneID
        let response: ControlResponse
        do { response = try transport.send(request) }
        catch { throw ToolFailure(String(describing: error)) }
        guard response.ok else { throw ToolFailure(response.error ?? "LatexTerm lehnt ab") }
        return response
    }

    /// Neue Kachel öffnen und als eigene merken.
    func open(_ request: ControlRequest) throws -> PaneInfo {
        guard let pane = try checked(request).pane else { throw ToolFailure("LatexTerm meldet keine neue Kachel") }
        opened.insert(pane.id.uppercased())
        shownIndex[pane.index] = pane.id.uppercased()
        return pane
    }

    /// Ziel-Kachel aus `pane` auflösen — dieselbe Regel wie im CLI: Ziffern = Index, sonst eindeutiges UUID-Präfix.
    func target(_ a: JSON, needsDetails: Bool = false) throws -> (PaneInfo, [PaneInfo]) {
        guard let selector = (a["pane"] as? String) ?? (a["pane"] as? Int).map(String.init), !selector.isEmpty else {
            throw ToolFailure("pane fehlt (Index oder UUID aus panes)")
        }
        let response = try checked(ControlRequest(cmd: "list-panes"))
        let panes = response.panes ?? []
        if needsDetails, !(response.capabilities ?? []).contains("pane-details") {
            throw ToolFailure("Die laufende LatexTerm-App ist älter als dieser Server (kennt keine Kachel-Details) — LatexTerm neu starten (⌥⌘R).")
        }
        let matches: [PaneInfo]
        if let index = Int(selector) {
            matches = panes.filter { $0.index == index }
            // Die Nummer, die das Modell gesehen hat, zeigt inzwischen auf eine andere Kachel (umgeordnet,
            // Kachel zu): lieber ablehnen als still die falsche treffen — `run_in_pane` führt dort aus.
            if let seen = shownIndex[index], matches.first?.id.uppercased() != seen {
                let now = matches.first.map { "jetzt \($0.kind ?? "terminal") \($0.id.prefix(8))" } ?? "gibt es nicht mehr"
                throw ToolFailure("Kachel-Nummern haben sich verschoben: Nr. \(index) war \(seen.prefix(8)), \(now). Nimm die UUID (erste 8 Zeichen) — aktueller Stand:\n\n" + panesTool())
            }
        } else {
            matches = panes.filter { $0.id.uppercased().hasPrefix(selector.uppercased()) }
        }
        guard matches.count == 1 else {
            throw ToolFailure("Kachel „\(selector)“ nicht eindeutig gefunden — panes zeigt Index und UUID.")
        }
        return (matches[0], panes)
    }

    /// Von dieser Session geöffnet: in diesem Prozess gemerkt ODER laut App von unserer Kachel aus
    /// (überlebt ⌥⌘R, weil die App Kachel-IDs und „geöffnet von“ wiederherstellt).
    func isMine(_ pane: PaneInfo) -> Bool {
        if opened.contains(pane.id.uppercased()) { return true }
        guard let paneID, let opener = pane.openedBy else { return false }
        return opener.caseInsensitiveCompare(paneID) == .orderedSame
    }

    /// Standardziel ohne `pane`: eigene fokussierte, einzige eigene, fokussierte, einzige, zuletzt eigene.
    /// Als Einzelschritte statt einer `??`-Kette — die lange Kette sprengt den Type-Checker in CI.
    func defaultPane(mine: [PaneInfo], all: [PaneInfo]) -> PaneInfo? {
        if let focused = mine.first(where: \.focused) { return focused }
        if mine.count == 1 { return mine[0] }
        if let focused = all.first(where: \.focused) { return focused }
        if all.count == 1 { return all[0] }
        return mine.last
    }

    func selfPane(in panes: [PaneInfo]) -> PaneInfo? {
        guard let paneID else { return nil }
        return panes.first { $0.id.caseInsensitiveCompare(paneID) == .orderedSame }
    }

    /// Agent einer Kachel: gemeldete Identität, sonst das Vordergrundprogramm (Sessions ohne Status-Sender).
    func agentOf(_ pane: PaneInfo) -> String? { pane.runningAgent }

    func describe(_ pane: PaneInfo, own: PaneInfo?) -> String {
        shownIndex[pane.index] = pane.id.uppercased()
        var parts = ["\(pane.index)", String(pane.id.prefix(8)), pane.kind ?? "terminal"]
        // Wo die Kachel „ist“: Ordner der Shell, bei App-Kacheln ihr einziges Arg (Web: die Datei).
        let shown = pane.args.flatMap { $0.count == 1 ? $0.values.first : nil } ?? pane.cwd
        if let shown { parts.append(tilde(shown) ?? shown) }
        var marks: [String] = []
        if let tab = pane.tab { marks.append("Brett \(tab)") }
        if let agent = pane.agent { marks.append(agent) }
        if pane.state != "none" { marks.append(pane.state) }
        if let program = pane.foreground, pane.agent == nil { marks.append("läuft: \(program)") }
        if pane.focused { marks.append("fokussiert") }
        if pane.zoomed { marks.append("gezoomt") }
        if pane.hidden == true { marks.append("verdeckter Reiter") }
        if let dock = pane.dock, let anchor = pane.companionOf { marks.append("Leiste \(dock) an \(anchor.prefix(8))") }
        if isMine(pane) { marks.append("von dir geöffnet") }
        else if pane.openedBy == "user" { marks.append("vom Nutzer geöffnet") }
        if !marks.isEmpty { parts.append(marks.joined(separator: ", ")) }
        if let title = pane.title, !title.isEmpty, (pane.kind ?? "terminal") != "terminal" {
            parts.append("„\(title.prefix(60))“")
        }
        var line = parts.joined(separator: " · ")
        if let own, own.id == pane.id { line += "  ← du" }
        return line
    }

    func tilde(_ path: String?) -> String? {
        guard let path else { return nil }
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Zahl aus JSON (Int, Double oder Zahl als Text).
    func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let text = value as? String { return Double(text.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Ordner: absolut, `~` oder relativ zum Ordner dieser Session; muss existieren.
    func directory(_ raw: String?) throws -> String {
        let path = resolve(raw ?? workingDirectory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolFailure("Ordner gibt es nicht: \(path)")
        }
        return path
    }

    func resolve(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : (workingDirectory as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    /// Arg-Werte, die wie ein Pfad aussehen und existieren, werden absolut — die App kennt den
    /// Ordner dieser Session nicht. Alles andere (Zahlen, Wörter, URLs) bleibt, wie es ist.
    func normalizedPath(_ value: String) -> String {
        guard !value.contains("://") else { return value }
        let candidate = resolve(value)
        return FileManager.default.fileExists(atPath: candidate) ? candidate : value
    }

    /// `load <pfad>` bekommt denselben Pfad-Service wie die Args.
    func normalizedAction(_ action: String) throws -> String {
        let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("load ") else { return trimmed }
        return "load " + normalizedPath(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces))
    }

    func sameArgs(_ shown: [String: String]?, _ wanted: [String: String]) -> Bool {
        // Nur die gewünschten Schlüssel zählen: eine Vorschau merkt sich zusätzlich Seite/Zoom.
        guard let shown else { return false }
        return wanted.allSatisfy { key, value in
            guard let other = shown[key] else { return false }
            if other == value { return true }
            // Ordner zeigt die App als dessen index.html.
            return other == (value as NSString).appendingPathComponent("index.html")
        }
    }
}
