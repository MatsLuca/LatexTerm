import Foundation

@main
struct MyzelLaunchTests {
    static func main() {
        var cases = 0
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            precondition(got == want, "\(what): got \(got), want \(want)")
            cases += 1
        }
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "myzel-launch-\(UUID().uuidString)"
        let agent = root + "/agent"
        let state = root + "/state"
        try! fm.createDirectory(atPath: agent, withIntermediateDirectories: true)
        try! "# Agent\n\n## Regeln\n\n@regeln.md\n".write(toFile: agent + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try! "- geheim: nichts".write(toFile: agent + "/regeln.md", atomically: true, encoding: .utf8)
        try! "Zusammenfassung".write(toFile: agent + "/zusammenfassung.md", atomically: true, encoding: .utf8)
        try! #"{"nach": "m_01ABC"}"#.write(toFile: agent + "/stand.json", atomically: true, encoding: .utf8)

        let token = "mza_" + String(repeating: "b", count: 64)
        var input = MyzelLaunch.Inputs(jobID: "j_01XYZ", token: token, server: URL(string: "https://chat.beispiel.de")!,
                                       stateFolder: state, agentFolder: agent, own: true, trigger: "mats",
                                       after: MyzelLaunch.lastSeen(agentFolder: agent))
        input.sessionID = "11111111-2222-3333-4444-555555555555"
        let launch = try! MyzelLaunch.prepare(input)

        check(input.after, "m_01ABC", "stand gelesen")
        check(launch.jobFolder, state + "/auftraege/j_01XYZ", "auftragsordner")
        let claude = try! String(contentsOfFile: launch.jobFolder + "/CLAUDE.md", encoding: .utf8)
        check(claude.contains("- geheim: nichts"), true, "regeln eingesetzt")
        check(claude.contains("@regeln.md"), false, "import ersetzt")
        check((try? String(contentsOfFile: launch.jobFolder + "/zusammenfassung.md", encoding: .utf8)), "Zusammenfassung", "zusammenfassung kopiert")

        let mcp = try! String(contentsOfFile: launch.mcpConfig, encoding: .utf8)
        check(mcp.contains("Bearer " + token), true, "token in datei")
        check(mcp.contains("https://chat.beispiel.de/mcp"), true, "mcp url")
        check(launch.mcpConfig.hasPrefix(launch.jobFolder), false, "zugang außerhalb des arbeitsordners")
        let perm = (try! fm.attributesOfItem(atPath: launch.mcpConfig)[.posixPermissions] as! NSNumber).intValue
        check(perm, 0o600, "zugang 0600")
        let dirPerm = (try! fm.attributesOfItem(atPath: state + "/zugang")[.posixPermissions] as! NSNumber).intValue
        check(dirPerm, 0o700, "zugang-ordner 0700")

        check(launch.command.contains(token), false, "kein token auf der kommandozeile")
        check(launch.command.hasPrefix(" claude '"), true, "leerzeichen + prompt zuerst")
        check(launch.command.contains("--session-id 11111111-2222-3333-4444-555555555555"), true, "session-id")
        check(launch.command.contains("--mcp-config " + MyzelLaunch.shellQuote(launch.mcpConfig)), true, "mcp-config")
        check(launch.command.contains("--add-dir"), true, "eigener auftrag: agenten-ordner")
        let promptEnd = launch.command.range(of: "--session-id")!.lowerBound
        check(launch.command[..<promptEnd].contains("nach: m_01ABC"), true, "nach im prompt")

        var foreign = input
        foreign.jobID = "j_02"
        foreign.own = false
        foreign.trigger = "maja"
        foreign.after = nil
        foreign.extraArgs = ["--settings", "/x y/s.json"]
        let other = try! MyzelLaunch.prepare(foreign)
        check(other.command.contains("--add-dir"), false, "fremd: kein agenten-ordner")
        check(other.command.contains("'/x y/s.json'"), true, "extra args gequotet")
        check(other.command.contains("n: 20"), true, "fremd ohne stand")
        check(MyzelLaunch.prompt(foreign, jobFolder: "").contains("nichts außerhalb"), true, "fremd-hinweis")

        check(MyzelLaunch.shellQuote("it's"), "'it'\\''s'", "quote apostroph")
        check(MyzelLaunch.shellQuote("--flag"), "--flag", "quote einfach")
        check(MyzelLaunch.isSafeID("j_01ABC"), true, "id ok")
        check(MyzelLaunch.isSafeID("../x"), false, "id pfad")
        check((try? MyzelLaunch.prepare({ var i = input; i.jobID = "../../x"; return i }())) == nil, true, "böse id abgelehnt")
        check((try? MyzelLaunch.prepare({ var i = input; i.agentFolder = root + "/fehlt"; return i }())) == nil, true, "ohne claude.md")

        MyzelLaunch.revoke(jobID: "j_01XYZ", stateFolder: state)
        check(fm.fileExists(atPath: launch.mcpConfig), false, "zugang gelöscht")
        try? fm.removeItem(atPath: root)
        print("myzel-launch: \(cases) Fälle grün")
    }
}
