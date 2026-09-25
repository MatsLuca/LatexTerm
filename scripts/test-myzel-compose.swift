import Foundation

@main
struct MyzelComposeTests {
    static func main() {
        var cases = 0
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            precondition(got == want, "\(what): got \(got), want \(want)")
            cases += 1
        }
        let c = MyzelCompose.self

        check(c.mime(forFileName: "Bild.PNG"), "image/png", "mime gross")
        check(c.mime(forFileName: "notiz.md"), "text/markdown", "mime md")
        check(c.mime(forFileName: "x.exe"), nil, "mime unbekannt")
        check(c.problem(name: "a.pdf", bytes: 100, alreadyAttached: 0), nil, "pdf ok")
        check(c.problem(name: "a.zip", bytes: 100, alreadyAttached: 0) != nil, true, "zip abgelehnt")
        check(c.problem(name: "a.pdf", bytes: 21 * 1024 * 1024, alreadyAttached: 0) != nil, true, "zu groß")
        check(c.problem(name: "a.pdf", bytes: 100, alreadyAttached: 5) != nil, true, "zu viele")
        check(c.problem(name: "a.pdf", bytes: 0, alreadyAttached: 0) != nil, true, "leer")

        func prefix(_ s: String) -> String? { c.mentionPrefix(in: s, cursor: (s as NSString).length)?.partial }
        check(prefix("hey @ma"), "ma", "angefangen")
        check(prefix("@"), "", "nur at")
        check(prefix("@mats-ag"), "mats-ag", "mit bindestrich")
        check(prefix("mail@ma"), nil, "mailadresse")
        check(prefix("hey ma"), nil, "ohne at")
        check(prefix("@mats "), nil, "nach leerzeichen vorbei")
        check(c.mentionPrefix(in: "x @ma y", cursor: 5).map { NSStringFromRange($0.range) }, "{2, 3}", "bereich mitten drin")

        let ids = ["mats", "maja", "mats-agent", "maja-agent"]
        check(c.completions("ma", among: ids, excluding: "mats"), ["maja", "maja-agent", "mats-agent"], "anfang, ohne mich")
        check(c.completions("agent", among: ids, excluding: nil), ["maja-agent", "mats-agent"], "enthält")
        check(c.completions("", among: ids, excluding: "mats"), ["maja", "maja-agent", "mats-agent"], "alle")

        check(c.messageBody(text: "hi", replyTo: nil, attachments: []).keys.sorted(), ["text"], "nur text")
        check(c.messageBody(text: "hi", replyTo: "m_1", attachments: ["a_1"]).keys.sorted(), ["anhaenge", "antwort_auf", "text"], "alles")
        check(c.canSend(text: "  \n", attachments: 0), false, "leer nicht senden")
        check(c.canSend(text: "", attachments: 1), true, "nur anhang")

        print("myzel-compose: \(cases) Fälle grün")
    }
}
