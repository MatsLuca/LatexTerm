import Foundation

/// „Neu starten“: ein losgelöster Helfer wartet, bis dieser Prozess wirklich weg ist, und öffnet
/// die App dann wieder. Vorher zu öffnen ginge nicht: LaunchServices aktivierte nur die alte
/// Instanz, und eine zweite übernähme den Steuer-Socket der ersten. Der Helfer ignoriert SIGHUP,
/// gibt nach 60 s auf (hängt das Beenden, bleibt nur die Marke im Snapshot stehen — das nächste
/// Öffnen von Hand stellt dann wieder her). Foundation-only, damit der Test ihn ohne App prüft.
enum AppRelaunch {
    static let script = """
        trap '' HUP
        pid=$1; shift
        i=0
        while /bin/kill -0 "$pid" 2>/dev/null; do
            i=$((i + 1)); [ "$i" -gt 600 ] && exit 1
            /bin/sleep 0.1
        done
        /bin/sleep 0.3
        exec "$@"
        """

    /// Startet den Helfer, der nach dem Ende von `pid` `command` ausführt (App: `/usr/bin/open <Bundle>`).
    static func run(after pid: pid_t, command: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "latexterm-relaunch", String(pid)] + command
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    static func reopen(_ app: URL) throws {
        try run(after: ProcessInfo.processInfo.processIdentifier, command: ["/usr/bin/open", app.path])
    }
}
