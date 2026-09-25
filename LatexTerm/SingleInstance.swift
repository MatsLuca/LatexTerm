import AppKit

/// Nur eine LatexTerm-Instanz (25.09.2026). LaunchServices dedupliziert über die Bundle-ID — aber nicht immer:
/// nach einem signierten Rebuild startete am 25.09. eine zweite Instanz neben der laufenden, hielt deren
/// Lauf-Marke für die Leiche eines Absturzes (stellte „wieder her“), ersetzte `control.sock` und räumte beim
/// Beenden die Marke weg — die laufende App war danach für CLI/MCP unerreichbar. Eine zweite Instanz holt deshalb
/// die erste nach vorn und beendet sich sofort per `exit` (nicht `terminate`: das schriebe Snapshot und Marke).
enum SingleInstance {
    /// Eine andere, noch laufende Instanz dieser App (gleiche Bundle-ID oder gleiches Programm).
    static func other() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        let bundleID = Bundle.main.bundleIdentifier
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.processIdentifier != me, !app.isTerminated else { return false }
            if let bundleID, app.bundleIdentifier == bundleID { return true }
            return exe != nil && app.executableURL?.resolvingSymlinksInPath() == exe
        }
    }

    /// Früh im Start aufrufen (vor Fenstern, Wiederherstellen, Steuerkanal).
    static func yieldIfRunning() {
        guard let first = other() else { return }
        LifecycleWatch.log("Zweite Instanz (pid \(getpid())) — pid \(first.processIdentifier) läuft schon, gebe ab")
        first.activate()
        exit(0)
    }
}
