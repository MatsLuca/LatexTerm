import Foundation
import Combine

/// Lokal-Modus: Claude Code läuft gegen ein lokales Ollama-Modell statt der Anthropic-API
/// (Fallback für „kein Internet" / „Tokens leer", claude-werkstatt/lokal/README.md).
/// Wahrheit ist die Flag-Datei `~/.config/projekte/lokal-modus` — nicht UserDefaults: Launcher
/// (`start.zsh`) und Datenschicht (`projekte.py`) prüfen sie bei jedem Start, und auch die Shell
/// darf sie setzen/löschen. Existiert sie, startet jedes Projekt über `lokal` statt `claude`.
final class LokalModusSettings: ObservableObject {
    static let shared = LokalModusSettings()
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/projekte/lokal-modus")

    @Published var enabled: Bool = false {
        didSet {
            guard !loading, enabled != oldValue else { return }
            let fm = FileManager.default
            if enabled {
                try? fm.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? "an\n".write(to: Self.fileURL, atomically: true, encoding: .utf8)
            } else {
                try? fm.removeItem(at: Self.fileURL)
            }
            // Statuszeilen-Segment mitschalten: Lokal an → 🦙-Infos an, aus → aus.
            // Bleibt danach im Statuszeile-Tab weiterhin von Hand übersteuerbar.
            StatuslineSettings.shared.set(.lokal, on: enabled)
        }
    }

    private var loading = false
    private init() { load() }

    /// Beim Öffnen des Fensters erneut aufrufen — die Datei kann auch von außen geändert worden sein.
    func load() {
        loading = true
        enabled = FileManager.default.fileExists(atPath: Self.fileURL.path)
        loading = false
    }
}
