import Foundation

// Aufträge in der Myzel-Kachel, reine Logik (Foundation-only, getestet in scripts/test-myzel-jobs.swift):
// wer darf was (PROTOKOLL §5.1), Entwurf senden (§6.1, §7), Umfang beim Zulassen (§8, lokal).

enum MyzelJobAction: String, Equatable {
    case approve, reject, start, restart, review, cancel

    var label: String {
        switch self {
        case .approve: return "Zulassen …"
        case .reject: return "Ablehnen"
        case .start: return "Starten"
        case .restart: return "Neu starten"
        case .review: return "Entwurf prüfen"
        case .cancel: return "Abbrechen"
        }
    }

    /// Knöpfe für `me` an diesem Auftrag, wie die Web-Seite (`auftragZeile`).
    static func available(for job: MyzelJob, me: String) -> [MyzelJobAction] {
        guard !job.status.isEnd else { return [] }
        var list: [MyzelJobAction] = []
        if job.besitzer == me {
            switch job.status {
            case .wartet: list += [.approve, .reject]
            case .zugelassen: list.append(.start)
            case .laeuft: list.append(.restart)
            case .bereit: list.append(.review)
            default: break
            }
        }
        if job.besitzer == me || job.ausloeser == me { list.append(.cancel) }
        return list
    }
}

/// `GET /auftrag/<id>/entwurf`
struct MyzelDraft: Codable, Equatable {
    let auftrag: String
    let status: String
    let text: String
    let anhaenge: [MyzelAttachment]?
    let version: String

    var attachments: [MyzelAttachment] { anhaenge ?? [] }
    /// Große Anhänge (> 2 MB), die einzeln geöffnet und bestätigt werden müssen.
    var needsConfirmation: [MyzelAttachment] { attachments.filter { $0.pruefen == true } }

    /// Was noch fehlt, bevor gesendet werden darf (§10.2); leer = darf.
    func missing(confirmed: Set<String>) -> [MyzelAttachment] {
        needsConfirmation.filter { !confirmed.contains($0.id) }
    }

    /// Körper für `POST /auftrag/<id>/senden`: immer die gesehene `version`, Text nur wenn geändert, Bestätigungen
    /// nur für Anhänge, die sie brauchen.
    func sendBody(editedText: String, confirmed: Set<String>) -> [String: Any] {
        var body: [String: Any] = ["version": version]
        if editedText != text { body["text"] = editedText }
        let ids = needsConfirmation.map(\.id).filter(confirmed.contains)
        if !ids.isEmpty { body["bestaetigt"] = ids }
        return body
    }
}

/// `POST /auftrag/<id>/starten`
struct MyzelStartReply: Codable, Equatable {
    let auftrag: String
    let token: String

    /// Auftrags-Token: `mza_` + 64 Hex (PROTOKOLL §6.2).
    var tokenLooksValid: Bool { token.count == 68 && token.hasPrefix("mza_") && token.dropFirst(4).allSatisfy(\.isHexDigit) }
}

/// Was ein fremder Agent sehen darf — gewählt beim Zulassen, gilt nur lokal (wird zur Lese-Freigabe der Sandbox).
enum MyzelScope: Codable, Equatable {
    case chat
    case project(name: String, path: String)
    case free

    var label: String {
        switch self {
        case .chat: return "nur Chat"
        case .project(let name, _): return "Projekt \(name)"
        case .free: return "frei (alles außer Sperrliste)"
        }
    }
}

/// Umfang je Auftrag, als kleine JSON-Datei neben den Auftragsordnern (überlebt einen Neustart der App).
struct MyzelScopeStore {
    let path: String
    private(set) var scopes: [String: MyzelScope] = [:]

    init(path: String) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode([String: MyzelScope].self, from: data) {
            scopes = decoded
        }
    }

    subscript(job: String) -> MyzelScope? { scopes[job] }

    mutating func set(_ scope: MyzelScope, for job: String) throws {
        scopes[job] = scope
        try save()
    }

    /// Endzustände vergessen (Auftrag ist durch).
    mutating func prune(keeping jobs: Set<String>) throws {
        let before = scopes.count
        scopes = scopes.filter { jobs.contains($0.key) }
        if scopes.count != before { try save() }
    }

    private func save() throws {
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(scopes)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
