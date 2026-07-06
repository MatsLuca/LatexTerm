import Foundation

/// Drahtformat des Steuerkanals (#28): eine JSON-Zeile Request → eine JSON-Zeile
/// Response über den Unix-Socket, dann schließt die App die Verbindung. Diese Datei
/// wird von App UND `latexterm`-CLI kompiliert (Foundation-only halten!) — sie ist
/// die einzige gemeinsame Wahrheit über das Protokoll.
enum ControlProtocol {
    /// Socket der laufenden App. Fester Pfad statt Discovery: LatexTerm läuft
    /// (LaunchServices-dedupliziert) nur einmal pro User.
    static var socketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("LatexTerm/control.sock").path
    }
}

struct ControlRequest: Codable {
    /// "list-panes" | "new-pane" | "send" | "zoom" | "focus"
    var cmd: String
    /// Ziel-Kachel: 1-basierter Index ("2") oder UUID(-Präfix). Fehlt er, nimmt
    /// die App bei zoom/focus/send die Kachel aus `paneID` (= LATEXTERM_PANE_ID
    /// des CLI-Aufrufers) — ein Hook kann so „seine" Kachel meinen.
    var pane: String?
    /// Vom CLI aus der Env übernommene LATEXTERM_PANE_ID (Fallback-Ziel).
    var paneID: String?
    /// send: zu tippender Text.
    var text: String?
    /// send: abschließendes Enter (\r) mitschicken. Default true.
    var enter: Bool?
    /// new-pane: Arbeitsverzeichnis der neuen Shell.
    var cwd: String?
    /// new-pane: Kommando, das nach dem Shell-Start ausgeführt wird.
    var exec: String?
}

struct PaneInfo: Codable {
    var id: String
    /// 1-basierte Position in der Grid-Reihenfolge (= Reihenfolge der Titlebar-Punkte).
    var index: Int
    var cwd: String?
    var focused: Bool
    var zoomed: Bool
    /// Passiv erkannter Claude-Code-Zustand: "none" | "working" | "awaitingInput".
    var state: String
}

struct ControlResponse: Codable {
    var ok: Bool
    var error: String?
    /// list-panes: alle Kacheln.
    var panes: [PaneInfo]?
    /// new-pane / zoom / focus / send: die betroffene Kachel.
    var pane: PaneInfo?

    static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}
