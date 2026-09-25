import Foundation

@main
struct MyzelJobsTests {
    static func main() {
        var cases = 0
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            precondition(got == want, "\(what): got \(got), want \(want)")
            cases += 1
        }
        func job(_ status: MyzelJobStatus, owner: String = "mats", trigger: String = "maja") -> MyzelJob {
            MyzelJob(id: "j_1", agent: "\(owner)-agent", besitzer: owner, ausloeser: trigger, nachricht: "m_1",
                     status: status, grund: nil, updated: "")
        }
        let a = MyzelJobAction.self
        check(a.available(for: job(.wartet), me: "mats"), [.approve, .reject, .cancel], "besitzer wartet")
        check(a.available(for: job(.wartet), me: "maja"), [.cancel], "auslöser wartet")
        check(a.available(for: job(.wartet), me: "dritter"), [], "fremder")
        check(a.available(for: job(.zugelassen), me: "mats"), [.start, .cancel], "zugelassen")
        check(a.available(for: job(.laeuft), me: "mats"), [.restart, .cancel], "läuft")
        check(a.available(for: job(.bereit), me: "mats"), [.review, .cancel], "bereit")
        check(a.available(for: job(.bereit), me: "maja"), [.cancel], "bereit auslöser")
        check(a.available(for: job(.gesendet), me: "mats"), [], "ende")
        check(a.available(for: job(.zugelassen, trigger: "mats"), me: "mats"), [.start, .cancel], "eigener")

        let big = MyzelAttachment(id: "a_big", name: "gross.pdf", mime: "application/pdf", bytes: 3_000_000, sha256: "x", pruefen: true)
        let small = MyzelAttachment(id: "a_small", name: "k.png", mime: "image/png", bytes: 10, sha256: "y", pruefen: false)
        let draft = MyzelDraft(auftrag: "j_1", status: "entwurf_bereit", text: "Hallo", anhaenge: [big, small], version: "v1")
        check(draft.needsConfirmation.map(\.id), ["a_big"], "prüfen")
        check(draft.missing(confirmed: []).map(\.id), ["a_big"], "fehlt")
        check(draft.missing(confirmed: ["a_big"]).isEmpty, true, "bestätigt")
        let unchanged = draft.sendBody(editedText: "Hallo", confirmed: ["a_big", "a_small"])
        check(unchanged.keys.sorted(), ["bestaetigt", "version"], "text unverändert weg")
        check(unchanged["bestaetigt"] as? [String], ["a_big"], "nur prüfpflichtige bestätigt")
        let edited = draft.sendBody(editedText: "Hallo!", confirmed: [])
        check(edited.keys.sorted(), ["text", "version"], "text geändert")
        check(edited["version"] as? String, "v1", "version")
        let decoded = try! JSONDecoder().decode(MyzelDraft.self, from: Data(#"{"auftrag":"j_1","status":"laeuft","text":"","version":""}"#.utf8))
        check(decoded.attachments.isEmpty, true, "entwurf ohne anhänge")

        let start = try! JSONDecoder().decode(MyzelStartReply.self, from: Data(("{\"auftrag\":\"j_1\",\"token\":\"mza_" + String(repeating: "a", count: 64) + "\"}").utf8))
        check(start.tokenLooksValid, true, "auftrags-token")
        check(MyzelStartReply(auftrag: "j", token: "mzm_" + String(repeating: "a", count: 64)).tokenLooksValid, false, "menschen-token abgelehnt")

        let path = NSTemporaryDirectory() + "myzel-test-\(UUID().uuidString)/umfang.json"
        var store = MyzelScopeStore(path: path)
        try! store.set(.project(name: "X", path: "/x"), for: "j_1")
        try! store.set(.chat, for: "j_2")
        let reloaded = MyzelScopeStore(path: path)
        check(reloaded["j_1"], .project(name: "X", path: "/x"), "umfang gespeichert")
        check(reloaded["j_2"], .chat, "umfang chat")
        let perms = (try! FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
        check(perms, 0o600, "0600")
        var pruned = reloaded
        try! pruned.prune(keeping: ["j_2"])
        check(MyzelScopeStore(path: path)["j_1"], nil, "aufgeräumt")
        check(MyzelScope.free.label.hasPrefix("frei"), true, "label")

        print("myzel-jobs: \(cases) Fälle grün")
    }
}
