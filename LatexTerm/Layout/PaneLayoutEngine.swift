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

/// Platz einer Kachel: `rect` = ihr Anteil ohne Steg, `frame` = was die Hülle bekommt (bei Reitern
/// unter der Reiterleiste). Hintere Reiter bekommen denselben Frame, bleiben aber verborgen — so hat
/// ihr Inhalt schon die richtige Größe, wenn sie nach vorn kommen (kein PTY-Resize beim Umschalten).
struct LayoutSlot: Equatable {
    var pane: String
    var rect: CGRect
    var frame: CGRect
    var outer: LayoutEdges
    var hidden = false
}

/// Reiterleiste eines Platzes mit mehreren Kacheln.
struct LayoutTabBar: Equatable {
    /// Kacheln in Reiter-Reihenfolge; `front` ist die sichtbare.
    var tabs: [String]
    var front: String
    var rect: CGRect
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
    /// Plätze, Trennlinien und Reiterleisten für `root` in `bounds`. Kanten werden gerundet wie im alten
    /// Raster (`(size * anteil).rounded()` ab dem Ursprung), damit keine Lücken durch Rundung entstehen;
    /// innen bekommt jede Kachel einen halben Steg Abstand, am Fensterrand keinen. Ein Platz mit Reitern
    /// gibt oben `tabBarHeight` an seine Leiste ab.
    static func layout(_ root: LayoutNode, in bounds: CGRect, gap: CGFloat, tabBarHeight: CGFloat = 0)
        -> (slots: [LayoutSlot], dividers: [LayoutDivider], tabBars: [LayoutTabBar]) {
        var out = Output()
        place(root, rect: bounds, path: [], bounds: bounds, gap: gap, bar: tabBarHeight, out: &out)
        return (out.slots, out.dividers, out.tabBars)
    }

    private struct Output {
        var slots: [LayoutSlot] = []
        var dividers: [LayoutDivider] = []
        var tabBars: [LayoutTabBar] = []
    }

    private static func place(_ node: LayoutNode, rect: CGRect, path: [Int], bounds: CGRect, gap g: CGFloat,
                              bar: CGFloat, out: inout Output) {
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
            guard node.isGroup else {
                out.slots.append(LayoutSlot(pane: pane, rect: rect, frame: frame, outer: outer))
                return
            }
            // Reiter: Leiste oben im Platz, die Kacheln darunter — ihre Oberkante liegt dann nie am Fensterrand.
            let height = min(bar, frame.height)
            out.tabBars.append(LayoutTabBar(tabs: node.members, front: pane,
                                            rect: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)))
            let content = CGRect(x: frame.minX, y: frame.minY + height, width: frame.width, height: frame.height - height)
            var below = outer
            if height > 0 { below.remove(.top) }
            for id in node.members {
                out.slots.append(LayoutSlot(pane: id, rect: rect, frame: content, outer: below, hidden: id != pane))
            }
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
            place(child, rect: childRect, path: path + [i], bounds: bounds, gap: g, bar: bar, out: &out)
            guard i + 1 < node.children.count else { continue }
            let b = edges[i + 1]
            let hit: CGRect
            switch axis {
            case .row: hit = CGRect(x: b - g / 2, y: rect.minY, width: g, height: rect.height)
            case .column: hit = CGRect(x: rect.minX, y: b - g / 2, width: rect.width, height: g)
            }
            out.dividers.append(LayoutDivider(path: path, index: i, axis: axis, rect: hit,
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

    /// Höchstens so viele Plätze übereinander in einer Nebenspalte; weitere Begleiter kommen als Reiter
    /// auf den letzten Platz (Live-Test 23.09.: vier Begleiter à 25 % Höhe waren alle unbrauchbar).
    static let maxCompanionPlaces = 3

    /// Begleiter auf Plätze verteilen: die ersten einzeln, der Rest gemeinsam als Reiter auf dem letzten.
    static func companionPlaces(_ companions: [String]) -> [[String]] {
        guard companions.count > maxCompanionPlaces else { return companions.map { [$0] } }
        let single = maxCompanionPlaces - 1
        return companions.prefix(single).map { [$0] } + [Array(companions.dropFirst(single))]
    }

    /// Wunschform eines Platzes mit Reitern: Form nur, wenn alle dieselbe wollen; Mindestmaße der größten.
    static func merged(_ preferences: [LayoutPreference]) -> LayoutPreference {
        guard let first = preferences.first else { return .flexible }
        guard preferences.count > 1 else { return first }
        let aspects = Set(preferences.map { $0.aspect })
        return LayoutPreference(aspect: aspects.count == 1 ? first.aspect : nil,
                                minWidth: preferences.map(\.minWidth).max() ?? first.minWidth,
                                minHeight: preferences.map(\.minHeight).max() ?? first.minHeight,
                                comfortWidth: preferences.compactMap(\.comfortWidth).max())
    }

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
                let places = companionPlaces(block.companions)
                let choice = chooseSplit(anchor: byID[block.anchor]?.preference ?? .flexible,
                                         companions: places.map { merged($0.map { byID[$0]?.preference ?? .flexible }) },
                                         width: blockWidth, height: blockHeight, gap: gap)
                let column: LayoutNode = places.count == 1
                    ? .group(places[0], weight: choice.fraction)
                    : .split(.column, zip(places, choice.heights).map { .group($0, weight: $1) },
                             weight: choice.fraction)
                nodes.append(.split(.row, [.leaf(block.anchor, weight: 1 - choice.fraction), column],
                                    weight: block.demand))
            }
        }
        return grid(nodes, rows: rows)?.normalized()
    }

    /// Breite der Nebenspalte (Anteil am Block) und Höhen der Begleiter darin: der Kandidat, bei dem
    /// die Begleiter ihrer Wunschform am nächsten kommen und niemand unter seine Mindestgröße fällt.
    /// Ab zwei Begleitern zählt die Fläche mehr als die Form (Live-Test 23.09.: drei Begleiter drückten
    /// die Spalte auf 25 %, weil ein hochkantes PDF in einem Drittel der Höhe nur schmal „passt“) —
    /// die Spalte zieht dann kräftig Richtung 45 %, die Form zählt je Begleiter nur anteilig.
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
            let pull = k >= 2 ? 4.0 : 0.25
            let formWeight = k >= 2 ? 1.0 / Double(k) : 1
            var cost = pull * abs(f - 0.45)
            for (pref, h) in zip(companions, heights) {
                if let aspect = pref.aspect { cost += formWeight * abs(log((columnWidth / h) / aspect)) }
                cost += deficit(columnWidth, pref.minWidth) / 50 + deficit(h, pref.minHeight) / 50
            }
            cost += deficit(anchorWidth, anchor.minWidth) / 50
            // Bequemlichkeit der Session (80 Spalten) nur bei einem Begleiter; ab zwei gilt ihr Minimum.
            if k < 2, let comfort = anchor.comfortWidth { cost += deficit(anchorWidth, comfort) / 400 }
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
        if root.members.contains(id) { return [] }
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
                        if sibling.axis == .column, sibling.children.count >= AutoLayout.maxCompanionPlaces,
                           let last = sibling.children.last, last.isLeaf, last.setBy != .mats {
                            // Spalte voll: als Reiter auf den letzten Platz (wie die Automatik) — nicht in Reiter, die Mats
                            // von Hand zusammengestellt hat; dann bekommt die Neue einen eigenen Platz darunter.
                            var column = sibling
                            column.children[column.children.count - 1] = .group(last.members + [id], front: last.pane,
                                                                               weight: last.weight, setBy: last.setBy)
                            grown = column
                        } else if sibling.axis == .column {
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
            var leaf = node(at: anchorPath, in: root)
            let rect = LayoutGeometry.rect(at: anchorPath, in: root, bounds: bounds)
            let choice = AutoLayout.chooseSplit(anchor: anchorPreference, companions: [preference],
                                                width: Double(rect.width), height: Double(rect.height), gap: gap)
            let weight = leaf.weight
            leaf.weight = 1 - choice.fraction
            let pair = LayoutNode.split(.row, [leaf, .leaf(id, weight: choice.fraction)], weight: weight)
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

    /// Neue Kachel verdeckt einsetzen, ohne Platz zu nehmen (Agent öffnet „im Hintergrund“): als hinterer Reiter
    /// auf den letzten Platz der Nebenspalte ihrer Kachel, gibt es keine, hinter die Kachel selbst. Nie in Reiter,
    /// die Mats zusammengestellt hat (✋) — nil, wenn es keinen erlaubten Platz gibt (der Aufrufer setzt sie dann
    /// normal ein). Welche Kachel vorn liegt, entscheidet die Split-View; die neue kommt hinten an.
    static func insertBehind(_ pane: String, anchor: String, anchorCompanions: Set<String>, into root: LayoutNode) -> LayoutNode? {
        let id = pane.uppercased()
        guard !root.paneIDs.contains(id), let anchorPath = path(of: anchor, in: root) else { return nil }
        let companions = Set(anchorCompanions.map { $0.uppercased() })
        var candidates: [[Int]] = []
        // Nebenspalte = rechter Nachbar in einer Zeile, der nur Begleiter enthält; ihr letzter Platz (unten).
        if let index = anchorPath.last {
            let parentPath = Array(anchorPath.dropLast())
            let parent = node(at: parentPath, in: root)
            if parent.axis == .row, index + 1 < parent.children.count {
                let sibling = parent.children[index + 1]
                if !sibling.paneIDs.isEmpty, sibling.paneIDs.allSatisfy(companions.contains) {
                    var placePath = parentPath + [index + 1]
                    while !node(at: placePath, in: root).isLeaf {
                        placePath.append(node(at: placePath, in: root).children.count - 1)
                    }
                    candidates.append(placePath)
                }
            }
        }
        candidates.append(anchorPath)
        for placePath in candidates {
            let place = node(at: placePath, in: root)
            guard place.setBy != .mats else { continue }
            let result = replacing(at: placePath, in: root,
                                   with: .group(place.members + [id], front: place.pane, weight: place.weight, setBy: place.setBy))
            return result.normalized() ?? result
        }
        return nil
    }

    /// Kachel herausnehmen; die Geschwister behalten ihr Verhältnis zueinander.
    static func remove(_ pane: String, from root: LayoutNode) -> LayoutNode? {
        let id = pane.uppercased()
        guard let target = path(of: id, in: root) else { return root }
        let place = node(at: target, in: root)
        if place.isGroup {
            // Ein Reiter geht, der Platz bleibt (mit einer Kachel wieder ein normales Blatt). Ging der
            // vordere, rückt sein rechter Nachbar vor (die Split-View wählt danach den zuletzt gezeigten).
            let rest = place.members.filter { $0 != id }
            let front = place.pane != id ? place.pane
                : place.members.firstIndex(of: id).flatMap { i in place.members[(i + 1)...].first ?? place.members[..<i].last }
            return replacing(at: target, in: root, with: .group(rest, front: front, weight: place.weight, setBy: place.setBy))
        }
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
    /// `a` als Reiter an den Platz von `b` legen (hinter die vordere Kachel dort).
    case tab(String, into: String)

    /// Kacheln, die die Absicht bewegt (für die Rechteprüfung).
    var panes: [String] {
        switch self {
        case .big(let a), .grow(let a), .shrink(let a): return [a]
        case .beside(let a, let b), .below(let a, let b), .swap(let a, let b), .tab(let a, let b): return [a, b]
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
                throw LayoutRefusal(split.isGroup
                    ? "Diese Reiter hat Mats von Hand zusammengestellt — sie bleiben, bis er etwas anderes sagt (dann auf_auftrag: true)."
                    : "Diese Aufteilung hat Mats von Hand gesetzt — sie bleibt, bis er etwas anderes sagt (dann auf_auftrag: true).")
            }
        }
        /// Kachel verlässt ihren Platz: aus Mats' Reitern oder aus seiner Teilung nur auf Auftrag.
        func guardLeaving(_ path: [Int]) throws {
            let place = node(at: path, in: root)
            if place.isGroup { try guardMats(place) }
            else if path.last != nil { try guardMats(node(at: Array(path.dropLast()), in: root)) }
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
            try guardLeaving(pathB)
            guard let without = remove(idB, from: root), let pathA = path(of: idA, in: without) else { return root }
            var leafA = node(at: pathA, in: without)
            let weight = leafA.weight
            leafA.weight = 1
            let axis: LayoutAxis = { if case .beside = op { return .row } else { return .column } }()
            let pair = LayoutNode.split(axis, [leafA, .leaf(idB)], weight: weight, setBy: actor)
            let result = replacing(at: pathA, in: without, with: pair)
            return result.normalized() ?? result

        case .swap(let a, let b):
            let idA = a.uppercased(), idB = b.uppercased()
            let pathA = try locate(idA)
            let pathB = try locate(idB)
            guard idA != idB else { throw LayoutRefusal("Zweimal dieselbe Kachel.") }
            // Tauschen ändert keine Anteile, wohl aber, wer in Mats' Reitern liegt (innerhalb eines Platzes: nur Reihenfolge).
            if pathA != pathB {
                if node(at: pathA, in: root).isGroup { try guardMats(node(at: pathA, in: root)) }
                if node(at: pathB, in: root).isGroup { try guardMats(node(at: pathB, in: root)) }
            }
            // Plätze tauschen, auch zwischen Reitern: überall A ↔ B.
            return root.mappingPanes { $0 == idA ? idB : $0 == idB ? idA : $0 } ?? root

        case .tab(let a, let b):
            let idA = a.uppercased(), idB = b.uppercased()
            guard idA != idB else { throw LayoutRefusal("Zweimal dieselbe Kachel.") }
            let pathA = try locate(idA)
            let pathB = try locate(idB)
            if pathA == pathB { return root }   // schon Reiter an diesem Platz
            try guardLeaving(pathA)
            try guardMats(node(at: pathB, in: root))   // zu Mats' Reitern nur auf Auftrag
            guard let without = remove(idA, from: root), let target = path(of: idB, in: without) else { return root }
            let place = node(at: target, in: without)
            let result = replacing(at: target, in: without,
                                   with: .group(place.members + [idA], front: place.pane, weight: place.weight, setBy: place.setBy))
            return result.normalized() ?? result
        }
    }
}

// MARK: - Kachel ziehen (Mats, Stufe 2 Scheibe B)

/// Wohin eine gezogene Kachel fällt: an eine Seite eines Platzes bzw. des Fensters, oder als Reiter in die Mitte.
enum LayoutDropZone: String, Equatable {
    case left, right, top, bottom, center

    /// Teilungsrichtung, die an dieser Seite entsteht; `center` teilt nicht.
    var axis: LayoutAxis? {
        switch self {
        case .left, .right: return .row
        case .top, .bottom: return .column
        case .center: return nil
        }
    }

    /// Die gezogene Kachel kommt vor (links/oben) das Ziel.
    var leading: Bool { self == .left || self == .top }
}

/// Ziel eines Kachel-Zugs. Plätze werden über eine ihrer Kacheln benannt (bei Reitern: irgendeine).
enum LayoutDropTarget: Equatable {
    /// An eine Seite des Platzes dieser Kachel (halbiert ihn) oder als Reiter in ihn (`center`).
    case place(String, LayoutDropZone)
    /// In die Reiterleiste dieses Platzes, vor den Reiter an Position `index` (Anzahl = ans Ende).
    case tabBar(String, index: Int)
    /// An den Fensterrand: über die ganze Höhe bzw. Breite.
    case window(LayoutDropZone)
}

enum LayoutDrop {
    /// Zone unter `point` in einem Platz: die innere Hälfte (je Achse 25–75 %) = Mitte, sonst die nächste
    /// Kante — die Diagonalen teilen den Rand in vier Dreiecke. nil = Punkt liegt nicht im Platz.
    static func zone(at point: CGPoint, in rect: CGRect) -> LayoutDropZone? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        let x = (point.x - rect.minX) / rect.width, y = (point.y - rect.minY) / rect.height
        if (0.25...0.75).contains(x), (0.25...0.75).contains(y) { return .center }
        let distances: [(LayoutDropZone, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return distances.min { $0.1 < $1.1 }?.0
    }

    /// Fensterrand: `point` liegt höchstens `band` pt innerhalb einer Kante (oben = minY, die Split-View ist
    /// geflippt). In Ecken gewinnt die nähere Kante.
    static func windowZone(at point: CGPoint, in bounds: CGRect, band: CGFloat) -> LayoutDropZone? {
        guard bounds.contains(point) else { return nil }
        let distances: [(LayoutDropZone, CGFloat)] = [(.left, point.x - bounds.minX), (.right, bounds.maxX - point.x),
                                                      (.top, point.y - bounds.minY), (.bottom, bounds.maxY - point.y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 <= band else { return nil }
        return nearest.0
    }
}

extension LayoutEdit {
    /// Kachel `pane` an `target` verschieben. Seiten halbieren den Zielplatz (bzw. geben am Fensterrand einen
    /// Teil wie ein weiteres Kind ab), die Mitte und die Reiterleiste legen sie als Reiter dazu, vorn. Die neue
    /// Teilung gilt als von `actor` gesetzt; alles andere behält seine Anteile, ihr alter Platz fällt an ihre
    /// Nachbarn. nil = nichts zu tun (Ziel ist sie selbst, unbekannte Kachel, einzige Kachel).
    static func moved(_ pane: String, to target: LayoutDropTarget, in root: LayoutNode, actor: LayoutActor) -> LayoutNode? {
        let id = pane.uppercased()
        guard let sourcePath = path(of: id, in: root) else { return nil }
        let source = node(at: sourcePath, in: root)
        let result: LayoutNode

        switch target {
        case .place(let other, let zone):
            guard let targetPath = path(of: other, in: root) else { return nil }
            let samePlace = targetPath == sourcePath
            // Auf sich selbst: nur ein Reiter lässt sich aus seinem Platz neben ihn herauslösen.
            if samePlace, !source.isGroup || zone == .center { return nil }
            let place = node(at: targetPath, in: root)
            guard let anchor = place.members.first(where: { $0 != id }),
                  let without = remove(id, from: root), let anchorPath = path(of: anchor, in: without) else { return nil }
            let remaining = node(at: anchorPath, in: without)
            let replacement: LayoutNode
            if let axis = zone.axis {
                var kept = remaining
                kept.weight = 1
                let moved = LayoutNode.leaf(id)
                replacement = .split(axis, zone.leading ? [moved, kept] : [kept, moved], weight: remaining.weight, setBy: actor)
            } else {
                replacement = .group(remaining.members + [id], front: id, weight: remaining.weight, setBy: actor)
            }
            result = replacing(at: anchorPath, in: without, with: replacement)

        case .tabBar(let other, let index):
            guard let targetPath = path(of: other, in: root) else { return nil }
            let place = node(at: targetPath, in: root)
            if let from = place.members.firstIndex(of: id) {
                // Im eigenen Platz umsortieren.
                var members = place.members
                var to = min(max(index, 0), members.count)
                members.remove(at: from)
                if from < to { to -= 1 }
                members.insert(id, at: to)
                guard members != place.members else { return nil }
                result = replacing(at: targetPath, in: root, with: .group(members, front: id, weight: place.weight, setBy: actor))
            } else {
                guard let anchor = place.members.first, let without = remove(id, from: root),
                      let anchorPath = path(of: anchor, in: without) else { return nil }
                let remaining = node(at: anchorPath, in: without)
                // Position bezieht sich auf die Leiste, wie Mats sie sah; die gezogene Kachel stand nicht darin.
                var members = remaining.members
                members.insert(id, at: min(max(index, 0), members.count))
                result = replacing(at: anchorPath, in: without, with: .group(members, front: id, weight: remaining.weight, setBy: actor))
            }

        case .window(let zone):
            guard let axis = zone.axis, var without = remove(id, from: root) else { return nil }
            // Wie ein weiteres Kind entlang der Achse: bei drei Spalten ein Viertel, sonst mindestens ein Drittel.
            // Der bisherige Baum bleibt ein Block (gleich gerichtete Teilungen werden nicht verschmolzen).
            let siblings = without.axis == axis ? without.children.count : 1
            without.weight = Double(max(2, siblings))
            let moved = LayoutNode.leaf(id)
            result = .split(axis, zone.leading ? [moved, without] : [without, moved], setBy: actor)
        }

        let normalized = result.normalized() ?? result
        return normalized == root ? nil : normalized
    }
}
