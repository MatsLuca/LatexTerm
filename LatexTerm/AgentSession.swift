import Foundation

/// Explicit identities only: neither the working directory nor terminal text identifies a session.
struct AgentSession {
    struct Identity: Equatable {
        let agent: String
        let sessionID: String
        var name: String { agent == "codex" ? "Codex" : "Claude" }
    }
    private(set) var identity: Identity?
    private(set) var turnID: String?

    nonisolated static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// Reject late events from a replaced session/turn. A new root session announces itself
    /// with ready; an explicit turn start (t=0, n=0) can replace the previous turn.
    mutating func accept(state: String, agent: String?, sessionID: String?, turnID: String?, startsTurn: Bool) -> Bool {
        guard ["ready", "working", "input", "done", "closed"].contains(state) else { return false }
        guard agent != nil || sessionID != nil else {
            return identity == nil // legacy hooks cannot overwrite an identified agent
        }
        guard let agent, ["claude", "codex"].contains(agent), let sessionID, Self.validID(sessionID),
              turnID.map(Self.validID) ?? true else { return false }
        let incoming = Identity(agent: agent, sessionID: sessionID)
        if state == "ready" {
            if identity != incoming { self.turnID = nil }
            identity = incoming
            return true
        }
        guard identity == nil || identity == incoming else { return false }
        if let turnID, let current = self.turnID, current != turnID, !startsTurn { return false }
        if state == "closed" {
            guard identity == incoming else { return false }
            clear()
        } else {
            identity = incoming
            if let turnID { self.turnID = turnID }
        }
        return true
    }

    mutating func clear() { identity = nil; turnID = nil }
}
