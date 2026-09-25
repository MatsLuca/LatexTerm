import Foundation

// Myzel-Kachel, reine Logik (Foundation-only, getestet in scripts/test-myzel-model.swift): Ereignisse des Servers
// → Nachrichten, Aufträge, Namen. Vertrag: PROTOKOLL.md des Myzel-Repos (§4 Ereignisse, §5 Aufträge).

/// Anhang einer Nachricht oder eines Entwurfs. `pruefen` nur im Entwurf (> 2 MB, einzeln bestätigen).
struct MyzelAttachment: Codable, Equatable {
    let id: String
    let name: String
    let mime: String
    let bytes: Int64
    let sha256: String
    var pruefen: Bool?

    var isImage: Bool { mime.hasPrefix("image/") }
}

struct MyzelParticipant: Codable, Equatable {
    let id: String
    /// "mensch" | "agent"
    let art: String
    var besitzer: String?
    var name: String

    var isAgent: Bool { art == "agent" }
}

/// `GET /ich`
struct MyzelMe: Codable, Equatable {
    let id: String
    let teilnehmer: [MyzelParticipant]
    var tailscale: String?
}

/// Eine Zeile des Chats (§4). Leere Felder lässt der Server weg, deshalb alles außer dem Kopf optional.
struct MyzelEvent: Codable, Equatable {
    var v: Int?
    let id: String
    let ts: String
    let typ: String
    let von: String

    var text: String?
    var antwort_auf: String?
    var erwaehnt: [String]?
    var anhaenge: [MyzelAttachment]?
    var gesendet_von: String?

    var agent: String?
    var besitzer: String?
    var ausloeser: String?
    var nachricht: String?

    var auftrag: String?
    var status: String?
    var grund: String?

    var teilnehmer: String?
    var name: String?

    var date: Date? { MyzelTime.parse(ts) }
}

enum MyzelTime {
    /// RFC 3339 mit bis zu 9 Nachkommastellen (Go `RFC3339Nano`); ISO8601DateFormatter kann höchstens Millisekunden.
    static func parse(_ ts: String) -> Date? {
        var s = ts
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = s[s.index(after: dot)..<end]
            s.replaceSubrange(s.index(after: dot)..<end, with: String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

enum MyzelJobStatus: String, CaseIterable {
    case wartet = "wartet_auf_zulassen"
    case zugelassen
    case abgelehnt
    case laeuft
    case bereit = "entwurf_bereit"
    case gesendet
    case verworfen
    case fehlgeschlagen
    case abgebrochen

    var isEnd: Bool { [.abgelehnt, .gesendet, .verworfen, .fehlgeschlagen, .abgebrochen].contains(self) }
}

/// Ein Auftrag an einen Agenten (§5): entsteht mit dem `auftrag`-Ereignis, der letzte `status` gewinnt.
struct MyzelJob: Equatable {
    let id: String
    let agent: String
    let besitzer: String
    let ausloeser: String
    /// Auslösende Nachricht.
    let nachricht: String
    var status: MyzelJobStatus
    var grund: String?
    var updated: String

    /// Fremder Auftrag: jemand anderes als der Besitzer hat den Agenten angepingt.
    var isForeign: Bool { ausloeser != besitzer }
}

/// Der Chat, wie ihn die Kachel sieht. Ereignisse kommen genau einmal an (Dedupe per id), in Server-Reihenfolge.
struct MyzelChat {
    private(set) var messages: [MyzelEvent] = []
    private(set) var jobs: [String: MyzelJob] = [:]
    private(set) var names: [String: String] = [:]
    private(set) var participants: [MyzelParticipant] = []
    private(set) var lastID: String?
    private var seen: Set<String> = []
    private var messageIndex: [String: Int] = [:]
    private var jobsByMessage: [String: [String]] = [:]

    /// Teilnehmer aus `/ich`; Umbenennungen aus dem Verlauf (`name`-Ereignisse) bleiben erhalten.
    mutating func setParticipants(_ list: [MyzelParticipant]) {
        participants = list
        for p in list where names[p.id] == nil { names[p.id] = p.name }
    }

    /// Ein Ereignis übernehmen; false = schon gesehen oder unbekannter Typ (nur `lastID` rückt dann weiter).
    @discardableResult
    mutating func apply(_ event: MyzelEvent) -> Bool {
        guard seen.insert(event.id).inserted else { return false }
        lastID = event.id
        switch event.typ {
        case "nachricht":
            messageIndex[event.id] = messages.count
            messages.append(event)
        case "auftrag":
            guard let agent = event.agent, let besitzer = event.besitzer, let ausloeser = event.ausloeser,
                  let nachricht = event.nachricht,
                  let status = event.status.flatMap(MyzelJobStatus.init(rawValue:)) else { return false }
            jobs[event.id] = MyzelJob(id: event.id, agent: agent, besitzer: besitzer, ausloeser: ausloeser,
                                      nachricht: nachricht, status: status, grund: nil, updated: event.ts)
            jobsByMessage[nachricht, default: []].append(event.id)
        case "status":
            guard let jobID = event.auftrag, var job = jobs[jobID],
                  let status = event.status.flatMap(MyzelJobStatus.init(rawValue:)) else { return false }
            job.status = status
            job.grund = event.grund
            job.updated = event.ts
            jobs[jobID] = job
        case "name":
            guard let who = event.teilnehmer, let name = event.name else { return false }
            names[who] = name
        default:
            return false   // §4: unbekannte Typen überspringen
        }
        return true
    }

    func message(_ id: String) -> MyzelEvent? { messageIndex[id].map { messages[$0] } }

    /// Aufträge, die diese Nachricht ausgelöst hat (in Entstehungsreihenfolge).
    func jobs(forMessage id: String) -> [MyzelJob] { (jobsByMessage[id] ?? []).compactMap { jobs[$0] } }

    /// Was auf `me` wartet: fremde Aufträge zum Zulassen und fertige Entwürfe zum Prüfen, älteste zuerst.
    func waiting(for me: String) -> [MyzelJob] {
        jobs.values.filter { $0.besitzer == me && ($0.status == .wartet || $0.status == .bereit) }
            .sorted { $0.id < $1.id }
    }

    /// Laufende eigene Aufträge (zugelassen oder läuft) — für Chip und Brett-Schutz.
    func active(for me: String) -> [MyzelJob] {
        jobs.values.filter { $0.besitzer == me && [.zugelassen, .laeuft, .bereit].contains($0.status) }
            .sorted { $0.id < $1.id }
    }

    func displayName(_ id: String) -> String { names[id] ?? id }

    func participant(_ id: String) -> MyzelParticipant? { participants.first { $0.id == id } }
}

/// Status-Texte wie in der Web-Seite (`STATUS` in server/web/app.js).
enum MyzelStatusText {
    static func text(_ job: MyzelJob, chat: MyzelChat) -> String {
        let owner = chat.displayName(job.besitzer)
        switch job.status {
        case .wartet: return "wartet auf \(owner)"
        case .zugelassen: return "zugelassen"
        case .laeuft: return "läuft"
        case .bereit: return "Entwurf liegt bei \(owner)"
        case .gesendet: return "gesendet"
        case .abgelehnt: return "abgelehnt"
        case .verworfen: return "verworfen"
        case .abgebrochen: return job.grund == "verfallen" ? "abgebrochen (verfallen)" : "abgebrochen"
        case .fehlgeschlagen: return job.grund.map { "fehlgeschlagen (\($0))" } ?? "fehlgeschlagen"
        }
    }
}
