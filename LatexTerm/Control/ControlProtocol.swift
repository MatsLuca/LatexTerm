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
    /// "list-panes" | "new-pane" | "send" | "zoom" | "focus" | "close-pane" | "status"
    var cmd: String
    /// Ziel-Kachel: 1-basierter Index ("2") oder UUID(-Präfix). Fehlt er, nimmt
    /// die App bei zoom/focus/send die Kachel aus `paneID` (= LATEXTERM_PANE_ID
    /// des CLI-Aufrufers) — ein Hook kann so „seine" Kachel meinen.
    var pane: String?
    /// Vom CLI aus der Env übernommene LATEXTERM_PANE_ID (Fallback-Ziel).
    var paneID: String?
    /// send: zu tippender Text. status: Payload `<state>[;detail][;k=v…]` (wie OSC 5522 `status=`).
    var text: String?
    /// send: abschließendes Enter (\r) mitschicken. Default true.
    var enter: Bool?
    /// new-pane: Arbeitsverzeichnis der neuen Shell.
    var cwd: String?
    /// new-pane: Kommando, das nach dem Shell-Start ausgeführt wird.
    var exec: String?
    /// close-pane: auch bei arbeitender Session oder Vordergrundprozess schließen.
    /// Default false: dann nur eine ruhende Shell ohne Vordergrundprozess.
    var force: Bool?
    /// Optional precise status identity. Legacy status senders remain valid Claude senders.
    var agent: String?
    var sessionID: String?
    var turnID: String?
    var sourceGroup: Int32?
}

struct PaneInfo: Codable {
    var id: String
    /// 1-basierte Position: registrierte Fenster, darin jeweils Grid-Reihenfolge.
    var index: Int
    var cwd: String?
    var focused: Bool
    var zoomed: Bool
    /// "none" | "ready" | "working" | "awaitingInput"; identity fields distinguish agents.
    var state: String
    var agent: String? = nil
    var sessionID: String? = nil
    var windowID: String? = nil
}

struct ControlResponse: Codable {
    var ok: Bool
    var capabilities: [String]? = ["agent-sessions", "all-windows"]
    var error: String?
    /// list-panes: alle Kacheln.
    var panes: [PaneInfo]?
    /// new-pane / zoom / focus / send: die betroffene Kachel.
    var pane: PaneInfo?

    static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}
