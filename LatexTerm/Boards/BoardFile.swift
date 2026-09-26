import Foundation

/// Ein Brett als Datei (25.09.2026, Plan claude-werkstatt `plans/brett-ablegen_2026-09-25.md`): dieselbe Form wie ein
/// Eintrag im Session-Snapshot, aber an einem Ort, den der Nutzer wählt — meist `<projekt>/_brett/brett.json`.
/// Pfade unterhalb des Ordners der Datei stehen relativ („./…“), damit ein verschobener Projektordner mitkommt.
/// Steuerkanal `board-save` (Brett des Aufrufers → Datei) und `board-open` (Datei → neues Brett).
/// Foundation-only, damit Tests es ohne AppKit prüfen können.
struct BoardFile: Codable, Equatable {
    var format = BoardFile.formatName
    var version = 1
    /// ISO-8601, wann gesichert.
    var saved: String
    /// Anzeigename des Bretts beim Öffnen; nil = Name des Projektordners.
    var name: String?
    var board: SessionSnapshot.Window

    static let formatName = "latexterm-board"

    /// Argumente, die Pfade tragen können. `url` nur, wenn es ein Dateipfad ist (Web-Kacheln mit http bleiben).
    static let pathKeys: Set<String> = ["cwd", "file", "url"]

    init(saved: Date = Date(), name: String?, board: SessionSnapshot.Window) {
        self.saved = ISO8601DateFormatter().string(from: saved)
        self.name = name
        self.board = board
    }

    /// Brett für die Datei: Home-Kacheln fallen weg (entstehen von selbst), Fenster-Felder ebenso, Pfade relativ zu `base`.
    static func make(from window: SessionSnapshot.Window, name: String?, base: URL, now: Date = Date()) -> BoardFile {
        let entries = window.panes.enumerated().filter { $0.element.kind != "home" }
        var board = window
        board.panes = entries.map { entry in
            var pane = entry.element
            pane.args = relativized(pane.args, base: base)
            return pane
        }
        board.focused = window.focused.flatMap { f in entries.firstIndex { $0.offset == f } }
        board.zoomed = window.zoomed.flatMap { z in entries.firstIndex { $0.offset == z } }
        board.tabGroup = nil
        board.selected = nil
        board.name = nil
        board.home = nil
        let ids = Set(board.panes.compactMap { $0.id?.uppercased() })
        board.layout = window.layout?.normalized(keeping: ids)
        return BoardFile(saved: now, name: name, board: board)
    }

    /// Brett zum Öffnen: relative Pfade gegen `base` auflösen, Name setzen (Datei › Projektordner).
    func resolved(base: URL) -> SessionSnapshot.Window {
        var window = board
        window.panes = board.panes.map { pane in
            var pane = pane
            pane.args = Self.resolved(pane.args, base: base)
            return pane
        }
        window.name = name ?? Self.projectName(base: base)
        window.selected = nil
        window.tabGroup = nil
        return window
    }

    /// `…/Projekt/_brett` → „Projekt“, sonst der Ordnername selbst.
    static func projectName(base: URL) -> String {
        let folder = base.standardizedFileURL
        return folder.lastPathComponent.hasPrefix("_") ? folder.deletingLastPathComponent().lastPathComponent : folder.lastPathComponent
    }

    /// Relativ wird, was im Projekt liegt: unter `base`, oder — liegt die Datei in einem Sonderordner wie `_brett` —
    /// unter dessen Elternordner (dann „..“, „../…“). Alles andere bleibt absolut.
    static func relativized(_ args: [String: String], base: URL) -> [String: String] {
        let dir = base.standardizedFileURL.path
        let inSpecial = base.lastPathComponent.hasPrefix("_")
        let project = inSpecial ? base.standardizedFileURL.deletingLastPathComponent().path : dir
        var out = args
        for key in pathKeys {
            guard let value = args[key], value.hasPrefix("/") else { continue }
            let path = URL(fileURLWithPath: value).standardizedFileURL.path
            if path == dir { out[key] = "." }
            else if path.hasPrefix(dir + "/") { out[key] = "./" + path.dropFirst(dir.count + 1) }
            else if inSpecial, path == project { out[key] = ".." }
            else if inSpecial, path.hasPrefix(project + "/") { out[key] = "../" + path.dropFirst(project.count + 1) }
        }
        return out
    }

    static func resolved(_ args: [String: String], base: URL) -> [String: String] {
        var out = args
        for key in pathKeys {
            guard let value = args[key], value == "." || value == ".." || value.hasPrefix("./") || value.hasPrefix("../") else { continue }
            out[key] = URL(fileURLWithPath: value, relativeTo: base.standardizedFileURL).standardizedFileURL.path
        }
        return out
    }

    // MARK: Datei

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Absoluter Pfad auf .json, sonst Fehler mit Grund.
    static func url(_ raw: String?) throws -> URL {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw Failure("Pfad fehlt (…/_brett/brett.json)")
        }
        let path = (raw as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw Failure("Brett-Datei braucht einen absoluten Pfad, nicht „\(raw)“") }
        guard path.lowercased().hasSuffix(".json") else { throw Failure("Brett-Datei endet auf .json") }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Schreiben, zurücklesen, vergleichen — erst dann gilt das Brett als gesichert.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        guard (try? Self.read(url)) == self else { throw Failure("Zurücklesen von \(url.path) ergab nicht dasselbe Brett") }
    }

    static func read(_ url: URL) throws -> BoardFile {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw Failure("\(url.path) nicht lesbar") }
        let file: BoardFile
        do { file = try JSONDecoder().decode(BoardFile.self, from: data) } catch {
            throw Failure("\(url.path) ist keine Brett-Datei (\(error.localizedDescription))")
        }
        guard file.format == formatName else { throw Failure("\(url.path): Format „\(file.format)“ unbekannt") }
        guard file.version <= 1 else { throw Failure("\(url.path): Version \(file.version) ist neuer als diese App — LatexTerm aktualisieren") }
        return file
    }
}
