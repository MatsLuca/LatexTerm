import AppKit

/// App-weite Kommandos des Steuerkanals (25.09.2026) — gehören keinem Brett, darum vor dem Router-Ziel:
/// - `snapshots`: Stand-Archiv (`SessionStore.archived`), neuester zuerst.
/// - `restore`: fehlende Bretter eines Stands in die laufende App, ohne Neustart (`dryRun` = nur zeigen).
/// - `board-open`: Brett aus einer Datei (`board-save` des Bretts) als neues Brett (25.09.).
/// - `doctor`: Gesundheitscheck — läuft der neueste Build, Absturzschutz, Archiv, letzte Lebenszeichen.
/// Anlass: das Zurückholen verlorener Bretter am 24./25.09. ging nur über Sperrdatei und ⌘Q (Plan claude-werkstatt
/// `plans/latexterm-wiederherstellen_2026-09-25.md`).
enum AppControl {
    static func handle(_ request: ControlRequest) -> ControlResponse? {
        switch request.cmd {
        case "snapshots":
            var response = ControlResponse(ok: true)
            response.snapshots = SessionStore.archived().map(\.summary)
            return response
        case "restore": return restore(request)
        case "board-open": return openBoard(request)
        case "doctor":
            var response = ControlResponse(ok: true)
            response.reply = doctor()
            return response
        default: return nil
        }
    }

    private static func restore(_ request: ControlRequest) -> ControlResponse {
        let found: (summary: SnapshotSummary, snapshot: SessionSnapshot)
        switch SessionStore.findArchived(request.snapshot) {
        case .success(let hit): found = hit
        case .failure(let error): return .failure(error.description)
        }
        let missing = BoardHostView.openPanes().missing(from: found.snapshot.windows)
        var summary = found.summary
        summary.boards = missing.map { SnapshotSummary.Board(name: $0.name, panes: $0.panes.map(SessionStore.describe)) }
        var response = ControlResponse(ok: true)
        response.snapshots = [summary]
        let paneCount = missing.reduce(0) { $0 + $1.panes.count }
        if missing.isEmpty {
            response.reply = "Alles aus Stand \(found.summary.name) ist schon offen — nichts zu tun."
        } else if request.dryRun ?? false {
            response.reply = "Probe: \(missing.count) Brett\(missing.count == 1 ? "" : "er") mit \(paneCount) Kachel\(paneCount == 1 ? "" : "n") käme\(missing.count == 1 ? "" : "n") dazu (Stand \(found.summary.name))."
        } else {
            guard BoardHostView.addRestoredBoards(missing) else { return .failure("Kein LatexTerm-Fenster offen") }
            LifecycleWatch.log("Wiederhergestellt aus \(found.summary.name): \(missing.count) Brett\(missing.count == 1 ? "" : "er"), \(paneCount) Kachel\(paneCount == 1 ? "" : "n")")
            response.reply = "\(missing.count) Brett\(missing.count == 1 ? "" : "er") mit \(paneCount) Kachel\(paneCount == 1 ? "" : "n") hinten angehängt (Stand \(found.summary.name)). Agenten-Sessions setzen sich fort."
        }
        return response
    }

    // MARK: Brett-Datei

    /// `board-open`: Brett aus einer Datei (`board-save`) als neues Brett, vorn (`focus` false = hinten lassen).
    /// Schon Offenes kommt nicht doppelt (gleiche Kachel, Agenten-Session oder angeheftete Zeichnung).
    private static func openBoard(_ request: ControlRequest) -> ControlResponse {
        let url: URL, file: BoardFile
        do {
            url = try BoardFile.url(request.text)
            file = try BoardFile.read(url)
        } catch { return .failure(String(describing: error)) }
        let window = file.resolved(base: url.deletingLastPathComponent())
        let missing = BoardHostView.openPanes().missing(from: [window])
        var response = ControlResponse(ok: true)
        let name = window.name ?? "Brett"
        guard let plan = missing.first else {
            response.reply = "„\(name)“ ist schon offen — nichts zu tun."
            return response
        }
        let described = plan.panes.map(SessionStore.describe).joined(separator: " · ")
        if request.dryRun ?? false {
            response.reply = "Probe: „\(name)“ mit \(plan.panes.count) Kachel\(plan.panes.count == 1 ? "" : "n") käme dazu (\(described))"
                + (plan.panes.count < window.panes.count ? " — \(window.panes.count - plan.panes.count) schon offen" : "")
            return response
        }
        guard BoardHostView.addRestoredBoards([plan], activate: request.focus ?? true) else { return .failure("Kein LatexTerm-Fenster offen") }
        LifecycleWatch.log("Brett geöffnet aus \(url.path): \(plan.panes.count) Kachel\(plan.panes.count == 1 ? "" : "n")")
        response.reply = "„\(name)“ geöffnet: \(plan.panes.count) Kachel\(plan.panes.count == 1 ? "" : "n") (\(described)). Agenten-Sessions setzen sich fort."
        return response
    }

    // MARK: doctor

    static func doctor(now: Date = Date()) -> String {
        let fm = FileManager.default
        var lines: [String] = []
        let started = LifecycleWatch.startedAt
        lines.append("LatexTerm · pid \(getpid()) · läuft seit \(clock(started)) (\(duration(now.timeIntervalSince(started))))")

        // Läuft der neueste Build? (Am 24.09. lief nach dem Bauen noch die alte App — die Absturzerkennung fehlte.)
        if let exe = Bundle.main.executableURL,
           let built = (try? fm.attributesOfItem(atPath: exe.path)[.modificationDate]) as? Date {
            lines.append(built > started.addingTimeInterval(5)
                ? "Build: NEUER Build von \(clock(built)) liegt bereit — läuft noch nicht (⌥⌘R lädt ihn)"
                : "Build: aktuell (\(clock(built)))")
        }

        let panes = ControlServer.shared.router.panes
        let agents = panes.filter { $0.runningAgent != nil }
        let working = panes.filter { $0.state == "working" }.count
        let boards = Set(panes.map { "\($0.windowID ?? "?")|\($0.tab ?? 0)" }).count
        lines.append("Kacheln: \(panes.count) auf \(boards) Brett\(boards == 1 ? "" : "ern") · \(agents.count) Agent\(agents.count == 1 ? "" : "en"), \(working) arbeite\(working == 1 ? "t" : "n")")

        let url = SessionStore.defaultURL
        let marker = SessionStore.runMarkerURL(for: url)
        let saved = url.flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date }
        let markerOK = marker.map { fm.fileExists(atPath: $0.path) } ?? false
        lines.append("Absturzschutz: " + (markerOK ? "Lauf-Marke steht" : "Lauf-Marke FEHLT (unsauberes Ende würde nicht erkannt)")
            + " · letzter Autosave " + (saved.map { "vor \(duration(now.timeIntervalSince($0)))" } ?? "–"))

        let archive = SessionStore.archived(for: url)
        if let newest = archive.first?.summary {
            lines.append("Stand-Archiv: \(archive.count) · neuester \(clock(iso(newest.date))) (\(newest.reason))")
        } else {
            lines.append("Stand-Archiv: leer")
        }

        let dir = url?.deletingLastPathComponent()
        for (file, count) in [("lifecycle.log", 8), ("unclean.log", 3)] {
            let text = dir.flatMap { try? String(contentsOf: $0.appendingPathComponent(file), encoding: .utf8) } ?? ""
            let tail = text.split(separator: "\n").suffix(count)
            lines.append("")
            lines.append(tail.isEmpty ? "\(file): –" : "\(file) (letzte \(tail.count)):")
            lines.append(contentsOf: tail.map { "  " + $0 })
        }
        return lines.joined(separator: "\n")
    }

    private static func iso(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }

    private static func clock(_ date: Date?) -> String {
        guard let date else { return "?" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "dd.MM. HH:mm"
        return f.string(from: date)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h \(s % 3600 / 60) min" }
        return "\(s / 86400) d \(s % 86400 / 3600) h"
    }
}
