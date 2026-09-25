import Foundation

@main
struct MyzelModelTests {
    static func main() {
        var cases = 0
        func check<T: Equatable>(_ got: T, _ want: T, _ what: String) {
            precondition(got == want, "\(what): got \(got), want \(want)")
            cases += 1
        }
        func event(_ json: String) -> MyzelEvent {
            try! JSONDecoder().decode(MyzelEvent.self, from: Data(json.utf8))
        }

        // Ereignisse wie vom Server (leere Felder fehlen)
        let m1 = event(#"{"v":1,"id":"m_01","ts":"2026-09-25T22:08:08.577488484Z","typ":"nachricht","von":"mats","text":"@mats-agent sag hallo","erwaehnt":["mats-agent"],"html":"<p>x</p>"}"#)
        let j1 = event(#"{"v":1,"id":"j_01","ts":"2026-09-25T22:08:08.579Z","typ":"auftrag","von":"server","agent":"mats-agent","besitzer":"mats","ausloeser":"mats","nachricht":"m_01","status":"zugelassen"}"#)
        let s1 = event(#"{"v":1,"id":"s_01","ts":"2026-09-25T22:10:24Z","typ":"status","von":"server","auftrag":"j_01","status":"laeuft"}"#)
        let s2 = event(#"{"v":1,"id":"s_02","ts":"2026-09-25T22:10:27Z","typ":"status","von":"mats-agent","auftrag":"j_01","status":"entwurf_bereit"}"#)
        let m2 = event(#"{"v":1,"id":"m_02","ts":"2026-09-25T22:10:56Z","typ":"nachricht","von":"mats-agent","text":"Hallo","antwort_auf":"m_01","gesendet_von":"mats","auftrag":"j_01","anhaenge":[{"id":"a_1","name":"x.png","mime":"image/png","bytes":10,"sha256":"ab"}]}"#)
        let fremd = event(#"{"v":1,"id":"j_02","ts":"2026-09-25T23:00:00Z","typ":"auftrag","von":"server","agent":"mats-agent","besitzer":"mats","ausloeser":"maja","nachricht":"m_03","status":"wartet_auf_zulassen"}"#)
        let unbekannt = event(#"{"v":2,"id":"x_01","ts":"2026-09-25T23:00:00Z","typ":"reaktion","von":"maja"}"#)
        let rename = event(#"{"v":1,"id":"n_01","ts":"2026-09-25T23:00:00Z","typ":"name","von":"mats","teilnehmer":"mats-agent","name":"Pilz"}"#)

        var chat = MyzelChat()
        chat.setParticipants([MyzelParticipant(id: "mats", art: "mensch", besitzer: nil, name: "mats"),
                              MyzelParticipant(id: "mats-agent", art: "agent", besitzer: "mats", name: "mats-agent")])
        check(chat.apply(m1), true, "nachricht")
        check(chat.apply(m1), false, "dedupe")
        check(chat.apply(j1), true, "auftrag")
        check(chat.jobs["j_01"]?.status, .zugelassen, "auftrag status")
        check(chat.active(for: "mats").map(\.id), ["j_01"], "aktiv")
        check(chat.apply(s1), true, "status laeuft")
        check(chat.apply(s2), true, "status bereit")
        check(chat.waiting(for: "mats").map(\.id), ["j_01"], "entwurf wartet")
        check(chat.waiting(for: "maja").isEmpty, true, "maja wartet nicht")
        check(chat.apply(m2), true, "antwort")
        check(chat.messages.count, 2, "zwei nachrichten")
        check(chat.message("m_02")?.anhaenge?.first?.isImage, true, "anhang bild")
        check(chat.jobs(forMessage: "m_01").map(\.id), ["j_01"], "auftrag an nachricht")
        check(chat.jobs["j_01"]?.isForeign, false, "eigener auftrag")
        check(chat.apply(fremd), true, "fremder auftrag")
        check(chat.jobs["j_02"]?.isForeign, true, "fremd")
        check(chat.waiting(for: "mats").map(\.id), ["j_01", "j_02"], "zwei warten")
        check(chat.apply(unbekannt), false, "unbekannter typ übersprungen")
        check(chat.lastID, "x_01", "lastID rückt trotzdem")
        check(chat.apply(rename), true, "umbenennen")
        check(chat.displayName("mats-agent"), "Pilz", "neuer name")
        chat.setParticipants([MyzelParticipant(id: "mats-agent", art: "agent", besitzer: "mats", name: "mats-agent")])
        check(chat.displayName("mats-agent"), "Pilz", "umbenennung überlebt /ich")
        check(chat.displayName("wer"), "wer", "unbekannt = id")
        check(MyzelStatusText.text(chat.jobs["j_02"]!, chat: chat), "wartet auf mats", "status text")
        var failed = chat.jobs["j_01"]!; failed.status = .fehlgeschlagen; failed.grund = "zeitlimit"
        check(MyzelStatusText.text(failed, chat: chat), "fehlgeschlagen (zeitlimit)", "status grund")
        check(MyzelJobStatus.gesendet.isEnd, true, "endzustand")
        check(MyzelJobStatus.bereit.isEnd, false, "kein endzustand")

        // Zeit mit Nanosekunden
        let date = MyzelTime.parse("2026-09-25T22:08:08.577488484Z")
        check(date.map { Int($0.timeIntervalSince1970) }, 1_790_374_088, "nano ts")
        check(MyzelTime.parse("2026-09-25T22:08:08Z") != nil, true, "ts ohne bruch")
        check(MyzelTime.parse("quatsch") == nil, true, "ts unsinn")

        // Konfiguration
        let config = try! MyzelConfig.parse(Data(#"{"server":"https://chat.beispiel.de/","agent_ordner":"~/Agent","projekte":{"b":"~/B","A":"/a"},"sperrliste":["~/.ssh"]}"#.utf8))
        check(config.server.absoluteString, "https://chat.beispiel.de", "server ohne slash")
        check(config.host, "chat.beispiel.de", "host")
        check(config.agentFolder, NSHomeDirectory() + "/Agent", "tilde")
        check(config.projects.map(\.name), ["A", "b"], "projekte sortiert")
        check(config.blocklist, [NSHomeDirectory() + "/.ssh"], "sperrliste")
        check(config.tokenFile == nil, true, "ohne token-datei")
        for bad in [#"{"server":"http://x.de","agent_ordner":"a"}"#, #"{"server":"https://x.de/pfad","agent_ordner":"a"}"#,
                    #"{"server":"https://x.de"}"#, #"{"server":"https://x.de","agent_ordner":"a","extra":1}"#, "[]"] {
            check((try? MyzelConfig.parse(Data(bad.utf8))) == nil, true, "config abgelehnt: \(bad)")
        }
        check(MyzelConfig.tilde(NSHomeDirectory() + "/x"), "~/x", "tilde zurück")

        print("myzel-model: \(cases) Fälle grün")
    }
}
