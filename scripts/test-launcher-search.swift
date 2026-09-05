import Foundation

@main
struct LauncherSearchTests {
    static func main() {
        assert(LauncherSearch.prompt("Projekt suchen") == nil)
        assert(LauncherSearch.prompt("/  frei fragen  ") == "frei fragen")
        assert(LauncherSearch.prompt("/") == "")
        assert(LauncherSearch.prompt("Projekt / Details") == nil)
        assert(LauncherSearch.score(query: "GRUSSE", title: "Grüsse", detail: "") == 1000)
        assert(LauncherSearch.score(query: "test", title: "Testprojekt", detail: "") == 800)
        assert(LauncherSearch.score(query: "codex reisen", title: "Reisen planen", detail: "Codex · Session") == 500)
        assert(LauncherSearch.score(query: "lt", title: "LatexTerm", detail: "") == 100)
        assert(LauncherSearch.score(query: "zzzz", title: "LatexTerm", detail: "") == nil)
        assert(LauncherSearch.score(query: "   ", title: "A", detail: "") == 0)
        assert(LauncherSearch.score(query: "abcdef", title: "A", detail: "b c d e f") == nil)
        let pane = HomePaneInfo(id: "pane-a", path: "/project", agent: "codex", sessionID: "session-a", state: "none", label: "Codex")
        assert(pane.matches(sessionID: "session-a", agent: "codex"))
        assert(!pane.matches(sessionID: "session-a", agent: "claude"))
        assert(!pane.matches(sessionID: "session-b", agent: "codex"))
        print("14 launcher search / identity / slash cases passed")
    }
}
