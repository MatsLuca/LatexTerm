import Foundation
import CoreGraphics

/// Formen der Pinnwand (26.09., Plan claude-werkstatt `plans/scratchpad-visuell_2026-09-26.md`): Karten dürfen statt des
/// Terminal-Looks eine Form haben (Kreis, Raute, Wolke, Haftnotiz …), Zonen legen eine farbige Fläche hinter eine Gruppe,
/// Pfeile tragen eine Beschriftung. Alles wird gesetzt wie eine Karte — Agenten rechnen keine Koordinaten, das
/// Scratchpad bemisst Form und Text. Nur Foundation/CG — Test `scripts/test-scratch-shapes.swift`.
enum ScratchShapes {
    enum Kind: String, CaseIterable {
        case box, pill, circle, diamond, hexagon, note, cloud

        /// Umriss aus dem Inhalt: Faktor auf den gepolsterten Inhalt plus fester Zuschlag je Seite. Kreis und Raute müssen
        /// den Text-Kasten ganz umschließen (Ellipse durch die Ecken: √2; Raute: 2, hier 1,9 — die Ecken sind Polster).
        var factor: CGFloat {
            switch self {
            case .circle: 1.42
            case .diamond: 1.9
            case .cloud: 1.45
            default: 1
            }
        }
        var extra: CGSize {
            switch self {
            case .pill: CGSize(width: 8, height: 0)
            case .hexagon: CGSize(width: 14, height: 0)
            case .note: CGSize(width: 4, height: 4)
            case .cloud: CGSize(width: 6, height: 6)
            default: .zero
            }
        }
        /// Inhalt standardmäßig mittig (Text in Formen liest sich zentriert).
        var centered: Bool { self != .note && self != .box }
    }

    static let names = Kind.allCases.map(\.rawValue)

    /// Äußere Breite für einen Inhalt der Breite `inner` (ohne Polster).
    static func outerWidth(inner: CGFloat, kind: Kind?, pad: CGSize) -> CGFloat {
        guard let kind else { return inner + 2 * pad.width }
        return (inner + 2 * pad.width) * kind.factor + 2 * kind.extra.width
    }

    /// Inhaltsbreite (ohne Polster) für eine äußere Breite.
    static func innerWidth(outer: CGFloat, kind: Kind?, pad: CGSize) -> CGFloat {
        guard let kind else { return outer - 2 * pad.width }
        return (outer - 2 * kind.extra.width) / kind.factor - 2 * pad.width
    }

    static func outerHeight(inner: CGFloat, kind: Kind?, pad: CGSize) -> CGFloat {
        guard let kind else { return inner + 2 * pad.height }
        return (inner + 2 * pad.height) * kind.factor + 2 * kind.extra.height
    }

    /// Umriss als geschlossener Linienzug (Welt), für Zeichnen und Treffer. Rundungen fein abgetastet.
    static func outline(_ kind: Kind, in r: CGRect) -> [CGPoint] {
        switch kind {
        case .box: return rounded(r, radius: min(8, r.height / 2))
        case .pill: return rounded(r, radius: r.height / 2)
        case .note: return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - noteFold(r), y: r.minY),
                            CGPoint(x: r.maxX, y: r.minY + noteFold(r)), CGPoint(x: r.maxX, y: r.maxY),
                            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        case .circle:
            return (0...72).map { i in
                let a = CGFloat(i) / 72 * 2 * .pi
                return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
            }
        case .diamond:
            return [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.midX, y: r.maxY),
                    CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.midX, y: r.minY)]
        case .hexagon:
            let d = min(kind.extra.width, r.width / 3)
            return [CGPoint(x: r.minX + d, y: r.minY), CGPoint(x: r.maxX - d, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
                    CGPoint(x: r.maxX - d, y: r.maxY), CGPoint(x: r.minX + d, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
                    CGPoint(x: r.minX + d, y: r.minY)]
        case .cloud:
            return cloud(r)
        }
    }

    /// Umgeknickte Ecke der Haftnotiz.
    static func noteFold(_ r: CGRect) -> CGFloat { min(14, r.width / 4, r.height / 3) }

    /// Rechteck mit runden Ecken als Linienzug.
    static func rounded(_ r: CGRect, radius: CGFloat) -> [CGPoint] {
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        guard rad > 0.5 else {
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                    CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]
        }
        let corners = [(CGPoint(x: r.maxX - rad, y: r.minY + rad), -CGFloat.pi / 2),
                       (CGPoint(x: r.maxX - rad, y: r.maxY - rad), 0),
                       (CGPoint(x: r.minX + rad, y: r.maxY - rad), CGFloat.pi / 2),
                       (CGPoint(x: r.minX + rad, y: r.minY + rad), CGFloat.pi)]
        var points: [CGPoint] = []
        for (c, start) in corners {
            for k in 0...8 {
                let a = start + CGFloat(k) / 8 * .pi / 2
                points.append(CGPoint(x: c.x + cos(a) * rad, y: c.y + sin(a) * rad))
            }
        }
        points.append(points[0])
        return points
    }

    /// Wolke: Bögen, die über eine Ellipse nach außen wölben — Anzahl nach Umfang (≈ alle 34 pt einer).
    static func cloud(_ r: CGRect) -> [CGPoint] {
        let base = r.insetBy(dx: r.width * 0.08, dy: r.height * 0.1)
        let (a, b) = (base.width / 2, base.height / 2)
        let perimeter = CGFloat.pi * (3 * (a + b) - sqrt((3 * a + b) * (a + 3 * b)))
        let n = max(7, min(18, Int(perimeter / 34)))
        func onEllipse(_ t: CGFloat) -> CGPoint { CGPoint(x: base.midX + cos(t) * a, y: base.midY + sin(t) * b) }
        var points: [CGPoint] = []
        for i in 0..<n {
            let t0 = CGFloat(i) / CGFloat(n) * 2 * .pi, t1 = CGFloat(i + 1) / CGFloat(n) * 2 * .pi
            let p0 = onEllipse(t0), p2 = onEllipse(t1), mid = onEllipse((t0 + t1) / 2)
            // Kontrollpunkt nach außen: so weit, dass der Bogen den Rahmen `r` gerade erreicht.
            let out = CGPoint(x: mid.x + (mid.x - base.midX) / max(a, 1) * r.width * 0.16,
                              y: mid.y + (mid.y - base.midY) / max(b, 1) * r.height * 0.2)
            for k in 0..<10 {
                let t = CGFloat(k) / 10, u = 1 - t
                points.append(CGPoint(x: u * u * p0.x + 2 * u * t * out.x + t * t * p2.x,
                                      y: u * u * p0.y + 2 * u * t * out.y + t * t * p2.y))
            }
        }
        points.append(points[0])
        return points
    }

    // MARK: Zonen

    /// Rand einer Zone um ihre Karten und Platz für die Überschrift.
    static let zonePad: CGFloat = 16
    static let zoneTitleRoom: CGFloat = 22

    /// Rahmen einer Zone um die Rechtecke ihrer Mitglieder; nil = keine Mitglieder.
    static func zoneFrame(around members: [CGRect], titled: Bool) -> CGRect? {
        guard let first = members.first else { return nil }
        let box = members.dropFirst().reduce(first) { $0.union($1) }
        let top = zonePad + (titled ? zoneTitleRoom : 0)
        return CGRect(x: box.minX - zonePad, y: box.minY - top, width: box.width + 2 * zonePad, height: box.height + top + zonePad)
    }

    // MARK: Pfeil-Beschriftung

    /// Mitte des längsten Stücks eines Linienzugs — dort sitzt die Beschriftung eines Pfeils.
    static func labelAnchor(_ points: [CGPoint]) -> CGPoint? {
        guard points.count >= 2 else { return points.first }
        var best: (length: CGFloat, mid: CGPoint)?
        for (a, b) in zip(points, points.dropFirst()) {
            let l = hypot(b.x - a.x, b.y - a.y)
            if best == nil || l > best!.length + 0.5 { best = (l, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)) }
        }
        return best?.mid
    }

    /// Strichbreite eines Pfeils nach Stärke; nil = unbekannt.
    static func arrowWidth(_ weight: String) -> CGFloat? {
        ["thin": 1.2, "normal": 2, "thick": 3.5][weight.lowercased()]
    }
}
