import Foundation

// latexterm — Steuerkanal-CLI (#28). Spricht die JSON-Zeilen des ControlProtocol
// über den Unix-Socket der laufenden App. Bewusst ohne ArgumentParser-Dependency:
// neun Verben, eine Handvoll Flags. `latexterm mcp` (22.09.2026) macht dasselbe
// Binary zum MCP-Server über stdio (MCPServer.swift). Wird ins App-Bundle eingebettet
// (LatexTerm.app/Contents/Helpers/latexterm); Nutzung via Symlink oder PATH.

let usage = """
latexterm — steuert die laufende LatexTerm.app

Verwendung:
  latexterm list-panes [--json]
  latexterm new-pane [--cwd VERZEICHNIS] [--exec KOMMANDO] [--no-focus]
  latexterm new-pane --kind ART [--arg SCHLÜSSEL=WERT]… [--no-focus]
  latexterm pane-kinds
  latexterm send [--pane ZIEL] [--no-enter] TEXT…
  latexterm zoom [--pane ZIEL]
  latexterm focus [--pane ZIEL]
  latexterm close-pane [--pane ZIEL] [--force]
  latexterm status [--pane ZIEL] [--agent claude|codex --session ID] [--turn ID] PAYLOAD
  latexterm mcp

ZIEL ist der 1-basierte Index aus `list-panes` oder eine Pane-UUID (auch Präfix).
ART ist eine Kachelart aus `pane-kinds` (terminal, home, scratchpad, …); --cwd/--exec nur für terminal.
send an eine App-Kachel reicht den Text an deren Inhalt (Scratchpad: `clear`, `undo`).
Ohne --pane verwenden send/zoom/focus/close-pane $LATEXTERM_PANE_ID — also die Kachel,
in deren Shell dieses Kommando läuft.

close-pane schließt ohne --force nur eine ruhende Shell ohne Vordergrundprozess.
Bei arbeitender Session oder laufendem Vordergrundprozess: Exit 1 mit Grund.
--force entspricht Cmd+W ohne Rückfrage.

status meldet Agenten-Zustand und optional die echte Session-ID (`working;Bash;t=12;n=3`).
Zustände: ready / working / input / done / closed. Ohne Anbieterfelder bleibt das Legacy-Claude-Protokoll.

--no-focus: die neue Kachel entsteht daneben, die Tastatur bleibt in der fokussierten Kachel.

mcp startet einen MCP-Server über stdio (für Claude Code / Codex): Werkzeuge auf Absichts-Ebene
(panes, open_terminal, start_agent, ask_session, …) und je App-Kachelart ein open_<art>.

Exit-Codes: 0 ok · 1 Fehler aus der App · 2 Aufruffehler · 3 App nicht erreichbar
"""

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

// MARK: - Argumente parsen

var args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail(usage, code: 2) }
if cmd == "--help" || cmd == "-h" || cmd == "help" { print(usage); exit(0) }
args.removeFirst()
if cmd == "mcp" {
    guard args.isEmpty else { fail("mcp nimmt keine Argumente\n\n\(usage)", code: 2) }
    MCPStdio.run(server: MCPServer(environment: ProcessInfo.processInfo.environment))
    exit(0)
}

var request = ControlRequest(cmd: cmd)
request.paneID = ProcessInfo.processInfo.environment["LATEXTERM_PANE_ID"]
var wantsJSON = false
var positional: [String] = []

while !args.isEmpty {
    let arg = args.removeFirst()
    func value(for flag: String) -> String {
        guard !args.isEmpty else { fail("\(flag) braucht einen Wert\n\n\(usage)", code: 2) }
        return args.removeFirst()
    }
    switch arg {
    case "--pane":     request.pane = value(for: arg)
    case "--cwd":      request.cwd = value(for: arg)
    case "--exec":     request.exec = value(for: arg)
    case "--kind":     request.kind = value(for: arg)
    case "--arg":
        let pair = value(for: arg)
        guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else {
            fail("--arg erwartet SCHLÜSSEL=WERT, bekam „\(pair)“", code: 2)
        }
        request.args = (request.args ?? [:]).merging([String(pair[..<eq]): String(pair[pair.index(after: eq)...])]) { $1 }
    case "--no-enter": request.enter = false
    case "--force":    request.force = true
    case "--no-focus": request.focus = false
    case "--agent":    request.agent = value(for: arg)
    case "--session":  request.sessionID = value(for: arg)
    case "--turn":     request.turnID = value(for: arg)
    case "--json":     wantsJSON = true
    case "--help", "-h": print(usage); exit(0)
    case "--":
        // Ende der Optionen: der Rest ist Text, auch wenn er mit „--" beginnt.
        positional.append(contentsOf: args); args.removeAll()
    default:
        if arg.hasPrefix("--") { fail("Unbekannte Option \(arg)\n\n\(usage)", code: 2) }
        positional.append(arg)
    }
}

switch cmd {
case "list-panes", "zoom", "focus", "new-pane", "close-pane", "pane-kinds":
    guard positional.isEmpty else { fail("\(cmd) nimmt keine freien Argumente\n\n\(usage)", code: 2) }
case "send":
    guard !positional.isEmpty else { fail("send braucht einen Text\n\n\(usage)", code: 2) }
    request.text = positional.joined(separator: " ")
case "status":
    guard !positional.isEmpty else { fail("status braucht eine Payload\n\n\(usage)", code: 2) }
    guard (request.agent == nil && request.sessionID == nil && request.turnID == nil) ||
            (["claude", "codex"].contains(request.agent ?? "") && !(request.sessionID ?? "").isEmpty) else {
        fail("status: --agent claude|codex und --session ID zusammen angeben", code: 2)
    }
    request.text = positional.joined(separator: " ")
default:
    fail("Unbekanntes Kommando „\(cmd)“\n\n\(usage)", code: 2)
}

// MARK: - Socket-Roundtrip

func roundtrip(_ request: ControlRequest) -> ControlResponse {
    do { return try ControlClient.roundtrip(request) }
    catch { fail(String(describing: error), code: 3) }
}

let response = roundtrip(request)

guard response.ok else { fail(response.error ?? "Unbekannter Fehler", code: 1) }

// MARK: - Ausgabe

if wantsJSON {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try! enc.encode(response), encoding: .utf8)!)
    exit(0)
}

func describe(_ pane: PaneInfo) -> String {
    var marks: [String] = []
    // App-Kacheln tragen ihre Art vorn (terminal/home bleiben ohne Marke wie bisher).
    let isApp = pane.kind.map { $0 != "terminal" && $0 != "home" } ?? false
    if isApp, let kind = pane.kind { marks.append(kind) }
    if pane.focused { marks.append("fokussiert") }
    if pane.zoomed { marks.append("gezoomt") }
    if pane.state != "none" { marks.append(pane.state) }
    if let agent = pane.agent { marks.append(agent) }
    if let id = pane.sessionID { marks.append(String(id.prefix(8))) }
    let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // App-Kacheln ohne Verzeichnis (Scratchpad): Strich statt „?“ — es kommt keins mehr.
    let cwd = pane.cwd.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 } ?? (isApp ? "–" : "?")
    return "\(pane.index)  \(pane.id.prefix(8))  \(cwd)\(suffix)"
}

switch cmd {
case "list-panes":
    for pane in response.panes ?? [] { print(describe(pane)) }
case "new-pane":
    if let pane = response.pane { print(describe(pane)) }
case "pane-kinds":
    for kind in response.kinds ?? [] { print(kind) }
default:
    break   // send/zoom/focus/close-pane: Erfolg ist still (Unix-Konvention)
}
