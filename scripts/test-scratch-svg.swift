import Foundation
import CoreGraphics

/// SVG-Übersetzer des Scratchpads: Formen, Farben, Transformationen, Einpassen, Pfeile, Text, Fehler.
@main
struct ScratchSVGTests {
    static let world = CGRect(x: -400, y: -300, width: 800, height: 600)

    static func parse(_ svg: String) -> ScratchSVG.Result {
        do { return try ScratchSVG.parse(svg, defaultColor: ScratchSVG.cyan, target: world) }
        catch { fatalError("parse failed: \(error) for \(svg)") }
    }

    static func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    static func main() {
        // Linie ohne Farbe: Weltkoordinaten, Standardfarbe als Linie, Standardbreite 2.
        var r = parse(##"<line x1="-10" y1="0" x2="10" y2="0"/>"##)
        assert(r.shapes.count == 1 && !r.fitted)
        assert(r.shapes[0].stroke == ScratchSVG.cyan && r.shapes[0].fill == nil && r.shapes[0].width == 2)
        assert(near(r.shapes[0].points.first!, CGPoint(x: -10, y: 0)) && near(r.shapes[0].points.last!, CGPoint(x: 10, y: 0)))

        // Rechteck mit Füllung und Kontur: zwei Elemente (Fläche, dann Linie), geschlossen.
        r = parse(##"<svg><rect x="0" y="0" width="100" height="50" fill="#ff0000" stroke="blue" stroke-width="3"/></svg>"##)
        assert(r.shapes.count == 2)
        assert(r.shapes[0].fill == ScratchSVG.red && r.shapes[0].stroke == nil && r.shapes[0].closed)
        assert(r.shapes[1].stroke == ScratchSVG.blue && r.shapes[1].width == 3)
        assert(r.shapes[1].points.count == 5 && near(r.shapes[1].points.first!, r.shapes[1].points.last!))

        // Nur fill → keine Linie; stroke="none" ohne fill → gefüllt in Standardfarbe.
        r = parse(##"<circle cx="0" cy="0" r="20" fill="green"/>"##)
        assert(r.shapes.count == 1 && r.shapes[0].fill == ScratchSVG.green)
        r = parse(##"<circle cx="0" cy="0" r="20" stroke="none"/>"##)
        assert(r.shapes.count == 1 && r.shapes[0].fill == ScratchSVG.cyan)

        // Kreis wird fein abgetastet und bleibt auf dem Radius.
        r = parse(##"<circle cx="5" cy="5" r="50" stroke="red"/>"##)
        let circle = r.shapes[0].points
        assert(circle.count > 60)
        assert(circle.allSatisfy { abs(hypot($0.x - 5, $0.y - 5) - 50) < 0.2 })

        // viewBox wird eingepasst: 0 0 100 100 → 600×600 mittig in 800×600.
        r = parse(##"<svg viewBox="0 0 100 100"><line x1="0" y1="0" x2="100" y2="100" stroke-width="1"/></svg>"##)
        assert(r.fitted)
        assert(near(r.shapes[0].points.first!, CGPoint(x: -300, y: -300)))
        assert(near(r.shapes[0].points.last!, CGPoint(x: 300, y: 300)))
        assert(abs(r.shapes[0].width - 6) < 0.001)
        // width/height ohne viewBox zählt wie eine viewBox.
        r = parse(##"<svg width="800" height="600"><line x1="0" y1="0" x2="800" y2="600"/></svg>"##)
        assert(r.fitted && near(r.shapes[0].points.first!, CGPoint(x: -400, y: -300)))

        // Transformationen: translate, scale, rotate um Punkt, verschachtelt, von rechts nach links.
        r = parse(##"<g transform="translate(100,0)"><line x1="0" y1="0" x2="10" y2="0" transform="scale(2)"/></g>"##)
        assert(near(r.shapes[0].points.last!, CGPoint(x: 120, y: 0)) && abs(r.shapes[0].width - 4) < 0.001)
        r = parse(##"<line x1="10" y1="0" x2="20" y2="0" transform="rotate(90 10 0)"/>"##)
        assert(near(r.shapes[0].points.first!, CGPoint(x: 10, y: 0)) && near(r.shapes[0].points.last!, CGPoint(x: 10, y: 10)))
        r = parse(##"<line x1="0" y1="0" x2="1" y2="0" transform="translate(5 5) scale(10)"/>"##)
        assert(near(r.shapes[0].points.last!, CGPoint(x: 15, y: 5)))

        // Pfad: relative Befehle, implizite Wiederholung, H/V, Z schließt, mehrere Teilpfade.
        r = parse(##"<path d="M0 0 h10 v10 h-10 z m20 0 l5 5 5 -5"/>"##)
        assert(r.shapes.count == 2)
        assert(r.shapes[0].closed && r.shapes[0].points.count == 5)
        assert(near(r.shapes[1].points.first!, CGPoint(x: 20, y: 0)) && near(r.shapes[1].points.last!, CGPoint(x: 30, y: 0)))
        // Kompakte Zahlen: „10-5.5.5“ = 10, -5.5, .5; Exponent.
        r = parse(##"<path d="M0,0L10-5.5.5 1e1"/>"##)
        assert(near(r.shapes[0].points[1], CGPoint(x: 10, y: -5.5)) && near(r.shapes[0].points[2], CGPoint(x: 0.5, y: 10)))

        // Kubisch/quadratisch endet exakt, S spiegelt den Kontrollpunkt.
        r = parse(##"<path d="M0 0 C 0 50 100 50 100 0 S 200 -50 200 0 Q 250 50 300 0 T 400 0"/>"##)
        assert(near(r.shapes[0].points.last!, CGPoint(x: 400, y: 0)))
        let curve = bounds(r.shapes[0].points)
        assert(curve.maxY > 36 && curve.maxY < 38.5, "Scheitel der ersten Kurve bei 37.5, war \(curve.maxY)")

        // Bogen: Halbkreis von (0,0) nach (100,0), Radius 50, Flags ohne Trenner.
        r = parse(##"<path d="M0 0 A50 50 0 01100 0"/>"##)
        let arc = r.shapes[0].points
        assert(near(arc.last!, CGPoint(x: 100, y: 0)))
        assert(arc.allSatisfy { abs(hypot($0.x - 50, $0.y) - 50) < 0.3 })
        assert(bounds(arc).minY < -49, "sweep=1 läuft in SVG-Koordinaten nach oben (y negativ)")
        // Zu kleiner Radius wird hochskaliert, Radius 0 = Linie.
        r = parse(##"<path d="M0 0 A1 1 0 0 1 100 0 M0 10 A0 5 0 0 1 10 10"/>"##)
        assert(r.shapes.count == 2 && near(r.shapes[0].points.last!, CGPoint(x: 100, y: 0)) && r.shapes[1].points.count == 2)

        // Polyline/Polygon.
        r = parse(##"<polygon points="0,0 10,0 10,10"/><polyline points="0 20 10 20 10 30"/>"##)
        assert(r.shapes.count == 2 && r.shapes[0].closed && r.shapes[0].points.count == 4 && !r.shapes[1].closed)

        // Abgerundetes Rechteck bleibt im Rechteck.
        r = parse(##"<rect x="0" y="0" width="100" height="40" rx="10"/>"##)
        let rounded = bounds(r.shapes[0].points)
        assert(abs(rounded.minX) < 0.01 && abs(rounded.maxX - 100) < 0.01 && abs(rounded.maxY - 40) < 0.01)

        // Pfeilspitze: marker-end → Linie verkürzt, gefülltes Dreieck mit Spitze am Ende, gleiche Farbe.
        r = parse(##"<defs><marker id="a"><path d="M0 0 L10 5 L0 10z"/></marker></defs><line x1="0" y1="0" x2="100" y2="0" stroke="red" stroke-width="2" marker-end="url(#a)"/>"##)
        assert(r.shapes.count == 2, "marker-Inhalt selbst wird nicht gezeichnet")
        assert(r.shapes[0].points.last!.x < 100 && r.shapes[0].points.last!.x > 85)
        assert(r.shapes[1].fill == ScratchSVG.red && r.shapes[1].closed && near(r.shapes[1].points[0], CGPoint(x: 100, y: 0)))
        r = parse(##"<path d="M0 0 L0 100" marker-start="url(#a)" marker-end="url(#a)"/>"##)
        assert(r.shapes.count == 3)

        // Stil über style-Attribut, Vererbung aus g, Deckkraft, Strichelung.
        r = parse(##"<g style="stroke: #00ff00; stroke-width: 4"><line x1="0" y1="0" x2="1" y2="1" style="opacity:0.4; stroke-dasharray: 4 2"/></g>"##)
        assert(r.shapes[0].stroke == ScratchSVG.green && r.shapes[0].width == 4 && r.shapes[0].translucent && r.shapes[0].dashed)

        // Farben: Namen, deutsch, Hex kurz/lang, rgb(), Grautöne → Tinte, Unbekanntes → Standard + Hinweis.
        assert(ScratchSVG.colorIndex("Rot") == ScratchSVG.red)
        assert(ScratchSVG.colorIndex("#00f") == ScratchSVG.blue)
        assert(ScratchSVG.colorIndex("#ffa500") == ScratchSVG.yellow)
        assert(ScratchSVG.colorIndex("rgb(128, 0, 128)") == ScratchSVG.violet)
        assert(ScratchSVG.colorIndex("#808080") == ScratchSVG.ink)
        assert(ScratchSVG.colorIndex("#111") == ScratchSVG.ink)
        assert(ScratchSVG.colorIndex("#00ced1") == ScratchSVG.cyan)
        r = parse(##"<line x1="0" y1="0" x2="1" y2="1" stroke="banana"/>"##)
        assert(r.shapes[0].stroke == ScratchSVG.cyan && !r.warnings.isEmpty)

        // Text: Anker, Größe, fett, Farbe aus fill, Grundlinie mittig, tspan-Zeilen, Entities, nacktes &.
        r = parse(##"<text x="10" y="20" font-size="12" text-anchor="middle" font-weight="bold" fill="red">Regler &amp; Strecke</text>"##)
        assert(r.shapes.count == 1)
        let label = r.shapes[0]
        assert(label.text == "Regler & Strecke" && label.fontSize == 12 && label.anchor == .middle && label.bold)
        assert(label.stroke == ScratchSVG.red && near(label.points[0], CGPoint(x: 10, y: 20)))
        r = parse(##"<text x="0" y="0" font-size="10" dominant-baseline="middle">A &rarr; B & C</text>"##)
        assert(r.shapes[0].text == "A → B & C" && near(r.shapes[0].points[0], CGPoint(x: 0, y: 3.5)))
        r = parse(##"<text x="5" y="10" font-size="10"><tspan>Zeile 1</tspan><tspan x="5" dy="1.5em">Zeile 2</tspan></text>"##)
        assert(r.shapes.count == 2 && r.shapes[1].text == "Zeile 2" && near(r.shapes[1].points[0], CGPoint(x: 5, y: 25)))
        r = parse(##"<svg viewBox="0 0 100 100"><text x="50" y="50" font-size="10">x</text></svg>"##)
        assert(abs(r.shapes[0].fontSize - 60) < 0.001 && near(r.shapes[0].points[0], .zero))

        // Übergangenes: title/desc nicht als Text, unbekannte Elemente als Hinweis, Markdown-Zaun.
        r = parse("```svg\n<svg><title>Titel</title><foo/><line x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\"/></svg>\n```")
        assert(r.shapes.count == 1 && r.warnings.contains { $0.contains("foo") })

        // Kaputtes XML und leere Eingabe werfen mit Grund.
        do { _ = try ScratchSVG.parse("<svg><line></svg>", defaultColor: 4, target: world); assertionFailure("sollte werfen") }
        catch { assert("\(error)".contains("XML")) }
        do { _ = try ScratchSVG.parse("   ", defaultColor: 4, target: world); assertionFailure("sollte werfen") }
        catch { assert("\(error)".contains("leer")) }

        print("scratch-svg: ok")
    }
}
