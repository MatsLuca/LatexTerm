import Foundation

/// Fake-App für `latexterm mcp`: hält Kacheln, beantwortet Steuerkanal-Requests, merkt sich alles.
final class FakeApp: ControlTransport {
    var panes: [PaneInfo]
    var kindInfos: [PaneKindInfo]? = [
        PaneKindInfo(kind: "terminal", displayName: "Neues Terminal", summary: "Shell"),
        PaneKindInfo(kind: "scratchpad", displayName: "Neues Scratchpad", summary: "Malfläche",
                     actions: [PaneKindAction(name: "clear", summary: "leeren")]),
        PaneKindInfo(kind: "web", displayName: "HTML", summary: "Lokale Datei",
                     args: [PaneKindArg(name: "url", summary: "Pfad", required: true)],
                     actions: [PaneKindAction(name: "reload", summary: "neu laden")]),
    ]
    var details = true
    var received: [ControlRequest] = []
    var onList: (() -> Void)?
    /// Kachel-Layout: Stand-Nummer und Baum (nil = alle nebeneinander, automatisch).
    var revision = 1
    var root: LayoutNode?

    func report() -> LayoutReport {
        LayoutReport(revision: revision, automatic: root == nil,
                     root: root ?? .split(.row, panes.map { .leaf($0.id) }), width: 1000, height: 600)
    }

    init(_ panes: [PaneInfo]) { self.panes = panes }

    func send(_ request: ControlRequest) throws -> ControlResponse {
        received.append(request)
        var caps = ["agent-sessions", "all-windows", "pane-kinds"]
        if details { caps += ["pane-kind-info", "pane-details", "mailbox", "quiet-new-pane"] }
        switch request.cmd {
        case "list-panes":
            onList?()
            var response = ControlResponse(ok: true, panes: panes)
            response.capabilities = caps
            if request.paneID != nil { response.layout = report() }
            return response
        case "layout":
            guard request.layoutRevision == revision else {
                var stale = ControlResponse.failure("Die Anordnung hat sich geändert (Stand \(request.layoutRevision ?? -1) → \(revision)).")
                stale.layout = report()
                return stale
            }
            revision += 1
            var response = ControlResponse(ok: true)
            response.layout = report()
            return response
        case "pane-kinds":
            return ControlResponse(ok: true, kinds: ["terminal", "home", "scratchpad", "web"], kindInfos: details ? kindInfos : nil)
        case "new-pane":
            let id = String(format: "NEW%05d-0000", panes.count + 1)
            let pane = PaneInfo(id: id, index: panes.count + 1, cwd: request.cwd, focused: false, zoomed: false,
                                state: "none", kind: request.kind ?? "terminal",
                                args: request.kind == nil ? nil : request.args)
            panes.append(pane)
            revision += 1
            return ControlResponse(ok: true, pane: pane)
        case "close-pane":
            panes.removeAll { $0.id == request.pane }
            return ControlResponse(ok: true)
        case "call":
            // Scratchpad-Attrappe: look schreibt ein „PNG“ an den Pfad, draw/clear melden Zahlen.
            guard details else { return .failure("Unbekanntes Kommando „call“") }
            let text = request.text ?? ""
            var reply: String
            if text.hasPrefix("look ") {
                FileManager.default.createFile(atPath: String(text.dropFirst(5)), contents: Data([0x89, 0x50, 0x4E, 0x47]))
                reply = #"{"grid":50,"pixelsPerUnit":1.75,"region":{"x":-400,"y":-300,"w":800,"h":600},"visible":{"x":-400,"y":-300,"w":800,"h":600},"mats":{"count":3,"bounds":{"x":-10,"y":-5,"w":20,"h":10}},"claude":{"count":0,"bounds":null}}"#
            } else if text.hasPrefix("draw") {
                reply = #"{"added":4,"removed":3,"fitted":true,"bounds":{"x":0,"y":0,"w":10,"h":10},"warnings":["<foo> unbekannt, übergangen"]}"#
            } else {
                reply = #"{"removed":2,"left":1}"#
            }
            var response = ControlResponse(ok: true, pane: panes.first { $0.id == request.pane })
            response.reply = reply
            return response
        default:
            return ControlResponse(ok: true, pane: panes.first { $0.id == request.pane })
        }
    }

    func sent(_ cmd: String) -> [ControlRequest] { received.filter { $0.cmd == cmd } }
}

func pane(_ id: String, _ index: Int, kind: String = "terminal", state: String = "none", agent: String? = nil,
          foreground: String? = nil, args: [String: String]? = nil) -> PaneInfo {
    PaneInfo(id: id, index: index, cwd: "/tmp", focused: false, zoomed: false, state: state, agent: agent,
             kind: kind, args: args, foreground: foreground)
}

func call(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) -> (text: String, error: Bool) {
    let response = server.handle(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                  "params": ["name": name, "arguments": arguments]])!
    guard let result = response["result"] as? [String: Any] else {
        return ((response["error"] as? [String: Any])?["message"] as? String ?? "?", true)
    }
    let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    return (text, result["isError"] as? Bool ?? false)
}

func callContent(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) -> [[String: Any]] {
    let response = server.handle(["jsonrpc": "2.0", "id": 8, "method": "tools/call",
                                  "params": ["name": name, "arguments": arguments]])!
    return ((response["result"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
}

func toolNames(_ server: MCPServer) -> [String] {
    let response = server.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])!
    return ((response["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
}

@main
struct MCPServerTests {
    static func main() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(getpid())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let html = tmp.appendingPathComponent("plot.html").path
        try "<p>hi</p>".write(toFile: html, atomically: true, encoding: .utf8)
        var clock = Date(timeIntervalSince1970: 0)

        func makeServer(_ app: FakeApp, paneID: String? = "SELF-0000", sleep: @escaping (TimeInterval) -> Void = { _ in }) -> MCPServer {
            MCPServer(environment: paneID.map { ["LATEXTERM_PANE_ID": $0, "LATEXTERM_START_CLAUDE": "yolo"] } ?? [:],
                      transport: app, workingDirectory: tmp.path,
                      mailboxPath: { tmp.appendingPathComponent("box/\($0.lowercased())").path },
                      sleep: { clock.addTimeInterval($0); sleep($0) }, now: { clock })
        }

        // Außerhalb LatexTerm: keine Werkzeuge, Aufruf abgelehnt.
        let outside = makeServer(FakeApp([]), paneID: nil)
        assert(toolNames(outside).isEmpty)
        assert(call(outside, "panes").error)

        // initialize: Lagebild mit eigener Kachel, Protokollversion ausgehandelt.
        let app = FakeApp([pane("SELF-0000", 1, agent: "claude", foreground: "claude"),
                           pane("SHEL-0000", 2), pane("BUSY-0000", 3, foreground: "npm"),
                           pane("CLAU-0000", 4, state: "ready", agent: "claude", foreground: "claude"),
                           pane("CODX-0000", 5, state: "working", agent: "codex", foreground: "codex"),
                           pane("WEB0-0000", 6, kind: "web", args: ["url": html])])
        let server = makeServer(app)
        let initialize = server.handle(["jsonrpc": "2.0", "id": 0, "method": "initialize",
                                        "params": ["protocolVersion": "2025-06-18"]])!["result"] as! [String: Any]
        assert(initialize["protocolVersion"] as? String == "2025-06-18")
        assert((initialize["instructions"] as? String)?.contains("Nr. 1") == true)
        assert(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        assert((server.handle(["jsonrpc": "2.0", "id": 9, "method": "nope"])!["error"] as? [String: Any])?["code"] as? Int == -32601)

        // Werkzeuge: statische + je App-Kachelart eins, terminal/home nicht doppelt.
        let names = toolNames(server)
        for expected in ["panes", "open_terminal", "start_agent", "ask_session", "wait_session", "run_in_pane",
                         "pane_action", "focus_pane", "close_pane", "open_web", "open_scratchpad"] {
            assert(names.contains(expected), "fehlt: \(expected)")
        }
        assert(!names.contains("open_terminal_") && !names.contains("open_home"))
        assert(call(server, "panes").text.contains("← du"))

        // run_in_pane: nie eigene Kachel, nie Agent, nicht in laufende Programme, keine App-Kachel.
        assert(call(server, "run_in_pane", ["pane": "1", "command": "ls"]).error)
        assert(call(server, "run_in_pane", ["pane": "4", "command": "ls"]).error)
        assert(call(server, "run_in_pane", ["pane": "3", "command": "ls"]).error)
        assert(call(server, "run_in_pane", ["pane": "6", "command": "ls"]).error)
        assert(app.sent("send").isEmpty)
        assert(!call(server, "run_in_pane", ["pane": "shel", "command": "make test"]).error)
        assert(app.sent("send").last?.text == "make test" && app.sent("send").last?.enter == true)
        assert(!call(server, "run_in_pane", ["pane": "3", "command": "q", "into_running_program": true]).error)
        // Alte App ohne Details: lieber ablehnen als blind tippen.
        app.details = false
        assert(call(server, "run_in_pane", ["pane": "2", "command": "ls"]).error)
        app.details = true

        // Mehrdeutig / unbekannt.
        assert(call(server, "focus_pane", ["pane": "C"]).error)
        assert(call(server, "focus_pane", ["pane": "99"]).error)

        // open_web: relativer Pfad wird absolut, ohne Fokus; dieselbe Datei nochmal = reload statt neuer Kachel.
        app.panes.removeAll { $0.kind == "web" }
        let opened = call(server, "open_web", ["url": "plot.html"])
        assert(!opened.error, opened.text)
        let newPane = app.sent("new-pane").last!
        assert(newPane.kind == "web" && newPane.args?["url"] == html && newPane.focus == false)
        let before = app.sent("new-pane").count
        let again = call(server, "open_web", ["url": html])
        assert(again.text.contains("schon offen") && app.sent("new-pane").count == before)
        assert(app.sent("send").last?.text == "reload")
        assert(call(server, "open_web", [:]).error)

        // close_pane: eigene Öffnungen ja, fremde nur mit foreign, eigene Kachel nie, nie force.
        let webID = app.panes.last!.id
        assert(call(server, "close_pane", ["pane": "2"]).error)
        assert(call(server, "close_pane", ["pane": "1", "foreign": true]).error)
        assert(!call(server, "close_pane", ["pane": webID]).error)
        assert(!call(server, "close_pane", ["pane": "SHEL", "foreign": true]).error)
        assert(app.sent("close-pane").allSatisfy { $0.force != true })

        // ask_session an Claude: Briefkasten; der Empfänger holt ab → eingereicht, kein Einfügen.
        let sendsBefore = app.sent("send").count
        app.onList = {
            let box = tmp.appendingPathComponent("box/clau-0000").path
            for file in (try? FileManager.default.contentsOfDirectory(atPath: box)) ?? [] where file.hasSuffix(".md") {
                try? FileManager.default.removeItem(atPath: (box as NSString).appendingPathComponent(file))
            }
        }
        let asked = call(server, "ask_session", ["pane": "CLAU", "prompt": "Bitte Tests laufen lassen"])
        assert(asked.text.contains("eingereicht") && !asked.error, asked.text)
        assert(app.sent("send").count == sendsBefore)
        // Ohne Empfänger (Brief bleibt liegen) → nach 6 s Ruhe Einfügen in zwei Schritten.
        app.onList = nil
        let pasted = call(server, "ask_session", ["pane": "CLAU", "prompt": "Zweiter Auftrag"])
        assert(pasted.text.contains("eingefügt"), pasted.text)
        let pastes = app.sent("send").suffix(2)
        assert(pastes.first?.enter == false && pastes.first?.text == "Zweiter Auftrag" && pastes.last?.text == " ")
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("box/clau-0000").path)) ?? []
        assert(leftover.filter { $0.hasSuffix(".md") }.isEmpty)
        // An Shell, eigene Kachel, arbeitenden Codex: abgelehnt.
        assert(call(server, "ask_session", ["pane": "BUSY", "prompt": "x"]).error)
        assert(call(server, "ask_session", ["pane": "1", "prompt": "x"]).error)
        assert(call(server, "ask_session", ["pane": "CODX", "prompt": "x"]).error)

        // start_agent: Startbefehl aus der Env, ohne Fokus, Prompt nicht in der Befehlszeile.
        app.onList = nil
        let started = call(server, "start_agent", ["agent": "claude", "prompt": "Hallo 'Welt'"])
        let start = app.sent("new-pane").last!
        assert(start.exec == "yolo" && start.focus == false && start.cwd == tmp.path)
        assert(started.error, "neue Kachel meldet nie eine Session → nicht zugestellt")
        assert(call(server, "start_agent", ["agent": "gpt"]).error)

        // wait_session: wartet, bis Arbeit vorbei ist.
        var polls = 0
        app.panes[app.panes.firstIndex { $0.id == "CODX-0000" }!].state = "working"
        app.onList = {
            polls += 1
            if polls == 3, let i = app.panes.firstIndex(where: { $0.id == "CODX-0000" }) { app.panes[i].state = "ready" }
        }
        let waited = call(server, "wait_session", ["pane": "CODX"])
        assert(waited.text.contains("fertig"), waited.text)

        // Alte App ohne Selbstbeschreibung: Werkzeug bleibt, Args frei.
        let legacy = FakeApp([pane("SELF-0000", 1)])
        legacy.details = false
        let legacyServer = makeServer(legacy)
        assert(toolNames(legacyServer).contains("open_web"))
        assert(!call(legacyServer, "open_web", ["args": ["url": html]]).error)
        assert(legacy.sent("new-pane").last?.args?["url"] == html)

        // Scratchpad: ohne offenes → Hinweis auf open_scratchpad; sonst eigenes > einziges; Bild + Lage.
        let pads = FakeApp([pane("SELF-0000", 1, agent: "claude")])
        let padServer = makeServer(pads)
        for expected in ["scratch_look", "scratch_draw", "scratch_clear"] { assert(toolNames(padServer).contains(expected)) }
        let none = call(padServer, "scratch_look")
        assert(none.error && none.text.contains("open_scratchpad"), none.text)
        pads.panes.append(pane("PAD1-0000", 2, kind: "scratchpad"))
        let look = callContent(padServer, "scratch_look")
        assert(look.count == 2 && look[0]["type"] as? String == "image" && look[0]["mimeType"] as? String == "image/png")
        assert((look[0]["data"] as? String) == Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())
        let lookText = look[1]["text"] as? String ?? ""
        assert(lookText.contains("x -400…400") && lookText.contains("Raster alle 50") && lookText.contains("Nutzer: 3 Striche"), lookText)
        let lookPath = String(pads.sent("call").last!.text!.dropFirst(5))
        assert(!FileManager.default.fileExists(atPath: lookPath), "Bild wird nach dem Lesen gelöscht")
        // Zwei Scratchpads: das von dieser Session geöffnete gewinnt, sonst Rückfrage.
        pads.panes.append(pane("PAD2-0000", 3, kind: "scratchpad"))
        assert(call(padServer, "scratch_clear", ["who": "claude"]).error, "zwei fremde → pane angeben")
        assert(!call(padServer, "open_scratchpad").error)
        let drawn = call(padServer, "scratch_draw", ["svg": "<svg viewBox='0 0 10 10'><foo/></svg>", "replace": "mats"])
        assert(!drawn.error && drawn.text.contains("4 Elemente") && drawn.text.contains("3 entfernt") && drawn.text.contains("Hinweise"), drawn.text)
        let drawCall = pads.sent("call").last!
        assert(drawCall.pane == pads.panes.last!.id && drawCall.text!.hasPrefix("draw replace=mats\n<svg"))
        assert(call(padServer, "scratch_draw", ["svg": "<line/>", "replace": "alles"]).error)
        assert(call(padServer, "scratch_draw", ["svg": "  "]).error)
        assert(call(padServer, "scratch_look", ["pane": "1"]).error, "Kachel 1 ist kein Scratchpad")
        let cleared = call(padServer, "scratch_clear", ["who": "claude", "pane": "2"])
        assert(!cleared.error && cleared.text.contains("2 entfernt"), cleared.text)
        assert(pads.sent("call").last!.pane == "PAD1-0000" && pads.sent("call").last!.text == "clear claude")
        // Alte App ohne call: klare Meldung.
        pads.details = false
        assert(call(padServer, "scratch_clear", ["who": "all", "pane": "2"]).text.contains("neu starten"))

        // Kachel-Layout: erst lesen, dann ändern — auf dem gelesenen Stand; Nummern, die sich verschoben
        // haben, werden abgelehnt; Platzierung und Ersetzen.
        let lay = FakeApp([pane("SELF-0000", 1, agent: "claude"), pane("WEB1-0000", 2, kind: "web", args: ["url": html]),
                           pane("FREM-0000", 3)])
        lay.panes[1].openedBy = "SELF-0000"
        lay.kindInfos = [PaneKindInfo(kind: "web", displayName: "HTML", summary: "Lokale Datei",
                                      args: [PaneKindArg(name: "url", summary: "Pfad", required: true)],
                                      actions: [PaneKindAction(name: "reload", summary: "neu laden"),
                                                PaneKindAction(name: "load <pfad>", summary: "andere Seite")])]
        let layServer = makeServer(lay)
        assert(toolNames(layServer).contains("layout"))
        var r = call(layServer, "layout", ["action": "gross", "pane": "WEB1"])
        assert(r.error && r.text.contains("Erst den aktuellen Stand") && r.text.contains("Anordnung (Stand 1") && lay.sent("layout").isEmpty, r.text)
        r = call(layServer, "layout", ["action": "gross", "pane": "WEB1"])
        assert(!r.error && lay.sent("layout").last?.layoutRevision == 1 && lay.sent("layout").last?.layoutOp == "big"
               && lay.sent("layout").last?.pane == "WEB1-0000" && lay.sent("layout").last?.paneID == "SELF-0000", r.text)
        assert(r.text.contains("Stand 2"), r.text)
        lay.revision += 1   // Mats zieht eine Trennlinie: der gelesene Stand ist veraltet
        r = call(layServer, "layout", ["action": "kleiner", "pane": "WEB1"])
        assert(r.error && r.text.contains("geändert") && r.text.contains("Anordnung (Stand 3"), r.text)
        r = call(layServer, "layout", ["action": "kleiner", "pane": "WEB1"])
        assert(!r.error && lay.sent("layout").last?.layoutRevision == 3, r.text)
        assert(call(layServer, "layout", ["action": "tauschen", "pane": "WEB1"]).error)
        assert(call(layServer, "layout", ["action": "quer", "pane": "WEB1"]).error)
        r = call(layServer, "layout", ["action": "nebeneinander", "pane": "SELF", "other": "WEB1", "auf_auftrag": true])
        assert(!r.error && lay.sent("layout").last?.otherPane == "WEB1-0000" && lay.sent("layout").last?.onBehalf == true, r.text)
        r = call(layServer, "layout", ["action": "automatisch"])
        assert(!r.error && lay.sent("layout").last?.layoutOp == "auto" && lay.sent("layout").last?.pane == nil, r.text)
        // Lagebild: Baum, Anteile, eigene/geöffnete Kacheln, Mats' Handarbeit.
        lay.root = .split(.row, [.leaf("SELF-0000", weight: 3),
                                 .split(.column, [.leaf("WEB1-0000"), .leaf("FREM-0000")], setBy: .mats)])
        let shown = call(layServer, "layout").text
        assert(shown.contains("angepasst") && shown.contains("├ 75 % · 1 · SELF-000 · terminal · claude · ← du")
               && shown.contains("└ 25 % · übereinander ✋") && shown.contains("von dir geöffnet")
               && shown.contains("✋ = Aufteilung"), shown)
        assert(call(layServer, "panes").text.contains("Anordnung (Stand"))
        // Nummern verschoben: die gesehene Nr. 2 ist jetzt eine andere Kachel → abgelehnt, danach gilt der neue Stand.
        lay.panes.swapAt(1, 2)
        lay.panes[1].index = 2
        lay.panes[2].index = 3
        r = call(layServer, "focus_pane", ["pane": "2"])
        assert(r.error && r.text.contains("verschoben") && r.text.contains("WEB1-000"), r.text)
        assert(!call(layServer, "focus_pane", ["pane": "2"]).error)
        assert(lay.sent("focus").last?.pane == "FREM-0000")
        // Platzierung: neben mich (Default), eigen; neue Agenten-Session immer eigen.
        _ = call(layServer, "open_terminal")
        assert(lay.sent("new-pane").last?.placement == "beside")
        _ = call(layServer, "open_terminal", ["placement": "eigen"])
        assert(lay.sent("new-pane").last?.placement == "own")
        assert(call(layServer, "open_terminal", ["placement": "ersetzen"]).error)
        _ = call(layServer, "start_agent", ["agent": "claude"])
        assert(lay.sent("new-pane").last?.placement == "own")
        // Ersetzen: die eigene Web-Kachel lädt die neue Seite, statt eine zweite zu öffnen.
        let other = tmp.appendingPathComponent("other.html").path
        try "<p>b</p>".write(toFile: other, atomically: true, encoding: .utf8)
        let panesBefore = lay.sent("new-pane").count
        r = call(layServer, "open_web", ["url": other, "placement": "ersetzen"])
        assert(!r.error && lay.sent("new-pane").count == panesBefore && lay.sent("send").last?.text == "load " + other
               && lay.sent("send").last?.pane == "WEB1-0000", r.text)
        let third = tmp.appendingPathComponent("third.html").path
        try "<p>c</p>".write(toFile: third, atomically: true, encoding: .utf8)
        r = call(layServer, "open_web", ["url": third])
        assert(!r.error && lay.sent("new-pane").last?.placement == "beside" && r.text.contains("Anordnung (Stand"), r.text)

        print("mcp-server: ok")
    }
}
