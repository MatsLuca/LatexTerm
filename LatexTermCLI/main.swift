import Foundation

// latexterm — Steuerkanal-CLI (#28). Spricht die JSON-Zeilen des ControlProtocol
// über den Unix-Socket der laufenden App. Bewusst ohne ArgumentParser-Dependency:
// fünf Verben, eine Handvoll Flags. Wird ins App-Bundle eingebettet
// (LatexTerm.app/Contents/MacOS/latexterm); Nutzung via Symlink oder PATH.

let usage = """
latexterm — steuert die laufende LatexTerm.app

Verwendung:
  latexterm list-panes [--json]
  latexterm new-pane [--cwd VERZEICHNIS] [--exec KOMMANDO]
  latexterm send [--pane ZIEL] [--no-enter] TEXT…
  latexterm zoom [--pane ZIEL]
  latexterm focus [--pane ZIEL]

ZIEL ist der 1-basierte Index aus `list-panes` oder eine Pane-UUID (auch Präfix).
Ohne --pane verwenden send/zoom/focus $LATEXTERM_PANE_ID — also die Kachel,
in deren Shell dieses Kommando läuft.

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
    case "--no-enter": request.enter = false
    case "--json":     wantsJSON = true
    case "--help", "-h": print(usage); exit(0)
    default:
        if arg.hasPrefix("--") { fail("Unbekannte Option \(arg)\n\n\(usage)", code: 2) }
        positional.append(arg)
    }
}

switch cmd {
case "list-panes", "zoom", "focus", "new-pane":
    guard positional.isEmpty else { fail("\(cmd) nimmt keine freien Argumente\n\n\(usage)", code: 2) }
case "send":
    guard !positional.isEmpty else { fail("send braucht einen Text\n\n\(usage)", code: 2) }
    request.text = positional.joined(separator: " ")
default:
    fail("Unbekanntes Kommando „\(cmd)“\n\n\(usage)", code: 2)
}

// MARK: - Socket-Roundtrip

func roundtrip(_ request: ControlRequest) -> ControlResponse {
    let path = ControlProtocol.socketPath
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("Socket-Fehler: \(String(cString: strerror(errno)))", code: 3) }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let fits = path.withCString { cstr -> Bool in
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard strlen(cstr) <= maxLen else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                .update(from: cstr, count: strlen(cstr) + 1)
        }
        return true
    }
    guard fits else { fail("Socket-Pfad zu lang: \(path)", code: 3) }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, size) == 0
        }
    }
    guard connected else {
        fail("LatexTerm nicht erreichbar (\(path)) — läuft die App?", code: 3)
    }

    var out = try! JSONEncoder().encode(request)
    out.append(UInt8(ascii: "\n"))
    _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count < 1_048_576 {
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { break }
        data.append(buf, count: n)
        if buf[..<n].contains(UInt8(ascii: "\n")) { break }
    }
    guard let response = try? JSONDecoder().decode(ControlResponse.self, from: data) else {
        fail("Antwort der App nicht lesbar", code: 3)
    }
    return response
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
    if pane.focused { marks.append("fokussiert") }
    if pane.zoomed { marks.append("gezoomt") }
    if pane.state != "none" { marks.append(pane.state) }
    let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]"
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let cwd = pane.cwd.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 } ?? "?"
    return "\(pane.index)  \(pane.id.prefix(8))  \(cwd)\(suffix)"
}

switch cmd {
case "list-panes":
    for pane in response.panes ?? [] { print(describe(pane)) }
case "new-pane":
    if let pane = response.pane { print(describe(pane)) }
default:
    break   // send/zoom/focus: Erfolg ist still (Unix-Konvention)
}
