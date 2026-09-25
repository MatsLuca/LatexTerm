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

/// Knoten im Layout-Baum: Blatt (ein Platz) oder Teilung mit Kindern. Ein Struct statt eines
/// rekursiven Enums, damit das JSON flach und nachsichtig lesbar bleibt (Snapshot von der Platte).
///
/// Reiter (Stufe 2, 23.09.2026): ein Blatt kann mehrere Kacheln an einem Platz halten (`tabs`), sichtbar
/// ist genau eine (`pane`). Welche vorn liegt, entscheidet die Split-View (zuletzt gezeigt,
/// `withFront`); der Baum trägt es nur mit, damit Lagebild und Snapshot es kennen.
struct LayoutNode: Codable, Equatable {
    /// Blatt: Kachel-UUID (groß geschrieben), bei Reitern die vordere. nil = Teilung.
    var pane: String?
    /// Blatt mit Reitern: alle Kacheln des Platzes in Reiter-Reihenfolge (enthält `pane`), sonst leer.
    var tabs: [String] = []
    /// Teilung: Richtung. Blätter haben keine.
    var axis: LayoutAxis?
    var children: [LayoutNode]
    /// Anteil im Elternknoten, relativ zu den Geschwistern (nur das Verhältnis zählt).
    var weight: Double
    /// Teilung: wer die Anteile der Kinder zuletzt gesetzt hat; Platz mit Reitern: wer ihn zusammengestellt hat
    /// (Mats per Ziehen). nil = Automatik.
    var setBy: LayoutActor?
    /// Feste Größe in pt entlang der Achse des Elternknotens (Höhe in einer Spalte, Breite in einer Zeile) statt
    /// eines Anteils — für angedockte Leisten (25.09.2026). Die Geschwister teilen sich den Rest nach `weight`.
    var fixed: Double?

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

    /// Platz mit Reitern; `front` = die sichtbare (Default: die erste). Eine Kachel = normales Blatt (ohne `setBy`).
    static func group(_ ids: [String], front: String? = nil, weight: Double = 1, setBy: LayoutActor? = nil) -> LayoutNode {
        let members = ids.map { $0.uppercased() }
        let shown = front.map { $0.uppercased() }.flatMap { members.contains($0) ? $0 : nil } ?? members.first ?? ""
        var node = LayoutNode.leaf(shown, weight: weight)
        if members.count > 1 { node.tabs = members; node.setBy = setBy }
        return node
    }
    static func split(_ axis: LayoutAxis, _ children: [LayoutNode], weight: Double = 1,
                      setBy: LayoutActor? = nil) -> LayoutNode {
        LayoutNode(pane: nil, axis: axis, children: children, weight: weight, setBy: setBy)
    }

    private enum CodingKeys: String, CodingKey { case pane, tabs, axis, children, weight, setBy, fixed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pane = try c.decodeIfPresent(String.self, forKey: .pane)
        tabs = (try? c.decodeIfPresent([String].self, forKey: .tabs)) ?? []
        axis = try? c.decodeIfPresent(LayoutAxis.self, forKey: .axis)
        children = try c.decodeIfPresent([LayoutNode].self, forKey: .children) ?? []
        weight = (try? c.decodeIfPresent(Double.self, forKey: .weight)) ?? 1
        setBy = try? c.decodeIfPresent(LayoutActor.self, forKey: .setBy)
        fixed = (try? c.decodeIfPresent(Double.self, forKey: .fixed)).flatMap { $0 }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pane, forKey: .pane)
        if !tabs.isEmpty { try c.encode(tabs, forKey: .tabs) }
        try c.encodeIfPresent(axis, forKey: .axis)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
        try c.encode(weight, forKey: .weight)
        try c.encodeIfPresent(setBy, forKey: .setBy)
        try c.encodeIfPresent(fixed, forKey: .fixed)
    }

    var isLeaf: Bool { pane != nil }

    /// Kacheln dieses Blatts: die Reiter, sonst die eine; Teilung = leer.
    var members: [String] {
        guard let pane else { return [] }
        return tabs.count > 1 ? tabs : [pane]
    }

    /// Blatt mit mehr als einer Kachel?
    var isGroup: Bool { pane != nil && tabs.count > 1 }

    /// Alle Kachel-IDs in Lesereihenfolge (links → rechts, oben → unten, Reiter in ihrer Reihenfolge) —
    /// die eine Reihenfolge für Index, Titelleisten-Chips und Lagebild.
    var paneIDs: [String] {
        if pane != nil { return members }
        return children.flatMap(\.paneIDs)
    }

    /// Kacheln, die gerade verdeckt sind (hintere Reiter).
    var hiddenPaneIDs: [String] {
        if let pane { return members.filter { $0 != pane } }
        return children.flatMap(\.hiddenPaneIDs)
    }

    /// Je Reiter-Platz die vordere Kachel neu bestimmen: die mit dem höchsten Rang (zuletzt gezeigt);
    /// bei Gleichstand bleibt die bisherige vorn.
    func withFront(_ rank: (String) -> Int) -> LayoutNode {
        var copy = self
        if isGroup, let current = pane {
            copy.pane = members.reduce(current) { best, id in rank(id) > rank(best) ? id : best }
        } else if pane == nil {
            copy.children = children.map { $0.withFront(rank) }
        }
        return copy
    }

    /// Kachel-IDs umschreiben (Wiederherstellen: alte → neue ID); Blätter ohne Ziel fallen weg.
    /// Danach `normalized()`, damit leere oder einkindrige Teilungen verschwinden.
    func mappingPanes(_ transform: (String) -> String?) -> LayoutNode? {
        if let pane {
            let mapped = members.compactMap { transform($0)?.uppercased() }
            guard !mapped.isEmpty else { return nil }
            var leaf = LayoutNode.group(mapped, front: transform(pane), weight: weight, setBy: setBy)
            leaf.fixed = fixed
            return leaf
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

    private var validFixed: Double? { fixed.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }

    private func normalized(keeping: Set<String>?, seen: inout Set<String>) -> LayoutNode? {
        let w = weight.isFinite && weight > 0 ? weight : 1
        if let pane {
            // Reiter: nur behaltene, jede einmal. Fällt die vordere weg, rückt ihr rechter Nachbar vor
            // (sonst der linke) — die Split-View bestimmt danach ohnehin die zuletzt gezeigte.
            let all = members.map { $0.uppercased() }
            var kept: [String] = []
            for id in all where !id.isEmpty && (keeping?.contains(id) ?? true) && seen.insert(id).inserted { kept.append(id) }
            guard !kept.isEmpty else { return nil }
            let front = pane.uppercased()
            let shown = kept.contains(front) ? front
                : (all.firstIndex(of: front).flatMap { i in all[(i + 1)...].first(where: kept.contains) ?? all[..<i].last(where: kept.contains) }
                   ?? kept[0])
            var leaf = LayoutNode.group(kept, front: shown, weight: w, setBy: setBy)
            leaf.fixed = validFixed
            return leaf
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
            only.fixed = validFixed
            return only
        }
        var split = LayoutNode.split(axis, kids, weight: w, setBy: setBy)
        split.fixed = validFixed
        return split
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

/// Seite, an der eine Leiste an ihrer Kachel hängt.
enum LayoutDockEdge: String, Codable, Equatable {
    case top, bottom
}

/// Angedockte Leiste (25.09.2026): eine Kachel steht fest über oder unter einer anderen, genauso breit wie
/// deren Platz und mit fester Höhe — sie wandert mit, wo immer die Kachel steht. Die Automatik, Mats' Züge und
/// Agenten-Absichten ordnen ohne Leisten an; eingesetzt werden sie erst im gültigen Baum (`LayoutEdit.docked`).
struct LayoutDock: Codable, Equatable {
    /// Kachel, an der die Leiste hängt (UUID, groß).
    var anchor: String
    var edge: LayoutDockEdge
    /// Höhe in pt (ohne Steg).
    var height: Double

    static let defaultHeight = 84.0
    static let minHeight = 36.0
    static let maxHeight = 400.0

    init(anchor: String, edge: LayoutDockEdge, height: Double = LayoutDock.defaultHeight) {
        self.anchor = anchor.uppercased()
        self.edge = edge
        self.height = LayoutDock.clamp(height)
    }

    static func clamp(_ height: Double) -> Double {
        guard height.isFinite else { return defaultHeight }
        return min(max(height, minHeight), maxHeight)
    }

    /// Kurzform fürs Lagebild und den Steuerkanal: „unten 84“.
    var label: String { "\(edge == .bottom ? "unten" : "oben") \(Int(height.rounded()))" }
}

