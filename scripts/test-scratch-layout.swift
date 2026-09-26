import Foundation
import CoreGraphics

/// Pinnwand-Geometrie für Agenten: Orte (absolut/relativ), Überdecken, Pfeilwege an Kanten um Karten herum.
@main
struct ScratchLayoutTests {
    typealias L = ScratchLayout

    static func main() {
        let k1 = CGRect(x: 0, y: 0, width: 300, height: 60)
        let size = CGSize(width: 300, height: 40)

        // Ort: ohne alles → Fehler; absolut; relativ mit Default-Abstand; Achse überschreiben; Bezug fehlt → Fehler.
        assert((try? L.origin(L.Placement(), size: size, refRect: nil)) == nil)
        assert((try? L.origin(L.Placement(x: 5), size: size, refRect: nil)) == nil)
        assert(try! L.origin(L.Placement(x: 5, y: 7), size: size, refRect: nil) == CGPoint(x: 5, y: 7))
        assert(try! L.origin(L.Placement(relation: .below, ref: "k1"), size: size, refRect: k1) == CGPoint(x: 0, y: 76))
        assert(try! L.origin(L.Placement(relation: .above, ref: "k1", gap: 10), size: size, refRect: k1) == CGPoint(x: 0, y: -50))
        assert(try! L.origin(L.Placement(relation: .rightOf, ref: "k1"), size: size, refRect: k1) == CGPoint(x: 316, y: 0))
        assert(try! L.origin(L.Placement(relation: .leftOf, ref: "k1", gap: 20), size: size, refRect: k1) == CGPoint(x: -320, y: 0))
        assert(try! L.origin(L.Placement(x: 40, relation: .below, ref: "k1"), size: size, refRect: k1) == CGPoint(x: 40, y: 76))
        assert((try? L.origin(L.Placement(relation: .below, ref: "k9"), size: size, refRect: nil)) == nil)

        // Überdecken: Rechteck mit Luft; Linienzug nur, wenn er wirklich durchläuft (nicht nur die Box).
        let card = L.Obstacle(name: "k1", rect: k1)
        assert(L.overlaps(CGRect(x: 0, y: 62, width: 100, height: 20), [card]) == ["k1"], "2 pt Luft ist zu wenig")
        assert(L.overlaps(CGRect(x: 0, y: 76, width: 100, height: 20), [card]).isEmpty)
        let diagonal = L.Obstacle(name: "Skizze", rect: CGRect(x: 0, y: 0, width: 400, height: 400),
                                  line: [CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 400)], reach: 1)
        assert(L.overlaps(CGRect(x: 300, y: 0, width: 80, height: 40), [diagonal]).isEmpty, "Box der Skizze, aber nicht der Strich")
        assert(L.overlaps(CGRect(x: 180, y: 180, width: 40, height: 40), [diagonal]) == ["Skizze"])

        // Strecke/Rechteck.
        assert(L.segment(CGPoint(x: -10, y: 30), CGPoint(x: 310, y: 30), hits: k1))
        assert(!L.segment(CGPoint(x: -10, y: 70), CGPoint(x: 310, y: 70), hits: k1))

        // Pfeil nebeneinander, gleiche Höhe: gerade von rechter zu linker Kante.
        let a = CGRect(x: 0, y: 0, width: 200, height: 40), b = CGRect(x: 300, y: 0, width: 200, height: 40)
        var r = L.route(from: a, to: b, obstacles: [.init(name: "a", rect: a), .init(name: "b", rect: b)], fromName: "a", toName: "b")
        assert(r.points == [CGPoint(x: 206, y: 20), CGPoint(x: 294, y: 20)], "\(r.points)")
        assert(r.hits.isEmpty)

        // Untereinander: bottom → top, gerade.
        let c = CGRect(x: 0, y: 100, width: 200, height: 40)
        r = L.route(from: a, to: c, obstacles: [.init(name: "a", rect: a), .init(name: "c", rect: c)], fromName: "a", toName: "c")
        assert(r.points == [CGPoint(x: 100, y: 46), CGPoint(x: 100, y: 94)], "\(r.points)")

        // Spalte: Pfeil von k1 zu k3 darf nicht durch k2 dazwischen — läuft außen herum, rechtwinklig.
        let s1 = CGRect(x: 0, y: 0, width: 200, height: 40), s2 = CGRect(x: 0, y: 60, width: 200, height: 40),
            s3 = CGRect(x: 0, y: 120, width: 200, height: 40)
        let column: [L.Obstacle] = [.init(name: "k1", rect: s1), .init(name: "k2", rect: s2), .init(name: "k3", rect: s3)]
        r = L.route(from: s1, to: s3, obstacles: column, fromName: "k1", toName: "k3")
        assert(r.hits.isEmpty, "\(r)")
        assert(zip(r.points, r.points.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y }, "rechtwinklig: \(r.points)")
        // Mit festen Kanten bottom→top geht es nur durch k2 — gemeldet.
        r = L.route(from: s1, to: s3, fromSide: .bottom, toSide: .top, obstacles: column, fromName: "k1", toName: "k3")
        assert(r.hits == ["k2"], "\(r)")

        // via: feste Zwischenpunkte werden genommen.
        r = L.route(from: a, to: b, fromSide: .top, toSide: .top, via: [CGPoint(x: 100, y: -40), CGPoint(x: 400, y: -40)],
                    obstacles: [], fromName: "a", toName: "b")
        assert(r.points == [CGPoint(x: 100, y: -6), CGPoint(x: 100, y: -40), CGPoint(x: 400, y: -40), CGPoint(x: 400, y: -6)], "\(r.points)")

        // Live-Befund 25.09.: drei Pfeile im selben Kanal zwischen zwei Spalten verschmolzen. Jetzt weicht jeder
        // folgende Pfeil den liegenden aus (anderer Kanal oder außen herum).
        func box(_ n: String, _ x: CGFloat, _ y: CGFloat, _ h: CGFloat) -> L.Obstacle { .init(name: n, rect: CGRect(x: x, y: y, width: 280, height: h)) }
        let board = [box("b1", -300, -340, 50), box("b2", -300, -274, 33), box("b3", -300, -225, 33),
                     box("r1", 20, -340, 50), box("r2", 20, -274, 33), box("r3", 20, -225, 33),
                     box("o1", -300, -144, 50), box("o2", -300, -78, 33), box("o3", 20, -144, 33)]
        func rectOf(_ n: String) -> CGRect { board.first { $0.name == n }!.rect }
        var laid: [[CGPoint]] = []
        // Gleicher Start (Gabel an der Kante) ist erlaubt, lange parallele Stücke nicht.
        for (from, to) in [("o1", "b1"), ("o1", "r1"), ("o2", "r3")] {
            let way = L.route(from: rectOf(from), to: rectOf(to), obstacles: board, fromName: from, toName: to, others: laid)
            assert(way.hits.isEmpty, "\(from)→\(to): \(way)")
            for other in laid { assert(L.sharedLength(way.points, other) < 20, "\(from)→\(to) liegt auf einem anderen Pfeil: \(way.points) / \(other)") }
            laid.append(way.points)
        }

        // Absturz 25.09. 22:07: Anker < 0,5 pt beieinander schrumpften den Weg auf einen Punkt. Jetzt immer ≥ 2 Punkte,
        // mindestens minLength lang — auch bei deckungsgleichen oder sich überlappenden Karten.
        for dx in stride(from: CGFloat(205), through: 220, by: 0.1) {
            for dy in [CGFloat(0), 0.2, 0.49] {
                let other = CGRect(x: dx, y: dy, width: 200, height: 40)
                let way = L.route(from: a, to: other, obstacles: [], fromName: "a", toName: "b")
                assert(way.points.count >= 2 && L.length(way.points) >= L.minLength, "dx \(dx) dy \(dy): \(way.points)")
                assert(L.head(way.points).count == 3)
            }
        }
        for other in [a, a.offsetBy(dx: 3, dy: 2), CGRect(x: 90, y: 10, width: 20, height: 10)] {
            let way = L.route(from: a, to: other, obstacles: [], fromName: "a", toName: "b")
            assert(way.points.count >= 2 && L.length(way.points) >= L.minLength, "\(other): \(way.points)")
        }

        // Vereinfachen: Doppelte und Kollineare weg.
        assert(L.simplify([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 0)])
               == [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])

        // Spitze am Ende, zeigt entlang des letzten Stücks.
        let head = L.head([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        assert(head.count == 3 && head[1] == CGPoint(x: 100, y: 0) && head[0].x < 100 && head[2].x < 100)

        print("scratch-layout: ok")
    }
}
