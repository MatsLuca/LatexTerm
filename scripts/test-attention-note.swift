import Foundation

@main
struct AttentionNoteTests {
    static func main() {
        var cases = 0
        func check(_ got: String?, _ want: String?, _ what: String) {
            precondition(got == want, "\(what): got \(got.map { "„\($0)“" } ?? "nil"), want \(want.map { "„\($0)“" } ?? "nil")")
            cases += 1
        }
        let n = AttentionNote.self

        // Klartext
        check(n.plain("Ist in `d828e1f` **gepusht**."), "Ist in d828e1f gepusht.", "backticks + bold")
        check(n.plain("Siehe [Plan](plans/x.md) und *das*."), "Siehe Plan und das.", "link + italic")
        check(n.plain("## Stand\n- eins\n- zwei"), "Stand eins zwei", "heading + list")
        check(n.plain("Vorher:\n```swift\nlet x = 1\n```\nNachher."), "Vorher: Nachher.", "code block gone")
        check(n.plain("Abgeschnitten ```bash\nrm -rf"), "Abgeschnitten", "unterminated code block")
        check(n.plain("kachel_layout_2026.md bleibt"), "kachel_layout_2026.md bleibt", "underscores stay")
        check(n.plain("Rückschau fertig, zwei Entscheidungen.** Die"), "Rückschau fertig, zwei Entscheidungen. Die", "stray bold")
        check(n.plain("a\u{1B}[31mb\tc"), "a [31mb c", "control chars")

        // Kürzen
        check(n.summary("Beide Repos sind gepusht, der Datenschutz-Check fand nichts.", max: 150),
              "Beide Repos sind gepusht, der Datenschutz-Check fand nichts.", "short stays")
        check(n.summary("Erster Satz ist da. Zweiter Satz ist deutlich länger und passt nicht mehr hinein.", max: 40),
              "Erster Satz ist da.", "cut at sentence")
        check(n.summary("Ein einziger sehr langer Satz ohne jedes Ende, der einfach weitergeht und weitergeht", max: 40),
              "Ein einziger sehr langer Satz ohne…", "cut at word")
        check(n.summary("Am 22.09. lief es. Danach war Ruhe im ganzen Haus und niemand sagte etwas.", max: 30),
              "Am 22.09. lief es.", "date is no sentence end")
        check(n.summary("Die Regressionstests sind grün:", max: 150), "Die Regressionstests sind grün …", "trailing colon")
        check(n.summary("   ", max: 10), nil, "empty → nil")
        check(n.summary(nil, max: 10), nil, "nil → nil")

        // Agenten-Meldungen
        check(n.agentMessage("Claude is waiting for your input"), nil, "waiting → nil")
        check(n.agentMessage("Claude needs your permission to use Bash"),
              "Möchte Bash verwenden – wartet auf Freigabe.", "permission builtin")
        check(n.agentMessage("Claude needs your permission to use mcp__latexterm__open_web"),
              "Möchte open_web (latexterm) verwenden – wartet auf Freigabe.", "permission mcp")
        check(n.agentMessage("Freigabe: shell"), "Möchte shell verwenden – wartet auf Freigabe.", "codex permission")
        check(n.plain("Fertig. ```sh rm x ``` Rest."), "Fertig. Rest.", "inline fence from joined lines")
        check(n.agentMessage("Welche Variante nehmen wir?"), "Welche Variante nehmen wir?", "question stays")

        // Ganzes Banner
        let note = AttentionNote(title: "Claude ist fertig", subtitle: "claude-werkstatt · 1:24",
                                 body: "Beide Korrekturen sind **gebaut** und `committet`, die Regressionstests grün:").cleaned
        check(note.body, "Beide Korrekturen sind gebaut und committet, die Regressionstests grün …", "note body")
        check(note.subtitle, "claude-werkstatt · 1:24", "note subtitle")

        print("attention-note: \(cases) Fälle grün")
    }
}
