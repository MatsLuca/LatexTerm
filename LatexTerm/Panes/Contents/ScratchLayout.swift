import Foundation
import CoreGraphics

/// Geometrie der Pinnwand für Agenten (25.09., Plan claude-werkstatt `plans/scratchpad-karten-layout_2026-09-25.md`):
/// Ein Agent legt nichts ungesehen ab — jede Karte braucht einen Ort (absolut oder relativ zu einer anderen), Überdecken
/// und Außerhalb-des-Sichtbaren gehen nur ausdrücklich, Pfeile docken an Kanten an und laufen rechtwinklig um Karten
/// herum. Nur Foundation/CG — Test `scripts/test-scratch-layout.swift`.
enum ScratchLayout {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    enum Side: String, CaseIterable {
        case top, right, bottom, left

        var direction: CGPoint {
            switch self {
            case .top: CGPoint(x: 0, y: -1)   // y nach unten
            case .right: CGPoint(x: 1, y: 0)
            case .bottom: CGPoint(x: 0, y: 1)
            case .left: CGPoint(x: -1, y: 0)
            }
        }
        var horizontal: Bool { self == .left || self == .right }
    }

    enum Relation: String, CaseIterable {
        case below, above, rightOf, leftOf
    }

    /// Ort einer Karte: `x`/`y` absolut (obere linke Ecke), oder relativ zu `ref` — dann überschreiben `x`/`y` nur ihre
    /// Achse (z. B. `below: k1` + `x: 40`).
    struct Placement: Equatable {
        var x: CGFloat?
        var y: CGFloat?
        var relation: Relation?
        var ref: String?
        var gap: CGFloat?

        var isEmpty: Bool { x == nil && y == nil && ref == nil }
        static let defaultGap: CGFloat = 16
    }

    /// Obere linke Ecke für eine Karte `size`; `refRect` = Rechteck der Bezugskarte (bei `relation`).
    static func origin(_ p: Placement, size: CGSize, refRect: CGRect?) throws -> CGPoint {
        guard let relation = p.relation else {
            guard let x = p.x, let y = p.y else {
                throw Failure("braucht einen Ort: x und y, oder below/above/rightOf/leftOf mit einer Karten-id")
            }
            return CGPoint(x: x, y: y)
        }
        guard let r = refRect else { throw Failure("Bezugskarte „\(p.ref ?? "?")“ gibt es nicht (ids aus scratch_look oder früher im selben Aufruf)") }
        let gap = p.gap ?? Placement.defaultGap
        var o: CGPoint
        switch relation {
        case .below: o = CGPoint(x: r.minX, y: r.maxY + gap)
        case .above: o = CGPoint(x: r.minX, y: r.minY - gap - size.height)
        case .rightOf: o = CGPoint(x: r.maxX + gap, y: r.minY)
        case .leftOf: o = CGPoint(x: r.minX - gap - size.width, y: r.minY)
        }
        if let x = p.x { o.x = x }
        if let y = p.y { o.y = y }
        return o
    }

    // MARK: Hindernisse

    /// Etwas, das auf dem Brett liegt: Rechteck (Karte, Bild, Beschriftung) oder Linienzug (Strich, Form).
    struct Obstacle {
        var name: String
        var rect: CGRect
        var line: [CGPoint]?
        var reach: CGFloat = 0
    }

    /// Namen der Hindernisse, die `rect` (mit `margin` Luft) berührt — jeder Name einmal, in Reihenfolge.
    static func overlaps(_ rect: CGRect, _ obstacles: [Obstacle], margin: CGFloat = 4) -> [String] {
        let zone = rect.insetBy(dx: -margin, dy: -margin)
        var names: [String] = []
        for o in obstacles where o.rect.insetBy(dx: -o.reach, dy: -o.reach).intersects(zone) {
            let hit: Bool
            if let line = o.line {
                let wide = zone.insetBy(dx: -o.reach, dy: -o.reach)
                hit = line.count == 1 ? wide.contains(line[0])
                    : zip(line, line.dropFirst()).contains { segment($0, $1, hits: wide) }
            } else {
                hit = true
            }
            if hit, !names.contains(o.name) { names.append(o.name) }
        }
        return names
    }

    /// Schneidet die Strecke a→b das Rechteck (Rand oder innen)? Liang–Barsky.
    static func segment(_ a: CGPoint, _ b: CGPoint, hits r: CGRect) -> Bool {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        var t0: CGFloat = 0, t1: CGFloat = 1
        for (p, q) in [(-d.x, a.x - r.minX), (d.x, r.maxX - a.x), (-d.y, a.y - r.minY), (d.y, r.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
            } else {
                let t = q / p
                if p < 0 { if t > t1 { return false }; t0 = max(t0, t) } else { if t < t0 { return false }; t1 = min(t1, t) }
            }
        }
        return t0 <= t1
    }

    // MARK: Pfeile

    struct Route: Equatable {
        var points: [CGPoint]
        /// Namen der Karten/Bilder, durch die der Pfeil läuft (ohne Anfang und Ziel).
        var hits: [String]
    }

    /// Abstand der Pfeilenden von der Kante.
    static let stub: CGFloat = 6

    static func anchor(_ r: CGRect, _ side: Side, stub: CGFloat = stub) -> CGPoint {
        switch side {
        case .top: CGPoint(x: r.midX, y: r.minY - stub)
        case .right: CGPoint(x: r.maxX + stub, y: r.midY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY + stub)
        case .left: CGPoint(x: r.minX - stub, y: r.midY)
        }
    }

    /// Pfeil von Karte `a` zu Karte `b`: an den gegebenen (sonst den günstigsten) Kanten, rechtwinklig, mit möglichst
    /// wenig Knicken und nicht durch fremde Karten. `via` = feste Zwischenpunkte (gerade Stücke dazwischen).
    /// `obstacles` enthält alle Karten/Bilder; `a` und `b` selbst heißen `fromName`/`toName` und zählen nur, wenn der
    /// Pfeil zurück durch sie hindurch liefe.
    /// `others` = Linienzüge schon liegender Pfeile: auf ihnen entlangzulaufen kostet (sonst verschmelzen zwei Pfeile
    /// in einem Kanal zu einer Linie, Befund 25.09. abends).
    static func route(from a: CGRect, to b: CGRect, fromSide: Side? = nil, toSide: Side? = nil, via: [CGPoint] = [],
                      obstacles: [Obstacle], fromName: String, toName: String, others: [[CGPoint]] = [],
                      centered: Bool = false) -> Route {
        var best: (score: CGFloat, route: Route)?
        for sa in fromSide.map({ [$0] }) ?? Side.allCases {
            for sb in toSide.map({ [$0] }) ?? Side.allCases {
                let p0 = anchor(a, sa), p1 = anchor(b, sb)
                var ways = via.isEmpty ? orthogonalCandidates(p0, sa, p1, sb) : [[p0] + via + [p1]]
                // `centered`: Formen (Kreis, Raute …) nur an Kantenmitten — kein gerader Weg auf der gemeinsamen Höhe.
                if via.isEmpty, !centered, let line = straight(a, sa, b, sb) { ways.insert(line, at: 0) }
                for way in ways {
                let points = simplify(way)
                // Zu kurz = kein Pfeil (Absturz 25.09. 22:07: liegen zwei Anker < 0,5 pt beieinander, schrumpft der Weg auf
                // einen Punkt und gewinnt mit Länge 0 — daraus wurde ein Strich ohne Punkte).
                guard points.count >= 2, length(points) >= minLength else { continue }
                var hits: [String] = []
                for o in obstacles {
                    // Anfang/Ziel: der Stummel an ihrer Kante gehört dazu, nur ein Rückweg durch sie zählt.
                    let r = o.rect.insetBy(dx: 1, dy: 1)
                    if zip(points, points.dropFirst()).contains(where: { segment($0, $1, hits: r) }), !hits.contains(o.name) {
                        hits.append(o.name)
                    }
                }
                let foreign = hits.filter { $0 != fromName && $0 != toName }
                let selfCross = hits.count - foreign.count
                let shared = others.reduce(0) { $0 + sharedLength(points, $1) }
                let score = CGFloat(foreign.count) * 100_000 + CGFloat(selfCross) * 50_000
                    + length(points) + CGFloat(max(0, points.count - 2)) * 40 + shared * 6
                if best == nil || score < best!.score { best = (score, Route(points: points, hits: foreign)) }
                }
            }
        }
        return best?.route ?? fallback(a, b)
    }

    /// Zugewandte Kanten, die sich gegenüberstehen (Karte neben einem Absatz, 26.09.): gerade auf der Mitte der gemeinsamen
    /// Höhe bzw. Breite statt Mitte-zu-Mitte mit Knick. nil = sie stehen sich nicht gegenüber (mindestens 6 pt gemeinsam).
    static func straight(_ a: CGRect, _ sa: Side, _ b: CGRect, _ sb: Side) -> [CGPoint]? {
        switch (sa, sb) {
        case (.right, .left) where a.maxX < b.minX, (.left, .right) where b.maxX < a.minX:
            let (lo, hi) = (max(a.minY, b.minY), min(a.maxY, b.maxY))
            guard hi - lo >= 6 else { return nil }
            let y = (lo + hi) / 2
            return sa == .right ? [CGPoint(x: a.maxX, y: y), CGPoint(x: b.minX, y: y)] : [CGPoint(x: a.minX, y: y), CGPoint(x: b.maxX, y: y)]
        case (.bottom, .top) where a.maxY < b.minY, (.top, .bottom) where b.maxY < a.minY:
            let (lo, hi) = (max(a.minX, b.minX), min(a.maxX, b.maxX))
            guard hi - lo >= 6 else { return nil }
            let x = (lo + hi) / 2
            return sa == .bottom ? [CGPoint(x: x, y: a.maxY), CGPoint(x: x, y: b.minY)] : [CGPoint(x: x, y: a.minY), CGPoint(x: x, y: b.maxY)]
        default:
            return nil
        }
    }

    /// Kürzester sinnvoller Pfeil; alles darunter wird nicht gewählt.
    static let minLength: CGFloat = 8

    /// Kein brauchbarer Weg (Karten berühren oder überdecken sich): gerade von Mitte zu Mitte, notfalls ein kurzer
    /// Stummel — immer mindestens zwei verschiedene Punkte.
    static func fallback(_ a: CGRect, _ b: CGRect) -> Route {
        let (ca, cb) = (CGPoint(x: a.midX, y: a.midY), CGPoint(x: b.midX, y: b.midY))
        if hypot(cb.x - ca.x, cb.y - ca.y) >= minLength { return Route(points: [ca, cb], hits: []) }
        let top = anchor(a, .top)
        return Route(points: [CGPoint(x: top.x, y: top.y - 16), top], hits: [])
    }

    /// Länge, auf der zwei Linienzüge (fast) deckungsgleich laufen: waagrechte/senkrechte Stücke näher als 8 pt lesen sich als eine Linie.
    static func sharedLength(_ p: [CGPoint], _ q: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        for (a0, a1) in zip(p, p.dropFirst()) {
            for (b0, b1) in zip(q, q.dropFirst()) {
                if abs(a0.y - a1.y) < 0.5, abs(b0.y - b1.y) < 0.5, abs(a0.y - b0.y) < 8 {
                    total += max(0, min(max(a0.x, a1.x), max(b0.x, b1.x)) - max(min(a0.x, a1.x), min(b0.x, b1.x)))
                } else if abs(a0.x - a1.x) < 0.5, abs(b0.x - b1.x) < 0.5, abs(a0.x - b0.x) < 8 {
                    total += max(0, min(max(a0.y, a1.y), max(b0.y, b1.y)) - max(min(a0.y, a1.y), min(b0.y, b1.y)))
                }
            }
        }
        return total
    }

    /// Mehrere rechtwinklige Wege je Kantenpaar: Kanal zwischen zwei zugewandten Kanten an verschiedenen Stellen,
    /// bei gleichen Seiten außen herum (mit etwas Versatz), damit ein zweiter Pfeil nicht auf dem ersten liegt.
    static func orthogonalCandidates(_ p0: CGPoint, _ sa: Side, _ p1: CGPoint, _ sb: Side) -> [[CGPoint]] {
        guard sa.horizontal == sb.horizontal else { return [orthogonal(p0, sa, p1, sb)] }
        let h = sa.horizontal
        let (c0, c1) = h ? (p0.x, p1.x) : (p0.y, p1.y)
        let (d0, d1) = h ? (sa.direction.x, sb.direction.x) : (sa.direction.y, sb.direction.y)
        var channels: [CGFloat]
        if d0 == d1 {
            // Gleiche Seite: außen herum.
            let outer = d0 > 0 ? max(c0, c1) + 14 : min(c0, c1) - 14
            channels = [0, 10, 20].map { outer + d0 * $0 }
        } else if (c1 - c0) * d0 > 0 {
            // Zugewandt: Kanal irgendwo zwischen den Kanten.
            channels = [0.5, 0.3, 0.7, 0.15, 0.85].map { c0 + (c1 - c0) * $0 }
        } else {
            return [orthogonal(p0, sa, p1, sb)]
        }
        return channels.map { m in
            h ? [p0, CGPoint(x: m, y: p0.y), CGPoint(x: m, y: p1.y), p1]
              : [p0, CGPoint(x: p0.x, y: m), CGPoint(x: p1.x, y: m), p1]
        }
    }

    /// Rechtwinkliger Weg: erst ein Stück senkrecht aus der Kante, dann höchstens zwei Knicke.
    static func orthogonal(_ p0: CGPoint, _ sa: Side, _ p1: CGPoint, _ sb: Side) -> [CGPoint] {
        let lead: CGFloat = 14
        let s0 = CGPoint(x: p0.x + sa.direction.x * lead, y: p0.y + sa.direction.y * lead)
        let s1 = CGPoint(x: p1.x + sb.direction.x * lead, y: p1.y + sb.direction.y * lead)
        var middle: [CGPoint]
        switch (sa.horizontal, sb.horizontal) {
        case (true, true):
            let mx = (s0.x + s1.x) / 2
            middle = [CGPoint(x: mx, y: s0.y), CGPoint(x: mx, y: s1.y)]
        case (false, false):
            let my = (s0.y + s1.y) / 2
            middle = [CGPoint(x: s0.x, y: my), CGPoint(x: s1.x, y: my)]
        case (true, false):
            middle = [CGPoint(x: s1.x, y: s0.y)]
        case (false, true):
            middle = [CGPoint(x: s0.x, y: s1.y)]
        }
        return [p0, s0] + middle + [s1, p1]
    }

    /// Doppelte und in einer Linie liegende Zwischenpunkte weg; Rücksprünge auf derselben Linie bleiben (sichtbar).
    static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points {
            if let last = out.last, abs(last.x - p.x) < 0.5, abs(last.y - p.y) < 0.5 { continue }
            if out.count >= 2 {
                let a = out[out.count - 2], b = out[out.count - 1]
                let cross = (b.x - a.x) * (p.y - b.y) - (b.y - a.y) * (p.x - b.x)
                let dot = (b.x - a.x) * (p.x - b.x) + (b.y - a.y) * (p.y - b.y)
                if abs(cross) < 0.5, dot >= 0 { out[out.count - 1] = p; continue }
            }
            out.append(p)
        }
        return out
    }

    static func length(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Pfeilspitze am Ende des Linienzugs (zwei Schenkel, 11 pt).
    static func head(_ points: [CGPoint]) -> [CGPoint] {
        guard let p1 = points.last, let p0 = points.dropLast().last else { return [] }
        let angle = atan2(p1.y - p0.y, p1.x - p0.x)
        let wings = [angle + .pi * 0.85, angle - .pi * 0.85].map { CGPoint(x: p1.x + cos($0) * 11, y: p1.y + sin($0) * 11) }
        return [wings[0], p1, wings[1]]
    }
}
