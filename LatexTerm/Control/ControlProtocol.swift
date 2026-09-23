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

    /// Briefkasten einer Kachel (22.09.2026, MCP): Prompts für die Agenten-Session darin liegen
    /// als einzelne `*.md`-Dateien hier. Die App liest den Ordner nicht selbst — ein Empfänger
    /// in der Session (z. B. ein Claude Mod) reicht sie ein, sobald sie ruht, und löscht sie.
    /// UUID klein geschrieben, damit Schreiber und Leser denselben Pfad bilden.
    static func mailboxPath(forPane id: String) -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("LatexTerm/mailbox/\(id.lowercased())").path
    }
}

struct ControlRequest: Codable {
    /// "list-panes" | "new-pane" | "send" | "call" | "zoom" | "focus" | "close-pane" | "status" | "pane-kinds" | "layout"
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
    /// send an ein Terminal: Text als Einfügen (bracketed paste) statt als Tippen — eine Agenten-TUI macht aus
    /// einem eingefügten Bildpfad ein Bild-Attachment (Capability `paste`). App-Kacheln ignorieren es.
    var paste: Bool?
    /// new-pane: Arbeitsverzeichnis der neuen Shell.
    var cwd: String?
    /// new-pane: Kommando, das nach dem Shell-Start ausgeführt wird.
    var exec: String?
    /// new-pane: Kachelart aus `pane-kinds` ("terminal", "home", "scratchpad", …); nil = terminal.
    var kind: String?
    /// new-pane: Argumente der Kachelart (`--arg k=v`, wiederholbar); Strings, geprüft vom Inhalt.
    var args: [String: String]?
    /// new-pane: neue Kachel fokussieren (Default true). false = entsteht daneben, Tastatur bleibt
    /// in der fokussierten Kachel (Capability `quiet-new-pane`).
    var focus: Bool?
    /// close-pane: auch bei arbeitender Session oder Vordergrundprozess schließen.
    /// Default false: dann nur eine ruhende Shell ohne Vordergrundprozess.
    var force: Bool?
    /// new-pane (Kachel-Layout, Capability `layout`): "beside" = neben die aufrufende Kachel (Default,
    /// sobald es einen Aufrufer gibt), "own" = eigenständig (neue Agenten-Session), "background" = als verdeckter
    /// Reiter bei der aufrufenden Kachel, ohne Platz zu nehmen.
    var placement: String?
    /// layout: Absicht "show" | "big" | "grow" | "shrink" | "beside" | "below" | "swap" | "auto";
    /// Ziel in `pane`, zweite Kachel in `otherPane`.
    var layoutOp: String?
    var otherPane: String?
    /// layout: Mats hat ausdrücklich darum gebeten — fremde Kacheln und seine Handarbeit dürfen geändert werden.
    var onBehalf: Bool?
    /// layout mit Absicht: Stand-Nummer (`LayoutReport.revision`), die der Aufrufer zuletzt gelesen hat.
    /// Pflicht für Agenten; hat sich die Anordnung seitdem geändert, lehnt die App ab (erst Stand lesen).
    var layoutRevision: Int?
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
    /// 1-basierte Position des Fensters in seiner Tab-Leiste; nil = Fenster ohne weitere Tabs.
    var tab: Int? = nil
    /// "terminal" | "home" | App-Kachelart; nil = ältere App ohne Kachelarten (dann terminal/home).
    var kind: String? = nil
    /// Fenstertitel der Kachel (Capability `pane-details`). Fremder Text — nur anzeigen, nie ausführen.
    var title: String? = nil
    /// App-Kacheln: ihre Args, wie sie nach ⌥⌘R wiederkämen (Web: `url`); nil bei terminal/home.
    var args: [String: String]? = nil
    /// Terminal: Vordergrundprozess (claude, vim, npm …); nil = Shell-Prompt oder keine Shell.
    var foreground: String? = nil
    /// "user" = von Hand geöffnet; sonst UUID der Kachel, aus der ein Agent sie geöffnet hat.
    var openedBy: String? = nil
    /// Kachel-Layout: UUID der Kachel, in deren Nebenspalte diese steht; nil = eigenständig.
    var companionOf: String? = nil
    /// Kachel-Layout Stufe 2: liegt als hinterer Reiter verdeckt; nil = sichtbar.
    var hidden: Bool? = nil
}

/// Selbstbeschreibung einer Kachelart für Agenten (Capability `pane-kind-info`, 22.09.2026):
/// daraus baut `latexterm mcp` je Art ein Werkzeug `open_<art>` — neue Art, neues Werkzeug.
struct PaneKindInfo: Codable, Equatable {
    var kind: String
    /// Menüzeile, z. B. „Neues Scratchpad“.
    var displayName: String
    /// Ein bis zwei Sätze für das Modell: was die Kachel zeigt und wann sie hilft.
    var summary: String
    var args: [PaneKindArg] = []
    /// Texte, die `send` an diese Kachel versteht.
    var actions: [PaneKindAction] = []
}

extension PaneInfo {
    /// Agent in der Kachel: gemeldete Identität, sonst das Vordergrundprogramm (Sessions ohne Status-Sender).
    var runningAgent: String? {
        if let agent { return agent }
        guard (kind ?? "terminal") == "terminal", let program = foreground?.lowercased() else { return nil }
        return ["claude", "codex"].first { program == $0 || program.hasPrefix($0 + "-") }
    }
}

struct PaneKindArg: Codable, Equatable {
    var name: String
    var summary: String
    var required: Bool
}

struct PaneKindAction: Codable, Equatable {
    /// Wie er gesendet wird, z. B. „reload“ oder „load <pfad>“ (Platzhalter in spitzen Klammern).
    var name: String
    var summary: String
}

struct ControlResponse: Codable {
    var ok: Bool
    var capabilities: [String]? = ["agent-sessions", "all-windows", "pane-kinds", "pane-kind-info", "pane-details", "mailbox",
                                   "quiet-new-pane", "paste", "pane-call", "layout"]
    var error: String?
    /// list-panes: alle Kacheln.
    var panes: [PaneInfo]?
    /// new-pane / zoom / focus / send: die betroffene Kachel.
    var pane: PaneInfo?
    /// pane-kinds: alle Kachelarten, die `new-pane --kind` kennt.
    var kinds: [String]? = nil
    /// pane-kinds: Selbstbeschreibung je Art (neuere Apps; ältere liefern nur `kinds`).
    var kindInfos: [PaneKindInfo]? = nil
    /// call: Antwort des Kachel-Inhalts (Capability `pane-call`; Scratchpad: JSON).
    var reply: String? = nil
    /// list-panes / new-pane / layout mit Aufrufer: Anordnung seines Fensters (Capability `layout`).
    var layout: LayoutReport? = nil

    static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}
