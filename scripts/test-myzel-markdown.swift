import Foundation

@main
struct MyzelMarkdownTests {
    static func main() {
        var cases = 0
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            precondition(got == want, "\(what):\n got  \(got)\n want \(want)")
            cases += 1
        }
        let md = MyzelMarkdown.self
        func kinds(_ s: String) -> [MyzelBlock.Kind] { md.blocks(s).map(\.kind) }
        func texts(_ s: String) -> [String] { md.blocks(s).map { $0.spans.map(\.text).joined() } }

        check(texts("Hallo **Welt**"), ["Hallo Welt"], "absatz")
        check(md.blocks("Hallo **Welt**")[0].spans.last?.style, .strong, "fett")
        check(md.blocks("a *b* `c` ~~d~~")[0].spans.map(\.style), [[], .emphasis, [], .code, [], .strike], "inline stile")
        check(kinds("# Titel\n\nText"), [.heading(1), .paragraph], "überschrift")
        check(texts("```swift\nlet x = 1\nlet y = 2\n```"), ["let x = 1\nlet y = 2"], "codeblock text")
        check(kinds("```\nx\n```"), [.code], "codeblock art")
        check(kinds("- a\n- b"), [.listItem(marker: "•", depth: 0), .listItem(marker: "•", depth: 0)], "liste")
        check(kinds("1. a\n2. b"), [.listItem(marker: "1.", depth: 0), .listItem(marker: "2.", depth: 0)], "nummeriert")
        check(kinds("- a\n  - b"), [.listItem(marker: "•", depth: 0), .listItem(marker: "•", depth: 1)], "verschachtelt")
        check(md.blocks("> zitat").first?.quote, 1, "zitat")
        check(kinds("a\n\n---\n\nb"), [.paragraph, .rule, .paragraph], "linie")
        check(texts("| A | B |\n|---|---|\n| 1 | 2 |"), ["A  │  B", "1  │  2"], "tabelle text")
        check(kinds("| A | B |\n|---|---|\n| 1 | 2 |"), [.tableRow(header: true), .tableRow(header: false)], "tabelle art")

        // Sicherheit
        check(md.blocks("[x](javascript:alert(1))")[0].spans[0].link, nil, "javascript-link weg")
        check(md.blocks("[x](https://beispiel.de)")[0].spans[0].link, URL(string: "https://beispiel.de"), "https-link")
        check(md.blocks("[x](file:///etc/passwd)")[0].spans[0].link, nil, "file-link weg")
        check(texts("![Katze](https://beispiel.de/k.png)"), ["🖼 Katze"], "bild nur als text")
        check(md.blocks("![Katze](https://beispiel.de/k.png)")[0].spans[0].link, nil, "bild ohne link")
        check(texts("<b>fett</b> <script>x</script>").joined().contains("<b>"), true, "html bleibt text")

        // Nackte URLs und Erwähnungen
        let auto = md.blocks("siehe https://beispiel.de/x und weiter")[0].spans
        check(auto.map(\.text), ["siehe ", "https://beispiel.de/x", " und weiter"], "autolink split")
        check(auto[1].link, URL(string: "https://beispiel.de/x"), "autolink url")
        let ment = md.blocks("hey @mats-agent und @niemand, mail@x.de", mentions: ["mats-agent", "niemand2"])[0].spans
        check(ment.filter(\.mention).map(\.text), ["@mats-agent"], "nur bekannte erwähnung")
        check(md.blocks("`@mats-agent`", mentions: ["mats-agent"])[0].spans.contains(where: \.mention), false, "keine erwähnung in code")
        check(md.blocks("```\n@mats-agent\n```", mentions: ["mats-agent"])[0].spans.contains(where: \.mention), false, "keine erwähnung in codeblock")
        check(md.plain("# A\n\n**b** c"), "A b c", "plain")
        check(texts(""), [], "leer")

        print("myzel-markdown: \(cases) Fälle grün")
    }
}
