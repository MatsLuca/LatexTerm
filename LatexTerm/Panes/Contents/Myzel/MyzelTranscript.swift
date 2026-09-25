import Foundation

/// Lesezugriffs-Protokoll am Entwurf: was der Agent angefasst hat, aus dem Claude-Code-Transkript seiner Session
/// (`~/.claude/projects/<ordner>/<session-id>.jsonl`). Nur lokal, nur für den Besitzer. Foundation-only, getestet in
/// scripts/test-myzel-transcript.swift.
enum MyzelTranscript {
    struct Access: Equatable {
        let tool: String
        /// Pfad, Muster oder Befehl — gekürzt.
        let target: String
        /// nil = Ergebnis fehlt (Session lief noch), true = abgelehnt/Fehler.
        var failed: Bool?
    }

    /// Transkript zur Session suchen (Ordnername leitet Claude Code aus dem Arbeitsordner ab — daher per Suche).
    static func file(sessionID: String, projectsFolder: String = NSHomeDirectory() + "/.claude/projects") -> String? {
        guard sessionID.allSatisfy({ $0.isHexDigit || $0 == "-" }), !sessionID.isEmpty else { return nil }
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(atPath: projectsFolder)) ?? [] {
            let path = projectsFolder + "/" + dir + "/" + sessionID + ".jsonl"
            if fm.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static func accesses(jsonl: String) -> [Access] {
        var list: [Access] = []
        var index: [String: Int] = [:]
        for line in jsonl.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for item in content {
                switch item["type"] as? String {
                case "tool_use":
                    guard let name = item["name"] as? String else { continue }
                    let input = item["input"] as? [String: Any] ?? [:]
                    if let id = item["id"] as? String { index[id] = list.count }
                    list.append(Access(tool: name, target: target(tool: name, input: input), failed: nil))
                case "tool_result":
                    guard let id = item["tool_use_id"] as? String, let i = index[id] else { continue }
                    list[i].failed = item["is_error"] as? Bool ?? false
                default:
                    continue
                }
            }
        }
        return list
    }

    static func target(tool: String, input: [String: Any]) -> String {
        func s(_ key: String) -> String? { input[key] as? String }
        let raw: String
        switch tool {
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": raw = s("file_path") ?? s("notebook_path") ?? ""
        case "Grep": raw = [s("pattern").map { "„\($0)“" }, s("path") ?? s("glob")].compactMap { $0 }.joined(separator: " in ")
        case "Glob": raw = [s("pattern"), s("path")].compactMap { $0 }.joined(separator: " in ")
        case "Bash": raw = s("command") ?? ""
        case "WebFetch": raw = s("url") ?? ""
        case "WebSearch": raw = s("query") ?? ""
        default:
            // MCP und Sonstiges: Schlüssel zeigen, keine Werte (Entwürfe, Base64-Anhänge).
            raw = input.keys.sorted().joined(separator: ", ")
        }
        let home = NSHomeDirectory()
        let short = raw.replacingOccurrences(of: home + "/", with: "~/").replacingOccurrences(of: "\n", with: " ⏎ ")
        return short.count > 160 ? String(short.prefix(159)) + "…" : short
    }

    /// Eine Zeile je Zugriff für die Anzeige: `✓ Read ~/pfad`, `✗ Bash cat …`.
    static func lines(_ accesses: [Access]) -> [String] {
        accesses.map { a in
            let mark = a.failed == nil ? "·" : (a.failed! ? "✗" : "✓")
            return "\(mark) \(a.tool)\(a.target.isEmpty ? "" : "  \(a.target)")"
        }
    }
}
