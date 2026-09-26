import Foundation

/// `call read` einer Terminal-Kachel (26.09.2026, MCP `terminal_look`): welche Zeilen aus Scrollback + Bildschirm
/// ein Agent zu sehen bekommt — die letzten N oder die Treffer einer Suche samt Umfeld. Rein (Foundation), damit
/// App und Test (`scripts/test-terminal-text.swift`) dieselbe Auswahl rechnen.
///
/// Drahtformat: Kopfzeile `read [last=N] [context=K]`, optional danach eine Zeile mit dem Suchmuster
/// (regulärer Ausdruck, Groß/klein egal; ungültig → wörtlich) — so darf das Muster Leerzeichen enthalten.
enum TerminalText {
    struct Query: Equatable {
        var last = 60
        var grep: String?
        var context = 0
    }

    struct Line: Codable, Equatable {
        /// Zeilennummer ab 1, gezählt vom Anfang des Scrollbacks.
        var n: Int
        var text: String
        /// Treffer der Suche (nur mit `grep`).
        var hit: Bool?
    }

    struct Result: Codable, Equatable {
        var lines: [Line]
        /// Zeilen mit Inhalt insgesamt (ohne die leeren unter dem Prompt).
        var total: Int
        var matches: Int?
        /// Mehr da als gezeigt (ältere Zeilen bzw. weitere Treffer).
        var truncated: Bool
    }

    static let maxLast = 2000
    static let maxContext = 20
    static let maxLineLength = 400
    /// Obergrenze der Antwort — ein Log mit langen Zeilen soll nicht den Kontext des Agenten fluten.
    static let maxCharacters = 60_000

    static func parse(_ text: String) throws -> Query {
        let newline = text.firstIndex(of: "\n")
        let head = text[..<(newline ?? text.endIndex)]
        var words = head.split(separator: " ").map(String.init)
        guard words.first?.lowercased() == "read" else { throw TerminalTextError("terminal versteht nur read [last=N] [context=K] (+ Suchmuster in Zeile 2)") }
        words.removeFirst()
        var query = Query()
        for word in words {
            let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let value = Int(parts[1]), value >= 0 else {
                throw TerminalTextError("read kennt last=N und context=K, nicht „\(word)“")
            }
            switch parts[0] {
            case "last": query.last = min(max(value, 1), maxLast)
            case "context": query.context = min(value, maxContext)
            default: throw TerminalTextError("read kennt last=N und context=K, nicht „\(word)“")
            }
        }
        if let newline {
            let pattern = text[text.index(after: newline)...].trimmingCharacters(in: .newlines)
            if !pattern.isEmpty { query.grep = pattern }
        }
        return query
    }

    static func select(_ all: [String], _ query: Query) -> Result {
        var end = all.count
        while end > 0, all[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        let lines = Array(all[..<end])
        guard let pattern = query.grep else {
            let start = max(0, lines.count - query.last)
            let picked = (start..<lines.count).map { Line(n: $0 + 1, text: clip(lines[$0])) }
            let (kept, cut) = cap(picked)
            return Result(lines: kept, total: lines.count, matches: nil, truncated: start > 0 || cut)
        }
        let matcher = self.matcher(pattern)
        let hits = lines.indices.filter { matcher(lines[$0]) }
        // Neueste Treffer zählen: bei zu vielen die letzten `last`.
        let shown = hits.suffix(query.last)
        var wanted = Set<Int>()
        for hit in shown {
            for i in max(0, hit - query.context)...min(lines.count - 1, hit + query.context) { wanted.insert(i) }
        }
        let hitSet = Set(shown)
        let picked = wanted.sorted().map { Line(n: $0 + 1, text: clip(lines[$0]), hit: hitSet.contains($0) ? true : nil) }
        let (kept, cut) = cap(picked)
        return Result(lines: kept, total: lines.count, matches: hits.count, truncated: shown.count < hits.count || cut)
    }

    /// Regulärer Ausdruck ohne Groß/klein; lässt er sich nicht bauen, wörtlich.
    static func matcher(_ pattern: String) -> (String) -> Bool {
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            return { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        return { $0.range(of: pattern, options: .caseInsensitive) != nil }
    }

    private static func clip(_ text: String) -> String {
        text.count > maxLineLength ? String(text.prefix(maxLineLength)) + "…" : text
    }

    /// Älteste Zeilen fallen weg, bis die Antwort unter `maxCharacters` liegt.
    private static func cap(_ lines: [Line]) -> ([Line], Bool) {
        var total = 0
        var start = lines.count
        while start > 0, total + lines[start - 1].text.count + 8 <= maxCharacters {
            start -= 1
            total += lines[start].text.count + 8
        }
        return (Array(lines[start...]), start > 0)
    }
}

struct TerminalTextError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
