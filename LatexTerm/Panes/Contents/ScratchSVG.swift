import Foundation
import CoreGraphics

/// SVG-Teilmenge → Scratchpad-Elemente (Scratchpad-Dialog, 22.09.2026). Ein Agent zeichnet am sichersten in
/// SVG; die Kachel übernimmt das aber nicht als Bild, sondern als eigene Elemente — radierbar, ⌘Z-fähig, in
/// Theme-Farben. Nur Foundation/CoreGraphics (Regressionstest `scripts/test-scratch-svg.swift`).
///
/// Unterstützt: path (M L H V C S Q T A Z, relativ und absolut), line, polyline, polygon, rect (rx/ry), circle,
/// ellipse, text/tspan; g und verschachteltes svg mit transform (matrix, translate, scale, rotate, skewX/Y);
/// stroke, fill, stroke-width, opacity, stroke-/fill-opacity, stroke-dasharray, font-size, font-weight,
/// text-anchor, dominant-baseline — als Attribut oder in `style`. `marker-start/-end` → Pfeilspitze.
/// Kurven und Bögen werden erst transformiert, dann in Weltkoordinaten zu Linienzügen abgetastet.
///
/// Koordinaten: hat das Wurzel-`svg` eine viewBox (oder width+height), wird diese in `target` eingepasst
/// (Seitenverhältnis bleibt, mittig); sonst gelten die Zahlen direkt als Weltkoordinaten.
enum ScratchSVG {
    /// Palette wie `ScratchPalette.names`: Tinte, Rot, Gelb, Grün, Cyan, Blau, Violett.
    static let ink = 0, red = 1, yellow = 2, green = 3, cyan = 4, blue = 5, violet = 6

    struct Result {
        var shapes: [ScratchShape]
        /// Was übergangen wurde (unbekannte Elemente, Farben …) — geht als Hinweis an den Agenten.
        var warnings: [String]
        /// true = viewBox wurde in `target` eingepasst.
        var fitted: Bool
        /// viewBox (bzw. 0 0 width height) des Wurzel-svg; nil = keine (Weltkoordinaten).
        var box: CGRect? = nil
    }

    struct ParseError: Error, CustomStringConvertible {
        let description: String
    }

    /// `defaultColor`: Farbe für Formen ohne stroke/fill-Angabe. `target`: Rechteck (Welt) für viewBox-Einpassung.
    static func parse(_ svg: String, defaultColor: Int, target: CGRect) throws -> Result {
        var source = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        // Markdown-Zaun, den ein Modell gern mitschickt.
        if source.hasPrefix("```") {
            source = source.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let end = source.range(of: "```", options: .backwards) { source.removeSubrange(end.lowerBound...) }
        }
        guard !source.isEmpty else { throw ParseError(description: "SVG ist leer") }
        // Einzelne Elemente ohne <svg>-Hülle sind erlaubt.
        if !source.contains("<svg") { source = "<svg>" + source + "</svg>" }
        // Benannte HTML-Entities, die XMLParser nicht kennt.
        for (entity, char) in [("&nbsp;", "\u{00A0}"), ("&middot;", "·"), ("&rarr;", "→"), ("&larr;", "←"),
                               ("&times;", "×"), ("&deg;", "°"), ("&mdash;", "—"), ("&ndash;", "–")] {
            source = source.replacingOccurrences(of: entity, with: char)
        }
        // Nacktes „&“ im Text („A & B“) ist kein gültiges XML — als Zeichen nehmen.
        source = source.replacingOccurrences(of: "&(?!(#[0-9]+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);)", with: "&amp;",
                                             options: .regularExpression)
        guard let data = source.data(using: .utf8) else { throw ParseError(description: "SVG nicht als UTF-8 lesbar") }
        let builder = Builder(defaultColor: defaultColor, target: target)
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else {
            let reason = parser.parserError.map { ($0 as NSError).localizedDescription } ?? "unbekannt"
            throw ParseError(description: "SVG ist kein gültiges XML (Zeile \(parser.lineNumber)): \(reason)")
        }
        if let error = builder.error { throw ParseError(description: error) }
        return Result(shapes: builder.shapes, warnings: builder.orderedWarnings, fitted: builder.fitted, box: builder.rootBox)
    }

    // MARK: Farben

    /// Farbe → Paletten-Index (nil = keine Farbe erkannt). Namen (englisch/deutsch) direkt, sonst nach Farbton.
    static func colorIndex(_ raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let named = namedColors[value] { return named }
        if value.hasPrefix("#") { return hexColor(String(value.dropFirst())) }
        if value.hasPrefix("rgb") {
            guard let open = value.firstIndex(of: "("), let close = value.firstIndex(of: ")"), open < close else { return nil }
            let parts = value[value.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            let numbers = parts.prefix(3).compactMap { part -> Double? in
                part.hasSuffix("%") ? Double(part.dropLast()).map { $0 * 2.55 } : Double(part)
            }
            guard numbers.count == 3 else { return nil }
            return hueIndex(r: numbers[0] / 255, g: numbers[1] / 255, b: numbers[2] / 255)
        }
        return nil
    }

    private static let namedColors: [String: Int] = {
        var map: [String: Int] = [:]
        for name in ["black", "white", "gray", "grey", "silver", "darkgray", "darkgrey", "lightgray", "lightgrey",
                     "dimgray", "dimgrey", "ink", "foreground", "tinte", "schwarz", "weiß", "weiss", "grau"] { map[name] = ink }
        for name in ["red", "darkred", "crimson", "maroon", "tomato", "firebrick", "indianred", "rot"] { map[name] = red }
        for name in ["yellow", "gold", "orange", "darkorange", "amber", "khaki", "goldenrod", "gelb"] { map[name] = yellow }
        for name in ["green", "lime", "limegreen", "darkgreen", "forestgreen", "seagreen", "olive", "olivedrab",
                     "mediumseagreen", "grün", "gruen"] { map[name] = green }
        for name in ["cyan", "aqua", "teal", "turquoise", "darkcyan", "lightseagreen", "türkis", "tuerkis"] { map[name] = cyan }
        for name in ["blue", "navy", "darkblue", "mediumblue", "royalblue", "steelblue", "dodgerblue", "cornflowerblue",
                     "skyblue", "deepskyblue", "blau"] { map[name] = blue }
        for name in ["purple", "violet", "magenta", "fuchsia", "indigo", "pink", "hotpink", "orchid", "plum",
                     "darkviolet", "mediumpurple", "violett", "lila"] { map[name] = violet }
        return map
    }()

    private static func hexColor(_ hex: String) -> Int? {
        var digits = hex
        if digits.count == 3 || digits.count == 4 { digits = String(digits.prefix(3).flatMap { [$0, $0] }) }
        guard digits.count == 6 || digits.count == 8, let value = UInt32(digits.prefix(6), radix: 16) else { return nil }
        return hueIndex(r: Double((value >> 16) & 0xFF) / 255, g: Double((value >> 8) & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }

    /// Unbunt (Grau, Schwarz, Weiß) → Tinte, sonst Farbton-Bereiche auf die sechs bunten Theme-Farben.
    static func hueIndex(r: Double, g: Double, b: Double) -> Int {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard high > 0.15, delta / high >= 0.25 else { return ink }
        var hue: Double
        if high == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        switch hue {
        case ..<30: return red
        case ..<75: return yellow
        case ..<165: return green
        case ..<195: return cyan
        case ..<255: return blue
        case ..<330: return violet
        default: return red
        }
    }
}

enum ScratchTextAnchor: Int, Codable {
    case start, middle, end
}

/// Ein übersetztes SVG-Element in Weltkoordinaten. Text: `points[0]` ist der Grundlinien-Anker.
struct ScratchShape: Equatable {
    var points: [CGPoint]
    var closed = false
    var stroke: Int?
    var fill: Int?
    var width: CGFloat = 2
    var translucent = false
    var dashed = false
    var text: String?
    var fontSize: CGFloat = 16
    var anchor: ScratchTextAnchor = .start
    var bold = false
}

// MARK: - Aufbau

private enum Paint: Equatable {
    case unset, none, color(Int)
}

private struct Style {
    var stroke: Paint = .unset
    var fill: Paint = .unset
    var strokeWidth: CGFloat?
    var opacity: CGFloat = 1
    var strokeOpacity: CGFloat = 1
    var fillOpacity: CGFloat = 1
    var dashed = false
    var fontSize: CGFloat = 16
    var bold = false
    var anchor: ScratchTextAnchor = .start
    /// Verschiebung der Grundlinie in Schriftgrößen (dominant-baseline).
    var baselineShift: CGFloat = 0
    var markerStart = false
    var markerEnd = false
    var transform: CGAffineTransform = .identity
}

private final class Builder: NSObject, XMLParserDelegate {
    let defaultColor: Int
    let target: CGRect
    var shapes: [ScratchShape] = []
    var fitted = false
    var rootBox: CGRect?
    var error: String?
    private var warnings: [String] = []
    var orderedWarnings: [String] { warnings }

    private var stack: [Style] = []
    private var skipDepth = 0
    private var sawRoot = false
    /// Laufender Text: Segmente (Position + Inhalt) mit dem Stil ihres Elements.
    private var textSegments: [(origin: CGPoint, text: String, style: Style)] = []
    private var textStyle: Style?
    private var textCursor: CGPoint = .zero
    private var elementNames: [String] = []

    /// Elemente, deren Inhalt nie gezeichnet wird.
    private static let skipped: Set<String> = ["defs", "marker", "clippath", "mask", "pattern", "symbol", "style",
                                                "title", "desc", "metadata", "lineargradient", "radialgradient", "filter"]

    init(defaultColor: Int, target: CGRect) {
        self.defaultColor = defaultColor
        self.target = target
    }

    private func warn(_ message: String) {
        if !warnings.contains(message), warnings.count < 12 { warnings.append(message) }
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let name = localName(elementName)
        elementNames.append(name)
        if skipDepth > 0 || Self.skipped.contains(name) {
            skipDepth += 1
            return
        }
        let attrs = normalized(attributes)
        let parent = stack.last ?? Style()
        var style = inherit(parent, attrs)

        if name == "svg" && !sawRoot {
            sawRoot = true
            if let fit = rootFit(attrs) { style.transform = style.transform.concatenating(fit); fitted = true }
            stack.append(style)
            return
        }
        stack.append(style)
        switch name {
        case "svg":
            // Verschachteltes svg: wie g, x/y verschieben.
            let dx = number(attrs["x"]) ?? 0, dy = number(attrs["y"]) ?? 0
            stack[stack.count - 1].transform = CGAffineTransform(translationX: dx, y: dy).concatenating(style.transform)
        case "g", "a", "switch": break
        case "path": addPath(attrs["d"] ?? "", style)
        case "line":
            let a = CGPoint(x: number(attrs["x1"]) ?? 0, y: number(attrs["y1"]) ?? 0)
            let b = CGPoint(x: number(attrs["x2"]) ?? 0, y: number(attrs["y2"]) ?? 0)
            addSubpaths([Subpath(start: a, segments: [.line(b)], closed: false)], style)
        case "polyline", "polygon":
            let values = numbers(attrs["points"] ?? "")
            let points = stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
            guard let first = points.first else { return }
            addSubpaths([Subpath(start: first, segments: points.dropFirst().map { .line($0) }, closed: name == "polygon")], style)
        case "rect": addRect(attrs, style)
        case "circle":
            let r = number(attrs["r"]) ?? 0
            addEllipse(cx: number(attrs["cx"]) ?? 0, cy: number(attrs["cy"]) ?? 0, rx: r, ry: r, style)
        case "ellipse":
            addEllipse(cx: number(attrs["cx"]) ?? 0, cy: number(attrs["cy"]) ?? 0,
                       rx: number(attrs["rx"]) ?? 0, ry: number(attrs["ry"]) ?? 0, style)
        case "text":
            textSegments = []
            textStyle = style
            textCursor = CGPoint(x: number(attrs["x"]) ?? 0, y: number(attrs["y"]) ?? 0)
            textCursor.x += number(attrs["dx"]) ?? 0
            textCursor.y += length(attrs["dy"], fontSize: style.fontSize) ?? 0
            textSegments.append((textCursor, "", style))
        case "tspan":
            guard textStyle != nil else { warn("tspan außerhalb von text übergangen"); return }
            let hasPosition = ["x", "y", "dx", "dy"].contains { attrs[$0] != nil }
            if hasPosition {
                let x = number(attrs["x"]) ?? textSegments.first?.origin.x ?? textCursor.x
                var y = number(attrs["y"]) ?? textCursor.y
                y += length(attrs["dy"], fontSize: style.fontSize) ?? 0
                textCursor = CGPoint(x: x + (number(attrs["dx"]) ?? 0), y: y)
                textSegments.append((textCursor, "", style))
            } else if let last = textSegments.last, last.text.isEmpty {
                textSegments[textSegments.count - 1].style = style
            }
        case "use": warn("<use> wird nicht unterstützt — Form direkt ausschreiben")
        case "image", "foreignobject": warn("<\(name)> wird nicht unterstützt (nur Vektorformen und Text)")
        default: warn("<\(name)> unbekannt, übergangen")
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementNames.popLast() ?? localName(elementName)
        if skipDepth > 0 { skipDepth -= 1; return }
        if name == "text" { flushText() }
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0, textStyle != nil, !textSegments.isEmpty else { return }
        textSegments[textSegments.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }

    // MARK: Stil

    private func localName(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    /// Attribute + `style="k: v; …"` in eine Tabelle (style gewinnt, wie in CSS).
    private func normalized(_ attributes: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in attributes { result[key.lowercased()] = value }
        if let style = result["style"] {
            for declaration in style.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                var value = parts[1].trimmingCharacters(in: .whitespaces)
                if value.hasSuffix("!important") { value = String(value.dropLast(10)).trimmingCharacters(in: .whitespaces) }
                result[key] = value
            }
        }
        return result
    }

    private func inherit(_ parent: Style, _ a: [String: String]) -> Style {
        var s = parent
        s.markerStart = false
        s.markerEnd = false
        if let value = a["stroke"] { s.stroke = paint(value, attribute: "stroke") }
        if let value = a["fill"] { s.fill = paint(value, attribute: "fill") }
        if let value = a["color"], let index = ScratchSVG.colorIndex(value), s.stroke == .unset { s.stroke = .color(index) }
        if let width = number(a["stroke-width"]) { s.strokeWidth = max(0, width) }
        if let value = number(a["opacity"]) { s.opacity *= clamp01(value) }
        if let value = number(a["stroke-opacity"]) { s.strokeOpacity = clamp01(value) }
        if let value = number(a["fill-opacity"]) { s.fillOpacity = clamp01(value) }
        if let dash = a["stroke-dasharray"] { s.dashed = dash.trimmingCharacters(in: .whitespaces) != "none" && !numbers(dash).allSatisfy { $0 == 0 } }
        if let size = length(a["font-size"], fontSize: parent.fontSize), size > 0 { s.fontSize = size }
        if let weight = a["font-weight"]?.lowercased() {
            s.bold = weight == "bold" || weight == "bolder" || (Double(weight) ?? 400) >= 600
        }
        if let anchor = a["text-anchor"]?.lowercased() {
            s.anchor = anchor == "middle" ? .middle : anchor == "end" ? .end : .start
        }
        if let baseline = (a["dominant-baseline"] ?? a["alignment-baseline"])?.lowercased() {
            switch baseline {
            case "middle", "central": s.baselineShift = 0.35
            case "hanging", "text-before-edge", "before-edge", "text-top": s.baselineShift = 0.8
            case "text-after-edge", "after-edge", "ideographic", "text-bottom": s.baselineShift = -0.2
            default: s.baselineShift = 0
            }
        }
        if let marker = a["marker-start"], marker != "none" { s.markerStart = true }
        if let marker = a["marker-end"], marker != "none" { s.markerEnd = true }
        if let transform = a["transform"] {
            s.transform = parseTransform(transform).concatenating(parent.transform)
        }
        return s
    }

    private func paint(_ raw: String, attribute: String) -> Paint {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if value == "none" || value == "transparent" { return .none }
        if value == "currentcolor" || value == "inherit" { return .unset }
        if value.hasPrefix("url(") {
            warn("Verläufe/Muster (\(attribute)=url(…)) gibt es nicht — Farbe direkt angeben")
            return .color(defaultColor)
        }
        if let index = ScratchSVG.colorIndex(value) { return .color(index) }
        warn("Farbe „\(raw)“ unbekannt — Standardfarbe genommen")
        return .color(defaultColor)
    }

    private func clamp01(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    /// Wurzel: viewBox (oder width+height) in `target` einpassen.
    private func rootFit(_ a: [String: String]) -> CGAffineTransform? {
        var box: CGRect?
        if let raw = a["viewbox"] {
            let v = numbers(raw)
            if v.count == 4, v[2] > 0, v[3] > 0 { box = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
        }
        if box == nil, let w = number(a["width"]), let h = number(a["height"]), w > 0, h > 0,
           !(a["width"] ?? "").contains("%"), !(a["height"] ?? "").contains("%") {
            box = CGRect(x: 0, y: 0, width: w, height: h)
        }
        rootBox = box
        guard let box, target.width > 0, target.height > 0 else { return nil }
        let scale = min(target.width / box.width, target.height / box.height)
        let dx = target.midX - box.midX * scale, dy = target.midY - box.midY * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy)
    }

    // MARK: Zahlen

    private func number(_ raw: String?) -> CGFloat? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        for unit in ["px", "pt"] where text.hasSuffix(unit) { text.removeLast(2) }
        return Double(text).map { CGFloat($0) }
    }

    private func length(_ raw: String?, fontSize: CGFloat) -> CGFloat? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasSuffix("em") { text.removeLast(2); return Double(text).map { CGFloat($0) * fontSize } }
        return number(text)
    }

    private func numbers(_ raw: String) -> [CGFloat] {
        var scanner = PathScanner(raw)
        var result: [CGFloat] = []
        while let value = scanner.number() { result.append(value) }
        return result
    }

    private func parseTransform(_ raw: String) -> CGAffineTransform {
        var result = CGAffineTransform.identity
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\n\t")).lowercased()
            let v = numbers(String(rest[rest.index(after: open)..<close]))
            var t = CGAffineTransform.identity
            switch name {
            case "matrix" where v.count == 6: t = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            case "translate" where !v.isEmpty: t = CGAffineTransform(translationX: v[0], y: v.count > 1 ? v[1] : 0)
            case "scale" where !v.isEmpty: t = CGAffineTransform(scaleX: v[0], y: v.count > 1 ? v[1] : v[0])
            case "rotate" where !v.isEmpty:
                let angle = v[0] * .pi / 180
                if v.count == 3 {
                    t = CGAffineTransform(translationX: -v[1], y: -v[2])
                        .concatenating(CGAffineTransform(rotationAngle: angle))
                        .concatenating(CGAffineTransform(translationX: v[1], y: v[2]))
                } else {
                    t = CGAffineTransform(rotationAngle: angle)
                }
            case "skewx" where !v.isEmpty: t = CGAffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy" where !v.isEmpty: t = CGAffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: warn("transform „\(name)“ nicht verstanden")
            }
            // SVG: die Liste wirkt von rechts nach links — die zuletzt genannte zuerst.
            result = t.concatenating(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }

    // MARK: Formen

    private enum Segment {
        case line(CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint)
    }

    private struct Subpath {
        var start: CGPoint
        var segments: [Segment]
        var closed: Bool
    }

    private func addRect(_ a: [String: String], _ style: Style) {
        let x = number(a["x"]) ?? 0, y = number(a["y"]) ?? 0
        let w = number(a["width"]) ?? 0, h = number(a["height"]) ?? 0
        guard w > 0, h > 0 else { return }
        var rx = number(a["rx"]), ry = number(a["ry"])
        if rx == nil { rx = ry }
        if ry == nil { ry = rx }
        let rX = min(max(rx ?? 0, 0), w / 2), rY = min(max(ry ?? 0, 0), h / 2)
        guard rX > 0, rY > 0 else {
            addSubpaths([Subpath(start: CGPoint(x: x, y: y),
                                 segments: [.line(CGPoint(x: x + w, y: y)), .line(CGPoint(x: x + w, y: y + h)),
                                            .line(CGPoint(x: x, y: y + h))], closed: true)], style)
            return
        }
        let k: CGFloat = 0.5522847498
        let (kx, ky) = (rX * k, rY * k)
        let segments: [Segment] = [
            .line(CGPoint(x: x + w - rX, y: y)),
            .cubic(CGPoint(x: x + w - rX + kx, y: y), CGPoint(x: x + w, y: y + rY - ky), CGPoint(x: x + w, y: y + rY)),
            .line(CGPoint(x: x + w, y: y + h - rY)),
            .cubic(CGPoint(x: x + w, y: y + h - rY + ky), CGPoint(x: x + w - rX + kx, y: y + h), CGPoint(x: x + w - rX, y: y + h)),
            .line(CGPoint(x: x + rX, y: y + h)),
            .cubic(CGPoint(x: x + rX - kx, y: y + h), CGPoint(x: x, y: y + h - rY + ky), CGPoint(x: x, y: y + h - rY)),
            .line(CGPoint(x: x, y: y + rY)),
            .cubic(CGPoint(x: x, y: y + rY - ky), CGPoint(x: x + rX - kx, y: y), CGPoint(x: x + rX, y: y)),
        ]
        addSubpaths([Subpath(start: CGPoint(x: x + rX, y: y), segments: segments, closed: true)], style)
    }

    private func addEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, _ style: Style) {
        guard rx > 0, ry > 0 else { return }
        let k: CGFloat = 0.5522847498
        let segments: [Segment] = [
            .cubic(CGPoint(x: cx + rx, y: cy + ry * k), CGPoint(x: cx + rx * k, y: cy + ry), CGPoint(x: cx, y: cy + ry)),
            .cubic(CGPoint(x: cx - rx * k, y: cy + ry), CGPoint(x: cx - rx, y: cy + ry * k), CGPoint(x: cx - rx, y: cy)),
            .cubic(CGPoint(x: cx - rx, y: cy - ry * k), CGPoint(x: cx - rx * k, y: cy - ry), CGPoint(x: cx, y: cy - ry)),
            .cubic(CGPoint(x: cx + rx * k, y: cy - ry), CGPoint(x: cx + rx, y: cy - ry * k), CGPoint(x: cx + rx, y: cy)),
        ]
        addSubpaths([Subpath(start: CGPoint(x: cx + rx, y: cy), segments: segments, closed: true)], style)
    }

    private func addPath(_ d: String, _ style: Style) {
        var scanner = PathScanner(d)
        var subpaths: [Subpath] = []
        var current: Subpath?
        var point = CGPoint.zero, start = CGPoint.zero
        var lastControl: CGPoint?      // für S/s
        var lastQuad: CGPoint?         // für T/t
        var command: Character?

        func finish() {
            if let path = current, !path.segments.isEmpty { subpaths.append(path) }
            current = nil
        }
        func ensure() { if current == nil { current = Subpath(start: point, segments: [], closed: false) } }
        func bail(_ d: String) {
            warn("Pfad mit unvollständigen Zahlen — bis dahin gezeichnet")
            finish()
            addSubpaths(subpaths, style)
        }

        while true {
            if let letter = scanner.command() { command = letter }
            else if scanner.atEnd { break }
            else if command == nil { warn("Pfad beginnt ohne Befehl"); break }
            guard let cmd = command else { break }
            let relative = cmd.isLowercase
            let base = relative ? point : .zero
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }

            switch cmd.uppercased().first! {
            case "M":
                guard let x = scanner.number(), let y = scanner.number() else { return bail(d) }
                finish()
                point = p(x, y); start = point
                current = Subpath(start: point, segments: [], closed: false)
                command = relative ? "l" : "L"   // weitere Paare nach M sind Linien
                lastControl = nil; lastQuad = nil
            case "L":
                guard let x = scanner.number(), let y = scanner.number() else { return bail(d) }
                ensure(); point = p(x, y); current!.segments.append(.line(point))
                lastControl = nil; lastQuad = nil
            case "H":
                guard let x = scanner.number() else { return bail(d) }
                ensure(); point = CGPoint(x: relative ? point.x + x : x, y: point.y); current!.segments.append(.line(point))
                lastControl = nil; lastQuad = nil
            case "V":
                guard let y = scanner.number() else { return bail(d) }
                ensure(); point = CGPoint(x: point.x, y: relative ? point.y + y : y); current!.segments.append(.line(point))
                lastControl = nil; lastQuad = nil
            case "C":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return bail(d) }
                ensure()
                let c1 = p(x1, y1), c2 = p(x2, y2), end = p(x, y)
                current!.segments.append(.cubic(c1, c2, end))
                point = end; lastControl = c2; lastQuad = nil
            case "S":
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(),
                      let y = scanner.number() else { return bail(d) }
                ensure()
                let c1 = lastControl.map { CGPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point
                let c2 = p(x2, y2), end = p(x, y)
                current!.segments.append(.cubic(c1, c2, end))
                point = end; lastControl = c2; lastQuad = nil
            case "Q":
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(),
                      let y = scanner.number() else { return bail(d) }
                ensure()
                let q = p(x1, y1), end = p(x, y)
                current!.segments.append(quadratic(from: point, q, end))
                point = end; lastQuad = q; lastControl = nil
            case "T":
                guard let x = scanner.number(), let y = scanner.number() else { return bail(d) }
                ensure()
                let q = lastQuad.map { CGPoint(x: 2 * point.x - $0.x, y: 2 * point.y - $0.y) } ?? point
                let end = p(x, y)
                current!.segments.append(quadratic(from: point, q, end))
                point = end; lastQuad = q; lastControl = nil
            case "A":
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return bail(d) }
                ensure()
                let end = p(x, y)
                current!.segments += arc(from: point, to: end, rx: rx, ry: ry, rotation: rotation, large: large, sweep: sweep)
                point = end; lastControl = nil; lastQuad = nil
            case "Z":
                if current != nil {
                    current!.closed = true
                    finish()
                }
                point = start
                command = nil   // nach Z muss ein neuer Befehl folgen (oder das Ende)
                lastControl = nil; lastQuad = nil
            default:
                warn("Pfadbefehl „\(cmd)“ unbekannt")
                finish()
                addSubpaths(subpaths, style)
                return
            }
        }
        finish()
        addSubpaths(subpaths, style)
    }

    private func quadratic(from p0: CGPoint, _ q: CGPoint, _ p1: CGPoint) -> Segment {
        .cubic(CGPoint(x: p0.x + 2 / 3 * (q.x - p0.x), y: p0.y + 2 / 3 * (q.y - p0.y)),
               CGPoint(x: p1.x + 2 / 3 * (q.x - p1.x), y: p1.y + 2 / 3 * (q.y - p1.y)), p1)
    }

    /// SVG-Bogen (Endpunkt-Form, Anhang F.6 der Spezifikation) → kubische Stücke à max. 90°.
    private func arc(from p0: CGPoint, to p1: CGPoint, rx rawRX: CGFloat, ry rawRY: CGFloat, rotation: CGFloat,
                     large: Bool, sweep: Bool) -> [Segment] {
        var rx = abs(rawRX), ry = abs(rawRY)
        guard p0 != p1 else { return [] }
        guard rx > 0, ry > 0 else { return [.line(p1)] }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy, len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }
        let pieces = max(1, Int(ceil(abs(delta) / (.pi / 2) - 0.001)))
        let step = delta / CGFloat(pieces)
        let t = 4 / 3 * tan(step / 4)
        func onEllipse(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi, y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi, y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
        }
        var segments: [Segment] = []
        var a = theta1
        for i in 0..<pieces {
            let b = a + step
            let pA = onEllipse(a), dA = derivative(a), dB = derivative(b)
            let pB = i == pieces - 1 ? p1 : onEllipse(b)
            segments.append(.cubic(CGPoint(x: pA.x + t * dA.x, y: pA.y + t * dA.y),
                                   CGPoint(x: pB.x - t * dB.x, y: pB.y - t * dB.y), pB))
            a = b
        }
        return segments
    }

    // MARK: In Weltkoordinaten abtasten

    /// Farben nach SVG-Regeln mit Scratchpad-Default: ohne stroke UND fill zeichnet die Form eine Linie in der
    /// Standardfarbe (statt schwarz gefüllt wie im Browser — Agenten meinen fast immer Linien).
    private func resolvedPaint(_ style: Style) -> (stroke: Int?, fill: Int?) {
        var stroke: Int?, fill: Int?
        switch style.stroke {
        case .color(let c): stroke = c
        case .none: stroke = nil
        case .unset: stroke = nil
        }
        switch style.fill {
        case .color(let c): fill = c
        case .none: fill = nil
        case .unset: fill = style.stroke == .none ? defaultColor : nil
        }
        if style.stroke == .unset, fill == nil { stroke = defaultColor }
        return (stroke, fill)
    }

    private func addSubpaths(_ subpaths: [Subpath], _ style: Style) {
        guard !subpaths.isEmpty else { return }
        let ctm = style.transform
        let scale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        let (stroke, fill) = resolvedPaint(style)
        let width = max(0.5, (style.strokeWidth ?? 2) * (scale > 0 ? scale : 1))
        for sub in subpaths {
            var points = flatten(sub, ctm)
            guard points.count >= 2 else { continue }
            if sub.closed, let first = points.first, points.last != first { points.append(first) }
            if let fill {
                shapes.append(ScratchShape(points: points, closed: true, stroke: nil, fill: fill, width: width,
                                           translucent: style.opacity * style.fillOpacity < 0.75))
            }
            guard let stroke else { continue }
            var line = points
            var heads: [ScratchShape] = []
            let head = max(8, width * 4)
            if style.markerEnd, !sub.closed, let (tip, base) = arrow(line, reversed: false, length: head) {
                heads.append(arrowHead(tip: tip, base: base, length: head, color: stroke, width: width, style: style))
                line[line.count - 1] = base
            }
            if style.markerStart, !sub.closed, let (tip, base) = arrow(line, reversed: true, length: head) {
                heads.append(arrowHead(tip: tip, base: base, length: head, color: stroke, width: width, style: style))
                line[0] = base
            }
            shapes.append(ScratchShape(points: line, closed: sub.closed, stroke: stroke, fill: nil, width: width,
                                       translucent: style.opacity * style.strokeOpacity < 0.75, dashed: style.dashed))
            shapes += heads
        }
    }

    /// Spitze und Basis-Mitte einer Pfeilspitze am Ende (oder Anfang) eines Linienzugs; die Richtung kommt vom
    /// ersten Punkt, der weiter als die halbe Spitzenlänge zurückliegt (winzige Endstücke verfälschen sie sonst).
    private func arrow(_ points: [CGPoint], reversed: Bool, length: CGFloat) -> (CGPoint, CGPoint)? {
        let ordered = reversed ? Array(points.reversed()) : points
        guard let tip = ordered.last else { return nil }
        var from: CGPoint?
        for p in ordered.dropLast().reversed() where hypot(tip.x - p.x, tip.y - p.y) >= length / 2 { from = p; break }
        guard let from = from ?? ordered.dropLast().first(where: { $0 != tip }) else { return nil }
        let d = hypot(tip.x - from.x, tip.y - from.y)
        guard d > 0 else { return nil }
        let ux = (tip.x - from.x) / d, uy = (tip.y - from.y) / d
        let back = min(length * 0.8, d)
        return (tip, CGPoint(x: tip.x - ux * back, y: tip.y - uy * back))
    }

    private func arrowHead(tip: CGPoint, base: CGPoint, length: CGFloat, color: Int, width: CGFloat, style: Style) -> ScratchShape {
        let d = max(hypot(tip.x - base.x, tip.y - base.y), 0.001)
        let ux = (tip.x - base.x) / d, uy = (tip.y - base.y) / d
        let back = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
        let half = length * 0.42
        let left = CGPoint(x: back.x - uy * half, y: back.y + ux * half)
        let right = CGPoint(x: back.x + uy * half, y: back.y - ux * half)
        return ScratchShape(points: [tip, left, right, tip], closed: true, stroke: nil, fill: color, width: width,
                            translucent: style.opacity * style.strokeOpacity < 0.75)
    }

    /// Kontrollpunkte transformieren (affin erhält Bézier-Kurven), dann in Weltkoordinaten abtasten: ~1 Punkt je 2 Einheiten.
    private func flatten(_ sub: Subpath, _ ctm: CGAffineTransform) -> [CGPoint] {
        var current = sub.start.applying(ctm)
        var points = [current]
        for segment in sub.segments {
            switch segment {
            case .line(let p):
                current = p.applying(ctm)
                points.append(current)
            case .cubic(let c1, let c2, let p):
                let a = current, b = c1.applying(ctm), c = c2.applying(ctm), d = p.applying(ctm)
                let span = hypot(b.x - a.x, b.y - a.y) + hypot(c.x - b.x, c.y - b.y) + hypot(d.x - c.x, d.y - c.y)
                let steps = min(400, max(2, Int(ceil(span / 2))))
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    let x = u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x
                    let y = u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
                    points.append(CGPoint(x: x, y: y))
                }
                current = d
            }
        }
        // Doppelte Punkte hintereinander raus (Radierer und Glättung mögen sie nicht).
        var cleaned: [CGPoint] = []
        for p in points where cleaned.last.map({ hypot($0.x - p.x, $0.y - p.y) > 0.01 }) ?? true { cleaned.append(p) }
        return cleaned
    }

    // MARK: Text

    private func flushText() {
        defer { textSegments = []; textStyle = nil }
        for segment in textSegments {
            let content = segment.text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            let style = segment.style
            let ctm = style.transform
            let scale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
            let size = style.fontSize * (scale > 0 ? scale : 1)
            let anchor = CGPoint(x: segment.origin.x, y: segment.origin.y + style.baselineShift * style.fontSize).applying(ctm)
            if abs(ctm.b) > 0.01 || abs(ctm.c) > 0.01 { warn("gedrehter Text wird waagerecht gesetzt") }
            let paint = resolvedTextColor(style)
            shapes.append(ScratchShape(points: [anchor], stroke: paint, fill: nil, width: 0,
                                       translucent: style.opacity < 0.75, text: content, fontSize: max(4, size),
                                       anchor: style.anchor, bold: style.bold))
        }
    }

    private func resolvedTextColor(_ style: Style) -> Int {
        if case .color(let c) = style.fill { return c }
        if case .color(let c) = style.stroke { return c }
        return defaultColor
    }
}

/// Zahlen und Befehle in SVG-Pfaden und Listen: „10-5.5e2.3“, „M0,0L10 10“, Bogen-Flags ohne Trenner („a1 1 0 00 1 1“).
private struct PathScanner {
    private let chars: [Character]
    private var index = 0

    init(_ text: String) { chars = Array(text) }

    var atEnd: Bool {
        mutating get { skipSeparators(); return index >= chars.count }
    }

    private mutating func skipSeparators() {
        while index < chars.count, chars[index].isWhitespace || chars[index] == "," { index += 1 }
    }

    mutating func command() -> Character? {
        skipSeparators()
        guard index < chars.count else { return nil }
        let c = chars[index]
        guard c.isLetter, c != "e", c != "E" else { return nil }
        index += 1
        return c
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < chars.count, chars[index] == "0" || chars[index] == "1" else { return nil }
        defer { index += 1 }
        return chars[index] == "1"
    }

    mutating func number() -> CGFloat? {
        skipSeparators()
        let begin = index
        var i = index
        if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
        var digits = 0, sawDot = false
        while i < chars.count {
            if chars[i].isASCII, chars[i].isNumber { digits += 1; i += 1 }
            else if chars[i] == ".", !sawDot { sawDot = true; i += 1 }
            else { break }
        }
        guard digits > 0 else { index = begin; return nil }
        if i < chars.count, chars[i] == "e" || chars[i] == "E" {
            var j = i + 1
            if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
            var expDigits = 0
            while j < chars.count, chars[j].isASCII, chars[j].isNumber { expDigits += 1; j += 1 }
            if expDigits > 0 { i = j }
        }
        index = i
        return Double(String(chars[begin..<i])).map { CGFloat($0) }
    }
}
