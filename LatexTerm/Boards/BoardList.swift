import Foundation

/// Bretter eines Fensters (23.09.2026, Plan `bretter_2026-09-23.md` in der Werkstatt): Reihenfolge, welches vorn ist,
/// wer beim Schließen nachrückt. Rein und ohne AppKit — `BoardHostView` hält die Ansichten, das hier die Regeln.
struct BoardList<ID: Hashable> {
    private(set) var order: [ID] = []
    private(set) var active: ID?

    var count: Int { order.count }

    /// Neues Brett rechts neben dem vorderen (wie ein neuer Tab in Safari), sonst hinten.
    mutating func add(_ id: ID, activate: Bool) {
        guard !order.contains(id) else { return }
        if let active, let index = order.firstIndex(of: active) { order.insert(id, at: index + 1) }
        else { order.append(id) }
        if activate || active == nil { active = id }
    }

    mutating func activate(_ id: ID) {
        if order.contains(id) { active = id }
    }

    /// Entfernt ein Brett. War es vorn, rückt der rechte Nachbar nach, am Ende der linke.
    mutating func remove(_ id: ID) {
        guard let index = order.firstIndex(of: id) else { return }
        order.remove(at: index)
        guard active == id else { return }
        active = order.isEmpty ? nil : order[min(index, order.count - 1)]
    }

    /// Nachbar des vorderen Bretts, rundherum (`step` +1 = rechts, −1 = links).
    func neighbor(_ step: Int) -> ID? {
        guard let active, let index = order.firstIndex(of: active), order.count > 1 else { return nil }
        return order[((index + step) % order.count + order.count) % order.count]
    }

    /// 1-basierte Position; nil, wenn unbekannt.
    func position(of id: ID) -> Int? { order.firstIndex(of: id).map { $0 + 1 } }

    /// Brett an Stelle `index` (0 … count−1) verschieben.
    mutating func move(_ id: ID, to index: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        order.insert(id, at: max(0, min(index, order.count)))
    }
}

enum BoardName {
    /// Automatischer Name: Projektordner der ersten Agenten-Kachel, sonst der ersten Kachel mit Ordner, sonst
    /// „Brett n“. Der Home-Ordner heißt „Home“.
    static func automatic(agentDirectories: [String], directories: [String], home: String, number: Int) -> String {
        guard let dir = agentDirectories.first ?? directories.first else { return "Brett \(number)" }
        let trimmed = dir.count > 1 && dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        if trimmed == home || trimmed == "~" { return "Home" }
        let last = (trimmed as NSString).lastPathComponent
        return last.isEmpty || last == "/" ? "Brett \(number)" : last
    }
}
