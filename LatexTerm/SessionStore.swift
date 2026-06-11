import Foundation

/// Session-Restore (#11): persistiert das Pane-Layout über App-Neustarts.
///
/// Gespeichert wird nur, was nicht rekonstruierbar ist: je Pane das zuletzt per
/// OSC 7 gemeldete Arbeitsverzeichnis (nil = Home). Die Grid-Anordnung selbst ist
/// eine reine Funktion der Pane-Anzahl + Fenstergröße (`TerminalSplitView.relayout`)
/// und braucht keinen eigenen Zustand. Persistenz als JSON-Datei in Application
/// Support — kein UserDefaults-Component-Salat, anschlussfähig an eine spätere
/// Config-Datei.
struct SessionSnapshot: Codable {
    var version: Int = 1
    /// Arbeitsverzeichnis je Pane, in Kachel-Reihenfolge. `nil` = Home.
    var paneDirectories: [String?]
}

enum SessionStore {

    private static var fileURL: URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("LatexTerm/session.json")
    }

    static func save(_ snapshot: SessionSnapshot) {
        guard let url = fileURL,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Letzter Snapshot — nil bei fehlender/korrupter Datei oder unbekannter Version
    /// (→ Aufrufer startet mit dem Default-Layout, eine Kachel im Home).
    static func load() -> SessionSnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(SessionSnapshot.self, from: data),
              snap.version == 1, !snap.paneDirectories.isEmpty else { return nil }
        return snap
    }
}
