import Foundation
import CoreGraphics

// Kachel-Layout (23.09.2026) — reine Logik ohne AppKit: Geometrie, Automatik, Bearbeiten.
// Die Split-View hält den Zustand und setzt Frames; alles, was hier steht, ist deterministisch und
// wird von `scripts/test-pane-layout.swift` geprüft (u. a.: ohne Begleiter exakt das alte Raster).
// Bauplan: claude-werkstatt `plans/kachel-layout_2026-09-23.md`.

/// Wie eine Kachel am liebsten aussieht. Die Automatik bewertet damit Kandidaten; harte Grenzen
/// gibt es keine (ein zu kleines Fenster bekommt trotzdem ein Layout, nur ein schlechteres).
struct LayoutPreference: Equatable {
    /// Breite/Höhe, die der Inhalt am liebsten hätte (PDF-Seite ~0,71, Bild = sein Format); nil = egal.
    var aspect: Double?
    /// Darunter wird die Kachel unbrauchbar (Terminal: ~60 Spalten).
    var minWidth: Double
    var minHeight: Double
    /// Darunter wird es eng, aber geht (Terminal: 80 Spalten); nil = keine.
    var comfortWidth: Double?

    static let flexible = LayoutPreference(aspect: nil, minWidth: 240, minHeight: 160, comfortWidth: nil)
}

/// Eine Kachel aus Sicht der Automatik.
struct LayoutItem: Equatable {
    var id: String
    /// Kachel, neben der sie steht (Agent, der sie geöffnet hat); nil = eigenständig.
    var companionOf: String?
    var preference: LayoutPreference
}

/// Außenkanten einer Kachel (liegt am Fensterrand).
struct LayoutEdges: OptionSet, Equatable {
    let rawValue: Int
    static let top = LayoutEdges(rawValue: 1), bottom = LayoutEdges(rawValue: 2)
    static let left = LayoutEdges(rawValue: 4), right = LayoutEdges(rawValue: 8)
}

/// Platz einer Kachel: `rect` = ihr Anteil ohne Steg, `frame` = was die Hülle bekommt.
struct LayoutSlot: Equatable {
    var pane: String
    var rect: CGRect
    var frame: CGRect
    var outer: LayoutEdges
}

/// Trennlinie zwischen Kind `index` und `index + 1` der Teilung bei `path`.
struct LayoutDivider: Equatable {
    var path: [Int]
    var index: Int
    var axis: LayoutAxis
    /// Fläche des Stegs (Mausziel).
    var rect: CGRect
    /// Anfang und Ende der beiden Nachbarn entlang der Achse (ohne Steg) — der Zugbereich.
    var start: Double
    var end: Double
}

/// Abgelehnte Änderung, mit Grund für den Agenten.
struct LayoutRefusal: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Geometrie

enum LayoutGeometry {
    /// Plätze und Trennlinien für `root` in `bounds`. Kanten werden gerundet wie im alten Raster
    /// (`(size * anteil).rounded()` ab dem Ursprung), damit keine Lücken durch Rundung entstehen;
    /// innen bekommt jede Kachel einen halben Steg Abstand, am Fensterrand keinen.
    static func layout(_ root: LayoutNode, in bounds: CGRect, gap: CGFloat) -> (slots: [LayoutSlot], dividers: [LayoutDivider]) {
        var slots: [LayoutSlot] = []
        var dividers: [LayoutDivider] = []
        place(root, rect: bounds, path: [], bounds: bounds, gap: gap, slots: &slots, dividers: &dividers)
        return (slots, dividers)
    }

    private static func place(_ node: LayoutNode, rect: CGRect, path: [Int], bounds: CGRect, gap g: CGFloat,
                              slots: inout [LayoutSlot], dividers: inout [LayoutDivider]) {
        if let pane = node.pane {
            // Auf ganze Punkte: innen sind die Kanten schon gerundet, außen (Fenstermaß mit halben
            // Punkten) rundet das alte Raster genauso.
            let rect = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
                              width: rect.maxX.rounded() - rect.minX.rounded(),
                              height: rect.maxY.rounded() - rect.minY.rounded())
            var outer: LayoutEdges = []
            if rect.minY == bounds.minY.rounded() { outer.insert(.top) }
            if rect.maxY == bounds.maxY.rounded() { outer.insert(.bottom) }
            if rect.minX == bounds.minX.rounded() { outer.insert(.left) }
            if rect.maxX == bounds.maxX.rounded() { outer.insert(.right) }
            let left = rect.minX + (outer.contains(.left) ? 0 : g / 2)
            let right = rect.maxX - (outer.contains(.right) ? 0 : g / 2)
            let top = rect.minY + (outer.contains(.top) ? 0 : g / 2)
            let bottom = rect.maxY - (outer.contains(.bottom) ? 0 : g / 2)
            let frame = CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            slots.append(LayoutSlot(pane: pane, rect: rect, frame: frame, outer: outer))
            return
        }
        let axis = node.axis ?? .row
        let edges = boundaries(node, rect: rect)
        for (i, child) in node.children.enumerated() {
            let childRect: CGRect
            switch axis {
            case .row: childRect = CGRect(x: edges[i], y: rect.minY, width: edges[i + 1] - edges[i], height: rect.height)
            case .column: childRect = CGRect(x: rect.minX, y: edges[i], width: rect.width, height: edges[i + 1] - edges[i])
            }
            place(child, rect: childRect, path: path + [i], bounds: bounds, gap: g, slots: &slots, dividers: &dividers)
            guard i + 1 < node.children.count else { continue }
            let b = edges[i + 1]
            let hit: CGRect
            switch axis {
            case .row: hit = CGRect(x: b - g / 2, y: rect.minY, width: g, height: rect.height)
            case .column: hit = CGRect(x: rect.minX, y: b - g / 2, width: rect.width, height: g)
            }
            dividers.append(LayoutDivider(path: path, index: i, axis: axis, rect: hit,
                                          start: Double(edges[i]), end: Double(edges[i + 2])))
        }
    }

    /// Kanten der Kinder einer Teilung entlang ihrer Achse (Anzahl Kinder + 1 Werte).
    static func boundaries(_ node: LayoutNode, rect: CGRect) -> [CGFloat] {
        let axis = node.axis ?? .row
        let origin = axis == .row ? rect.minX : rect.minY
        let size = axis == .row ? rect.width : rect.height
        let total = node.children.reduce(0) { $0 + $1.weight }
        var edges: [CGFloat] = [origin]
        var cumulative = 0.0
        for child in node.children {
            cumulative += child.weight
            // Dieselbe Rechnung wie das alte Raster: (W * k) / c, dann runden.
            edges.append(origin + (size * CGFloat(cumulative) / CGFloat(total)).rounded())
        }
        return edges
    }

    /// Anteil (ohne Steg) einer Kachel.
    static func rect(of pane: String, in root: LayoutNode, bounds: CGRect) -> CGRect? {
        layout(root, in: bounds, gap: 0).slots.first { $0.pane == pane.uppercased() }?.rect
    }

    /// Anteil eines Teilbaums (Pfad) ohne Steg.
    static func rect(at path: [Int], in root: LayoutNode, bounds: CGRect) -> CGRect {
        var node = root, rect = bounds
        for index in path {
            let edges = boundaries(node, rect: rect)
            switch node.axis ?? .row {
            case .row: rect = CGRect(x: edges[index], y: rect.minY, width: edges[index + 1] - edges[index], height: rect.height)
            case .column: rect = CGRect(x: rect.minX, y: edges[index], width: rect.width, height: edges[index + 1] - edges[index])
            }
            node = node.children[index]
        }
        return rect
    }
}

// MARK: - Automatik

enum AutoLayout {
    /// Ziel-Seitenverhältnis einer Zelle im Raster ohne Begleiter — das alte Raster, unverändert.
    /// < 1 = leicht hochkant → mehr Spalten nebeneinander, bevor eine Reihe aufgemacht wird.
    static let idealCellAspect = 0.82

    /// Reihenzahl für `n` Zellen, deren Seitenverhältnis dem Ziel am nächsten kommt; bei Gleichstand
    /// weniger Reihen (breiter). Bewertet mit der vollen Spaltenzahl `ceil(n/rows)`.
    static func gridRows(for n: Int, width: Double, height: Double) -> Int {
        guard n > 1, width > 0, height > 0 else { return 1 }
        let targetLog = log(idealCellAspect)
        var bestRows = 1
        var bestScore = Double.greatestFiniteMagnitude
        for rows in 1...n {
            let cols = Int((Double(n) / Double(rows)).rounded(.up))
            let cellAspect = (width / Double(cols)) / (height / Double(rows))
            let score = abs(log(cellAspect) - targetLog)
            if score < bestScore - 1e-9 {
                bestScore = score
                bestRows = rows
            }
        }
        return bestRows
    }

    /// `n` Zellen top-heavy auf `rows` Reihen (obere Reihen kriegen die Extra-Zelle).
    static func rowCounts(n: Int, rows: Int) -> [Int] {
        let base = n / rows, rem = n % rows
        return (0..<rows).map { $0 < rem ? base + 1 : base }
    }

    /// Knoten als Raster: `rows` Reihen, innen nach ihrem Gewicht. Eine Reihe = nebeneinander.
    static func grid(_ nodes: [LayoutNode], rows: Int) -> LayoutNode? {
        guard !nodes.isEmpty else { return nil }
        if nodes.count == 1 { var only = nodes[0]; only.weight = 1; return only }
        let counts = rowCounts(n: nodes.count, rows: max(1, min(rows, nodes.count)))
        var rest = nodes[...]
        let lines: [LayoutNode] = counts.map { count in
            let line = Array(rest.prefix(count))
            rest = rest.dropFirst(count)
            if line.count == 1 { var only = line[0]; only.weight = 1; return only }
            return .split(.row, line)
        }
        return lines.count == 1 ? lines[0] : .split(.column, lines)
    }

    /// Wurzel-Kachel jeder Kachel: der Begleiter eines Begleiters gehört zu dessen Kachel. Ziele, die
    /// nicht (mehr) da sind, und Kreise machen eine Kachel eigenständig.
    static func anchors(of items: [LayoutItem]) -> [String: String] {
        let ids = Set(items.map { $0.id.uppercased() })
        let parent = Dictionary(items.map { ($0.id.uppercased(), $0.companionOf?.uppercased()) }, uniquingKeysWith: { a, _ in a })
        var result: [String: String] = [:]
        for item in items {
            let id = item.id.uppercased()
            var current = id
            var visited: Set<String> = [id]
            while let next = parent[current] ?? nil, ids.contains(next), next != current {
                guard visited.insert(next).inserted else { current = id; break }   // Kreis
                current = next
            }
            result[id] = current
        }
        return result
    }

    /// Automatische Anordnung. Ohne Begleiter exakt das alte Raster; mit Begleitern bekommt jede
    /// eigenständige Kachel ihre Begleiter als Nebenspalte rechts daneben („Block“), die Blöcke stehen
    /// nebeneinander, solange ihre Mindestbreiten passen, sonst im Raster.
    static func build(_ items: [LayoutItem], width: Double, height: Double, gap: Double) -> LayoutNode? {
        guard !items.isEmpty else { return nil }
        let anchorOf = anchors(of: items)
        let byID = Dictionary(items.map { ($0.id.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        var order: [String] = []
        var companions: [String: [String]] = [:]
        for item in items {
            let id = item.id.uppercased()
            let anchor = anchorOf[id] ?? id
            if anchor == id { order.append(id) } else { companions[anchor, default: []].append(id) }
        }
        let leaves = order.map { LayoutNode.leaf($0) }
        guard companions.values.contains(where: { !$0.isEmpty }) else {
            return grid(leaves, rows: gridRows(for: leaves.count, width: width, height: height))
        }

        struct Block { var anchor: String; var companions: [String]; var demand: Double }
        let blocks = order.map { Block(anchor: $0, companions: companions[$0] ?? [],
                                       demand: (companions[$0] ?? []).isEmpty ? 1 : 2) }
        func minWidth(_ b: Block) -> Double {
            let anchor = byID[b.anchor]?.preference.minWidth ?? 0
            guard !b.companions.isEmpty else { return anchor }
            return anchor + gap + (b.companions.map { byID[$0]?.preference.minWidth ?? 0 }.max() ?? 0)
        }
        func fits(rows: Int) -> Bool {
            let counts = rowCounts(n: blocks.count, rows: rows)
            var start = 0
            for count in counts {
                let line = blocks[start..<(start + count)]
                start += count
                let demand = line.reduce(0) { $0 + $1.demand }
                for block in line where width * block.demand / demand - gap < minWidth(block) { return false }
            }
            return true
        }
        var rows = 1
        if !fits(rows: 1) {
            let preferred = gridRows(for: blocks.count, width: width, height: height)
            rows = (max(2, preferred)...max(2, blocks.count)).first(where: fits) ?? max(2, preferred)
            rows = min(rows, blocks.count)
        }

        let counts = rowCounts(n: blocks.count, rows: rows)
        var nodes: [LayoutNode] = []
        var start = 0
        for count in counts {
            let line = blocks[start..<(start + count)]
            start += count
            let demand = line.reduce(0) { $0 + $1.demand }
            for block in line {
                guard !block.companions.isEmpty else { nodes.append(.leaf(block.anchor, weight: block.demand)); continue }
                let blockWidth = width * block.demand / demand - (line.count > 1 ? gap : 0)
                let blockHeight = height / Double(rows) - (rows > 1 ? gap : 0)
                let choice = chooseSplit(anchor: byID[block.anchor]?.preference ?? .flexible,
                                         companions: block.companions.map { byID[$0]?.preference ?? .flexible },
                                         width: blockWidth, height: blockHeight, gap: gap)
                let column: LayoutNode = block.companions.count == 1
                    ? .leaf(block.companions[0], weight: choice.fraction)
                    : .split(.column, zip(block.companions, choice.heights).map { .leaf($0, weight: $1) },
                             weight: choice.fraction)
                nodes.append(.split(.row, [.leaf(block.anchor, weight: 1 - choice.fraction), column],
                                    weight: block.demand))
            }
        }
        return grid(nodes, rows: rows)?.normalized()
    }

    /// Breite der Nebenspalte (Anteil am Block) und Höhen der Begleiter darin: der Kandidat, bei dem
    /// die Begleiter ihrer Wunschform am nächsten kommen und niemand unter seine Mindestgröße fällt.
    /// Deterministisch: bei Gleichstand gewinnt der schmalere Anteil.
    static func chooseSplit(anchor: LayoutPreference, companions: [LayoutPreference],
                            width: Double, height: Double, gap: Double) -> (fraction: Double, heights: [Double]) {
        let k = companions.count
        let available = max(1, height - gap * Double(max(0, k - 1)))
        var best: (cost: Double, fraction: Double, heights: [Double])?
        var f = 0.25
        while f <= 0.65 + 1e-9 {
            defer { f += 0.025 }
            let columnWidth = width * f - gap / 2
            let anchorWidth = width * (1 - f) - gap / 2
            guard columnWidth > 0, anchorWidth > 0 else { continue }
            let wanted = companions.map { $0.aspect.map { columnWidth / $0 } }
            let known = wanted.compactMap { $0 }
            let fallback = known.isEmpty ? available / Double(k) : known.reduce(0, +) / Double(known.count)
            let ideal = wanted.map { $0 ?? fallback }
            let scale = available / ideal.reduce(0, +)
            let heights = ideal.map { $0 * scale }
            var cost = 0.25 * abs(f - 0.45)
            for (pref, h) in zip(companions, heights) {
                if let aspect = pref.aspect { cost += abs(log((columnWidth / h) / aspect)) }
                cost += deficit(columnWidth, pref.minWidth) / 50 + deficit(h, pref.minHeight) / 50
            }
            cost += deficit(anchorWidth, anchor.minWidth) / 50
            if let comfort = anchor.comfortWidth { cost += deficit(anchorWidth, comfort) / 400 }
            if best == nil || cost < best!.cost - 1e-9 { best = (cost, f, heights) }
        }
        guard let best else { return (0.45, Array(repeating: 1, count: k)) }
        return (best.fraction, best.heights)
    }

    private static func deficit(_ value: Double, _ minimum: Double) -> Double { max(0, minimum - value) }
}

// MARK: - Bearbeiten

enum LayoutEdit {
    /// Pfad (Kind-Indizes) zum Blatt einer Kachel.
    static func path(of pane: String, in root: LayoutNode) -> [Int]? {
        let id = pane.uppercased()
        if root.pane == id { return [] }
        for (i, child) in root.children.enumerated() {
            if let rest = path(of: id, in: child) { return [i] + rest }
        }
        return nil
    }

    static func node(at path: [Int], in root: LayoutNode) -> LayoutNode {
        path.reduce(root) { $0.children[$1] }
    }

    /// Gibt es den Pfad in diesem Baum (Trennlinie aus einem älteren Stand)?
    static func exists(_ path: [Int], in root: LayoutNode) -> Bool {
        var node = root
        for index in path {
            guard node.children.indices.contains(index) else { return false }
            node = node.children[index]
        }
        return true
    }

    static func replacing(at path: [Int], in root: LayoutNode, with replacement: LayoutNode) -> LayoutNode {
        guard let first = path.first else { return replacement }
        var copy = root
        copy.children[first] = replacing(at: Array(path.dropFirst()), in: root.children[first], with: replacement)
        return copy
    }

    /// Kleinster Teilbaum, der genau diese Kacheln enthält (nil, wenn keiner genau passt).
    static func subtree(exactly panes: Set<String>, in root: LayoutNode) -> [Int]? {
        let wanted = Set(panes.map { $0.uppercased() })
        guard !wanted.isEmpty else { return nil }
        func search(_ node: LayoutNode, _ path: [Int]) -> [Int]? {
            let ids = Set(node.paneIDs)
            guard wanted.isSubset(of: ids) else { return nil }
            for (i, child) in node.children.enumerated() {
                if let deeper = search(child, path + [i]) { return deeper }
            }
            return ids == wanted ? path : nil
        }
        return search(root, [])
    }

    /// Neue Kachel einsetzen, ohne den Rest umzuwerfen (angepasstes Layout).
    /// - Begleiter (`companionOf`): in die Nebenspalte ihrer Kachel; gibt es keine, entsteht sie rechts
    ///   neben der Kachel mit dem Anteil, den die Automatik wählen würde.
    /// - Eigenständig: teilt den Platz der fokussierten Kachel samt deren Nebenspalte (`focusBlock`)
    ///   entlang der längeren Seite; ohne Fokus den des ganzen Fensters.
    static func insert(_ pane: String, companionOf anchor: String?, anchorCompanions: Set<String>,
                       focusBlock: Set<String>, preference: LayoutPreference, anchorPreference: LayoutPreference,
                       into root: LayoutNode?, bounds: CGRect, gap: Double) -> LayoutNode {
        let id = pane.uppercased()
        guard let root else { return .leaf(id) }
        if root.paneIDs.contains(id) { return root }
        let companions = Set(anchorCompanions.map { $0.uppercased() })

        if let anchor, let anchorPath = path(of: anchor, in: root) {
            if let index = anchorPath.last {
                let parentPath = Array(anchorPath.dropLast())
                let parent = node(at: parentPath, in: root)
                if parent.axis == .row, index + 1 < parent.children.count {
                    let sibling = parent.children[index + 1]
                    let ids = sibling.paneIDs
                    if !ids.isEmpty, ids.allSatisfy(companions.contains) {
                        let grown: LayoutNode
                        if sibling.axis == .column {
                            var column = sibling
                            let average = column.children.reduce(0) { $0 + $1.weight } / Double(column.children.count)
                            column.children.append(.leaf(id, weight: average))
                            grown = column
                        } else {
                            var first = sibling
                            first.weight = 1
                            grown = .split(.column, [first, .leaf(id)], weight: sibling.weight)
                        }
                        let result = replacing(at: parentPath + [index + 1], in: root, with: grown)
                        return result.normalized() ?? result
                    }
                }
            }
            let leaf = node(at: anchorPath, in: root)
            let rect = LayoutGeometry.rect(at: anchorPath, in: root, bounds: bounds)
            let choice = AutoLayout.chooseSplit(anchor: anchorPreference, companions: [preference],
                                                width: Double(rect.width), height: Double(rect.height), gap: gap)
            let pair = LayoutNode.split(.row, [.leaf(leaf.pane ?? anchor, weight: 1 - choice.fraction),
                                               .leaf(id, weight: choice.fraction)], weight: leaf.weight)
            let result = replacing(at: anchorPath, in: root, with: pair)
            return result.normalized() ?? result
        }

        let targetPath = subtree(exactly: focusBlock, in: root) ?? []
        let target = node(at: targetPath, in: root)
        let rect = LayoutGeometry.rect(at: targetPath, in: root, bounds: bounds)
        var first = target
        first.weight = 1
        let pair = LayoutNode.split(rect.width >= rect.height ? .row : .column, [first, .leaf(id)], weight: target.weight)
        let result = replacing(at: targetPath, in: root, with: pair)
        return result.normalized() ?? result
    }

    /// Kachel herausnehmen; die Geschwister behalten ihr Verhältnis zueinander.
    static func remove(_ pane: String, from root: LayoutNode) -> LayoutNode? {
        let id = pane.uppercased()
        guard let target = path(of: id, in: root) else { return root }
        guard let last = target.last else { return nil }
        let parentPath = Array(target.dropLast())
        var parent = node(at: parentPath, in: root)
        parent.children.remove(at: last)
        return replacing(at: parentPath, in: root, with: parent).normalized()
    }

    /// Trennlinie auf `position` (Punkte entlang der Achse) gezogen. Die beiden Nachbarn teilen sich
    /// ihren gemeinsamen Anteil neu, keiner wird kleiner als `minimum`. Die Teilung gilt danach als
    /// von `actor` gesetzt.
    static func dragged(_ root: LayoutNode, divider: LayoutDivider, to position: Double,
                        minimum: Double, actor: LayoutActor) -> LayoutNode {
        let span = divider.end - divider.start
        guard span > 2 * minimum, exists(divider.path, in: root) else { return root }
        let p = min(max(position, divider.start + minimum), divider.end - minimum)
        var split = node(at: divider.path, in: root)
        guard divider.index + 1 < split.children.count else { return root }
        let combined = split.children[divider.index].weight + split.children[divider.index + 1].weight
        split.children[divider.index].weight = combined * (p - divider.start) / span
        split.children[divider.index + 1].weight = combined * (divider.end - p) / span
        split.setBy = actor
        return replacing(at: divider.path, in: root, with: split)
    }

    /// Doppelklick auf eine Trennlinie: beide Nachbarn gleich groß.
    static func equalized(_ root: LayoutNode, divider: LayoutDivider, actor: LayoutActor) -> LayoutNode {
        guard exists(divider.path, in: root) else { return root }
        var split = node(at: divider.path, in: root)
        guard divider.index + 1 < split.children.count else { return root }
        let half = (split.children[divider.index].weight + split.children[divider.index + 1].weight) / 2
        split.children[divider.index].weight = half
        split.children[divider.index + 1].weight = half
        split.setBy = actor
        return replacing(at: divider.path, in: root, with: split)
    }

    /// Anteil eines Kindes an seiner Teilung (0…1).
    static func share(at path: [Int], in root: LayoutNode) -> Double {
        guard let index = path.last else { return 1 }
        let parent = node(at: Array(path.dropLast()), in: root)
        let total = parent.children.reduce(0) { $0 + $1.weight }
        return total > 0 ? parent.children[index].weight / total : 1
    }
}

// MARK: - Absichten (Agenten)

/// Was ein Agent an der Anordnung ändern kann — Absichten, keine Pixel.
enum LayoutOp: Equatable {
    /// Kachel groß zeigen, der Rest wird schmal (kein Zoom: alles bleibt sichtbar).
    case big(String)
    case grow(String)
    case shrink(String)
    /// `b` neben bzw. unter `a` stellen.
    case beside(String, String)
    case below(String, String)
    case swap(String, String)

    /// Kacheln, die die Absicht bewegt (für die Rechteprüfung).
    var panes: [String] {
        switch self {
        case .big(let a), .grow(let a), .shrink(let a): return [a]
        case .beside(let a, let b), .below(let a, let b), .swap(let a, let b): return [a, b]
        }
    }
}

extension LayoutEdit {
    /// Absicht anwenden. Teilungen, deren Anteile Mats von Hand gesetzt hat, bleiben unangetastet —
    /// außer `overrideMats` (Mats hat den Agenten ausdrücklich darum gebeten).
    static func apply(_ op: LayoutOp, to root: LayoutNode, actor: LayoutActor, overrideMats: Bool) throws -> LayoutNode {
        func locate(_ pane: String) throws -> [Int] {
            guard let path = path(of: pane, in: root) else { throw LayoutRefusal("Kachel \(pane.prefix(8)) steht nicht in diesem Fenster.") }
            return path
        }
        func guardMats(_ split: LayoutNode) throws {
            if split.setBy == .mats, !overrideMats {
                throw LayoutRefusal("Diese Aufteilung hat Mats von Hand gesetzt — sie bleibt, bis er etwas anderes sagt (dann auf_auftrag: true).")
            }
        }
        /// Anteil des Kindes `index` auf `share` setzen, die Geschwister behalten ihr Verhältnis.
        func setShare(_ split: inout LayoutNode, _ index: Int, _ share: Double) {
            let total = split.children.reduce(0) { $0 + $1.weight }
            let others = total - split.children[index].weight
            let s = min(max(share, 0.08), 0.92)
            for i in split.children.indices where i != index {
                split.children[i].weight = others > 0 ? split.children[i].weight * total * (1 - s) / others
                                                      : total * (1 - s) / Double(split.children.count - 1)
            }
            split.children[index].weight = total * s
            split.setBy = actor
        }

        switch op {
        case .big(let pane):
            let leafPath = try locate(pane)
            guard !leafPath.isEmpty else { throw LayoutRefusal("Nur eine Kachel im Fenster — sie ist schon groß.") }
            var result = root
            for depth in stride(from: leafPath.count - 1, through: 0, by: -1) {
                let splitPath = Array(leafPath.prefix(depth))
                var split = node(at: splitPath, in: result)
                try guardMats(split)
                let index = leafPath[depth]
                let current = share(at: splitPath + [index], in: result)
                setShare(&split, index, max(current, 0.66))
                result = replacing(at: splitPath, in: result, with: split)
            }
            return result

        case .grow(let pane), .shrink(let pane):
            let leafPath = try locate(pane)
            guard let index = leafPath.last else { throw LayoutRefusal("Nur eine Kachel im Fenster.") }
            let splitPath = Array(leafPath.dropLast())
            var split = node(at: splitPath, in: root)
            try guardMats(split)
            let delta = { if case .grow = op { return 0.12 } else { return -0.12 } }()
            setShare(&split, index, share(at: leafPath, in: root) + delta)
            return replacing(at: splitPath, in: root, with: split)

        case .beside(let a, let b), .below(let a, let b):
            let idA = a.uppercased(), idB = b.uppercased()
            guard idA != idB else { throw LayoutRefusal("Zweimal dieselbe Kachel.") }
            _ = try locate(idA)
            let pathB = try locate(idB)
            if let _ = pathB.last { try guardMats(node(at: Array(pathB.dropLast()), in: root)) }
            guard let without = remove(idB, from: root), let pathA = path(of: idA, in: without) else { return root }
            var leafA = node(at: pathA, in: without)
            let weight = leafA.weight
            leafA.weight = 1
            let axis: LayoutAxis = { if case .beside = op { return .row } else { return .column } }()
            let pair = LayoutNode.split(axis, [leafA, .leaf(idB)], weight: weight, setBy: actor)
            let result = replacing(at: pathA, in: without, with: pair)
            return result.normalized() ?? result

        case .swap(let a, let b):
            let pathA = try locate(a), pathB = try locate(b)
            guard pathA != pathB else { throw LayoutRefusal("Zweimal dieselbe Kachel.") }
            var result = root
            var leafA = node(at: pathA, in: root), leafB = node(at: pathB, in: root)
            swap(&leafA.pane, &leafB.pane)
            result = replacing(at: pathA, in: result, with: leafA)
            result = replacing(at: pathB, in: result, with: leafB)
            return result
        }
    }
}
