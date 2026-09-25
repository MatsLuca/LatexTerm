import Foundation

@main
struct MyzelSandboxTests {
    static func main() {
        var cases = 0
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            precondition(got == want, "\(what): got \(got), want \(want)")
            cases += 1
        }
        let s = MyzelSandbox.self
        var input = MyzelSandbox.Inputs(jobFolder: "/state/auftraege/j_1", scope: .chat, blocklist: ["/home/.ssh"],
                                        accessFolder: "/state/zugang", serverHost: "chat.beispiel.de")
        func perms(_ i: MyzelSandbox.Inputs) -> [String: Any] { s.settings(i)["permissions"] as! [String: Any] }
        func box(_ i: MyzelSandbox.Inputs) -> [String: Any] { s.settings(i)["sandbox"] as! [String: Any] }

        let p = perms(input)
        check(p["defaultMode"] as? String, "dontAsk", "dontAsk")
        check(p["disableBypassPermissionsMode"] as? String, "disable", "kein bypass")
        check(p["blockReadsOutsideWorkingDirectories"] as? Bool, true, "nur chat: lese-sperre")
        let allow = p["allow"] as! [String]
        check(allow.contains("Edit(//state/auftraege/j_1/**)"), true, "schreiben nur im auftrag")
        check(allow.contains("mcp__myzel__entwurf"), true, "myzel-werkzeuge")
        check(allow.contains { $0.hasPrefix("WebFetch") }, false, "kein webfetch erlaubt")
        let deny = p["deny"] as! [String]
        check(deny.contains("WebFetch") && deny.contains("WebSearch"), true, "web gesperrt")
        check(deny.contains("mcp__claude-in-chrome"), true, "browser gesperrt")
        check(deny.contains("Read(//home/.ssh/**)"), true, "sperrliste werkzeuge")
        check(deny.contains("Read(//state/zugang/**)"), true, "zugang gesperrt")

        let b = box(input)
        check(b["enabled"] as? Bool, true, "sandbox an")
        check(b["failIfUnavailable"] as? Bool, true, "ohne sandbox kein start")
        check(b["allowUnsandboxedCommands"] as? Bool, false, "kein ausweg")
        let fs = b["filesystem"] as! [String: Any]
        check(fs["allowWrite"] as? [String], ["/state/auftraege/j_1"], "bash schreibt nur im auftrag")
        check(fs["denyRead"] as? [String], ["/home/.ssh", "/state/zugang"], "bash sperrliste")
        let net = b["network"] as! [String: Any]
        check(net["allowedDomains"] as? [String], ["chat.beispiel.de"], "netz nur myzel")
        check(net["strictAllowlist"] as? Bool, true, "strikt")

        input.scope = .project(name: "X", path: "/proj/x/")
        check(perms(input)["blockReadsOutsideWorkingDirectories"] as? Bool, true, "projekt: lese-sperre")
        check((perms(input)["deny"] as! [String]).contains("Edit(//proj/x/**)"), true, "projekt nicht schreiben")
        check(((box(input)["filesystem"] as! [String: Any])["denyWrite"] as? [String]), ["/proj/x/"], "bash projekt nicht schreiben")
        check(s.args(settingsPath: "/s.json", scope: input.scope).suffix(2), ["--add-dir", "/proj/x/"], "projekt add-dir")

        input.scope = .free
        check(perms(input)["blockReadsOutsideWorkingDirectories"] == nil, true, "frei: ohne lese-sperre")
        check((perms(input)["deny"] as! [String]).contains("Read(//home/.ssh/**)"), true, "frei: sperrliste bleibt")
        check(s.args(settingsPath: "/s.json", scope: .free),
              ["--settings", "/s.json", "--strict-mcp-config", "--permission-mode", "dontAsk", "--no-chrome"], "args")
        check(s.rule("/a/b/"), "//a/b", "regel-pfad")

        let dir = NSTemporaryDirectory() + "myzel-sb-\(UUID().uuidString)"
        input.accessFolder = dir
        let args = try! s.prepare(input, jobID: "j_9")
        let path = dir + "/j_9.settings.json"
        check(args[1], path, "settings-pfad")
        let perm = (try! FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as! NSNumber).intValue
        check(perm, 0o600, "settings 0600")
        check((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) != nil, true, "json lesbar")
        check((try? s.prepare(input, jobID: "../x")) == nil, true, "böse id")
        try? FileManager.default.removeItem(atPath: dir)

        print("myzel-sandbox: \(cases) Fälle grün")
    }
}
