import Foundation
import Combine

/// Schalter für Claude Codes Statuszeile (mats-tools `statusline-command.sh`). Wahrheit ist die
/// Datei `~/.claude/statusline.conf` — nicht UserDefaults: das Skript liest sie bei jedem Rendern
/// (alle `refreshInterval` Sekunden), damit greift ein Umschalten in allen laufenden Sessions
/// binnen Sekunden. Fehlt die Datei, zeigt das Skript alles, zweizeilig — genau die Defaults hier.
final class StatuslineSettings: ObservableObject {
    static let shared = StatuslineSettings()
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/statusline.conf")

    /// Ein Segment = ein Schlüssel im Skript; Reihenfolge = Reihenfolge in der Zeile.
    enum Segment: String, CaseIterable, Identifiable {
        case dir, git, model, effort, timer, earn   // Zeile 1
        case ctx, limits, fable, cost, month         // Zeile 2
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dir: return "Verzeichnis"
            case .git: return "Git (Zweig, Diff, ↓)"
            case .model: return "Modell"
            case .effort: return "Effort-Stufe"
            case .timer: return "Session-Timer"
            case .earn: return "Kickbacks-Einnahmen"
            case .ctx: return "Kontextfenster"
            case .limits: return "5h/7d-Limits"
            case .fable: return "Fable-Wochenlimit"
            case .cost: return "Session-Kosten"
            case .month: return "Monatssumme"
            }
        }
        /// Der Schalter hängt an einem anderen (ohne Modell keine Effort-Stufe, ohne Kosten keine Summe).
        var parent: Segment? {
            switch self {
            case .effort: return .model
            case .month: return .cost
            default: return nil
            }
        }
        var line: Int { [.dir, .git, .model, .effort, .timer, .earn].contains(self) ? 1 : 2 }
    }

    enum Lines: Int, CaseIterable, Identifiable {
        case two = 2, one = 1
        var id: Int { rawValue }
        var label: String { self == .two ? "Zweizeilig" : "Einzeilig" }
    }

    @Published private(set) var enabled: [Segment: Bool] = Dictionary(uniqueKeysWithValues: Segment.allCases.map { ($0, true) })
    @Published var lines: Lines = .two { didSet { guard !loading else { return }; save() } }

    func isOn(_ s: Segment) -> Bool { enabled[s] ?? true }
    func set(_ s: Segment, on: Bool) {
        guard enabled[s] != on else { return }
        enabled[s] = on
        save()
    }
    var isDefault: Bool { lines == .two && Segment.allCases.allSatisfy { isOn($0) } }

    func reset() {
        loading = true
        for s in Segment.allCases { enabled[s] = true }
        lines = .two
        loading = false
        try? FileManager.default.removeItem(at: Self.fileURL)   // fehlend = Skript-Defaults
    }

    private var loading = false
    private init() { load() }

    /// Liest `key=0|1` je Zeile; unbekannte Schlüssel und Kommentare bleiben unberücksichtigt.
    func load() {
        loading = true
        defer { loading = false }
        for s in Segment.allCases { enabled[s] = true }
        lines = .two
        guard let text = try? String(contentsOf: Self.fileURL, encoding: .utf8) else { return }
        for raw in text.split(separator: "\n") {
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            if parts[0] == "lines", let n = Int(parts[1]), let l = Lines(rawValue: n) { lines = l; continue }
            if let s = Segment(rawValue: parts[0]) { enabled[s] = parts[1] != "0" }
        }
    }

    /// Schreibt die Datei komplett (auch die Einsen — lesbar, und das Skript ignoriert nichts).
    private func save() {
        var out = "# Claude-Code-Statuszeile — geschrieben von LatexTerm (⌘, → Statuszeile). 1 = an, 0 = aus.\n"
        for s in Segment.allCases { out += "\(s.rawValue)=\(isOn(s) ? 1 : 0)\n" }
        out += "lines=\(lines.rawValue)\n"
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? out.write(to: Self.fileURL, atomically: true, encoding: .utf8)
    }
}
