import Foundation

enum LauncherSearch {
    /// Bewertung eines Treffers plus die Stellen im Originaltitel, die getroffen wurden (UTF-16, für
    /// die Hervorhebung in der Zelle). Ohne Treffer nil.
    struct Match {
        var score: Int
        var ranges: [NSRange]
    }

    static func prompt(_ input: String) -> String? {
        guard input.hasPrefix("/") else { return nil }
        return String(input.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE"))
    }

    /// Reihenfolge der Stufen: exakt · Titelanfang · Wortanfang · Teilstring · alle Wörter im Titel ·
    /// alle Wörter in Titel+Kontext · Abkürzung (Buchstabenfolge im Titel, zusammenhängende Stücke zählen mehr).
    static func match(query rawQuery: String, title rawTitle: String, detail: String) -> Match? {
        let query = fold(rawQuery).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Match(score: 0, ranges: []) }
        let title = fold(rawTitle)
        let text = title + " " + fold(detail)
        let mapper = RangeMapper(original: rawTitle, folded: title)

        if title == query { return Match(score: 1000, ranges: mapper.ranges([title.startIndex..<title.endIndex])) }
        if title.hasPrefix(query) {
            return Match(score: 900, ranges: mapper.ranges([title.startIndex..<title.index(title.startIndex, offsetBy: query.count)]))
        }
        if let r = wordStart(of: query, in: title) { return Match(score: 800, ranges: mapper.ranges([r])) }
        if let r = title.range(of: query) { return Match(score: 700, ranges: mapper.ranges([r])) }

        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        if words.count > 1 {
            var ranges: [Range<String.Index>] = []
            var allInTitle = true
            for w in words {
                if let r = wordStart(of: w, in: title) ?? title.range(of: w) { ranges.append(r) } else { allInTitle = false }
            }
            if allInTitle { return Match(score: 600, ranges: mapper.ranges(ranges)) }
            if words.allSatisfy({ text.contains($0) }) { return Match(score: 500, ranges: mapper.ranges(ranges)) }
        }

        // Abkürzung: jedes Zeichen der Anfrage in Reihenfolge im Titel. Nur für kurze Anfragen
        // sinnvoll, sonst passt „e s n" auf alles.
        let letters = query.filter { !$0.isWhitespace }
        guard letters.count <= 12 else { return nil }
        var cursor = title.startIndex
        var ranges: [Range<String.Index>] = []
        var contiguous = 0
        for ch in letters {
            guard let hit = title[cursor...].firstIndex(of: ch) else { return nil }
            if let last = ranges.last, last.upperBound == hit {
                ranges[ranges.count - 1] = last.lowerBound..<title.index(after: hit); contiguous += 1
            } else {
                ranges.append(hit..<title.index(after: hit))
            }
            cursor = title.index(after: hit)
        }
        return Match(score: 100 + min(contiguous * 15, 150), ranges: mapper.ranges(ranges))
    }

    private static func wordStart(of needle: String, in haystack: String) -> Range<String.Index>? {
        var searchFrom = haystack.startIndex
        while let r = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
            if r.lowerBound == haystack.startIndex { return r }
            let before = haystack[haystack.index(before: r.lowerBound)]
            if before.isWhitespace || before.isPunctuation || before == "_" || before == "-" || before == "/" { return r }
            searchFrom = haystack.index(after: r.lowerBound)
        }
        return nil
    }

    /// Bildet Bereiche aus dem gefalteten Titel auf den Originaltitel ab. Faltung verändert bei
    /// Umlauten die Zeichenzahl nicht; weicht sie doch ab, gibt es keine Hervorhebung (kein Absturz).
    private struct RangeMapper {
        let original: String
        let folded: String
        let sameShape: Bool
        init(original: String, folded: String) {
            self.original = original; self.folded = folded
            sameShape = original.count == folded.count
        }
        func ranges(_ rs: [Range<String.Index>]) -> [NSRange] {
            guard sameShape else { return [] }
            return rs.compactMap { r in
                let start = folded.distance(from: folded.startIndex, to: r.lowerBound)
                let len = folded.distance(from: r.lowerBound, to: r.upperBound)
                guard start + len <= original.count else { return nil }
                let s = original.index(original.startIndex, offsetBy: start)
                let e = original.index(s, offsetBy: len)
                return NSRange(s..<e, in: original)
            }
        }
    }
}

struct HomePaneInfo: Equatable {
    var id: String
    var path: String
    var agent: String?
    var sessionID: String?
    var state: String
    var label: String

    func matches(sessionID: String, agent: String) -> Bool {
        self.sessionID == sessionID && self.agent == agent
    }
}
