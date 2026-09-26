import AppKit

/// Wie endet die App? (25.09.2026) LatexTerm verschwand dreimal ohne ⌘Q, jedes Mal um Schlaf/Zuklappen herum
/// (zuletzt 25.09. 04:35 in einem DarkWake), ohne Absturzbericht. Diese Spur macht das nächste Verschwinden
/// zum Beweisstück: `lifecycle.log` neben `session.json` hält Start, Schlaf/Aufwachen, Beenden samt Anlass und
/// Signale fest. Ein SIGKILL lässt sich nicht fangen — dann ist die letzte Zeile vor dem nächsten „Start“ der Hinweis.
///
/// Dazu zwei Schutzmaßnahmen:
/// - macOS darf die App nicht still beenden (automatic/sudden termination aus).
/// - SIGTERM/SIGHUP von außen sichern den Stand und lassen die Lauf-Marke stehen → der nächste Start stellt wieder her.
enum LifecycleWatch {
    private static var signalSources: [DispatchSourceSignal] = []
    private static let maxLogBytes: UInt64 = 256 * 1024
    /// Start dieses Prozesses (für `doctor`: Laufzeit, läuft der neueste Build?).
    private(set) static var startedAt = Date()

    static func start() {
        startedAt = Date()
        ProcessInfo.processInfo.disableAutomaticTermination("Terminal-Sitzungen laufen")
        ProcessInfo.processInfo.disableSuddenTermination()
        log("Start · pid \(getpid())")

        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "Schlaf"),
            (NSWorkspace.didWakeNotification, "Aufgewacht"),
            (NSWorkspace.screensDidSleepNotification, "Bildschirm aus"),
            (NSWorkspace.screensDidWakeNotification, "Bildschirm an"),
            (NSWorkspace.willPowerOffNotification, "Abmelden/Ausschalten angekündigt"),
        ]
        for (name, text) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in log(text) }
        }

        // Eigener (leerer) Handler statt SIG_IGN: ein ignoriertes Signal erbten die Shells der Kacheln über exec,
        // ein Handler fällt dort auf den Standard zurück. Die Dispatch-Quelle sieht das Signal trotzdem.
        // SIGPIPE nie tödlich: Schreiben in eine geschlossene Pipe/Socket (Kind-Prozess weg, Client aufgelegt) liefert
        // dann EPIPE. Standardaktion wäre stilles Beenden ohne Absturzbericht (25.09. 21:48, Neustart verlor die Bretter).
        signal(SIGPIPE) { _ in }
        for (number, name) in [(SIGTERM, "SIGTERM"), (SIGHUP, "SIGHUP")] {
            signal(number) { _ in }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                log("\(name) von außen — Stand gesichert, Marke bleibt (nächster Start stellt wieder her)")
                let snapshot = BoardHostView.sessionSnapshot(restoreOnce: false)
                SessionStore.save(snapshot)
                SessionStore.archive(snapshot, reason: "signal")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Anlass eines Beenden-Wunschs: nil = aus der App (⌘Q, Menü, letztes Fenster), sonst der Grund aus dem
    /// Quit-Apple-Event des Systems (Abmelden, Neustart, Ausschalten).
    static func systemQuitReason() -> String? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication),
              let why = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) else { return nil }
        switch why.enumCodeValue {
        case OSType(kAELogOut), OSType(kAEReallyLogOut): return "Abmelden"
        case OSType(kAEShowRestartDialog), OSType(kAERestart): return "Neustart"
        case OSType(kAEShowShutdownDialog), OSType(kAEShutDown): return "Ausschalten"
        default: return "System (\(why.enumCodeValue))"
        }
    }

    static func log(_ text: String) {
        guard let url = SessionStore.defaultURL?.deletingLastPathComponent().appendingPathComponent("lifecycle.log")
        else { return }
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = .current
        let data = Data("\(stamp.string(from: Date())) \(text)\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Kürzen: über 256 KB bleibt die jüngere Hälfte.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? UInt64, size > maxLogBytes,
           let old = try? Data(contentsOf: url) {
            try? old.suffix(Int(maxLogBytes / 2)).write(to: url, options: .atomic)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
