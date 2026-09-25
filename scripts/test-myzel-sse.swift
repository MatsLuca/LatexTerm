import Foundation

@main
struct MyzelSSETests {
    static func main() {
        var cases = 0
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            precondition(got == want, "\(what): got \(got), want \(want)")
            cases += 1
        }
        typealias F = MyzelSSEParser.Frame

        var p = MyzelSSEParser()
        check(p.feed(Data("id: m_1\ndata: {\"a\":1}\n\n".utf8)), [F(id: "m_1", data: "{\"a\":1}")], "ganzer frame")
        check(p.feed(Data(": puls\n\n".utf8)), [], "puls ist kein frame")
        check(p.feed(Data("id: m_2\nda".utf8)), [], "halber frame")
        check(p.feed(Data("ta: x\n".utf8)), [], "noch ohne leerzeile")
        check(p.feed(Data("\n".utf8)), [F(id: "m_2", data: "x")], "frame fertig")
        check(p.feed(Data("id: m_3\r\ndata: y\r\n\r\n".utf8)), [F(id: "m_3", data: "y")], "crlf")

        // UTF-8 mitten im Zeichen getrennt
        let umlaut = Array("data: ä€\n\n".utf8)
        check(p.feed(Data(umlaut[0..<7])), [], "halbes zeichen")
        check(p.feed(Data(umlaut[7...])), [F(id: nil, data: "ä€")], "zeichen zusammengesetzt")

        // Mehrere Frames in einem Stück, mehrzeilige Daten, Feld ohne Leerzeichen
        check(p.feed(Data("data:a\ndata: b\n\nid: m_4\ndata: c\n\n".utf8)),
              [F(id: nil, data: "a\nb"), F(id: "m_4", data: "c")], "zwei frames")
        check(p.feed(Data("event: x\nretry: 5\n\n".utf8)), [], "ohne data kein frame")
        check(p.feed(Data()), [], "leer")

        check(MyzelBackoff.delay(attempt: 1), 2, "backoff 1")
        check(MyzelBackoff.delay(attempt: 3), 8, "backoff 3")
        check(MyzelBackoff.delay(attempt: 10), 30, "backoff max")

        print("myzel-sse: \(cases) Fälle grün")
    }
}
