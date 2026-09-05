import Foundation

/// Launch-only observation of Codex's TUI. This is not a live agent status API.
enum CodexLaunchReadiness {
    enum State: Equatable { case starting, ready, interaction }

    static func state(lines: [String]) -> State {
        let rows = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.suffix(12)
        let text = rows.joined(separator: "\n").lowercased()
        if text.contains("sign in") || text.contains("trust this") ||
            text.contains("resume a previous session") || text.contains("no sessions found") ||
            text.contains("command not found") {
            return .interaction
        }
        if text.contains("loading") || text.contains("starting mcp") || text.contains("to interrupt") {
            return .starting
        }
        let prompt = rows.contains { $0.hasPrefix("›") }
        // Real startup probe: the initial placeholder already has › and ? for shortcuts.
        // Wait for the resolved model/directory footer as well.
        let footer = rows.contains { $0.contains(" · ~/") || $0.contains(" · /") || $0.contains("context left") }
        return prompt && footer ? .ready : .starting
    }
}
