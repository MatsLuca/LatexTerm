import Foundation

@main
struct SessionRestoreTests {
    static func main() throws {
        var cases = 0
        func check(_ ok: Bool, _ what: String) {
            precondition(ok, what)
            cases += 1
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("latexterm restore test \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sub dir/session.json")

        // Codec: v2 hin und zurück, fehlende args, v1-Übersetzung, unbekannte Version.
        let claude = PaneSnapshot(kind: "terminal", args: ["cwd": "/Users/x/Projekt", "agent": "claude",
                                                          "session": "0b1c-22_ab", "accentName": "cyan"])
        let window = SessionSnapshot.Window(panes: [claude, PaneSnapshot(kind: "home")], focused: 1, zoomed: 0)
        let bare = SessionSnapshot.Window(panes: [PaneSnapshot(kind: "terminal")])
        let snap = SessionSnapshot(windows: [window, bare], restoreOnce: true)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(snap))
        check(decoded == snap, "v2 roundtrip")
        let noArgs = try JSONDecoder().decode(PaneSnapshot.self, from: Data(#"{"kind":"home"}"#.utf8))
        check(noArgs == PaneSnapshot(kind: "home"), "missing args decode as empty")
        check(noArgs.id == nil && noArgs.openedBy == nil, "old snapshot has no id/openedBy")
        let owned = PaneSnapshot(kind: "web", args: ["url": "/tmp/a.html"], id: "AAAA-1", openedBy: "BBBB-2")
        check(try JSONDecoder().decode(PaneSnapshot.self, from: try JSONEncoder().encode(owned)) == owned,
              "id and openedBy survive the round trip")
        // Kachel-Layout: Begleiter und angepasste Anordnung überleben; das Layout behält nur Kacheln des
        // Snapshots; ein kaputtes Layout kostet nur die Anordnung, nie die Kacheln; alte Snapshots haben keins.
        let companion = PaneSnapshot(kind: "preview", args: ["url": "/tmp/a.pdf"], id: "CCCC-3", openedBy: "AAAA-1",
                                     companionOf: "AAAA-1")
        check(try JSONDecoder().decode(PaneSnapshot.self, from: try JSONEncoder().encode(companion)) == companion,
              "companionOf survives the round trip")
        // Reiter (Stufe 2): verdeckte Kacheln und der Reiter-Platz im Layout überleben; alt = sichtbar.
        let behind = PaneSnapshot(kind: "web", args: ["url": "/tmp/b.html"], id: "DDDD-4", companionOf: "AAAA-1", hidden: true)
        check(try JSONDecoder().decode(PaneSnapshot.self, from: try JSONEncoder().encode(behind)) == behind,
              "hidden survives the round trip")
        check(companion.hidden == nil, "old snapshot panes are visible")
        let tabPlace = SessionSnapshot.Window(entries: [
            (snapshot: PaneSnapshot(kind: "terminal", id: "AAAA-1"), focused: true, zoomed: false),
            (snapshot: companion, focused: false, zoomed: false),
            (snapshot: behind, focused: false, zoomed: false),
        ], layout: .split(.row, [.leaf("AAAA-1"), .group(["CCCC-3", "DDDD-4", "GONE-9"], front: "CCCC-3")], setBy: .mats))
        check(tabPlace.layout?.children[1] == .group(["CCCC-3", "DDDD-4"], front: "CCCC-3"),
              "tab place keeps its snapshot panes: \(String(describing: tabPlace.layout))")
        let arranged = LayoutNode.split(.row, [.leaf("AAAA-1", weight: 0.6), .leaf("CCCC-3", weight: 0.4)], setBy: .mats)
        let laidOut = SessionSnapshot.Window(entries: [
            (snapshot: PaneSnapshot(kind: "terminal", id: "AAAA-1"), focused: true, zoomed: false),
            (snapshot: nil, focused: false, zoomed: false),
            (snapshot: companion, focused: false, zoomed: false),
        ], layout: .split(.row, [arranged, .leaf("GONE-9")]))
        check(laidOut.layout == arranged, "layout keeps only snapshot panes: \(String(describing: laidOut.layout))")
        let laidOutSnap = SessionSnapshot(windows: [laidOut], restoreOnce: true)
        check(try JSONDecoder().decode(SessionSnapshot.self, from: JSONEncoder().encode(laidOutSnap)) == laidOutSnap,
              "layout round trip")
        let brokenLayout = try JSONDecoder().decode(SessionSnapshot.Window.self,
            from: Data(#"{"panes":[{"kind":"home"}],"layout":{"children":"kaputt"}}"#.utf8))
        check(brokenLayout.panes.count == 1 && brokenLayout.layout == nil, "broken layout drops only the layout")
        check(window.layout == nil, "no layout = automatic")
        let v1 = try JSONDecoder().decode(SessionSnapshot.self,
            from: Data(##"{"version":1,"paneDirectories":["/tmp/a",null],"paneAccents":["#FFFFFF"]}"##.utf8))
        check(v1.windows == [SessionSnapshot.Window(panes: [PaneSnapshot(kind: "terminal", args: ["cwd": "/tmp/a"]),
                                                            PaneSnapshot(kind: "home")])],
              "v1 paneDirectories become one window")
        check(v1.restoreOnce == false && v1.version == 2, "v1 never restores")
        check((try? JSONDecoder().decode(SessionSnapshot.self, from: Data(#"{"version":3,"windows":[]}"#.utf8))) == nil,
              "unknown version rejected")
        let v2NoFlag = try JSONDecoder().decode(SessionSnapshot.self,
            from: Data(#"{"version":2,"windows":[{"panes":[{"kind":"home"}]}]}"#.utf8))
        check(!v2NoFlag.restoreOnce && v2NoFlag.windows[0].focused == nil, "v2 optional fields default")

        // Fenster aus Kacheln: Kacheln ohne Snapshot fallen weg, Indizes rücken nach.
        let built = SessionSnapshot.Window(entries: [
            (snapshot: nil, focused: false, zoomed: false),
            (snapshot: PaneSnapshot(kind: "home"), focused: false, zoomed: true),
            (snapshot: nil, focused: false, zoomed: false),
            (snapshot: claude, focused: true, zoomed: false),
        ])
        check(built.panes == [PaneSnapshot(kind: "home"), claude] && built.focused == 1 && built.zoomed == 0,
              "focus/zoom indices follow dropped panes")
        let unfocused = SessionSnapshot.Window(entries: [(snapshot: claude, focused: false, zoomed: false)])
        check(unfocused.focused == nil && unfocused.zoomed == nil, "no focus stays nil")

        // Was wird wie wiederhergestellt.
        check(RestoreStep(PaneSnapshot(kind: "home")) == .home, "home stays home")
        check(RestoreStep(PaneSnapshot(kind: "zeichenbrett", args: ["cwd": "/tmp"])) == .app(kind: "zeichenbrett", args: ["cwd": "/tmp"]),
              "other kind goes to the registry (unknown → Home in the split view)")
        check(RestoreStep(claude) == .resume(agent: "claude", sessionID: "0b1c-22_ab", cwd: "/Users/x/Projekt", accentName: "cyan"),
              "claude session resumes")
        check(RestoreStep(PaneSnapshot(kind: "terminal", args: ["agent": "codex", "session": "019a-b"]))
              == .resume(agent: "codex", sessionID: "019a-b", cwd: nil, accentName: nil), "codex session resumes without cwd")
        check(RestoreStep(PaneSnapshot(kind: "terminal", args: ["cwd": "/tmp/vim"])) == .shell(cwd: "/tmp/vim"),
              "pane without identity becomes shell")
        check(RestoreStep(PaneSnapshot(kind: "terminal")) == .shell(cwd: nil), "shell without cwd")
        check(RestoreStep(PaneSnapshot(kind: "terminal", args: ["cwd": "/tmp", "agent": "claude", "session": "x; rm -rf ~"]))
              == .shell(cwd: "/tmp"), "unsafe session id never reaches a command")
        check(RestoreStep(PaneSnapshot(kind: "terminal", args: ["cwd": "/tmp", "agent": "gemini", "session": "abc"]))
              == .shell(cwd: "/tmp"), "unknown agent becomes shell")
        check(RestoreStep(PaneSnapshot(kind: "terminal", args: ["cwd": "/tmp", "session": "abc"])) == .shell(cwd: "/tmp"),
              "session without agent becomes shell")
        check(RestoreStep(PaneSnapshot(kind: "terminal", args: ["cwd": "relativ/pfad"])) == .shell(cwd: nil),
              "relative cwd dropped")
        check(RestoreStep(PaneSnapshot(kind: "terminal", args: ["agent": "claude", "session": "abc", "accentName": "red; x"]))
              == .resume(agent: "claude", sessionID: "abc", cwd: nil, accentName: nil), "unsafe accent name dropped")

        // Marke: genau einmal, vor dem Wiederherstellen gelöscht.
        check(SessionStore.takeRestore(from: file) == nil, "missing file → normal start")
        SessionStore.save(SessionSnapshot(windows: [window]), to: file)
        check(SessionStore.takeRestore(from: file) == nil, "normal quit → normal start")
        check(SessionStore.load(from: file)?.windows == [window], "normal quit still saves the layout")
        SessionStore.save(SessionSnapshot(windows: [window, SessionSnapshot.Window(panes: [])], restoreOnce: true), to: file)
        check(SessionStore.takeRestore(from: file) == [window], "marked snapshot restores, empty windows dropped")
        check(SessionStore.load(from: file)?.restoreOnce == false, "mark cleared on disk")
        check(SessionStore.load(from: file)?.windows.first == window, "layout kept after taking")
        check(SessionStore.takeRestore(from: file) == nil, "second launch → normal start")
        SessionStore.save(SessionSnapshot(windows: [SessionSnapshot.Window(panes: [])], restoreOnce: true), to: file)
        check(SessionStore.takeRestore(from: file) == nil, "marked but empty → normal start")
        try Data("{kaputt".utf8).write(to: file)
        check(SessionStore.takeRestore(from: file) == nil, "corrupt file → normal start")

        // Fensterverteilung beim Start.
        let second = SessionSnapshot.Window(panes: [PaneSnapshot(kind: "terminal", args: ["cwd": "/tmp"])])
        var queue = RestoreQueue([window, second])
        check(queue.claim() == window && !queue.isEmpty, "first window claims first plan")
        check(queue.drain() == [second] && queue.isEmpty && queue.claim() == nil, "leftovers drained once")

        // Tab-Leisten (22.09.): Felder optional, Reihenfolge je Leiste, eigene Fenster je Leiste.
        let tabbed = SessionSnapshot.Window(panes: [PaneSnapshot(kind: "home")], tabGroup: 1, selected: true)
        check(try JSONDecoder().decode(SessionSnapshot.Window.self, from: JSONEncoder().encode(tabbed)) == tabbed,
              "tab fields round trip")
        check(v2NoFlag.windows[0].tabGroup == nil && v2NoFlag.windows[0].selected == nil, "old snapshot has no tab fields")
        // Fenster 0 und 2 teilen eine Leiste (angezeigt: 2 vor 0), 1 steht allein, 3 meldet Unsinn.
        let order = SessionSnapshot.tabOrder(count: 4) { i in
            switch i { case 0, 2: return [2, 0]; case 3: return [7]; default: return nil }
        }
        check(order.map(\.index) == [2, 0, 1, 3] && order.map(\.group) == [0, 0, 1, 2],
              "tabs stay together in shown order, groups by first window")
        let a = SessionSnapshot.Window(panes: [PaneSnapshot(kind: "home")], tabGroup: 0)
        let b = SessionSnapshot.Window(panes: [PaneSnapshot(kind: "terminal")], tabGroup: 0)
        let c = SessionSnapshot.Window(panes: [PaneSnapshot(kind: "home")], tabGroup: 1)
        var tabs = RestoreQueue([a, b, c])
        check(tabs.count == 3, "queue counts plans")
        check(tabs.claimTab()?.ownWindow == false, "first window is never moved")
        check(tabs.claimTab()?.ownWindow == false, "same group → tab next to it")
        check(tabs.claimTab()?.ownWindow == true, "new group → own window")
        var legacy = RestoreQueue([window, second])
        check(legacy.claimTab()?.ownWindow == false && legacy.claimTab()?.ownWindow == false,
              "old snapshots become tabs of one bar")

        // Neustart-Helfer: wartet auf das Prozessende, dann erst der Befehl.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.8"]
        try sleeper.run()
        let marker = directory.appendingPathComponent("reopened marker")
        try AppRelaunch.run(after: sleeper.processIdentifier, command: ["/usr/bin/touch", marker.path])
        Thread.sleep(forTimeInterval: 0.4)
        check(!FileManager.default.fileExists(atPath: marker.path), "helper waits while the app still runs")
        sleeper.waitUntilExit()
        let end = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker.path) && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        check(FileManager.default.fileExists(atPath: marker.path), "helper reopens after the app is gone")

        print("\(cases) session snapshot / restore / relaunch cases passed")
    }
}
