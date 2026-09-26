import Foundation

// `latexterm mcp` (22.09.2026) — MCP-Server über stdio für Agenten-Sessions in einer Kachel.
//
// Warum im CLI: derselbe Socket-Code, dieselbe `ControlProtocol.swift` wie `latexterm` selbst —
// App und Server können nicht auseinanderlaufen. Der Server ist eine Schicht auf dem Steuerkanal,
// kein Ersatz: Skripte, Hooks und Mods sprechen weiter das CLI.
//
// Was er anders macht als das CLI:
// - Werkzeuge auf Absichts-Ebene (Datei zeigen, Session fragen, Agent starten) statt Verben.
// - Schutz als Bauart: kein `force`, nie in die eigene Kachel tippen, Befehle nur in ruhende
//   Shells, Prompts an Agenten über den Briefkasten (`ControlProtocol.mailboxPath`).
// - Je App-Kachelart ein Werkzeug `open_<art>`, gebaut aus der Selbstbeschreibung der App
//   (`pane-kinds` → `kindInfos`): neue Kachelart, neues Werkzeug — ohne Änderung hier.
// - `instructions` beim Start: wo die Session sitzt und wofür Kacheln gut sind.
//
// Außerhalb LatexTerm (keine `LATEXTERM_PANE_ID`) bietet er keine Werkzeuge an. Ein Server-Prozess
// gehört genau einer Session; er merkt sich, welche Kacheln sie geöffnet hat (`close_pane`).
//
// Aufteilung (26.09.2026): hier Rahmen und JSON-RPC; `+Werkzeuge` Katalog und Verteilung, `+Lagebild` Instructions,
// `panes` und Anordnungsbaum, `+Kacheln` öffnen/bedienen/anordnen/Bretter, `+Sessions` Agenten und Briefkasten,
// `+Ansehen` Vorschau/Web/Terminal lesen, `+Scratchpad` Malfläche, `+Hilfen` Roundtrip, Ziele, Pfade.

/// Weg zur App; im Test ein Fake.
protocol ControlTransport {
    func send(_ request: ControlRequest) throws -> ControlResponse
}

struct SocketTransport: ControlTransport {
    func send(_ request: ControlRequest) throws -> ControlResponse {
        try ControlClient.roundtrip(request)
    }
}

/// Fehler, den das Modell als Werkzeug-Ergebnis sieht (`isError`), mit Grund und Ausweg.
struct ToolFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

final class MCPServer {
    typealias JSON = [String: Any]

    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let paneID: String?
    let transport: ControlTransport
    let startCommands: [String: String]
    let workingDirectory: String
    let mailboxPath: (String) -> String
    let sleep: (TimeInterval) -> Void
    let now: () -> Date
    /// Kacheln, die diese Session geöffnet hat (UUID groß) — nur die darf sie ohne Auftrag schließen.
    var opened: Set<String> = []
    var kindInfos: [PaneKindInfo] = []
    /// Arten, die die laufende App nur beim Namen nennt (App älter als der Server).
    var undescribed: Set<String> = []
    /// Kachel-Layout: Stand-Nummer der Anordnung, die das Modell zuletzt gesehen hat — nur damit darf es
    /// umordnen (die App lehnt einen veralteten Stand ab und schickt den aktuellen mit).
    var layoutSeen: Int?
    /// Nummer → UUID, wie das Modell sie zuletzt gesehen hat. Verschieben sich die Nummern (Umordnen,
    /// Kachel zu), wird eine alte Nummer abgelehnt statt still eine andere Kachel zu treffen.
    var shownIndex: [Int: String] = [:]

    init(environment: [String: String],
         transport: ControlTransport = SocketTransport(),
         workingDirectory: String = FileManager.default.currentDirectoryPath,
         mailboxPath: @escaping (String) -> String = ControlProtocol.mailboxPath(forPane:),
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         now: @escaping () -> Date = Date.init) {
        let pane = environment["LATEXTERM_PANE_ID"]?.trimmingCharacters(in: .whitespaces)
        paneID = (pane?.isEmpty ?? true) ? nil : pane
        self.transport = transport
        startCommands = ["claude": environment["LATEXTERM_START_CLAUDE"] ?? "claude",
                         "codex": environment["LATEXTERM_START_CODEX"] ?? "codex"]
        self.workingDirectory = workingDirectory
        self.mailboxPath = mailboxPath
        self.sleep = sleep
        self.now = now
    }

    // MARK: - JSON-RPC

    /// Eine Nachricht rein, Antwort raus (nil bei Notifications).
    func handle(_ message: JSON) -> JSON? {
        guard let method = message["method"] as? String else { return nil }
        let id = message["id"]
        guard id != nil else { return nil }   // Notification (initialized, cancelled …): nichts zu antworten
        let params = message["params"] as? JSON ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[1]
            return reply(id, ["protocolVersion": version,
                              "capabilities": ["tools": ["listChanged": false]],
                              "serverInfo": ["name": "latexterm", "title": "LatexTerm", "version": "1.0.0"],
                              "instructions": instructions()])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": tools()])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return failure(id, code: -32602, "tools/call ohne name")
            }
            let arguments = params["arguments"] as? JSON ?? [:]
            if paneID != nil, !toolNames.contains(name) { _ = tools() }   // Aufruf ohne vorheriges tools/list
            guard paneID != nil, toolNames.contains(name) else {
                return failure(id, code: -32602, "Unbekanntes Werkzeug „\(name)“")
            }
            do {
                return reply(id, ["content": try content(name, arguments), "isError": false])
            } catch {
                return reply(id, ["content": [["type": "text", "text": String(describing: error)]], "isError": true])
            }
        default:
            return failure(id, code: -32601, "Methode „\(method)“ gibt es hier nicht")
        }
    }

    func reply(_ id: Any?, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    func failure(_ id: Any?, code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}

/// stdio-Rahmen: eine JSON-Nachricht je Zeile rein, eine je Zeile raus (MCP stdio transport).
enum MCPStdio {
    static func run(server: MCPServer) {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let response: [String: Any]?
            if let data = line.data(using: .utf8),
               let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                response = server.handle(message)
            } else {
                response = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Kein gültiges JSON"]]
            }
            guard let response,
                  let out = try? JSONSerialization.data(withJSONObject: response, options: [.withoutEscapingSlashes]) else { continue }
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
        }
    }
}
