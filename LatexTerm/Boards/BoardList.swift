import Foundation

/// Bretter eines Fensters (23.09.2026, Plan `bretter_2026-09-23.md` in der Werkstatt): Reihenfolge, welches vorn ist,
/// wer beim Schließen nachrückt. Rein und ohne AppKit — `BoardHostView` hält die Ansichten, das hier die Regeln.
struct BoardList<ID: Hashable> {
    private(set) var order: [ID] = []
    private(set) var active: ID?

    var count: Int { order.count }

    /// Neues Brett rechts neben dem vorderen (wie ein neuer Tab in Safari), sonst hinten. `atEnd`: immer hinten —
    /// beim Wiederherstellen, sonst landeten Bretter 2…n hinter dem ersten in umgekehrter Reihenfolge (Bug 24.09.).
    mutating func add(_ id: ID, activate: Bool, atEnd: Bool = false) {
        guard !order.contains(id) else { return }
        if !atEnd, let active, let index = order.firstIndex(of: active) { order.insert(id, at: index + 1) }
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

    /// Zielstelle für `move`, wenn ein Brett in die Lücke `gap` (0 … count, vor Eintrag `gap`) gezogen wird;
    /// nil = bleibt, wo es ist.
    func moveIndex(for id: ID, gap: Int) -> Int? {
        guard let from = order.firstIndex(of: id) else { return nil }
        let to = gap > from ? gap - 1 : gap
        return to == from ? nil : max(0, min(to, order.count - 1))
    }

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

/// Kürzen der Brett-Leiste bei Enge (Scheibe 2, 24.09.): das vordere Brett behält seinen Namen, die verdeckten
/// teilen sich den Rest mit einer gemeinsamen Obergrenze (Wasserstand wie bei den Reitern); reicht auch das nicht
/// für `minWidth`, zeigen die verdeckten nur noch ihre Nummer.
enum BoardStripFit {
    /// Textbreiten je Eintrag, oder nil, wenn selbst `minWidth` je verdecktem Namen nicht passt.
    static func names(natural: [Double], active: Int?, available: Double, minWidth: Double) -> [Double]? {
        guard natural.reduce(0, +) > available else { return natural }
        let fixed = active.map { natural[$0] } ?? 0
        let others = natural.indices.filter { $0 != active }.map { natural[$0] }
        guard !others.isEmpty else { return [min(natural[0], max(minWidth, available))] }
        var rest = available - fixed
        var open = others.sorted()
        while let smallest = open.first, smallest * Double(open.count) <= rest {
            rest -= smallest
            open.removeFirst()
        }
        let cap = open.isEmpty ? .infinity : (rest / Double(open.count)).rounded(.down)
        guard cap >= minWidth else { return nil }
        return natural.indices.map { $0 == active ? natural[$0] : min(natural[$0], cap) }
    }

    /// Nummern-Modus: verdeckte bekommen ihre Nummernbreite, das vordere den Rest (mindestens `minWidth`).
    static func numbers(natural: [Double], numberWidths: [Double], active: Int?, available: Double, minWidth: Double) -> [Double] {
        let others = numberWidths.indices.filter { $0 != active }.map { numberWidths[$0] }.reduce(0, +)
        return natural.indices.map { i in
            i == active ? min(natural[i], max(minWidth, available - others)) : numberWidths[i]
        }
    }
}
