import Foundation

/// „Agent dazuholen“, reine Logik (Foundation-only, getestet in scripts/test-myzel-launch.swift): Auftragsordner
/// vorbereiten, Auftrags-Token in eine Datei statt auf die Kommandozeile, Startbefehl bauen.
///
/// Ablage unter `<state>` (= ~/Library/Application Support/LatexTerm/myzel):
/// - `auftraege/<auftrag>/` — Arbeitsordner der Session: CLAUDE.md (Agenten-CLAUDE.md + regeln.md zusammengeführt),
///   Kopie von zusammenfassung.md. Hier darf der Agent schreiben.
/// - `zugang/<auftrag>.mcp.json` (0600, Ordner 0700) — MCP-Konfiguration mit dem Auftrags-Token, außerhalb des
///   Arbeitsordners (ein Agent mit Lese-Sperre sieht sie nicht); wird beim Endzustand gelöscht.
struct MyzelLaunch: Equatable {
    let jobID: String
    let sessionID: String
    let jobFolder: String
    let mcpConfig: String
    let command: String

    struct Inputs {
        var jobID: String
        var token: String
        var server: URL
        var stateFolder: String
        var agentFolder: String
        /// Eigener Auftrag (Auslöser = Besitzer): normales Setup, darf die Zusammenfassung im Agenten-Ordner nachführen.
        var own: Bool
        var trigger: String
        /// Letzte id, die der Agent kennt (aus stand.json); nil = von vorn (`n: 20`).
        var after: String?
        /// Zusätzliche Argumente (Sandbox-Profil fremder Aufträge, Etappe 5).
        var extraArgs: [String] = []
        var sessionID = UUID().uuidString.lowercased()
    }

    /// Ordner und Dateien anlegen, Befehl bauen. Wirft mit Grund (fehlender Agenten-Ordner, Schreibfehler).
    static func prepare(_ input: Inputs, fileManager fm: FileManager = .default) throws -> MyzelLaunch {
        guard isSafeID(input.jobID) else { throw MyzelConfigError("Auftrags-id „\(input.jobID)“ unerwartet") }
        let agentClaude = input.agentFolder + "/CLAUDE.md"
        guard let base = fm.contents(atPath: agentClaude).map({ String(decoding: $0, as: UTF8.self) }) else {
            throw MyzelConfigError("Agenten-Ordner ohne CLAUDE.md: \(MyzelConfig.tilde(input.agentFolder))")
        }
        let rules = fm.contents(atPath: input.agentFolder + "/regeln.md").map { String(decoding: $0, as: UTF8.self) }

        let jobs = input.stateFolder + "/auftraege"
        let access = input.stateFolder + "/zugang"
        let folder = jobs + "/" + input.jobID
        for dir in [input.stateFolder, jobs, access, folder] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        }

        try write(mergedClaude(base: base, rules: rules, agentFolder: input.agentFolder), to: folder + "/CLAUDE.md", fm: fm)
        if let summary = fm.contents(atPath: input.agentFolder + "/zusammenfassung.md") {
            try? fm.removeItem(atPath: folder + "/zusammenfassung.md")
            try summary.write(to: URL(fileURLWithPath: folder + "/zusammenfassung.md"))
        }

        let mcpPath = access + "/" + input.jobID + ".mcp.json"
        let config: [String: Any] = ["mcpServers": ["myzel": [
            "type": "http", "url": input.server.absoluteString + "/mcp",
            "headers": ["Authorization": "Bearer " + input.token]]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
        fm.createFile(atPath: mcpPath, contents: nil, attributes: [.posixPermissions: 0o600])
        try data.write(to: URL(fileURLWithPath: mcpPath))
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mcpPath)

        var args = [prompt(input, jobFolder: folder), "--session-id", input.sessionID, "--mcp-config", mcpPath]
        if input.own { args += ["--add-dir", input.agentFolder] }
        args += input.extraArgs
        // Führendes Leerzeichen: zsh (HIST_IGNORE_SPACE) nimmt den Befehl nicht in den Verlauf.
        let command = " claude " + args.map { shellQuote($0) }.joined(separator: " ")
        return MyzelLaunch(jobID: input.jobID, sessionID: input.sessionID, jobFolder: folder, mcpConfig: mcpPath,
                           command: command)
    }

    /// Erster Auftrag an die Session. Der Prompt steht vor `--mcp-config` (die Option nimmt mehrere Werte).
    static func prompt(_ input: Inputs, jobFolder: String) -> String {
        var text = "Myzel-Auftrag \(input.jobID) (Auslöser: \(input.trigger)). Lies zusammenfassung.md hier im Ordner, "
            + "hol den Auftrag mit dem Werkzeug lesen"
        text += input.after.map { " (nach: \($0))" } ?? " (n: 20)"
        text += ", arbeite ihn nach den Regeln in CLAUDE.md ab und leg mit entwurf (fertig: true) eine Antwort an. "
            + "Senden kann nur dein Besitzer."
        if input.own {
            text += " Danach zusammenfassung.md und stand.json in \(input.agentFolder) nachführen (stand.json: "
                + "{\"nach\": \"<letzte gelesene id>\"})."
        } else {
            text += " Fremder Auftrag: nichts außerhalb dieses Ordners ändern."
        }
        return text
    }

    /// Agenten-CLAUDE.md mit eingesetzten Regeln (statt `@regeln.md`, das im Auftragsordner nicht auflöst).
    static func mergedClaude(base: String, rules: String?, agentFolder: String) -> String {
        let header = "<!-- Kopie aus \(MyzelConfig.tilde(agentFolder)) — dort ändern, nicht hier. -->\n\n"
        guard let rules else { return header + base }
        let lines = base.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) == "@regeln.md" ? rules : $0 }
        let merged = lines.joined(separator: "\n")
        return header + (merged.contains(rules) ? merged : merged + "\n\n" + rules)
    }

    /// Letzte bekannte id aus `stand.json` des Agenten-Ordners (`{"nach": "…"}`), leer = nil.
    static func lastSeen(agentFolder: String) -> String? {
        guard let data = FileManager.default.contents(atPath: agentFolder + "/stand.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let after = object["nach"] as? String, isSafeID(after) else { return nil }
        return after
    }

    /// Zugang (Token-Datei) eines beendeten Auftrags löschen.
    static func revoke(jobID: String, stateFolder: String) {
        guard isSafeID(jobID) else { return }
        try? FileManager.default.removeItem(atPath: stateFolder + "/zugang/" + jobID + ".mcp.json")
        try? FileManager.default.removeItem(atPath: stateFolder + "/zugang/" + jobID + ".settings.json")
    }

    /// Server-ids: Präfix + `_` + Crockford-ULID (PROTOKOLL §4) — nichts, was einen Pfad verlassen könnte.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 40 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty && s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_./:=@".contains($0)) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func write(_ text: String, to path: String, fm: FileManager) throws {
        try? fm.removeItem(atPath: path)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }
}
