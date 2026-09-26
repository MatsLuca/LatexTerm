import Foundation

// Kacheln öffnen, bedienen, schließen, anordnen; Stände und Brett-Dateien.

extension MCPServer {
    // MARK: Werkzeug-Implementierungen

    func describeSnapshot(_ snap: SnapshotSummary) -> String {
        let panes = snap.boards.reduce(0) { $0 + $1.panes.count }
        var text = "\(snap.index) · \(snap.date) · \(snap.reason) · \(snap.boards.count) Brett\(snap.boards.count == 1 ? "" : "er"), \(panes) Kachel\(panes == 1 ? "" : "n") [\(snap.name)]"
        for board in snap.boards { text += "\n   " + (board.name ?? "Brett") + ": " + board.panes.joined(separator: " · ") }
        return text
    }

    func snapshotsTool() throws -> String {
        let all = try checked(ControlRequest(cmd: "snapshots")).snapshots ?? []
        return all.isEmpty ? "Noch keine gespeicherten Stände." : all.map(describeSnapshot).joined(separator: "\n")
    }

    func restoreSnapshot(_ a: JSON) throws -> String {
        var request = ControlRequest(cmd: "restore")
        request.snapshot = a["stand"] as? String ?? (a["stand"] as? Int).map(String.init)
        request.dryRun = a["probe"] as? Bool ?? false
        let response = try checked(request)
        let boards = (response.snapshots?.first?.boards ?? [])
            .map { "   " + ($0.name ?? "Brett") + ": " + $0.panes.joined(separator: " · ") }
        return ([response.reply ?? ""] + boards).joined(separator: "\n")
    }

    func placement(_ a: JSON, allowReplace: Bool) throws -> String? {
        switch a["placement"] as? String {
        case nil, "neben_mich": return "beside"
        case "eigen": return "own"
        case "hintergrund": return "background"
        case "leiste_unten": return "dock-bottom"
        case "leiste_oben": return "dock-top"
        case "ersetzen" where allowReplace: return "replace"
        case let other: throw ToolFailure("placement „\(other ?? "")“ gibt es hier nicht (neben_mich, eigen, hintergrund, leiste_unten, leiste_oben\(allowReplace ? ", ersetzen" : "")).")
        }
    }

    func openTerminal(_ a: JSON) throws -> String {
        var request = ControlRequest(cmd: "new-pane")
        request.cwd = try directory(a["cwd"] as? String)
        if let command = nonEmpty(a["command"]) { request.exec = command }
        request.focus = a["focus"] as? Bool ?? false
        request.placement = try placement(a, allowReplace: false)
        request.dockHeight = number(a["hoehe"])
        let pane = try open(request)
        let moved = try moveToBoard(pane, a)
        return "Terminal-Kachel \(pane.index) (\(pane.id.prefix(8))) in \(tilde(pane.cwd ?? request.cwd) ?? "?")"
            + (request.exec.map { " — läuft: \($0)" } ?? "") + "." + moved + currentLayout()
    }

    /// `brett` am Öffnen (26.09.): die frische Kachel gleich auf ein anderes Brett umziehen — derselbe Weg wie layout brett.
    func moveToBoard(_ pane: PaneInfo, _ a: JSON) throws -> String {
        guard let board = (a["brett"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? (a["brett"] as? Int).map(String.init) else { return "" }
        let target = board == "neu" ? "new" : board
        var request = ControlRequest(cmd: "layout")
        request.layoutOp = "board"
        request.pane = pane.id
        request.board = target
        request.focus = false
        request.paneID = paneID
        request.layoutRevision = try checked(ControlRequest(cmd: "list-panes")).layout?.revision
        let response: ControlResponse
        do { response = try transport.send(request) }
        catch { throw ToolFailure("Kachel \(pane.index) ist offen, der Umzug aufs Brett scheiterte: \(error) — layout brett nachholen.") }
        guard response.ok else {
            throw ToolFailure("Kachel \(pane.index) ist offen, der Umzug aufs Brett scheiterte: \(response.error ?? "abgelehnt") — layout brett nachholen.")
        }
        return target == "new" ? " — auf eigenem neuen Brett" : " — auf Brett \(board)"
    }

    func runInPane(_ a: JSON) throws -> String {
        guard let command = nonEmpty(a["command"]) else { throw ToolFailure("command fehlt") }
        let (pane, panes) = try target(a, needsDetails: true)
        if pane.id == selfPane(in: panes)?.id {
            throw ToolFailure("Nicht in die eigene Kachel — dort läufst du selbst. Für eigene Befehle dein Shell-Werkzeug, für Hintergrund open_terminal.")
        }
        guard (pane.kind ?? "terminal") == "terminal" else {
            throw ToolFailure("Kachel \(pane.index) ist keine Shell (\(pane.kind ?? "?")). App-Kacheln: pane_action.")
        }
        if let agent = agentOf(pane) {
            throw ToolFailure("In Kachel \(pane.index) läuft eine \(agent)-Session — Prompts per ask_session, nicht als Befehl.")
        }
        if let program = pane.foreground, !(a["into_running_program"] as? Bool ?? false) {
            throw ToolFailure("In Kachel \(pane.index) läuft gerade „\(program)“. Nur mit into_running_program: true hineintippen, wenn das gewollt ist.")
        }
        var request = ControlRequest(cmd: "send")
        request.pane = pane.id
        request.text = command
        request.enter = true
        _ = try checked(request)
        return "In Kachel \(pane.index) ausgeführt: \(command.prefix(120))"
    }

    func paneAction(_ a: JSON) throws -> String {
        guard let action = nonEmpty(a["action"]) else { throw ToolFailure("action fehlt") }
        let (pane, _) = try target(a)
        guard let kind = pane.kind, kind != "terminal", kind != "home" else {
            throw ToolFailure("Kachel \(pane.index) ist eine Shell — dafür run_in_pane oder ask_session.")
        }
        // Scratchpad leeren meldet, was entfernt wurde (früher eigenes Werkzeug scratch_clear).
        let words = action.lowercased().split(separator: " ")
        if kind == "scratchpad", words.first == "clear" {
            let who = words.count > 1 ? String(words[1]) : "all"
            guard words.count <= 2, ["cards", "claude", "mats", "all"].contains(who) else {
                throw ToolFailure("clear kennt cards, claude, mats oder all")
            }
            return try scratchClear(pane, who: who)
        }
        var request = ControlRequest(cmd: "send")
        request.pane = pane.id
        request.text = try normalizedAction(action)
        request.enter = false
        _ = try checked(request)
        return "Kachel \(pane.index) (\(kind)): \(action)"
    }

    func focusPane(_ a: JSON) throws -> String {
        let (pane, _) = try target(a)
        var request = ControlRequest(cmd: "focus")
        request.pane = pane.id
        _ = try checked(request)
        if a["zoom"] as? Bool == true, !pane.zoomed {
            request.cmd = "zoom"
            _ = try checked(request)
        }
        return "Kachel \(pane.index) im Fokus\(a["zoom"] as? Bool == true ? ", gezoomt" : "")."
    }

    func closePane(_ a: JSON) throws -> String {
        let (pane, panes) = try target(a)
        if pane.id == selfPane(in: panes)?.id { throw ToolFailure("Deine eigene Kachel schließt du nicht.") }
        let mine = isMine(pane)
        guard mine || a["auf_auftrag"] as? Bool == true else {
            throw ToolFailure("Kachel \(pane.index) hast nicht du geöffnet. Schließen nur, wenn der Nutzer es ausdrücklich will — dann auf_auftrag: true.")
        }
        var request = ControlRequest(cmd: "close-pane")
        request.pane = pane.id
        _ = try checked(request)   // nie force: arbeitende Sessions und laufende Programme bleiben offen
        opened.remove(pane.id.uppercased())
        return "Kachel \(pane.index) geschlossen."
    }

    func openKind(_ info: PaneKindInfo, _ a: JSON) throws -> String {
        var args: [String: String] = [:]
        if let free = a["args"] as? [String: Any] {
            for (key, value) in free { args[key] = normalizedPath("\(value)") }
        }
        for arg in info.args {
            if let value = a[arg.name] { args[arg.name] = normalizedPath("\(value)") }
            else if arg.required { throw ToolFailure("\(arg.name) fehlt: \(arg.summary)") }
        }
        let placed = try placement(a, allowReplace: true)
        let panes = try listPanes()
        if placed == "replace", let mine = panes.last(where: { $0.kind == info.kind && isMine($0) }),
           args.isEmpty || !sameArgs(mine.args, args) {
            // Ersetzen: eigene Kachel dieser Art weiterverwenden — neuer Inhalt per „load“, wenn die Art es kann.
            if args.isEmpty { return "Deine \(info.kind)-Kachel \(mine.index) (\(mine.id.prefix(8))) bleibt — nichts Neues zu laden." }
            if info.actions.contains(where: { $0.name.hasPrefix("load ") }),
               let main = info.args.first(where: \.required) ?? info.args.first, let value = args[main.name] {
                var request = ControlRequest(cmd: "send")
                request.pane = mine.id
                request.text = "load " + value
                request.enter = false
                _ = try checked(request)
                shownIndex[mine.index] = mine.id.uppercased()
                return "In deiner \(info.kind)-Kachel \(mine.index) (\(mine.id.prefix(8))) geladen: \(tilde(value) ?? value)."
            }
            // Art ohne „load“: dann eben eine neue Kachel daneben.
        }
        if !args.isEmpty, let existing = panes.first(where: { $0.kind == info.kind && sameArgs($0.args, args) }) {
            if info.actions.contains(where: { $0.name == "reload" }) {
                var request = ControlRequest(cmd: "send")
                request.pane = existing.id
                request.text = "reload"
                request.enter = false
                _ = try checked(request)
                return "War schon offen: Kachel \(existing.index) (\(existing.id.prefix(8))) — neu geladen."
            }
            return "War schon offen: Kachel \(existing.index) (\(existing.id.prefix(8)))."
        }
        var request = ControlRequest(cmd: "new-pane")
        request.kind = info.kind
        request.args = args
        request.focus = false
        request.placement = placed == "replace" ? "beside" : placed
        request.dockHeight = number(a["hoehe"])
        let pane = try open(request)
        return "\(info.kind)-Kachel \(pane.index) (\(pane.id.prefix(8))) geöffnet." + currentLayout()
    }

    // MARK: - Anordnung

    /// layout benennen (26.09.): Brett umbenennen wie per Doppelklick in der Leiste — ohne ziel das eigene.
    func nameBoard(_ a: JSON) throws -> String {
        guard let name = a["name"] as? String else { throw ToolFailure("benennen braucht name (leer = wieder automatisch)") }
        var request = ControlRequest(cmd: "board-name")
        request.text = name
        request.board = (a["ziel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (a["ziel"] as? Int).map(String.init)
        do { return try checked(request).reply ?? "" }
        catch let failure as ToolFailure where failure.description.contains("Unbekanntes Kommando") {
            throw ToolFailure("Die laufende LatexTerm-App kennt das Umbenennen noch nicht — LatexTerm neu starten (⌥⌘R).")
        }
    }

    func layoutTool(_ a: JSON) throws -> String {
        let action = (a["action"] as? String) ?? "zeigen"
        if action == "benennen" { return try nameBoard(a) }
        let ops = ["zeigen": "show", "gross": "big", "groesser": "grow", "kleiner": "shrink", "nebeneinander": "beside",
                   "untereinander": "below", "tauschen": "swap", "reiter": "tab", "vorholen": "front", "brett": "board", "automatisch": "auto",
                   "leiste_unten": "dock-bottom", "leiste_oben": "dock-top", "loesen": "undock"]
        guard let op = ops[action] else { throw ToolFailure("action „\(action)“ gibt es nicht (\(ops.keys.sorted().joined(separator: ", ")))") }
        if op == "show" { return panesTool() }

        var request = ControlRequest(cmd: "layout")
        request.layoutOp = op
        request.onBehalf = a["auf_auftrag"] as? Bool ?? false
        let panes = try listPanes()
        if op != "auto" {
            guard a["pane"] != nil else { throw ToolFailure("pane fehlt — welche Kachel?") }
            request.pane = try target(a).0.id
        }
        if op.hasPrefix("dock-") {
            // Ohne other: an die eigene Kachel hängen.
            let other: Any? = a["other"] ?? paneID
            guard let other else { throw ToolFailure("\(action) braucht other (die Kachel, unter/über die die Leiste soll)") }
            request.otherPane = try target(["pane": other]).0.id
            request.dockHeight = number(a["hoehe"])
        }
        if ["beside", "below", "swap", "tab"].contains(op) {
            guard let other = a["other"] else { throw ToolFailure("\(action) braucht other (die zweite Kachel)") }
            request.otherPane = try target(["pane": other]).0.id
        }
        if op == "board" {
            request.board = (a["ziel"] as? String) ?? (a["ziel"] as? Int).map(String.init) ?? "new"
            request.focus = a["zeigen"] as? Bool ?? false
        }
        guard let seen = layoutSeen else {
            // Nie gelesen: erst den Stand zeigen, nichts ändern.
            throw ToolFailure("Erst den aktuellen Stand lesen, dann ändern:\n\n" + panesTool())
        }
        request.layoutRevision = seen
        request.paneID = paneID
        let response: ControlResponse
        do { response = try transport.send(request) }
        catch { throw ToolFailure(String(describing: error)) }
        guard response.ok else {
            let reason = response.error ?? "LatexTerm lehnt ab"
            // Veralteter Stand: der neue kommt mit — gelesen gilt er als gesehen, der nächste Versuch trifft.
            if let layout = response.layout { throw ToolFailure(reason + "\n\n" + lagebild(layout, panes: (try? listPanes()) ?? panes)) }
            throw ToolFailure(reason)
        }
        let fresh = (try? checked(ControlRequest(cmd: "list-panes")))
        return "Erledigt: \(action)." + (fresh.map { "\n\n" + lagebild($0.layout ?? response.layout, panes: $0.panes ?? panes) } ?? "")
    }

    /// board_save / board_open: Pfad auflösen, Probe, Anzeige.
    func boardFile(_ cmd: String, _ a: JSON) throws -> String {
        guard let file = nonEmpty(a["file"]) else { throw ToolFailure("file fehlt (…/_brett/brett.json)") }
        var request = ControlRequest(cmd: cmd)
        request.text = resolve(file)
        request.dryRun = a["probe"] as? Bool ?? false
        if cmd == "board-save", let name = nonEmpty(a["name"]) { request.args = ["name": name] }
        if cmd == "board-open" { request.focus = a["zeigen"] as? Bool ?? true }
        return try checked(request).reply ?? ""
    }
}
