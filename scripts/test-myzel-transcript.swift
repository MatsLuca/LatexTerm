import Foundation

@main
struct MyzelTranscriptTests {
    static func main() {
        var cases = 0
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            precondition(got == want, "\(what): got \(got), want \(want)")
            cases += 1
        }
        let t = MyzelTranscript.self
        let home = NSHomeDirectory()
        let jsonl = """
        {"type":"user","message":{"role":"user","content":"Myzel-Auftrag"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"los"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"\(home)/Documents/a.md"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"cat /etc/x\\nls"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"denied"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"mcp__myzel__entwurf","input":{"text":"GEHEIMER ENTWURF","fertig":true}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t4","name":"Grep","input":{"pattern":"foo","path":"/p"}}]}}
        kaputte zeile
        """
        let list = t.accesses(jsonl: jsonl)
        check(list.map(\.tool), ["Read", "Bash", "mcp__myzel__entwurf", "Grep"], "werkzeuge")
        check(list[0].target, "~/Documents/a.md", "pfad mit tilde")
        check(list[0].failed, false, "erfolgreich")
        check(list[1].failed, true, "abgelehnt")
        check(list[1].target, "cat /etc/x ⏎ ls", "bash einzeilig")
        check(list[2].target, "fertig, text", "mcp nur schlüssel, kein inhalt")
        check(list[3].target, "„foo“ in /p", "grep")
        check(list[3].failed, nil, "ohne ergebnis")
        check(t.lines(list), ["✓ Read  ~/Documents/a.md", "✗ Bash  cat /etc/x ⏎ ls", "· mcp__myzel__entwurf  fertig, text", "· Grep  „foo“ in /p"], "zeilen")
        check(t.target(tool: "Bash", input: ["command": String(repeating: "x", count: 300)]).count, 160, "gekürzt")

        let dir = NSTemporaryDirectory() + "myzel-tr-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir + "/-a-b", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir + "/-a-b/abc-123.jsonl", contents: Data())
        check(t.file(sessionID: "abc-123", projectsFolder: dir), dir + "/-a-b/abc-123.jsonl", "gefunden")
        check(t.file(sessionID: "../x", projectsFolder: dir), nil, "böse id")
        check(t.file(sessionID: "fff", projectsFolder: dir), nil, "fehlt")
        try? FileManager.default.removeItem(atPath: dir)
        print("myzel-transcript: \(cases) Fälle grün")
    }
}
