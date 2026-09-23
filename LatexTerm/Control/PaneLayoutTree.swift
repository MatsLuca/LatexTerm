import Foundation

// Kachel-Layout (23.09.2026) — Datenform, die App UND `latexterm`-CLI kennen (Foundation-only halten!).
// Die App rechnet damit Frames, speichert sie im Session-Snapshot und meldet sie über den Steuerkanal;
// der MCP-Server macht daraus das Lagebild für Agenten. Bauplan: claude-werkstatt
// `plans/kachel-layout_2026-09-23.md`.

/// Richtung einer Teilung.
enum LayoutAxis: String, Codable, Equatable {
    /// Kinder nebeneinander (links → rechts).
    case row
    /// Kinder übereinander (oben → unten).
    case column
}

/// Wer die Anteile einer Teilung zuletzt gesetzt hat. `mats` sperrt sie für Agenten.
enum LayoutActor: String, Codable, Equatable {
    case mats, agent
}

/// Knoten im Layout-Baum: Blatt (eine Kachel) oder Teilung mit Kindern. Ein Struct statt eines
/// rekursiven Enums, damit das JSON flach und nachsichtig lesbar bleibt (Snapshot von der Platte).
struct LayoutNode: Codable, Equatable {
    /// Blatt: Kachel-UUID (groß geschrieben). nil = Teilung.
    var pane: String?
    /// Teilung: Richtung. Blätter haben keine.
    var axis: LayoutAxis?
    var children: [LayoutNode]
    /// Anteil im Elternknoten, relativ zu den Geschwistern (nur das Verhältnis zählt).
    var weight: Double
    /// Teilung: wer die Anteile der Kinder zuletzt gesetzt hat; nil = Automatik.
    var setBy: LayoutActor?

    init(pane: String?, axis: LayoutAxis?, children: [LayoutNode], weight: Double, setBy: LayoutActor?) {
        self.pane = pane
        self.axis = axis
        self.children = children
        self.weight = weight
        self.setBy = setBy
    }

    static func leaf(_ id: String, weight: Double = 1) -> LayoutNode {
        LayoutNode(pane: id.uppercased(), axis: nil, children: [], weight: weight, setBy: nil)
    }

    static func split(_ axis: LayoutAxis, _ children: [LayoutNode], weight: Double = 1,
                      setBy: LayoutActor? = nil) -> LayoutNode {
        LayoutNode(pane: nil, axis: axis, children: children, weight: weight, setBy: setBy)
    }

    private enum CodingKeys: String, CodingKey { case pane, axis, children, weight, setBy }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pane = try c.decodeIfPresent(String.self, forKey: .pane)
        axis = try? c.decodeIfPresent(LayoutAxis.self, forKey: .axis)
        children = try c.decodeIfPresent([LayoutNode].self, forKey: .children) ?? []
        weight = (try? c.decodeIfPresent(Double.self, forKey: .weight)) ?? 1
        setBy = try? c.decodeIfPresent(LayoutActor.self, forKey: .setBy)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pane, forKey: .pane)
        try c.encodeIfPresent(axis, forKey: .axis)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
        try c.encode(weight, forKey: .weight)
        try c.encodeIfPresent(setBy, forKey: .setBy)
    }

    var isLeaf: Bool { pane != nil }

    /// Alle Kachel-IDs in Lesereihenfolge (links → rechts, oben → unten) — die eine Reihenfolge für
    /// Index, Titelleisten-Chips und Lagebild.
    var paneIDs: [String] {
        if let pane { return [pane] }
        return children.flatMap(\.paneIDs)
    }

    /// Kachel-IDs umschreiben (Wiederherstellen: alte → neue ID); Blätter ohne Ziel fallen weg.
    /// Danach `normalized()`, damit leere oder einkindrige Teilungen verschwinden.
    func mappingPanes(_ transform: (String) -> String?) -> LayoutNode? {
        if let pane {
            guard let mapped = transform(pane) else { return nil }
            var copy = self
            copy.pane = mapped.uppercased()
            return copy
        }
        var copy = self
        copy.children = children.compactMap { $0.mappingPanes(transform) }
        return copy.children.isEmpty ? nil : copy
    }

    /// Gesetzt von Mats irgendwo im Teilbaum?
    var containsMatsLock: Bool {
        setBy == .mats || children.contains { $0.containsMatsLock }
    }

    /// Bereinigt einen Baum, der von der Platte, aus dem Steuerkanal oder nach einer Änderung kommt:
    /// nur Kacheln aus `keeping` (nil = alle), jede höchstens einmal, Gewichte endlich und positiv,
    /// leere Teilungen weg, Teilungen mit einem Kind aufgelöst (das Kind erbt den Anteil). nil = nichts übrig.
    func normalized(keeping: Set<String>? = nil) -> LayoutNode? {
        var seen = Set<String>()
        return normalized(keeping: keeping?.reduce(into: Set<String>()) { $0.insert($1.uppercased()) }, seen: &seen)
    }

    private func normalized(keeping: Set<String>?, seen: inout Set<String>) -> LayoutNode? {
        let w = weight.isFinite && weight > 0 ? weight : 1
        if let pane {
            let id = pane.uppercased()
            guard !id.isEmpty, keeping?.contains(id) ?? true, seen.insert(id).inserted else { return nil }
            return .leaf(id, weight: w)
        }
        let axis = self.axis ?? .row
        // Gleich gerichtete Teilungen werden bewusst NICHT verschmolzen: eine Teilung in einer Teilung
        // ist ein Block (Session + Nebenspalte) — schließt eine Kachel darin, fällt ihr Platz an den
        // Block zurück statt an alle Nachbarn.
        let kids = children.compactMap { $0.normalized(keeping: keeping, seen: &seen) }
        guard !kids.isEmpty else { return nil }
        if kids.count == 1 {
            var only = kids[0]
            only.weight = w
            return only
        }
        return .split(axis, kids, weight: w, setBy: setBy)
    }
}

/// Anordnung eines Fensters, wie der Steuerkanal sie meldet (Capability `layout`).
struct LayoutReport: Codable, Equatable {
    /// Stand-Nummer: wächst mit jeder Änderung der Anordnung dieses Fensters (Kachel auf/zu, Trennlinie,
    /// Agent ordnet an, Automatik zurück). Wer umordnen will, schickt die zuletzt gelesene mit
    /// (`ControlRequest.layoutRevision`) — passt sie nicht mehr, lehnt die App ab: erst den Stand lesen.
    var revision: Int
    /// true = die Automatik ordnet an (nichts von Hand oder per Agent festgelegt).
    var automatic: Bool
    /// Aktueller Baum (auch im Automatik-Modus: so, wie er gerade berechnet ist).
    var root: LayoutNode?
    /// Fenster-Innenmaß in pt.
    var width: Double
    var height: Double
}
