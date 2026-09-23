import Foundation

/// Inhalt einer macOS-Benachrichtigung, wie ihn eine Kachel formuliert: Titel = was passiert ist
/// („Claude ist fertig“), Untertitel = wo („claude-werkstatt · 1:24“), Text = worum es geht (erster Satz
/// der Antwort, die Frage). Die Teile kommen aus untrusted Programm-Output — `cleaned` macht daraus
/// kurzen Klartext ohne Markdown, Code oder Steuerzeichen; der Notifier wendet es vor dem Posten an.
struct AttentionNote: Equatable {
    var title: String
    var subtitle: String?
    var body: String?

    static let titleLimit = 60
    static let subtitleLimit = 60
    static let bodyLimit = 150

    var cleaned: AttentionNote {
        AttentionNote(title: Self.summary(title, max: Self.titleLimit) ?? title,
                      subtitle: Self.summary(subtitle, max: Self.subtitleLimit),
                      body: Self.summary(body, max: Self.bodyLimit))
    }

    // MARK: - Klartext

    /// Markdown und Code raus, eine Zeile: Codeblöcke fallen weg, Links behalten ihren Text,
    /// Hervorhebungen und Backticks verschwinden, Listen-/Überschrift-Zeichen am Zeilenanfang auch.
    static func plain(_ text: String) -> String {
        var s = text
        s = replace(s, #"```[\s\S]*?(```|$)"#, " ")                 // Codeblöcke (auch abgeschnittene)
        s = replace(s, #"!?\[([^\]\n]*)\]\([^)\n]*\)"#, "$1")      // [Text](url), Bilder
        s = replace(s, #"(?m)^[ \t]*(#{1,6}|>|[-*+•]|\d{1,2}[.)])[ \t]+"#, "")
        s = replace(s, #"\*\*|~~|`"#, "")   // `__` bleibt: mcp__server__tool
        s = replace(s, #"(?<![\w*])\*(?=\S)([^*\n]+?)\*(?![\w*])"#, "$1")  // *kursiv*
        s = String(String.UnicodeScalarView(s.unicodeScalars.map {
            ($0.value < 0x20 || (0x7F...0x9F).contains($0.value)) ? " " : $0
        }))
        s = replace(s, #"\s+"#, " ")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Klartext, gekappt auf ganze Sätze (so viele, wie in `max` passen). Passt nicht einmal der
    /// erste, endet er am letzten Wort mit „…“. Ein Doppelpunkt am Ende kündigt eine Liste an, die
    /// fehlt — dann ebenfalls „…“. Leer → nil.
    static func summary(_ text: String?, max: Int) -> String? {
        guard let text else { return nil }
        let s = plain(text)
        guard !s.isEmpty else { return nil }
        var out = s
        if s.count > max {
            let head = String(s.prefix(max))
            if let end = lastSentenceEnd(in: head, full: s) {
                out = String(head[..<end])
            } else {
                let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? String(head.dropLast())
                out = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:–-(")) + "…"
            }
        }
        if out.hasSuffix(":") { out = String(out.dropLast()).trimmingCharacters(in: .whitespaces) + " …" }
        return out
    }

    /// Ende des letzten vollständigen Satzes in `head`: Satzzeichen, danach Leerzeichen und ein
    /// Großbuchstabe oder das Textende — „22.09. am“ oder „z. B. die“ zählen nicht.
    private static func lastSentenceEnd(in head: String, full: String) -> String.Index? {
        var best: String.Index?
        var i = head.startIndex
        while i < head.endIndex {
            let ch = head[i]
            let next = head.index(after: i)
            if ".!?…".contains(ch) {
                if next == full.endIndex {
                    best = next
                } else if next < full.endIndex, full[next] == " " {
                    let after = full.index(after: next)
                    if after < full.endIndex, full[after].isUppercase { best = next }
                }
            }
            i = next
        }
        return best
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    // MARK: - Agenten-Meldungen

    /// Claude Codes Notification-Texte sind englisch und oft redundant zum Titel: „waiting for your
    /// input“ sagt nichts Neues (→ nil), „needs your permission to use X“ wird deutsch und nennt das
    /// Werkzeug lesbar. Alles andere bleibt, wie es kam.
    static func agentMessage(_ message: String?) -> String? {
        guard let raw = message.map(plain), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("waiting for your input") { return nil }
        if let range = raw.range(of: #"permission to use (.+)$"#, options: .regularExpression) {
            let tool = String(raw[range]).replacingOccurrences(of: "permission to use ", with: "")
            return "Möchte \(toolName(tool)) verwenden – wartet auf Freigabe."
        }
        if raw.hasPrefix("Freigabe: ") {   // Codex-Hook
            return "Möchte \(toolName(String(raw.dropFirst(10)))) verwenden – wartet auf Freigabe."
        }
        if lower.contains("permission") || lower.contains("approval") { return "Wartet auf deine Freigabe." }
        return raw
    }

    /// `mcp__latexterm__open_web` → „open_web (latexterm)“; eingebaute Werkzeuge bleiben.
    static func toolName(_ tool: String) -> String {
        let parts = tool.trimmingCharacters(in: CharacterSet(charactersIn: " .")).components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return parts.joined(separator: "__") }
        return "\(parts[2...].joined(separator: "__")) (\(parts[1]))"
    }
}
