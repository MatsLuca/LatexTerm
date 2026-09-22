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

    init(kind: String, args: [String: String] = [:], id: String? = nil, openedBy: String? = nil) {
        self.kind = kind
        self.args = args
        self.id = id
        self.openedBy = openedBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        args = try c.decodeIfPresent([String: String].self, forKey: .args) ?? [:]
        id = try c.decodeIfPresent(String.self, forKey: .id)
        openedBy = try c.decodeIfPresent(String.self, forKey: .openedBy)
    }
}

/// Session-Snapshot v2 (#11, Kachel-Protokoll §3.7): je Fenster die Kacheln in Reihenfolge
/// plus Fokus und Zoom. Die Grid-Anordnung selbst ist eine reine Funktion der Kachelzahl und
/// Fenstergröße (`TerminalSplitView.relayout`) und braucht keinen eigenen Zustand.
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

        init(panes: [PaneSnapshot], focused: Int? = nil, zoomed: Int? = nil) {
            self.panes = panes
            self.focused = focused
            self.zoomed = zoomed
        }

        /// Aus den Kacheln eines Fensters: Kacheln ohne Snapshot fallen weg, Fokus- und
        /// Zoom-Index zählen danach (sonst zeigte der Index auf die falsche Kachel).
        init(entries: [(snapshot: PaneSnapshot?, focused: Bool, zoomed: Bool)]) {
            var panes: [PaneSnapshot] = []
            var focused: Int?, zoomed: Int?
            for entry in entries {
                guard let snapshot = entry.snapshot else { continue }
                if entry.focused { focused = panes.count }
                if entry.zoomed { zoomed = panes.count }
                panes.append(snapshot)
            }
            self.init(panes: panes, focused: focused, zoomed: zoomed)
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

    /// Fenster zum Wiederherstellen, wenn die Marke steht — sonst nil (normaler Start mit Home).
    /// Die Marke wird VOR dem Wiederherstellen gelöscht: bricht der Start ab, kommt beim nächsten
    /// Öffnen wieder Home statt derselben Wiederherstellung in Schleife.
    static func takeRestore(from url: URL? = defaultURL) -> [SessionSnapshot.Window]? {
        guard var snapshot = load(from: url), snapshot.restoreOnce else { return nil }
        snapshot.restoreOnce = false
        save(snapshot, to: url)
        let windows = snapshot.windows.filter { !$0.panes.isEmpty }
        return windows.isEmpty ? nil : windows
    }
}

/// Wiederherzustellende Fenster beim Start. Jedes neue Fenster holt sich das nächste; was nach
/// dem Start niemand geholt hat (macOS öffnet nach ⌘Q meist nur ein Fenster), hängt das erste
/// Fenster als Kacheln an — keine Session geht verloren, nur die Fenstergrenze.
struct RestoreQueue {
    private var windows: [SessionSnapshot.Window]
    init(_ windows: [SessionSnapshot.Window]) { self.windows = windows }

    var isEmpty: Bool { windows.isEmpty }

    mutating func claim() -> SessionSnapshot.Window? {
        windows.isEmpty ? nil : windows.removeFirst()
    }

    mutating func drain() -> [SessionSnapshot.Window] {
        defer { windows = [] }
        return windows
    }
}
