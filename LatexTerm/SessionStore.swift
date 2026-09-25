import Foundation

/// Eine Kachel im Session-Snapshot: Art + Argumente als Strings (dieselbe Form wie später
/// `new-pane --kind … --arg k=v`). Terminal-Schlüssel: `cwd`, `agent`, `session`, `accentName`.
struct PaneSnapshot: Codable, Equatable {
    var kind: String
    var args: [String: String] = [:]
    /// Kachel-ID (UUID) — beim Wiederherstellen wiederverwendet; nil in alten Snapshots.
    var id: String? = nil
    /// ID der Kachel, von der aus diese geöffnet wurde (Agent erkennt „seine“ Kacheln wieder).
    var openedBy: String? = nil
    /// ID der Kachel, neben der sie steht (Kachel-Layout: Begleiter in deren Nebenspalte).
    var companionOf: String? = nil
    /// Lag als hinterer Reiter verdeckt (Kachel-Layout Stufe 2); nil = sichtbar.
    var hidden: Bool? = nil

    init(kind: String, args: [String: String] = [:], id: String? = nil, openedBy: String? = nil,
         companionOf: String? = nil, hidden: Bool? = nil) {
        self.kind = kind
        self.args = args
        self.id = id
        self.openedBy = openedBy
        self.companionOf = companionOf
        self.hidden = hidden
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        args = try c.decodeIfPresent([String: String].self, forKey: .args) ?? [:]
        id = try c.decodeIfPresent(String.self, forKey: .id)
        openedBy = try c.decodeIfPresent(String.self, forKey: .openedBy)
        companionOf = try? c.decodeIfPresent(String.self, forKey: .companionOf)
        hidden = try? c.decodeIfPresent(Bool.self, forKey: .hidden)
    }
}

/// Session-Snapshot v2 (#11, Kachel-Protokoll §3.7): je Fenster die Kacheln in Reihenfolge
/// plus Fokus und Zoom. Die automatische Anordnung ist eine reine Funktion der Kacheln und der
/// Fenstergröße; nur eine angepasste (Mats zog eine Trennlinie, ein Agent ordnete an) liegt als
/// `layout` bei (Kachel-Layout, 23.09.2026 — optionales Feld, v2 bleibt).
///
/// Geschrieben bei jedem Beenden, als Startlayout benutzt aber nur einmal nach „Neu starten“ /
/// „Beenden und Kacheln merken“ (`restoreOnce`). Sonst beginnt die App mit Home (Mats' Entscheidung
/// 24.08.). Akzentfarben liegen nur als Claude-Farbname bei, damit Nachbarkacheln nach dem
/// Neustart nicht die Farben tauschen.
struct SessionSnapshot: Codable, Equatable {
    struct Window: Codable, Equatable {
        var panes: [PaneSnapshot]
        /// Index in `panes`; nil = keine Kachel fokussiert bzw. nichts gezoomt.
        var focused: Int?
        var zoomed: Int?
        /// Fenster: Einträge mit derselben Nummer sind die Bretter eines Fensters, in Snapshot-Reihenfolge =
        /// Brett-Reihenfolge (bis 22.09. native Tabs einer Leiste — dieselbe Bedeutung, alte Snapshots gelten
        /// weiter). nil = alter Snapshot (alles landet dann in einem Fenster).
        var tabGroup: Int?
        /// Das vordere Brett seines Fensters.
        var selected: Bool?
        /// Angepasste Anordnung; Blätter tragen die Kachel-IDs aus `panes`. nil = Automatik.
        var layout: LayoutNode?
        /// Bretter (23.09.): von Mats gesetzter Name; nil = automatisch.
        var name: String?
        /// Home-Brett (24.09., wieder entfernt 25.09.): nur noch zum Wiedererkennen alter Stände — wird übersprungen.
        var home: Bool?

        init(panes: [PaneSnapshot], focused: Int? = nil, zoomed: Int? = nil,
             tabGroup: Int? = nil, selected: Bool? = nil, layout: LayoutNode? = nil, name: String? = nil) {
            self.panes = panes
            self.focused = focused
            self.zoomed = zoomed
            self.tabGroup = tabGroup
            self.selected = selected
            self.layout = layout
            self.name = name
        }

        private enum CodingKeys: String, CodingKey { case panes, focused, zoomed, tabGroup, selected, layout, name, home }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            panes = try c.decode([PaneSnapshot].self, forKey: .panes)
            focused = try c.decodeIfPresent(Int.self, forKey: .focused)
            zoomed = try c.decodeIfPresent(Int.self, forKey: .zoomed)
            tabGroup = try c.decodeIfPresent(Int.self, forKey: .tabGroup)
            selected = try c.decodeIfPresent(Bool.self, forKey: .selected)
            // Ein kaputtes Layout kostet nur die Anordnung, nie die Kacheln.
            layout = try? c.decodeIfPresent(LayoutNode.self, forKey: .layout)
            name = try? c.decodeIfPresent(String.self, forKey: .name)
            home = try? c.decodeIfPresent(Bool.self, forKey: .home)
        }

        /// Aus den Kacheln eines Fensters: Kacheln ohne Snapshot fallen weg, Fokus- und
        /// Zoom-Index zählen danach (sonst zeigte der Index auf die falsche Kachel).
        /// Das Layout behält nur Kacheln, die im Snapshot stehen.
        init(entries: [(snapshot: PaneSnapshot?, focused: Bool, zoomed: Bool)], layout: LayoutNode? = nil) {
            var panes: [PaneSnapshot] = []
            var focused: Int?, zoomed: Int?
            for entry in entries {
                guard let snapshot = entry.snapshot else { continue }
                if entry.focused { focused = panes.count }
                if entry.zoomed { zoomed = panes.count }
                panes.append(snapshot)
            }
            let ids = Set(panes.compactMap { $0.id?.uppercased() })
            self.init(panes: panes, focused: focused, zoomed: zoomed, layout: layout?.normalized(keeping: ids))
        }
    }

    var version = 2
    var windows: [Window]
    /// Beim nächsten Start einmal wiederherstellen; `SessionStore.takeRestore` löscht die Marke.
    var restoreOnce = false

    init(windows: [Window], restoreOnce: Bool = false) {
        self.windows = windows
        self.restoreOnce = restoreOnce
    }

    private enum CodingKeys: String, CodingKey { case version, windows, restoreOnce }
    private enum V1Keys: String, CodingKey { case paneDirectories }

    /// v1 (`paneDirectories`: CWD je Kachel, nil = Home) wird zu einem Fenster übersetzt; v1 hatte
    /// nie eine Wiederherstell-Marke. Unbekannte Versionen sind ein Fehler (→ Home).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .version)
        switch version {
        case 1:
            let dirs = try decoder.container(keyedBy: V1Keys.self)
                .decode([String?].self, forKey: .paneDirectories)
            windows = [Window(panes: dirs.map { dir in
                dir.map { PaneSnapshot(kind: "terminal", args: ["cwd": $0]) } ?? PaneSnapshot(kind: "home")
            })]
        case 2:
            windows = try c.decode([Window].self, forKey: .windows)
            restoreOnce = try c.decodeIfPresent(Bool.self, forKey: .restoreOnce) ?? false
        default:
            throw DecodingError.dataCorruptedError(forKey: .version, in: c,
                                                   debugDescription: "Snapshot-Version \(version) unbekannt")
        }
    }
}

extension SessionSnapshot {
    /// Fenster in Leisten-Reihenfolge (22.09.): jede Tab-Leiste zusammenhängend und so sortiert wie
    /// angezeigt, Leisten in der Reihenfolge ihres ersten Fensters. `tabs(i)` = Indizes der Fenster in
    /// der Leiste von Fenster i (nil oder ohne i = steht allein). Jedes Fenster kommt genau einmal vor.
    static func tabOrder(count: Int, tabs: (Int) -> [Int]?) -> [(index: Int, group: Int)] {
        var result: [(index: Int, group: Int)] = []
        var seen = Set<Int>()
        var group = 0
        for i in 0..<count where !seen.contains(i) {
            var members = (tabs(i) ?? []).filter { (0..<count).contains($0) && !seen.contains($0) }
            if !members.contains(i) { members = [i] }
            for m in members where seen.insert(m).inserted { result.append((m, group)) }
            group += 1
        }
        return result
    }
}

/// Was aus einer gespeicherten Kachel beim Wiederherstellen wird. Alles im Snapshot gilt als
/// ungeprüft (Datei auf der Platte): Session-IDs und Farbnamen landen später in einem getippten
/// Befehl und müssen deshalb dieselben Regeln erfüllen wie im Steuerkanal.
enum RestoreStep: Equatable {
    /// Home-Kachel.
    case home
    /// App-Kachel aus der Registry (Scratchpad, …). Kennt der Build die Art nicht oder passen
    /// die Args nicht, legt die Split-View stattdessen Home an — der Platz bleibt erhalten.
    case app(kind: String, args: [String: String])
    /// Nackte Shell im Verzeichnis — auch für Kacheln ohne Session-Identität oder mit fremdem
    /// Vordergrundprozess (vim, ssh): deren Zustand lässt sich nicht fortsetzen.
    case shell(cwd: String?)
    /// Agenten-Session über den Home-Weg „Weiter“ fortsetzen.
    case resume(agent: String, sessionID: String, cwd: String?, accentName: String?)

    init(_ pane: PaneSnapshot) {
        if pane.kind == "home" { self = .home; return }
        guard pane.kind == "terminal" else { self = .app(kind: pane.kind, args: pane.args); return }
        let cwd = pane.args["cwd"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        guard let agent = pane.args["agent"], ["claude", "codex"].contains(agent),
              let session = pane.args["session"], AgentSession.validID(session) else {
            self = .shell(cwd: cwd); return
        }
        let accent = pane.args["accentName"].flatMap { name in
            (1...16).contains(name.count) && name.allSatisfy { $0.isASCII && $0.isLowercase } ? name : nil
        }
        self = .resume(agent: agent, sessionID: session, cwd: cwd, accentName: accent)
    }
}

enum SessionStore {

    static var defaultURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("LatexTerm/session.json")
    }

    static func save(_ snapshot: SessionSnapshot, to url: URL? = defaultURL) {
        guard let url, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Letzter Snapshot — nil bei fehlender/korrupter Datei oder unbekannter Version.
    static func load(from url: URL? = defaultURL) -> SessionSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    // MARK: Unsauberes Ende (24.09.2026)
    //
    // Regulär endet die App nur über ⌘Q, ⌥⌘R („Neu starten“) oder das letzte ⌘W — alle laufen durch
    // `applicationWillTerminate`, speichern und räumen die Lauf-Marke weg. Verschwindet die App anders
    // (Absturz, Kill, Zuklappen — zweimal am 24.09. ohne Absturzbericht), steht die Marke beim nächsten
    // Start noch: dann kommt der letzte Autosave-Stand wieder statt Home.

    /// Lauf-Marke neben dem Snapshot: Startzeit + PID des laufenden Prozesses.
    static func runMarkerURL(for url: URL?) -> URL? {
        url?.deletingLastPathComponent().appendingPathComponent("running")
    }

    /// Reguläres Ende: Marke weg (nach dem letzten `save`).
    static func markCleanExit(for url: URL? = defaultURL) {
        guard let marker = runMarkerURL(for: url) else { return }
        try? FileManager.default.removeItem(at: marker)
    }

    /// Stand des Vorlaufs: endete er unsauber (`unclean`), und soll sein Stand zurückkommen (`restore` — nicht, wenn er
    /// schon in der Startphase starb)? Schreibt eine Zeile ins Log.
    private static func previousRunEnd(for url: URL?, now: Date) -> (unclean: Bool, restore: Bool) {
        guard let marker = runMarkerURL(for: url) else { return (false, false) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: marker.path) else { return (false, false) }
        let started = (try? fm.attributesOfItem(atPath: marker.path)[.modificationDate]) as? Date
        let lastSave = url.flatMap { (try? fm.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date }
        // Nur wenn der Vorlauf nach seinem Start noch gespeichert hat (Autosave beginnt erst nach der Startphase):
        // starb er schon vorher, war vermutlich die Wiederherstellung schuld → Home statt Absturz-Schleife.
        var crashed = false
        if let started, let lastSave { crashed = lastSave > started }
        let info = (try? String(contentsOf: marker, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = .current
        appendLog("\(stamp.string(from: now)) unsauberes Ende · Vorlauf \(info) · letzter Autosave "
            + (lastSave.map { stamp.string(from: $0) } ?? "–")
            + (crashed ? " → stelle wieder her" : " → Startphase, Home"), next: marker)
        return (true, crashed)
    }

    /// Eigene Lauf-Marke setzen — nach dem Speichern beim Start, sonst zählte dieses als „nach dem Start gespeichert“.
    private static func writeRunMarker(for url: URL?, now: Date) {
        guard let marker = runMarkerURL(for: url) else { return }
        let line = "pid \(ProcessInfo.processInfo.processIdentifier) seit \(ISO8601DateFormatter().string(from: now))"
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(line.utf8).write(to: marker, options: .atomic)
    }

    /// `unclean.log` neben der Marke — Spur für die Ursachensuche.
    private static func appendLog(_ line: String, next marker: URL) {
        let log = marker.deletingLastPathComponent().appendingPathComponent("unclean.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }

    /// Autosave: nur schreiben, wenn sich etwas geändert hat.
    private static var lastAutosave: Data?
    private static var lastAutosaveArchived: Date?
    /// Höchstens so oft landet ein Autosave-Stand im Archiv (nur bei Änderung).
    static let autosaveArchiveInterval: TimeInterval = 600
    static func autosave(_ snapshot: SessionSnapshot, to url: URL? = defaultURL, now: Date = Date()) {
        guard let url, let data = try? JSONEncoder().encode(snapshot), data != lastAutosave else { return }
        lastAutosave = data
        try? data.write(to: url, options: .atomic)
        if lastAutosaveArchived.map({ now.timeIntervalSince($0) >= autosaveArchiveInterval }) ?? true {
            lastAutosaveArchived = now
            archive(snapshot, reason: "autosave", for: url, now: now)
        }
    }

    /// Fenster zum Wiederherstellen, wenn die Marke steht oder der Vorlauf unsauber endete — sonst nil
    /// (normaler Start mit Home). Die Marke wird VOR dem Wiederherstellen gelöscht: bricht der Start ab,
    /// kommt beim nächsten Öffnen wieder Home statt derselben Wiederherstellung in Schleife.
    static func takeRestore(from url: URL? = defaultURL, now: Date = Date()) -> [SessionSnapshot.Window]? {
        let end = previousRunEnd(for: url, now: now)
        defer { writeRunMarker(for: url, now: now) }
        // Den vorgefundenen Stand eines unsauberen Endes immer ins Archiv — auch wenn er nicht automatisch zurückkommt.
        if end.unclean, let found = load(from: url) { archive(found, reason: "absturz", for: url, now: now) }
        guard var snapshot = load(from: url), snapshot.restoreOnce || end.restore else { return nil }
        snapshot.restoreOnce = false
        save(snapshot, to: url)
        let windows = snapshot.windows.filter { !$0.panes.isEmpty }
        return windows.isEmpty ? nil : windows
    }
}

// MARK: Stand-Archiv (25.09.2026)
//
// `session.json` ist nur der letzte Stand und wird bei jedem Beenden überschrieben. Das Archiv hält die letzten
// `archiveLimit` Stände als eigene Dateien, damit ein verlorener Stand auch später noch zurückkommt
// (`latexterm snapshots` / `restore`, MCP `snapshots` / `restore_snapshot`).
extension SessionStore {
    static let archiveLimit = 30

    static func archiveDirectory(for url: URL?) -> URL? {
        url?.deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
    }

    private static func archiveStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: date)
    }

    /// Stand ablegen — nicht, wenn er leer ist oder dem neuesten Eintrag gleicht. Hält höchstens `archiveLimit`.
    static func archive(_ snapshot: SessionSnapshot, reason: String, for url: URL? = defaultURL, now: Date = Date()) {
        guard let dir = archiveDirectory(for: url), snapshot.windows.contains(where: { !$0.panes.isEmpty }) else { return }
        var clean = snapshot
        clean.restoreOnce = false
        guard let data = try? JSONEncoder().encode(clean) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = archivedFiles(in: dir)
        if let newest = existing.first, let old = try? Data(contentsOf: newest),
           let oldSnapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: old), oldSnapshot == clean { return }
        var name = "\(archiveStamp(now))_\(reason)"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(name + ".json").path) { name = "\(archiveStamp(now))_\(reason)-\(n)"; n += 1 }
        try? data.write(to: dir.appendingPathComponent(name + ".json"), options: .atomic)
        for stale in archivedFiles(in: dir).dropFirst(archiveLimit) { try? fm.removeItem(at: stale) }
    }

    /// Archiv-Dateien, neueste zuerst (der Name beginnt mit Datum und Uhrzeit).
    private static func archivedFiles(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Archivierte Stände, neuester zuerst.
    static func archived(for url: URL? = defaultURL) -> [(summary: SnapshotSummary, snapshot: SessionSnapshot)] {
        guard let dir = archiveDirectory(for: url) else { return [] }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        var result: [(SnapshotSummary, SessionSnapshot)] = []
        for file in archivedFiles(in: dir) {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) else { continue }
            let name = file.deletingPathExtension().lastPathComponent
            let stamp = String(name.prefix(19))
            let reason = name.count > 20 ? String(name.dropFirst(20)) : "?"
            let date = parse.date(from: stamp).map { iso.string(from: $0) } ?? stamp
            let boards = snapshot.windows.filter { !$0.panes.isEmpty && $0.home != true }
                .map { SnapshotSummary.Board(name: $0.name, panes: $0.panes.map(describe)) }
            result.append((SnapshotSummary(name: name, index: result.count + 1, date: date, reason: reason, boards: boards),
                           snapshot))
        }
        return result
    }

    /// Stand nach Nummer (1 = neuester) oder Name (auch Präfix, eindeutig); nil = neuester.
    static func findArchived(_ selector: String?, for url: URL? = defaultURL)
        -> Result<(summary: SnapshotSummary, snapshot: SessionSnapshot), SnapshotLookupError> {
        let all = archived(for: url)
        guard !all.isEmpty else { return .failure(SnapshotLookupError("Noch keine gespeicherten Stände")) }
        guard let selector = selector?.trimmingCharacters(in: .whitespaces), !selector.isEmpty else { return .success(all[0]) }
        if let n = Int(selector) {
            guard all.indices.contains(n - 1) else {
                return .failure(SnapshotLookupError("Stand \(n) gibt es nicht (1–\(all.count))"))
            }
            return .success(all[n - 1])
        }
        let matches = all.filter { $0.summary.name.hasPrefix(selector) }
        guard matches.count == 1 else {
            return .failure(SnapshotLookupError(matches.isEmpty ? "Kein Stand „\(selector)“ — `latexterm snapshots` zeigt alle"
                                                                : "„\(selector)“ passt auf \(matches.count) Stände"))
        }
        return .success(matches[0])
    }

    /// Kurzbeschreibung einer gespeicherten Kachel für Menschen und Agenten.
    static func describe(_ pane: PaneSnapshot) -> String {
        let home = NSHomeDirectory()
        let cwd = pane.args["cwd"].map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
        switch RestoreStep(pane) {
        case .home: return "home"
        case .shell: return "shell" + (cwd.map { " " + $0 } ?? "")
        case .resume(let agent, let session, _, _): return agent + (cwd.map { " " + $0 } ?? "") + " (\(session.prefix(8)))"
        case .app(let kind, let args):
            let detail = args["url"].map { " " + ($0 as NSString).lastPathComponent } ?? ""
            return kind + detail
        }
    }
}

struct SnapshotLookupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Was von einem Stand fehlt: Kacheln, die schon offen sind, fallen heraus (gleiche Kachel-ID, gleiche Agenten-Session,
/// gleicher App-Inhalt), ein Brett ohne Rest entfällt, das Home-Brett kommt nie aus dem Stand (entsteht von selbst).
struct OpenPanes {
    var ids: Set<String> = []
    var sessions: Set<String> = []
    /// „<art>|<id oder url>“ der App-Kacheln.
    var contents: Set<String> = []

    static func contentKey(kind: String, args: [String: String]) -> String? {
        guard let key = args["id"] ?? args["url"] else { return nil }
        return kind + "|" + key.uppercased()
    }

    func contains(_ pane: PaneSnapshot) -> Bool {
        if let id = pane.id?.uppercased(), ids.contains(id) { return true }
        switch RestoreStep(pane) {
        case .resume(_, let session, _, _): return sessions.contains(session.lowercased())
        case .app(let kind, let args): return OpenPanes.contentKey(kind: kind, args: args).map(contents.contains) ?? false
        case .home, .shell: return false
        }
    }

    /// Fehlende Bretter; Fokus zeigt danach auf dieselbe Kachel, falls sie mitkommt.
    func missing(from windows: [SessionSnapshot.Window]) -> [SessionSnapshot.Window] {
        windows.compactMap { window in
            guard window.home != true else { return nil }
            let entries = window.panes.enumerated().filter { !contains($0.element) }
            guard !entries.isEmpty else { return nil }
            var kept = window
            kept.panes = entries.map(\.element)
            kept.focused = window.focused.flatMap { f in entries.firstIndex { $0.offset == f } }
            kept.zoomed = window.zoomed.flatMap { z in entries.firstIndex { $0.offset == z } }
            kept.selected = false
            let ids = Set(kept.panes.compactMap { $0.id?.uppercased() })
            kept.layout = window.layout?.normalized(keeping: ids)
            return kept
        }
    }
}

/// Wiederherzustellende Bretter beim Start. Jedes neue Fenster holt sich die nächste Gruppe (seine Bretter); das
/// erste öffnet für die übrigen Gruppen neue Fenster (macOS öffnet nach ⌘Q meist nur eins). Was danach noch niemand
/// geholt hat, hängt das erste Fenster als Kacheln an — keine Session geht verloren, schlimmstenfalls die Grenze.
struct RestoreQueue {
    private var windows: [SessionSnapshot.Window]
    /// Home-Bretter alter Stände (24.09.) kommen nicht wieder — die Art gibt es nicht mehr.
    init(_ windows: [SessionSnapshot.Window]) { self.windows = windows.filter { $0.home != true } }

    var isEmpty: Bool { windows.isEmpty }
    var count: Int { windows.count }
    /// Zahl der Gruppen (Fenster), die noch warten.
    var groupCount: Int {
        zip(windows, windows.dropFirst()).filter { $0.tabGroup != $1.tabGroup }.count + (windows.isEmpty ? 0 : 1)
    }

    /// Bretter (23.09.): alle aufeinanderfolgenden Pläne derselben Gruppe = die Bretter eines Fensters.
    mutating func claimGroup() -> [SessionSnapshot.Window] {
        guard let first = claim() else { return [] }
        var group = [first]
        while let next = windows.first, next.tabGroup == first.tabGroup { group.append(next); windows.removeFirst() }
        return group
    }

    mutating func claim() -> SessionSnapshot.Window? {
        windows.isEmpty ? nil : windows.removeFirst()
    }

    mutating func drain() -> [SessionSnapshot.Window] {
        defer { windows = [] }
        return windows
    }
}
