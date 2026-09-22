import Foundation

@main
struct AgentSessionTests {
    static func main() {
        var session = AgentSession()
        func send(_ state: String, _ agent: String? = "codex", _ id: String? = "thread-a", _ turn: String? = nil, start: Bool = false) -> Bool {
            session.accept(state: state, agent: agent, sessionID: id, turnID: turn, startsTurn: start)
        }
        assert(send("working", nil, nil))
        assert(session.identity == nil)
        assert(!send("garbage"))
        assert(!send("ready", "unknown"))
        assert(!send("ready", "codex", "bad;id"))
        assert(!send("ready", "codex", ""))
        assert(send("ready"))
        assert(session.identity == .init(agent: "codex", sessionID: "thread-a"))
        assert(!send("working", nil, nil))
        assert(!send("done", "claude", "thread-a"))
        assert(send("working", "codex", "thread-a", "turn-1", start: true))
        assert(send("input", "codex", "thread-a", "turn-1"))
        assert(send("done", "codex", "thread-a", "turn-1"))
        assert(send("working", "codex", "thread-a", "turn-2", start: true))
        assert(!send("done", "codex", "thread-a", "turn-1"))
        assert(!send("working", "codex", "thread-a", "turn-1"))
        assert(send("ready", "claude", "thread-b"))
        assert(session.turnID == nil && session.identity?.name == "Claude")
        assert(!send("closed"))
        assert(send("closed", "claude", "thread-b"))
        assert(session.identity == nil)
        assert(!send("closed", "claude", "thread-b"))
        assert(send("working", "codex", "thread-c", "turn-3", start: true))
        session.clear()
        assert(session.identity == nil && session.turnID == nil)
        print("24 agent identity / stale session / turn cases passed")
    }
}
