import Foundation
import SwiftUI

/// Vertrag mit der Datenschicht (`projekte widget`, claude-werkstatt). Die Extension läuft
/// sandboxed und liest nur diesen fertigen Schnappschuss — keine Pfade, keine Befehle, Farben
/// kommen als Hex, Zeiten als fertige Kurztexte. Fehlt die Datei, zeigt das Widget den Hinweis
/// „LatexTerm einmal starten" (die App schreibt den Schnappschuss beim Start und alle 5 min).
struct WidgetSnapshot: Decodable {
    struct Ring: Decodable, Identifiable {
        var label: String
        var percent: Int
        var color: String
        var resetsIn: String?
        var stale: Bool?
        var id: String { label }
    }
    struct Due: Decodable, Identifiable {
        var title: String
        var kind: String          // wiedervorlage | erinnerung
        var daysLeft: Int
        var overdue: Bool
        var when: String
        var url: String?
        var id: String { kind + "|" + title + "|" + String(daysLeft) }
    }
    struct Bar: Decodable, Identifiable {
        var date: String
        var sessions: Int
        var id: String { date }
    }
    struct Stats: Decodable {
        var sessionsToday: Int
        var activeToday: Int?
        var repliesToday: Int
        var toolsToday: Int
        var tokensToday: Int
        var topModelToday: String?
        var streakDays: Int
        var favoriteHour: Int?
        var activeDays: Int
        var sessionsTotal: Int
        var promptsTotal: Int
        var since: String?
        var bars: [Bar]
    }
    var generatedAt: String
    var generatedLabel: String?
    var rings: [Ring]
    var codexRings: [Ring]?
    var due: [Due]
    var stats: Stats

    /// Beispiel für Galerie und Platzhalter — bewusst generische Inhalte.
    static let sample = WidgetSnapshot(
        generatedAt: "2026-09-11T15:58:00", generatedLabel: "15:58",
        rings: [Ring(label: "5h", percent: 42, color: "#ffaf00", resetsIn: "2h21m", stale: false),
                Ring(label: "7d", percent: 18, color: "#d75fff", resetsIn: "5d4h", stale: false),
                Ring(label: "Fable", percent: 27, color: "#ff5faf", resetsIn: "5d4h", stale: false)],
        codexRings: [],
        due: [Due(title: "Wiedervorlage: Vorgang abschließen", kind: "wiedervorlage", daysLeft: -1, overdue: true, when: "1 d über", url: nil),
              Due(title: "Formular einreichen", kind: "erinnerung", daysLeft: 0, overdue: false, when: "heute", url: nil),
              Due(title: "Termin bestätigen", kind: "erinnerung", daysLeft: 1, overdue: false, when: "morgen", url: nil),
              Due(title: "Erinnerungen durchgehen", kind: "erinnerung", daysLeft: 2, overdue: false, when: "So", url: nil)],
        stats: Stats(sessionsToday: 7, activeToday: 9, repliesToday: 812, toolsToday: 430, tokensToday: 312_000_000,
                     topModelToday: "Fable 5.1", streakDays: 12, favoriteHour: 22, activeDays: 131,
                     sessionsTotal: 967, promptsTotal: 6205, since: "2025-12-31",
                     bars: (0..<28).map { Bar(date: "d\($0)", sessions: [2, 5, 3, 0, 6, 8, 4, 1, 3, 7, 5, 2, 0, 4, 6, 9, 3, 2, 5, 7, 1, 0, 4, 6, 8, 3, 4, 7][$0]) }))
}

enum SnapshotStore {
    /// App-Group von LatexTerm (Team-ID-Präfix ist auf macOS Pflicht).
    static let groupID = "74U49TS6SR.com.mats.LatexTerm"
    static let fileName = "widget-snapshot.json"

    static var candidates: [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        if let g = fm.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            urls.append(g.appendingPathComponent(fileName))
        }
        if let s = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(s.appendingPathComponent("LatexTermWidgets").appendingPathComponent(fileName))
        }
        return urls
    }

    static func load() -> WidgetSnapshot? {
        for url in candidates {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) { return snap }
        }
        return nil
    }
}

extension Color {
    /// "#rrggbb" → Color; ungültig → Grau.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .gray; return }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

enum Fmt {
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.groupingSeparator = "."; f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
    /// 494668445 → „495 M", 12345 → „12 k"
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1f Mrd", Double(n) / 1e9) }
        if n >= 1_000_000 { return "\(Int((Double(n) / 1e6).rounded())) M" }
        if n >= 1_000 { return "\(Int((Double(n) / 1e3).rounded())) k" }
        return String(n)
    }
    /// "2025-12-31" → „Dez 25"
    static func monthYear(_ iso: String?) -> String? {
        guard let iso, iso.count >= 7, let m = Int(iso.dropFirst(5).prefix(2)) else { return nil }
        let names = ["Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez"]
        guard (1...12).contains(m) else { return nil }
        return "\(names[m - 1]) \(iso.dropFirst(2).prefix(2))"
    }
}
