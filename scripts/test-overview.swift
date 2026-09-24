import AppKit

@main
struct OverviewTests {
    static func main() {
        var cases = 0
        func check(_ ok: Bool, _ what: String) { precondition(ok, what); cases += 1 }

        func agent(_ state: OverviewState, say: String? = nil, permission: Bool = false) -> OverviewAgent {
            OverviewAgent(paneID: UUID().uuidString, name: "Claude", agent: "claude", state: state, say: say,
                          since: Date(), permission: permission, isWorker: false)
        }
        let views = (0..<4).map { _ in NSView() }
        func board(_ n: Int, _ name: String, _ agents: [OverviewAgent]) -> OverviewBoard {
            OverviewBoard(id: ObjectIdentifier(views[n - 1]), number: n, name: name, accent: .red, cells: [], agents: agents)
        }

        // Schwerkraft
        let boards = [board(1, "LatexTerm", [agent(.working)]), board(2, "werkstatt", [agent(.idle)]),
                      board(3, "untertage", [agent(.waiting, say: "Weiter?")]), board(4, "Documents", [agent(.outcome), agent(.error)])]
        check(OverviewRules.sorted(boards).map(\.number) == [4, 3, 1, 2], "error › waiting › working › idle")
        check(boards[3].lead?.state == .error, "lead = highest state")
        check(OverviewRules.sorted([board(2, "b", [agent(.working)]), board(1, "a", [agent(.working)])]).map(\.number) == [1, 2],
              "ties keep board order")
        check(board(1, "leer", []).state == .idle, "board without agents is idle")
        check(OverviewCardSize(.waiting) == .big && OverviewCardSize(.idle) == .tiny, "sizes")

        // Schnellknöpfe
        check(OverviewRules.quickReplies(for: agent(.waiting, say: "Soll ich pushen?")) == ["ja", "nein"], "yes/no question")
        check(OverviewRules.quickReplies(for: agent(.waiting, say: "Toleranz anheben oder Ursache suchen?")).isEmpty, "choice → no yes/no")
        check(OverviewRules.quickReplies(for: agent(.waiting, say: "x", permission: true)) == ["erlauben", "ablehnen"], "permission")
        check(OverviewRules.quickReplies(for: agent(.outcome, say: "Fertig?")).isEmpty, "only when waiting")

        // Tippzeile
        let names = [(1, "LatexTerm"), (2, "claude-werkstatt"), (3, "claude-config")]
        check(OverviewRules.parse("wie läuft's?", boards: names).map { $0.target == .chef && $0.text == "wie läuft's?" } == true, "no @ → chef")
        check(OverviewRules.parse("@latex push bitte", boards: names).map { $0.target == .board(1) && $0.text == "push bitte" } == true, "prefix")
        check(OverviewRules.parse("@2 weiter", boards: names).map { $0.target == .board(2) } == true, "number")
        check(OverviewRules.parse("@claude weiter", boards: names) == nil, "ambiguous prefix")
        check(OverviewRules.parse("@claude-config weiter", boards: names).map { $0.target == .board(3) } == true, "exact name")
        check(OverviewRules.parse("@alle Stand?", boards: names).map { $0.target == .chef && $0.text == "@alle Stand?" } == true, "@alle → chef with @alle")
        check(OverviewRules.parse("@latexterm", boards: names) == nil, "no text")
        check(OverviewRules.parse("   ", boards: names) == nil, "empty")

        // Alter
        let now = Date()
        check(OverviewRules.age(since: now.addingTimeInterval(-30), now: now) == "eben", "eben")
        check(OverviewRules.age(since: now.addingTimeInterval(-240), now: now) == "4 min", "minutes")
        check(OverviewRules.age(since: now.addingTimeInterval(-7200), now: now) == "2 h", "hours")
        print("overview: \(cases) Fälle grün")
    }
}
