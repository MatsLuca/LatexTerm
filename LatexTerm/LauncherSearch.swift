import Foundation

enum LauncherSearch {
    static func prompt(_ input: String) -> String? {
        guard input.hasPrefix("/") else { return nil }
        return String(input.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func score(query: String, title: String, detail: String) -> Int? {
        func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "de_DE")) }
        let query = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return 0 }
        let title = fold(title), text = fold(title + " " + detail)
        if title == query { return 1000 }
        if title.hasPrefix(query) { return 800 }
        let words = query.split(whereSeparator: \.isWhitespace)
        if words.allSatisfy({ text.contains($0) }) { return 500 }
        // Abbreviations work, but only inside the title, not across long paths.
        var cursor = title.startIndex
        for ch in query where !ch.isWhitespace {
            guard let hit = title[cursor...].firstIndex(of: ch) else { return nil }
            cursor = title.index(after: hit)
        }
        return 100
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
