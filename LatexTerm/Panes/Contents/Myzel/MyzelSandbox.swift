import Foundation

/// Rechte eines Agenten bei einem **fremden** Auftrag (PROTOKOLL §8), als Claude-Code-Einstellungen für genau diese
/// Session (Foundation-only, getestet in scripts/test-myzel-sandbox.swift):
///
/// - schreiben nur im Auftragsordner (Werkzeuge: `Edit(…)`-Regel; Bash: Sandbox `allowWrite`),
/// - Netz nur zum Myzel-Server (Sandbox-Allowlist, `strictAllowlist`), kein WebFetch/WebSearch, kein Browser,
/// - lesen je Umfang: *nur Chat* / *Projekt* = nur die Arbeitsordner (`blockReadsOutsideWorkingDirectories`),
///   *frei* = alles außer der Sperrliste; die Sperrliste gilt immer, für Werkzeuge (`Read(…)`-Deny) und Bash
///   (`denyRead`), ebenso die Zugangsdateien anderer Aufträge,
/// - `dontAsk`: was nicht erlaubt ist, wird abgelehnt statt nachgefragt; Bypass und Auto-Modus gesperrt.
///
/// Die Sandbox von Claude Code gilt nur für Bash und dessen Kindprozesse; die eingebauten Werkzeuge regeln die
/// Permission-Regeln — deshalb steht jede Grenze doppelt.
enum MyzelSandbox {
    struct Inputs {
        var jobFolder: String
        var scope: MyzelScope
        var blocklist: [String]
        /// Ordner mit den Zugangsdateien aller Aufträge — immer gesperrt.
        var accessFolder: String
        var serverHost: String
        /// Zusätzliche MCP-Werkzeuge, die lesen dürfen (`mcp__server__tool`).
        var readTools: [String] = []
    }

    static let myzelTools = ["mcp__myzel__lesen", "mcp__myzel__entwurf", "mcp__myzel__anhang", "mcp__myzel__anhang_holen"]

    static func settings(_ input: Inputs) -> [String: Any] {
        let blocked = input.blocklist + [input.accessFolder]
        var allow = ["Read", "Grep", "Glob", "LS", "Bash", "Edit(\(rule(input.jobFolder))/**)"] + myzelTools + input.readTools
        allow = Array(NSOrderedSet(array: allow)) as? [String] ?? allow
        var deny = ["WebFetch", "WebSearch", "mcp__claude-in-chrome", "mcp__latexterm"]
        deny += blocked.flatMap { ["Read(\(rule($0))/**)", "Edit(\(rule($0))/**)"] }
        var denyWrite: [String] = []
        if case .project(_, let path) = input.scope {
            deny.append("Edit(\(rule(path))/**)")
            denyWrite.append(path)
        }
        var permissions: [String: Any] = [
            "defaultMode": "dontAsk",
            "disableBypassPermissionsMode": "disable",
            "disableAutoMode": "disable",
            "allow": allow,
            "deny": deny,
        ]
        if input.scope != .free { permissions["blockReadsOutsideWorkingDirectories"] = true }
        var filesystem: [String: Any] = ["allowWrite": [input.jobFolder], "denyRead": blocked]
        if !denyWrite.isEmpty { filesystem["denyWrite"] = denyWrite }
        return [
            "permissions": permissions,
            "sandbox": [
                "enabled": true,
                "failIfUnavailable": true,
                "autoAllowBashIfSandboxed": true,
                "allowUnsandboxedCommands": false,
                "filesystem": filesystem,
                "network": ["allowedDomains": [input.serverHost], "strictAllowlist": true,
                            "allowLocalBinding": false, "allowAllUnixSockets": false],
            ] as [String: Any],
        ]
    }

    /// Einstellungen als Datei (0600) neben der Zugangsdatei schreiben; Rückgabe: zusätzliche `claude`-Argumente.
    static func prepare(_ input: Inputs, jobID: String) throws -> [String] {
        guard MyzelLaunch.isSafeID(jobID) else { throw MyzelConfigError("Auftrags-id „\(jobID)“ unerwartet") }
        let path = input.accessFolder + "/" + jobID + ".settings.json"
        let data = try JSONSerialization.data(withJSONObject: settings(input), options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(atPath: input.accessFolder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        return args(settingsPath: path, scope: input.scope)
    }

    static func args(settingsPath: String, scope: MyzelScope) -> [String] {
        var args = ["--settings", settingsPath, "--strict-mcp-config", "--permission-mode", "dontAsk", "--no-chrome"]
        if case .project(_, let path) = scope { args += ["--add-dir", path] }
        return args
    }

    /// Absoluter Pfad als Regel-Pfad (`//abs/pfad`), ohne Schrägstrich am Ende.
    static func rule(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return "/" + p
    }
}
