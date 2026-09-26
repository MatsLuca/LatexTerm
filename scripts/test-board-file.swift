import Foundation

/// Brett als Datei (25.09.2026): Home fällt weg, Fokus zählt danach, Pfade im Projekt relativ (auch über `_brett`
/// hinaus), fremde Pfade und URLs bleiben, Hin- und Rückweg nach Verschieben, Zurücklesen, falsches Format, zu neue Version.
@main
struct BoardFileTests {
    static func main() throws {
        var cases = 0
        func check(_ ok: Bool, _ what: String) {
            precondition(ok, what)
            cases += 1
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("latexterm board test \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let root = tmp.appendingPathComponent("Mein Projekt")
        let dir = root.appendingPathComponent("_brett")

        let claude = PaneSnapshot(kind: "terminal", args: ["cwd": root.path, "agent": "claude", "session": "abc-1"], id: "A")
        let shell = PaneSnapshot(kind: "terminal", args: ["cwd": "/tmp"], id: "B")
        let pad = PaneSnapshot(kind: "scratchpad", args: ["id": "C0", "file": dir.appendingPathComponent("skizze.scratch.json").path], id: "C")
        let web = PaneSnapshot(kind: "web", args: ["url": "http://localhost:3000"], id: "D")
        let preview = PaneSnapshot(kind: "preview", args: ["url": root.appendingPathComponent("out/a.pdf").path], id: "F")
        let home = PaneSnapshot(kind: "home", id: "E")
        let window = SessionSnapshot.Window(panes: [home, claude, shell, pad, web, preview], focused: 3, zoomed: 0,
                                            tabGroup: 2, selected: true, name: "x")

        let file = BoardFile.make(from: window, name: nil, base: dir)
        check(file.board.panes.count == 5, "Home fällt weg")
        check(file.board.focused == 2, "Fokus zeigt nach dem Wegfall auf dasselbe Scratchpad")
        check(file.board.zoomed == nil, "Zoom auf Home fällt weg")
        check(file.board.tabGroup == nil && file.board.selected == nil && file.board.name == nil, "Fensterfelder leer")
        check(file.board.panes[0].args["cwd"] == "..", "Projektordner über _brett → ..")
        check(file.board.panes[1].args["cwd"] == "/tmp", "fremder Pfad bleibt absolut")
        check(file.board.panes[2].args["file"] == "./skizze.scratch.json", "Zeichnung neben der Datei → ./")
        check(file.board.panes[3].args["url"] == "http://localhost:3000", "URL bleibt")
        check(file.board.panes[4].args["url"] == "../out/a.pdf", "Datei im Projekt → ../")
        check(file.board.panes[0].args["session"] == "abc-1", "Session bleibt")

        // Schreiben, lesen, nach Verschieben des Projekts auflösen.
        let url = try BoardFile.url(dir.appendingPathComponent("brett.json").path)
        try file.write(to: url)
        check(try BoardFile.read(url) == file, "Hin und zurück gleich")
        let moved = tmp.appendingPathComponent("Umgezogen")
        try FileManager.default.moveItem(at: root, to: moved)
        let movedDir = moved.appendingPathComponent("_brett")
        let opened = try BoardFile.read(movedDir.appendingPathComponent("brett.json")).resolved(base: movedDir)
        check(opened.panes[0].args["cwd"] == moved.standardizedFileURL.path, "cwd folgt dem Umzug")
        check(opened.panes[2].args["file"] == movedDir.appendingPathComponent("skizze.scratch.json").standardizedFileURL.path, "Zeichnung folgt")
        check(opened.panes[4].args["url"] == moved.appendingPathComponent("out/a.pdf").standardizedFileURL.path, "Vorschau folgt")
        check(opened.panes[1].args["cwd"] == "/tmp", "absolut bleibt absolut")
        check(opened.name == "Umgezogen", "Name = Projektordner, nicht _brett")
        var named = file; named.name = "Logo"
        check(named.resolved(base: movedDir).name == "Logo", "gesetzter Name gewinnt")

        // Pfad-Prüfung und kaputte Dateien.
        check((try? BoardFile.url("relativ/brett.json")) == nil, "relativer Pfad abgelehnt")
        check((try? BoardFile.url("/x/brett.txt")) == nil, "nicht .json abgelehnt")
        let bad = movedDir.appendingPathComponent("fremd.json")
        try Data(#"{"format":"anders","version":1,"saved":"x","board":{"panes":[]}}"#.utf8).write(to: bad)
        check((try? BoardFile.read(bad)) == nil, "fremdes Format abgelehnt")
        try Data(#"{"format":"latexterm-board","version":9,"saved":"x","board":{"panes":[]}}"#.utf8).write(to: bad)
        check((try? BoardFile.read(bad)) == nil, "zu neue Version abgelehnt")

        // OpenPanes: angeheftete Zeichnung gilt über die Datei als offen, auch unter anderer id.
        var open = OpenPanes()
        open.contents.insert(OpenPanes.contentKey(kind: "scratchpad", args: ["id": "ZZ", "file": "/p/s.scratch.json"])!)
        check(open.contains(PaneSnapshot(kind: "scratchpad", args: ["id": "YY", "file": "/p/s.scratch.json"])), "gleiche Datei = offen")
        check(!open.contains(PaneSnapshot(kind: "scratchpad", args: ["id": "YY"])), "andere Zeichnung nicht")

        print("board-file: \(cases) Fälle grün")
    }
}
