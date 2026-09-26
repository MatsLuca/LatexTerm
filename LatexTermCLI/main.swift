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
  latexterm new-pane --kind ART [--arg SCHLÜSSEL=WERT]… [--no-focus] [--dock unten|oben [--height PT]]
  latexterm pane-kinds
  latexterm send [--pane ZIEL] [--no-enter] [--paste] TEXT…
  latexterm call [--pane ZIEL] TEXT…            (TEXT „-“ = von stdin)
  latexterm zoom [--pane ZIEL]
  latexterm focus [--pane ZIEL]
  latexterm close-pane [--pane ZIEL] [--force]
  latexterm status [--pane ZIEL] [--agent claude|codex --session ID] [--turn ID] PAYLOAD
  latexterm snapshots [--json]
  latexterm restore [STAND] [--dry-run]
  latexterm doctor
  latexterm board-save [--pane ZIEL] [--arg name=NAME] [--dry-run] DATEI
  latexterm board-open [--no-focus] [--dry-run] DATEI
  latexterm board-name [--board N] [NAME]
  latexterm read [--pane ZIEL] [--lines N] [--grep MUSTER] [--context K]
  latexterm mcp

ZIEL ist der 1-basierte Index aus `list-panes` oder eine Pane-UUID (auch Präfix).
ART ist eine Kachelart aus `pane-kinds` (terminal, home, scratchpad, …); --cwd/--exec nur für terminal.
send an eine App-Kachel reicht den Text an deren Inhalt (Scratchpad: `clear`, `undo`).
--paste fügt in ein Terminal als Paste ein (bracketed paste) — ein Bildpfad wird in Claude Code/Codex zum Bild.
call fragt eine App-Kachel und druckt ihre Antwort (Scratchpad: `look /pfad.png`, `clear claude`,
`draw [replace=mats|claude|all]` + Zeilenumbruch + SVG — per stdin: `call --pane 2 - < zeichnung.txt`).
Ohne --pane verwenden send/zoom/focus/close-pane $LATEXTERM_PANE_ID — also die Kachel,
in deren Shell dieses Kommando läuft.

close-pane schließt ohne --force nur eine ruhende Shell ohne Vordergrundprozess.
Bei arbeitender Session oder laufendem Vordergrundprozess: Exit 1 mit Grund.
--force entspricht Cmd+W ohne Rückfrage.

status meldet Agenten-Zustand und optional die echte Session-ID (`working;Bash;t=12;n=3`).
Zustände: ready / working / input / done / closed. Ohne Anbieterfelder bleibt das Legacy-Claude-Protokoll.

snapshots listet gespeicherte Stände (Bretter + Kacheln), neuester = 1. Einer entsteht bei jedem Beenden,
Neustart und unsauberen Ende, dazu höchstens alle 10 min aus dem Autosave; die letzten 30 bleiben.
restore öffnet, was von STAND (Nummer oder Name, Default 1) fehlt, als neue Bretter in der laufenden App —
ohne Neustart; schon Offenes bleibt, wie es ist. --dry-run zeigt nur, was käme.
board-save sichert das Brett der Kachel (ohne --pane: deins) als Datei, meist <projekt>/_brett/brett.json; Pfade im
Projekt stehen relativ. Ungesicherte Scratchpads mit Inhalt werden vorher daneben angeheftet (skizze.scratch.json).
board-open öffnet so eine Datei als neues Brett (vorn; --no-focus = hinten) — schon Offenes kommt nicht doppelt.
Scratchpad anheften einzeln: `call --pane ZIEL pin /pfad/<name>.scratch.json`, Zustand: `call --pane ZIEL state`.
board-name ohne NAME listet die Bretter des Fensters; mit NAME benennt es deins (--board N: Brett N) um, "" = automatisch.
read liest eine Terminal-Kachel: die letzten N Zeilen (Default 60) oder mit --grep die Treffer (Regex, Groß/klein egal).
--probe ist gleichbedeutend mit --dry-run (so heißt es im MCP).
doctor: läuft der neueste Build, Absturzschutz, Stand-Archiv, letzte Zeilen aus lifecycle.log/unclean.log.

--no-focus: die neue Kachel entsteht daneben, die Tastatur bleibt in der fokussierten Kachel.
--dock unten|oben: die neue Kachel hängt als flache Leiste fest unter/über der aufrufenden (so breit wie sie,
--height pt, Default 84) und wandert mit ihr.

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
var readLines = 60, readContext = 0
var readGrep: String?

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
    case "--paste":    request.paste = true
    case "--force":    request.force = true
    case "--no-focus": request.focus = false
    case "--dock":
        // Leiste fest unter/über der aufrufenden Kachel ($LATEXTERM_PANE_ID): unten | oben
        switch value(for: arg) {
        case "unten", "bottom": request.placement = "dock-bottom"
        case "oben", "top":     request.placement = "dock-top"
        case let other: fail("--dock erwartet unten oder oben, bekam „\(other)“", code: 2)
        }
    case "--height":
        guard let h = Double(value(for: arg)) else { fail("--height erwartet eine Zahl (pt)", code: 2) }
        request.dockHeight = h
    case "--agent":    request.agent = value(for: arg)
    case "--session":  request.sessionID = value(for: arg)
    case "--turn":     request.turnID = value(for: arg)
    case "--json":     wantsJSON = true
    case "--dry-run", "--probe": request.dryRun = true
    case "--board":    request.board = value(for: arg)
    case "--lines":
        guard let n = Int(value(for: arg)), n > 0 else { fail("--lines erwartet eine positive Zahl", code: 2) }
        readLines = n
    case "--context":
        guard let n = Int(value(for: arg)), n >= 0 else { fail("--context erwartet eine Zahl ≥ 0", code: 2) }
        readContext = n
    case "--grep":     readGrep = value(for: arg)
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
case "list-panes", "zoom", "focus", "new-pane", "close-pane", "pane-kinds", "snapshots", "doctor":
    guard positional.isEmpty else { fail("\(cmd) nimmt keine freien Argumente\n\n\(usage)", code: 2) }
case "send":
    guard !positional.isEmpty else { fail("send braucht einen Text\n\n\(usage)", code: 2) }
    request.text = positional.joined(separator: " ")
case "call":
    guard !positional.isEmpty else { fail("call braucht einen Text\n\n\(usage)", code: 2) }
    request.text = positional == ["-"]
        ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        : positional.joined(separator: " ")
case "status":
    guard !positional.isEmpty else { fail("status braucht eine Payload\n\n\(usage)", code: 2) }
    guard (request.agent == nil && request.sessionID == nil && request.turnID == nil) ||
            (["claude", "codex"].contains(request.agent ?? "") && !(request.sessionID ?? "").isEmpty) else {
        fail("status: --agent claude|codex und --session ID zusammen angeben", code: 2)
    }
    request.text = positional.joined(separator: " ")
case "restore":
    guard positional.count <= 1 else { fail("restore nimmt höchstens einen STAND\n\n\(usage)", code: 2) }
    request.snapshot = positional.first
case "board-save", "board-open":
    guard positional.count == 1 else { fail("\(cmd) braucht genau eine DATEI\n\n\(usage)", code: 2) }
    // Relativ zum Aufruf-Ordner auflösen — die App kennt das Arbeitsverzeichnis der Shell nicht.
    let raw = (positional[0] as NSString).expandingTildeInPath
    request.text = raw.hasPrefix("/") ? raw
        : URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL.path
case "board-name":
    guard positional.count <= 1 else { fail("board-name nimmt höchstens einen NAME (in Anführungszeichen)\n\n\(usage)", code: 2) }
    request.text = positional.first
case "read":
    // Terminal lesen = `call read` an die Kachel (ohne --pane: die eigene).
    guard positional.isEmpty else { fail("read nimmt keine freien Argumente — Muster per --grep\n\n\(usage)", code: 2) }
    request.cmd = "call"
    request.text = "read last=\(readLines) context=\(readContext)" + (readGrep.map { "\n" + $0 } ?? "")
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

func describe(_ snap: SnapshotSummary) -> String {
    let date = ISO8601DateFormatter().date(from: snap.date).map { d -> String in
        let f = DateFormatter(); f.dateFormat = "dd.MM. HH:mm"; return f.string(from: d)
    } ?? snap.date
    let panes = snap.boards.reduce(0) { $0 + $1.panes.count }
    var text = "\(snap.index)  \(date)  \(snap.reason)  ·  \(snap.boards.count) Brett\(snap.boards.count == 1 ? "" : "er"), \(panes) Kachel\(panes == 1 ? "" : "n")  [\(snap.name)]"
    for board in snap.boards {
        text += "\n     " + (board.name ?? "Brett") + ": " + board.panes.joined(separator: " · ")
    }
    return text
}

switch cmd {
case "list-panes":
    for pane in response.panes ?? [] { print(describe(pane)) }
case "new-pane":
    if let pane = response.pane { print(describe(pane)) }
case "pane-kinds":
    for kind in response.kinds ?? [] { print(kind) }
case "call", "doctor", "board-save", "board-open", "board-name":
    if let reply = response.reply { print(reply) }
case "read":
    // Nur der Text, eine Zeile je Zeile — pipe-fähig (Nummern mit --json).
    struct ReadReply: Decodable { struct Line: Decodable { let text: String }; let lines: [Line] }
    if let data = response.reply?.data(using: .utf8), let parsed = try? JSONDecoder().decode(ReadReply.self, from: data) {
        for line in parsed.lines { print(line.text) }
    }
case "snapshots":
    let all = response.snapshots ?? []
    if all.isEmpty { print("Noch keine gespeicherten Stände") }
    for snap in all { print(describe(snap)) }
case "restore":
    if let reply = response.reply { print(reply) }
    for board in response.snapshots?.first?.boards ?? [] {
        print("  " + (board.name ?? "Brett") + ": " + board.panes.joined(separator: " · "))
    }
default:
    break   // send/zoom/focus/close-pane: Erfolg ist still (Unix-Konvention)
}
