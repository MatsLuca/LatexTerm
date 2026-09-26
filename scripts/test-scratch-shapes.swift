import Foundation
import CoreGraphics

/// Formen der Pinnwand: Umriss aus dem Inhalt, Umrisse geschlossen und im Rahmen, Zonen um ihre Karten, Pfeil-Beschriftung.
@main
struct ScratchShapesTests {
    typealias S = ScratchShapes

    static func main() {
        let pad = CGSize(width: 10, height: 8)
        var cases = 0
        func check(_ ok: Bool, _ what: String) {
            cases += 1
            if !ok { print("FEHLER: \(what)"); exit(1) }
        }

        // Ohne Form genau der alte Satz: Polster rundum, hin und zurück ohne Verlust.
        check(S.outerWidth(inner: 100, kind: nil, pad: pad) == 120, "ohne Form: Breite = Inhalt + Polster")
        check(S.innerWidth(outer: 120, kind: nil, pad: pad) == 100, "ohne Form: zurück")
        check(S.outerHeight(inner: 16, kind: nil, pad: pad) == 32, "ohne Form: Höhe")
        for kind in S.Kind.allCases {
            let w = S.outerWidth(inner: 140, kind: kind, pad: pad)
            check(abs(S.innerWidth(outer: w, kind: kind, pad: pad) - 140) < 0.001, "\(kind): Breite hin und zurück")
            check(w >= 160, "\(kind): Form ist nie schmaler als der gepolsterte Inhalt")
        }
        // Kreis und Raute umschließen den Textkasten ganz: seine Ecken liegen im Umriss.
        for kind in [S.Kind.circle, .diamond] {
            let inner = CGSize(width: 140, height: 20)
            let w = S.outerWidth(inner: inner.width, kind: kind, pad: pad), h = S.outerHeight(inner: inner.height, kind: kind, pad: pad)
            let r = CGRect(x: 0, y: 0, width: w, height: h)
            let box = CGRect(x: (w - inner.width) / 2, y: (h - inner.height) / 2, width: inner.width, height: inner.height)
            let path = CGMutablePath()
            path.addLines(between: S.outline(kind, in: r))
            path.closeSubpath()
            for corner in [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)] {
                check(path.contains(corner), "\(kind): Textecke \(corner) liegt im Umriss")
            }
        }
        // Umrisse: geschlossen, im Rahmen (Wolke darf die Bögen bis an den Rand wölben).
        let frame = CGRect(x: -50, y: 10, width: 200, height: 90)
        for kind in S.Kind.allCases {
            let points = S.outline(kind, in: frame)
            check(points.count >= 4, "\(kind): genug Punkte")
            check(hypot(points[0].x - points.last!.x, points[0].y - points.last!.y) < 0.01, "\(kind): geschlossen")
            let slack = frame.insetBy(dx: -1, dy: -1)
            check(points.allSatisfy { slack.contains($0) }, "\(kind): bleibt im Rahmen")
        }

        // Zone: Rand rundum, Platz für die Überschrift, nil ohne Mitglieder.
        let a = CGRect(x: 0, y: 0, width: 100, height: 40), b = CGRect(x: 150, y: 60, width: 80, height: 30)
        let zone = S.zoneFrame(around: [a, b], titled: true)!
        check(zone == CGRect(x: -16, y: -38, width: 262, height: 144), "Zone um zwei Karten mit Überschrift: \(zone)")
        check(S.zoneFrame(around: [a], titled: false)! == a.insetBy(dx: -16, dy: -16), "Zone ohne Überschrift")
        check(S.zoneFrame(around: [], titled: true) == nil, "Zone ohne Karten")

        // Pfeil-Beschriftung auf dem längsten Stück.
        let way = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 100), CGPoint(x: 30, y: 100)]
        check(S.labelAnchor(way) == CGPoint(x: 10, y: 50), "Beschriftung mittig auf dem langen Stück")
        check(S.arrowWidth("thick") == 3.5 && S.arrowWidth("THIN") == 1.2 && S.arrowWidth("dick") == nil, "Pfeilstärken")

        print("scratch-shapes: \(cases) Fälle grün")
    }
}
