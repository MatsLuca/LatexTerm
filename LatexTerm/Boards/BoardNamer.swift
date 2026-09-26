import Foundation

/// KI-Namen für Bretter (26.09.2026, Plan `brett-namen_2026-09-26.md` in der Werkstatt). Von Mats gesetzte Namen
/// gewinnen immer; darunter liegt ein Name, den Sonnet aus den Kacheln des Bretts wählt — nur, solange Mats das Brett
/// ansieht, und erst nach `dwell` Sekunden Verweilen. Rein und ohne AppKit: wann ein Brett dran ist. Den Aufruf macht
/// `BoardNameRequest`, das Verweilen und den Punkt im Strich `BoardHostView` und `BoardStripView`.
struct BoardNaming: Equatable {
    /// Verweilen, bevor gefragt wird (Mats: „wenn ich zehn Sekunden drauf bin, arbeite ich gerade daran“).
    static let dwell: TimeInterval = 10
    /// Reife: so viele neue Turns seit dem letzten Blick, bevor wieder gefragt wird …
    static let matureTurns = 3
    /// … und mindestens so viel Abstand (neue Kachel ausgenommen).
    static let matureInterval: TimeInterval = 600

    /// Zuletzt gewählter KI-Name; nil = Anlauf (noch keiner).
    var name: String?
    /// Stand beim letzten Blick: fertige Turns aller Kacheln, Kachel-IDs.
    var checkedTurns = 0
    var checkedPanes: Set<String> = []
    var lastCheck: Date?

    /// Ist das Brett dran? `turns` = fertige Agenten-Turns seit App-Start, `panes` = Kachel-IDs, `hasSession` = eine
    /// Kachel trägt eine Agenten-Session (auch eine wiederhergestellte — die hat schon Verlauf).
    /// `working` = ein Agent arbeitet gerade (Turn läuft).
    /// Anlauf (kein Name): solange ein Agent arbeitet, immer wieder (Mats 26.09.: die erste Antwort dauert, der Prompt
    /// steht aber schon im Transkript) — sonst bei neuem Turn oder neuer Kachel; beim ersten Mal reicht eine Session.
    /// Reife: neue Kachel, oder ≥ `matureTurns` neue Turns und ≥ `matureInterval` seit dem letzten Blick.
    func isDue(turns: Int, panes: Set<String>, hasSession: Bool, working: Bool = false, now: Date) -> Bool {
        guard turns > 0 || hasSession else { return false }
        guard let lastCheck else { return true }
        let newPane = !panes.subtracting(checkedPanes).isEmpty
        if name == nil { return working || turns > checkedTurns || newPane }
        if newPane { return true }
        return turns - checkedTurns >= Self.matureTurns && now.timeIntervalSince(lastCheck) >= Self.matureInterval
    }

    /// Blick gemacht: Stand merken, Namen übernehmen (nil = „bleibt“).
    mutating func checked(turns: Int, panes: Set<String>, now: Date, newName: String?) {
        checkedTurns = turns
        checkedPanes = panes
        lastCheck = now
        if let newName, !newName.isEmpty { name = newName }
    }
}

/// Ein Aufruf von `projekte brettname` (Werkstatt, `launcher/brettname.py`): Anfrage auf stdin, Antwort
/// `{"keep": bool, "name": str}`. Fehler, Zeitlimit, kein Kontingent → nil, der alte Name bleibt.
enum BoardNameRequest {
    struct PaneInput: Encodable {
        var kind: String
        var cwd: String?
        var agent: String?
        var sessionID: String?
        var title: String?
    }
    struct Input: Encodable {
        var phase: String
        var current: String?
        var fallback: String
        var panes: [PaneInput]
    }
    private struct Output: Decodable { var keep: Bool; var name: String }

    /// Schalter (Rückweg): `defaults write <bundle> boardAutoNames -bool NO` — dann nur noch Ordnernamen.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "boardAutoNames") as? Bool ?? true }

    static func run(_ input: Input, completion: @escaping (String?) -> Void) {
        guard let payload = try? JSONEncoder().encode(input) else { completion(nil); return }
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "exec projekte brettname"]
            let stdin = Pipe(), stdout = Pipe()
            proc.standardInput = stdin; proc.standardOutput = stdout
            proc.standardError = FileHandle.nullDevice
            var name: String?
            do {
                try proc.run()
                let deadline = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
                try stdin.fileHandleForWriting.write(contentsOf: payload)
                try stdin.fileHandleForWriting.close()
                let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                deadline.cancel()
                if proc.terminationStatus == 0, let out = try? JSONDecoder().decode(Output.self, from: bytes), !out.keep {
                    let trimmed = out.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    name = trimmed.isEmpty ? nil : String(trimmed.prefix(32))
                }
            } catch {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.main.async { completion(name) }
        }
    }
}
