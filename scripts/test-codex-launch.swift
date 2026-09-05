import Foundation

@main
struct CodexLaunchTests {
    static func main() {
        typealias R = CodexLaunchReadiness
        assert(R.state(lines: ["│ model: loading │", "› Ask Codex to do anything", "? for shortcuts"]) == .starting)
        assert(R.state(lines: ["Starting MCP servers (esc to interrupt)", "› Ask Codex to do anything", "gpt-6-astra medium · ~/Documents"]) == .starting)
        assert(R.state(lines: ["› Ask Codex to do anything", "gpt-6-astra medium · ~/Documents"]) == .ready)
        assert(R.state(lines: ["›", "custom-model · /tmp/project"]) == .ready)
        assert(R.state(lines: ["Sign in with ChatGPT"]) == .interaction)
        assert(R.state(lines: ["Resume a previous session"]) == .interaction)
        assert(R.state(lines: ["zsh: command not found: codex"]) == .interaction)
        assert(R.state(lines: ["shell prompt >", "~/Documents"]) == .starting)
        print("8 Codex launch cases passed")
    }
}
