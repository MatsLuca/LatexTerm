import Foundation

@main
struct LauncherSearchTests {
    static func main() {
        assert(LauncherSearch.prompt("Projekt suchen") == nil)
        assert(LauncherSearch.prompt("/  frei fragen  ") == "frei fragen")
        assert(LauncherSearch.prompt("/") == "")
        assert(LauncherSearch.prompt("Projekt / Details") == nil)
        assert(LauncherSearch.match(query: "GRUSSE", title: "Grüsse", detail: "")?.score == 1000)
        assert(LauncherSearch.match(query: "test", title: "Testprojekt", detail: "")?.score == 900)
        assert(LauncherSearch.match(query: "codex reisen", title: "Reisen planen", detail: "Codex · Session")?.score == 500)
        assert(LauncherSearch.match(query: "lt", title: "LatexTerm", detail: "")?.score == 100)
        assert(LauncherSearch.match(query: "zzzz", title: "LatexTerm", detail: "") == nil)
        assert(LauncherSearch.match(query: "   ", title: "A", detail: "")?.score == 0)
        assert(LauncherSearch.match(query: "abcdef", title: "A", detail: "b c d e f") == nil)

        // Ranking is a user-facing contract: exact > prefix > word start > substring > abbreviation.
        let ranked = ["Test", "Testprojekt", "Mein Test", "VorTestEnde", "T_e_s_t"]
            .map { LauncherSearch.match(query: "test", title: $0, detail: "")!.score }
        assert(zip(ranked, ranked.dropFirst()).allSatisfy { $0 > $1 })
        assert(LauncherSearch.match(query: "reisen planen", title: "Planen: Reisen", detail: "")?.score == 600)
        assert(LauncherSearch.match(query: "zz", title: "A", detail: "zz") == nil)
        assert(LauncherSearch.match(query: "grusse", title: "Grüße", detail: "")!.ranges.isEmpty)
        let unicode = LauncherSearch.match(query: "cafe", title: "🧭 Café planen", detail: "")!
        assert(unicode.ranges == [NSRange(location: 3, length: 4)])
        assert(("🧭 Café planen" as NSString).substring(with: unicode.ranges[0]) == "Café")
        assert(LauncherSearch.match(query: "test", title: "  test", detail: "")?.score == 800)
        let pane = HomePaneInfo(id: "pane-a", path: "/project", agent: "codex", sessionID: "session-a", state: "none", label: "Codex")
        assert(pane.matches(sessionID: "session-a", agent: "codex"))
        assert(!pane.matches(sessionID: "session-a", agent: "claude"))
        assert(!pane.matches(sessionID: "session-b", agent: "codex"))
        let unknown = HomePaneInfo(id: "pane-b", path: "/project", agent: "codex", sessionID: nil, state: "none", label: "Codex")
        assert(!unknown.matches(sessionID: "session-a", agent: "codex"))
        print("22 launcher search / identity / slash / highlight cases passed")
    }
}
