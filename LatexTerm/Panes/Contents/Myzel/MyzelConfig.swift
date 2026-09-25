import Foundation

/// Lokale Einstellungen der Myzel-Kachel. Liegen bewusst außerhalb des Repos (`~/.config/myzel/kachel.json`, 0600):
/// Server-Adresse, Ordner und Sperrliste sind privat. Foundation-only, getestet in scripts/test-myzel-model.swift.
///
/// ```json
/// { "server": "https://myzel.beispiel.ts.net",
///   "agent_ordner": "~/Pfad/zum/Agenten-Ordner",
///   "token_datei": "~/.config/myzel/token",          // optional, nur zum einmaligen Übernehmen in den Schlüsselbund
///   "projekte": { "Name": "~/Pfad" },                 // Umfang „Projekt X“ beim Zulassen
///   "sperrliste": ["~/.ssh", "~/.config"],            // fremde Agenten lesen hier nie
///   "lesende_werkzeuge": ["mcp__server__tool"] }      // MCP-Werkzeuge, die fremde Agenten nutzen dürfen
/// ```
struct MyzelConfig: Equatable {
    struct Project: Equatable {
        let name: String
        let path: String
    }

    let server: URL
    let agentFolder: String
    let tokenFile: String?
    let projects: [Project]
    let blocklist: [String]
    let readTools: [String]

    static var defaultPath: String { NSHomeDirectory() + "/.config/myzel/kachel.json" }

    /// Host für Anzeige, Schlüsselbund und Netz-Freigabe der Sandbox.
    var host: String { server.host ?? server.absoluteString }

    static func load(path: String = defaultPath) throws -> MyzelConfig {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw MyzelConfigError("Keine Einstellungen unter \(Self.tilde(path)) — Muster steht in MyzelConfig.swift.")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> MyzelConfig {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MyzelConfigError("kachel.json ist kein JSON-Objekt.")
        }
        let known: Set<String> = ["server", "agent_ordner", "token_datei", "projekte", "sperrliste", "lesende_werkzeuge"]
        let unknown = Set(object.keys).subtracting(known)
        guard unknown.isEmpty else {
            throw MyzelConfigError("kachel.json: unbekannte Schlüssel \(unknown.sorted().joined(separator: ", ")).")
        }
        guard let raw = object["server"] as? String, let server = URL(string: raw),
              server.scheme == "https", server.host != nil, server.path.isEmpty || server.path == "/" else {
            throw MyzelConfigError("kachel.json: \"server\" muss eine https-Adresse ohne Pfad sein.")
        }
        guard let agent = object["agent_ordner"] as? String, !agent.isEmpty else {
            throw MyzelConfigError("kachel.json: \"agent_ordner\" fehlt.")
        }
        let projects = (object["projekte"] as? [String: String] ?? [:])
            .map { Project(name: $0.key, path: expand($0.value)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return MyzelConfig(server: URL(string: "https://\(server.host!)" + (server.port.map { ":\($0)" } ?? ""))!,
                           agentFolder: expand(agent),
                           tokenFile: (object["token_datei"] as? String).map { expand($0) },
                           projects: projects,
                           blocklist: (object["sperrliste"] as? [String] ?? []).map { expand($0) },
                           readTools: object["lesende_werkzeuge"] as? [String] ?? [])
    }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct MyzelConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
