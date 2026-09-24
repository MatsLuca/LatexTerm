import AppKit

// Übersicht im Home-Brett (24.09.2026, Plan claude-werkstatt `plans/home-brett_2026-09-24.md`, Scheibe ①):
// was eine Karte über ein Brett zeigt. Gebaut von `TerminalSplitView.overviewBoard`, sortiert und bemessen hier,
// gezeichnet von `OverviewView`. Mats' Wahl: Schwerkraft fließend · Miniatur + Satz · Feld in der Karte.

/// Zustand eines Agenten aus Sicht der Übersicht; der Rohwert ist die Schwerkraft (wer wartet, steht oben).
enum OverviewState: Int, Comparable {
    case idle = 0, working = 1, outcome = 2, waiting = 4, error = 5

    static func < (a: OverviewState, b: OverviewState) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .idle: return "ruhig"
        case .working: return "arbeitet"
        case .outcome: return "Ergebnis neu"
        case .waiting: return "wartet"
        case .error: return "Fehler"
        }
    }

    /// Braucht Mats: Karte groß, Antwortfeld offen.
    var needsYou: Bool { self >= .waiting }
}

/// Eine Kachel in der Miniatur: Rahmen im Brett (0…1, y nach unten) und was sie ist.
struct OverviewCell: Equatable {
    var paneID: String
    var rect: CGRect
    /// Agent (claude/codex) = Mitarbeiter mit Zustand; nil = Arbeitsfläche (web, Vorschau, Shell …), klein und grau.
    var agent: String?
    var label: String
    var state: OverviewState
    var accent: NSColor
}

/// Ein Agent im Brett mit seinem letzten Satz.
struct OverviewAgent: Equatable {
    var paneID: String
    /// „Claude“, „Codex“ — bei mehreren im Brett mit Ordner/Titel unterschieden.
    var name: String
    var agent: String
    var state: OverviewState
    /// Was er zuletzt gesagt hat (Frage, Antwort-Anfang) oder woran er gerade arbeitet.
    var say: String?
    var since: Date
    /// Wartet auf eine Freigabe (Werkzeug-Rückfrage), nicht auf einen neuen Prompt.
    var permission: Bool
    /// Von einem anderen Agenten gestartet (Hierarchie aus Eigentum): eingerückt.
    var isWorker: Bool
}

struct OverviewBoard: Equatable {
    /// Brett (ObjectIdentifier der Split-View) — nur für Klicks, nie gespeichert.
    var id: ObjectIdentifier
    var number: Int
    var name: String
    var accent: NSColor
    var cells: [OverviewCell]
    var agents: [OverviewAgent]

    /// Wichtigster Agent: höchster Zustand, bei Gleichstand der erste (Lesereihenfolge).
    var lead: OverviewAgent? {
        agents.reduce(nil) { best, a in best.map { a.state > $0.state ? a : $0 } ?? a }
    }
    var state: OverviewState { lead?.state ?? .idle }
}

/// Karten-Größe in vier Stufen (Schwerkraft): groß = braucht dich, dann Ergebnis, arbeitet, ruhig.
enum OverviewCardSize: Int, Comparable {
    case tiny, small, medium, big

    static func < (a: OverviewCardSize, b: OverviewCardSize) -> Bool { a.rawValue < b.rawValue }

    init(_ state: OverviewState) {
        switch state {
        case .waiting, .error: self = .big
        case .outcome: self = .medium
        case .working: self = .small
        case .idle: self = .tiny
        }
    }
}

enum OverviewRules {
    /// Schwerkraft: höherer Zustand zuerst, sonst Brett-Reihenfolge. Umsortiert wird nur bei Zustandswechsel — die
    /// Reihenfolge hängt an keiner Uhr.
    static func sorted(_ boards: [OverviewBoard]) -> [OverviewBoard] {
        boards.sorted { a, b in a.state != b.state ? a.state > b.state : a.number < b.number }
    }

    /// Schnellknöpfe zur Frage: Freigabe → erlauben/ablehnen; Ja-Nein-Frage → ja/nein; sonst keine.
    static func quickReplies(for agent: OverviewAgent) -> [String] {
        if agent.permission { return ["erlauben", "ablehnen"] }
        guard agent.state == .waiting, let say = agent.say, say.hasSuffix("?") else { return [] }
        let lower = say.lowercased()
        let choice = [" oder ", " or "].contains { lower.contains($0) }
        return choice ? [] : ["ja", "nein"]
    }

    /// „eben“, „4 min“, „2 h“ — wie lange der Zustand schon gilt.
    static func age(since: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(since))
        if s < 60 { return "eben" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86400 { return "\(Int(s / 3600)) h" }
        return "\(Int(s / 86400)) d"
    }

    /// Tippzeile: `@brett text` → an das Brett (Name-Präfix oder Nummer), `@alle` und ohne @ → an den Chef.
    enum Target: Equatable { case chef, board(Int) }

    static func parse(_ line: String, boards: [(number: Int, name: String)]) -> (target: Target, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("@") else { return (.chef, trimmed) }
        let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let key = parts.first.map({ String($0).lowercased() }) else { return nil }
        let text = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        if key == "alle" || key == "chef" { return text.isEmpty ? nil : (.chef, key == "alle" ? trimmed : text) }
        guard !text.isEmpty else { return nil }
        if let n = Int(key), boards.contains(where: { $0.number == n }) { return (.board(n), text) }
        let exact = boards.filter { $0.name.lowercased() == key }
        let prefix = exact.isEmpty ? boards.filter { $0.name.lowercased().hasPrefix(key) } : exact
        guard prefix.count == 1 else { return nil }
        return (.board(prefix[0].number), text)
    }
}
