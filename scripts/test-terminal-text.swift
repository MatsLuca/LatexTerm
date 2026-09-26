import Foundation

// `call read` der Terminal-Kachel (26.09.2026, MCP `terminal_look`): letzte Zeilen, Suche mit Umfeld, Grenzen.
@main
struct TerminalTextTests {
    static func main() throws {
        let lines = (1...100).map { "Zeile \($0)" } + ["ERROR: Port 3000 belegt", "npm ERR! code 1", "", "", ""]

        // Ohne Muster: die letzten N, leere Zeilen unter dem Prompt zählen nicht.
        var q = try TerminalText.parse("read last=3")
        var r = TerminalText.select(lines, q)
        assert(r.total == 102 && r.truncated && r.lines.map(\.n) == [100, 101, 102], "\(r.lines.map(\.n))")
        assert(r.lines.last?.text == "npm ERR! code 1" && r.matches == nil)
        assert(TerminalText.select(["a", "b"], TerminalText.Query()).truncated == false)

        // Muster in Zeile 2 (mit Leerzeichen), Regex ohne Groß/klein, Umfeld.
        q = try TerminalText.parse("read context=1\nport 3000")
        r = TerminalText.select(lines, q)
        assert(r.matches == 1 && r.lines.map(\.n) == [100, 101, 102] && r.lines[1].hit == true && r.lines[0].hit == nil, "\(r)")
        q = try TerminalText.parse("read\nerr(or|!)")
        r = TerminalText.select(lines, q)
        assert(r.matches == 2 && r.lines.count == 2)
        // Ungültiger Regex → wörtlich.
        r = TerminalText.select(["a (b", "c"], try TerminalText.parse("read\n(b"))
        assert(r.matches == 1 && r.lines[0].text == "a (b")
        // Zu viele Treffer: die neuesten `last`, Rest als abgeschnitten gemeldet.
        r = TerminalText.select(lines, try TerminalText.parse("read last=2\nZeile"))
        assert(r.matches == 100 && r.truncated && r.lines.map(\.n) == [99, 100])

        // Grenzen: last gekappt, lange Zeilen gekürzt, Gesamtgröße begrenzt.
        let maxed = try TerminalText.parse("read last=999999")
        assert(maxed.last == TerminalText.maxLast)
        let long = TerminalText.select([String(repeating: "x", count: 5000)], TerminalText.Query())
        assert(long.lines[0].text.count == TerminalText.maxLineLength + 1)
        let many = (1...2000).map { _ in String(repeating: "y", count: 400) }
        let capped = TerminalText.select(many, try TerminalText.parse("read last=2000"))
        assert(capped.truncated && capped.lines.last?.n == 2000 && capped.lines.reduce(0) { $0 + $1.text.count } <= TerminalText.maxCharacters)

        // Unsinn wird abgelehnt.
        for bad in ["look", "read last=x", "read tail=3", "read last=-1"] {
            assert((try? TerminalText.parse(bad)) == nil, bad)
        }
        print("terminal-text: ok")
    }
}
