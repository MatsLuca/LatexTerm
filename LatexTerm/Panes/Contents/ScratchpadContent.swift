import AppKit
import UniformTypeIdentifiers

/// Malfläche (Kachel-Protokoll, Schritt 6; ausgebaut 22.09.): Stift, Marker, Radierer, sieben Farben aus dem
/// Theme, drei Stärken, ⌘Z/⇧⌘Z, ⌘S sichert als PNG, ⌘C kopiert als Bild. Die Zeichnung wird bei jeder
/// Änderung unter `Application Support/LatexTerm/scratchpads/<id>.json` gesichert und kommt nach ⌥⌘R
/// wieder; ⌘W schließt die Kachel samt Zeichnung.
///
/// Dialog mit Agenten (22.09. abends, Plan claude-werkstatt `plans/scratchpad-dialog_2026-09-22.md`):
/// ➤ bzw. ⇧⌘⏎ fügt die Skizze als Bildpfad in eine Claude-/Codex-Kachel ein (die des Öffners direkt, sonst
/// Auswahl; ⌥ erzwingt die Auswahl). Agenten sehen die Fläche per `call look` und zeichnen per `call draw`
/// (SVG → eigene Elemente mit `author = claude`, `ScratchSVG.swift`).
final class ScratchpadContent: PaneContent {
    static let kind = "scratchpad"
    static let displayName = "Neues Scratchpad"
    static let manual = PaneKindManual(
        summary: "Gemeinsame Malfläche: der Nutzer skizziert mit Maus/Trackpad und schickt dir die Skizze per ➤ als Bild; "
            + "du siehst sie mit scratch_look (Bild mit Koordinatenraster) und zeichnest mit scratch_draw (SVG) sauber hinein "
            + "— eigene Ebene in Cyan, ⌘Z nimmt deinen Beitrag als einen Schritt zurück. Bleibt über einen Neustart erhalten.",
        actions: [PaneKindAction(name: "clear", summary: "Fläche leeren (rückgängig machbar)"),
                  PaneKindAction(name: "clear claude", summary: "nur deine Elemente entfernen"),
                  PaneKindAction(name: "clear mats", summary: "nur die Striche des Nutzers entfernen"),
                  PaneKindAction(name: "undo", summary: "letzten Schritt zurücknehmen"),
                  PaneKindAction(name: "redo", summary: "zurückgenommenen Schritt wiederholen"),
                  PaneKindAction(name: "save <pfad>", summary: "Zeichnung als PNG an einen absoluten Pfad schreiben (zugeschnitten)")])

    weak var delegate: PaneContentDelegate?
    private let id: UUID
    private let root = ScratchpadView()

    /// `id` kommt nur aus dem Snapshot (Restore); neue Kacheln bekommen eine frische.
    init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, allowed: ["id"], kind: Self.kind)
        if let raw = args["id"] {
            guard let id = UUID(uuidString: raw) else { throw PaneArgsError("scratchpad: ungültige id „\(raw)“") }
            self.id = id
        } else {
            id = UUID()
        }
        Self.pruneOrphans()
        if let doc = Self.load(from: file) { root.canvas.restore(doc) }
        root.canvas.onChange = { [weak self] in self?.canvasChanged() }
        root.canvas.onSaveRequest = { [weak self] in self?.runSavePanel() }
        root.canvas.onSendRequest = { [weak self] choose in self?.sendToAgent(choose: choose) }
        root.onSend = { [weak self] choose in self?.sendToAgent(choose: choose) }
    }

    var view: NSView { root }
    var keyView: NSView { root.canvas }
    var title: String { "Scratchpad" }
    var chip: StatusChip? {
        let canvas = root.canvas
        let (mine, claude) = (canvas.count(.mats), canvas.count(.claude))
        var parts = [canvas.tool.label, ScratchPalette.names[canvas.colorIndex], mine == 1 ? "1 Strich" : "\(mine) Striche"]
        if claude > 0 { parts.append("\(claude) von Claude") }
        return StatusChip(tone: canvas.inkColor, tooltip: parts.joined(separator: " · "))
    }
    var closeGuard: CloseGuard {
        let count = root.canvas.strokeCount
        return count == 0 ? .free : .busy("hat eine Zeichnung (\(count == 1 ? "1 Element" : "\(count) Elemente"))")
    }

    func applyTheme(_ theme: TerminalTheme) {
        root.apply(theme)
        delegate?.contentStyleChanged()
    }

    func receive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let layer = Self.clearLayer(trimmed) { root.canvas.clear(layer); return true }
        switch trimmed {
        case "undo": root.canvas.undo(); return true
        case "redo": root.canvas.redo(); return true
        default: break
        }
        guard trimmed.hasPrefix("save ") else { return false }
        let path = (String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), let png = root.canvas.pngData() else { return false }
        do {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// „clear“, „clear all|alles“, „clear claude“, „clear mats|user|nutzer“ → Ebene; sonst nil.
    private static func clearLayer(_ text: String) -> ScratchLayer? {
        let words = text.lowercased().split(separator: " ")
        guard words.first == "clear", words.count <= 2 else { return nil }
        guard words.count == 2 else { return .all }
        switch words[1] {
        case "all", "alles": return .all
        case "claude", "agent", "mine": return .claude
        case "mats", "user", "nutzer": return .mats
        default: return nil
        }
    }

    // MARK: Agenten-Abfragen (`call`)

    /// `look <pfad>` → PNG mit Raster an den Pfad, Lage als JSON. `draw [replace=claude|mats|all]` + Zeilenumbruch + SVG
    /// → zeichnen (mit Ersetzen ein Undo-Schritt). `clear <wer>` → entfernen, Anzahl als JSON.
    func call(_ text: String) throws -> String {
        let newline = text.firstIndex(of: "\n")
        let head = String(text[..<(newline ?? text.endIndex)]).trimmingCharacters(in: .whitespaces)
        let body = newline.map { String(text[text.index(after: $0)...]) } ?? ""
        let words = head.split(separator: " ").map(String.init)
        switch words.first?.lowercased() {
        case "look":
            let raw = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw PaneArgsError("look braucht einen absoluten Pfad für das PNG") }
            return try look(writingTo: path)
        case "draw":
            var replace: ScratchLayer?
            for option in words.dropFirst() {
                guard option.hasPrefix("replace="), let layer = ScratchLayer(rawValue: String(option.dropFirst(8))) else {
                    throw PaneArgsError("draw kennt nur replace=claude|mats|all, nicht „\(option)“")
                }
                replace = layer
            }
            return try draw(body, replacing: replace)
        case "clear":
            guard let layer = Self.clearLayer(head) else { throw PaneArgsError("clear kennt claude, mats oder all") }
            let removed = root.canvas.clear(layer)
            return Self.json(["removed": removed, "left": root.canvas.strokeCount])
        default:
            throw PaneArgsError("scratchpad versteht „\(head.prefix(40))“ nicht — look <pfad>, draw, clear <wer>")
        }
    }

    private func look(writingTo path: String) throws -> String {
        let canvas = root.canvas
        guard let shot = canvas.lookImage(maxSide: 1400) else { throw PaneArgsError("Scratchpad hat noch keine Größe") }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try shot.png.write(to: url, options: .atomic)
        } catch {
            throw PaneArgsError("PNG nicht schreibbar: \(error.localizedDescription)")
        }
        return Self.json([
            "image": path,
            "region": Self.rect(shot.region),
            "pixelsPerUnit": Double(shot.scale),
            "grid": Double(shot.grid),
            "visible": Self.rect(canvas.visibleWorldRect),
            "mats": ["count": canvas.count(.mats), "bounds": Self.rectOrNull(canvas.contentBounds(.mats))],
            "claude": ["count": canvas.count(.claude), "bounds": Self.rectOrNull(canvas.contentBounds(.claude))],
            "colors": ScratchPalette.names,
            "claudeColor": ScratchPalette.names[ScratchPalette.claude],
        ])
    }

    private func draw(_ svg: String, replacing: ScratchLayer?) throws -> String {
        let canvas = root.canvas
        let target = canvas.visibleWorldRect.insetBy(dx: 24, dy: 24)
        let result: ScratchSVG.Result
        do { result = try ScratchSVG.parse(svg, defaultColor: ScratchPalette.claude, target: target) }
        catch { throw PaneArgsError(String(describing: error)) }
        guard !result.shapes.isEmpty else {
            let why = result.warnings.isEmpty ? "" : " (" + result.warnings.joined(separator: "; ") + ")"
            throw PaneArgsError("SVG ergab keine zeichenbaren Formen\(why)")
        }
        let points = result.shapes.reduce(0) { $0 + $1.points.count }
        guard result.shapes.count <= 5000, points <= 400_000 else {
            throw PaneArgsError("SVG zu groß (\(result.shapes.count) Formen, \(points) Punkte) — einfacher zeichnen")
        }
        let items = result.shapes.map { ScratchStroke(shape: $0, author: ScratchStroke.claude) }
        let removed = canvas.add(items, replacing: replacing)
        let box = items.map(\.bounds).reduce(items[0].bounds) { $0.union($1) }
        return Self.json(["added": items.count, "removed": removed, "fitted": result.fitted,
                          "bounds": Self.rect(box), "visible": Self.rect(canvas.visibleWorldRect),
                          "warnings": result.warnings])
    }

    private static func rect(_ r: NSRect) -> [String: Double] {
        func tenth(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        return ["x": tenth(r.minX), "y": tenth(r.minY), "w": tenth(r.width), "h": tenth(r.height)]
    }

    private static func rectOrNull(_ r: NSRect?) -> Any {
        guard let r else { return NSNull() }
        return rect(r)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: An Agent schicken

    /// Ziel: die Agenten-Kachel, die dieses Scratchpad geöffnet hat — sonst (oder mit ⌥) Auswahl aus allen.
    private func sendToAgent(choose: Bool) {
        guard root.canvas.strokeCount > 0 else {
            NSSound.beep()
            root.showNote("Noch nichts gezeichnet")
            return
        }
        switch AgentHandoff.target(delegate, choose: choose) {
        case .none(let reason):
            NSSound.beep()
            root.showNote(reason)
        case .direct(let pane):
            deliver(to: pane)
        case .choose(let agents):
            let menu = AgentHandoff.menu(agents, header: "Skizze an …", opener: delegate?.contentOpener) { [weak self] pane in
                self?.deliver(to: pane)
            }
            let anchor = root.sendAnchor
            menu.popUp(positioning: nil, at: NSPoint(x: anchor.rect.maxX + 4, y: anchor.rect.minY), in: anchor.view)
        }
    }

    /// PNG in den Cache (Pfad ohne Leerzeichen, nicht im Documents-Spiegel), Pfad als Einfügen in die Ziel-Kachel —
    /// Claude Code und Codex machen daraus ein Bild-Attachment; Enter drückt der Nutzer selbst.
    private func deliver(to pane: PaneInfo) {
        guard let png = root.canvas.pngData() else { NSSound.beep(); return }
        let file: URL
        do { file = try AgentHandoff.writePNG(png, prefix: "Skizze") } catch {
            NSSound.beep()
            root.showNote("Bild nicht speicherbar")
            return
        }
        guard delegate?.contentPaste(file.path, intoPaneID: pane.id) == true else {
            NSSound.beep()
            root.showNote("Kachel \(pane.index) nimmt nichts an")
            return
        }
        root.showNote("Skizze liegt in Kachel \(pane.index)")
    }

    /// Kachel zu = Zeichnung weg (wie ein Terminal seinen Inhalt verliert). Nicht beim Beenden der App:
    /// dort ruft niemand `willClose`, die Datei bleibt für den Restore.
    func willClose() {
        root.canvas.onChange = nil
        root.canvas.onSaveRequest = nil
        root.canvas.onSendRequest = nil
        root.onSend = nil
        try? FileManager.default.removeItem(at: file)
    }

    func snapshotArgs() -> [String: String]? { ["id": id.uuidString] }

    // MARK: Sichern

    private func canvasChanged() {
        delegate?.contentStyleChanged()
        guard let data = try? JSONEncoder().encode(root.canvas.document()) else { return }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// ⌘S: PNG über den Sichern-Dialog, als Sheet am Fenster.
    private func runSavePanel() {
        guard let png = root.canvas.pngData() else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        panel.nameFieldStringValue = "Scratchpad \(stamp.string(from: Date())).png"
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try png.write(to: url, options: .atomic) } catch { NSSound.beep() }
        }
        if let window = root.window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }

    private var file: URL { Self.folder.appendingPathComponent("\(id.uuidString).json") }

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LatexTerm/scratchpads", isDirectory: true)
    }

    /// Unlesbare Datei beiseitelegen statt überschreiben — die Kachel startet dann leer.
    private static func load(from url: URL) -> ScratchDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let doc = try? JSONDecoder().decode(ScratchDocument.self, from: data) { return doc }
        try? FileManager.default.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("defekt.json"))
        return nil
    }

    /// Zeichnungen, deren Kachel nie wiederkam (⌘Q ohne „Kacheln merken“, Absturz): nach 30 Tagen weg.
    private static func pruneOrphans() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for url in files {
            guard let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate, date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}


// MARK: - Modell

enum ScratchTool: String, Codable {
    case pen, marker, eraser

    var label: String {
        switch self {
        case .pen: "Stift"
        case .marker: "Marker"
        case .eraser: "Radierer"
        }
    }
}

/// Wessen Elemente: alle, nur die des Nutzers, nur die des Agenten.
enum ScratchLayer: String {
    case all, mats, claude
}

/// Farben als Index ins Theme — ein Theme-Wechsel färbt die ganze Zeichnung mit um.
enum ScratchPalette {
    static let names = ["Tinte", "Rot", "Gelb", "Grün", "Cyan", "Blau", "Violett"]
    /// Standardfarbe des Agenten — hebt sich von Mats' Tinte ab.
    static let claude = ScratchSVG.cyan

    static func colors(_ theme: TerminalTheme) -> [NSColor] {
        [theme.foreground, theme.red, theme.yellow, theme.green, theme.cyan, theme.blue, theme.violet]
            .map { $0.withAlphaComponent(1) }
    }
}

/// Ein Element der Zeichnung: Strich des Nutzers (geglättet) oder Form/Beschriftung eines Agenten (exakt).
/// Punkte in Zeichnungs-Koordinaten (0,0 = Kachelmitte in der Normalsicht, y nach unten; bis v1: oben links).
final class ScratchStroke: Codable {
    static let claude = "claude"

    var points: [CGPoint]
    let color: Int
    let width: CGFloat
    /// Halbdeckend (Marker bzw. durchscheinende Agenten-Form).
    let marker: Bool
    /// "claude" = vom Agenten gezeichnet; nil = vom Nutzer.
    let author: String?
    /// Handschrift wird geglättet, Agenten-Formen sind exakte Linienzüge.
    let smooth: Bool
    let filled: Bool
    let dashed: Bool
    /// Beschriftung: `points[0]` ist der Anker auf der Grundlinie.
    let text: String?
    let fontSize: CGFloat
    let anchor: ScratchTextAnchor
    let bold: Bool
    private var cachedPath: NSBezierPath?
    private var cachedTextRect: NSRect?

    private enum CodingKeys: String, CodingKey {
        case points, color, width, marker, author, smooth, filled, dashed, text, fontSize, anchor, bold
    }

    init(start: CGPoint, color: Int, width: CGFloat, marker: Bool) {
        points = [start]
        self.color = color
        self.width = width
        self.marker = marker
        author = nil
        smooth = true
        filled = false
        dashed = false
        text = nil
        fontSize = 16
        anchor = .start
        bold = false
    }

    init(shape: ScratchShape, author: String) {
        points = shape.points
        color = max(0, min(shape.fill ?? shape.stroke ?? ScratchPalette.claude, ScratchPalette.names.count - 1))
        width = shape.width
        marker = shape.translucent
        self.author = author
        smooth = false
        filled = shape.fill != nil && shape.text == nil
        dashed = shape.dashed
        text = shape.text
        fontSize = shape.fontSize
        anchor = shape.anchor
        bold = shape.bold
    }

    /// v1/v2-Dateien kennen nur points/color/width/marker.
    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = try c.decode([CGPoint].self, forKey: .points)
        color = try c.decode(Int.self, forKey: .color)
        width = try c.decode(CGFloat.self, forKey: .width)
        marker = try c.decode(Bool.self, forKey: .marker)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        smooth = try c.decodeIfPresent(Bool.self, forKey: .smooth) ?? true
        filled = try c.decodeIfPresent(Bool.self, forKey: .filled) ?? false
        dashed = try c.decodeIfPresent(Bool.self, forKey: .dashed) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 16
        anchor = try c.decodeIfPresent(ScratchTextAnchor.self, forKey: .anchor) ?? .start
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        guard !points.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .points, in: c, debugDescription: "Element ohne Punkte")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
        try c.encode(color, forKey: .color)
        try c.encode(width, forKey: .width)
        try c.encode(marker, forKey: .marker)
        try c.encodeIfPresent(author, forKey: .author)
        if !smooth { try c.encode(smooth, forKey: .smooth) }
        if filled { try c.encode(filled, forKey: .filled) }
        if dashed { try c.encode(dashed, forKey: .dashed) }
        if let text {
            try c.encode(text, forKey: .text)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(anchor, forKey: .anchor)
            if bold { try c.encode(bold, forKey: .bold) }
        }
    }

    var isClaude: Bool { author == Self.claude }

    func offset(by d: CGPoint) {
        points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        cachedPath = nil
        cachedTextRect = nil
    }

    func append(_ p: CGPoint) {
        points.append(p)
        cachedPath = nil
    }

    /// ⇧ beim Ziehen: gerade Linie vom Startpunkt.
    func straighten(to p: CGPoint) {
        points = [points[0], p]
        cachedPath = nil
    }

    /// Handschrift: quadratische Kurven durch die Mittelpunkte — glättet das Zittern der Maus, ohne Ecken zu
    /// verlieren. Agenten-Formen: exakter Linienzug (Kurven sind schon fein abgetastet).
    var path: NSBezierPath {
        if let cachedPath { return cachedPath }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        if points.count < 3 || !smooth {
            if points.count == 1 { path.line(to: points[0]) }   // ein Klick ohne Ziehen hinterlässt einen Punkt
            for p in points.dropFirst() { path.line(to: p) }
        } else {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.curve(to: mid, controlPoint: points[i])
            }
            path.line(to: points.last!)
        }
        if dashed { path.setLineDash([max(4, width * 3), max(3, width * 2)], count: 2, phase: 0) }
        cachedPath = path
        return path
    }

    // MARK: Text

    var font: NSFont { NSFont.systemFont(ofSize: fontSize, weight: bold ? .semibold : .regular) }

    /// Rechteck der Beschriftung: Anker auf der Grundlinie, links/mittig/rechts ausgerichtet.
    var textRect: NSRect {
        if let cachedTextRect { return cachedTextRect }
        let font = self.font
        let size = ((text ?? "") as NSString).size(withAttributes: [.font: font])
        let x: CGFloat
        switch anchor {
        case .start: x = points[0].x
        case .middle: x = points[0].x - size.width / 2
        case .end: x = points[0].x - size.width
        }
        let rect = NSRect(x: x, y: points[0].y - font.ascender, width: size.width, height: size.height)
        cachedTextRect = rect
        return rect
    }

    var bounds: NSRect {
        if text != nil { return textRect.insetBy(dx: -2, dy: -2) }
        return path.bounds.insetBy(dx: -width, dy: -width)
    }

    /// Berührt ein Kreis um `p` das Element? (Abstand zu jedem Teilstück, nicht nur zu den Punkten; Flächen und
    /// Beschriftungen auch innen.)
    func touches(_ p: CGPoint, radius: CGFloat) -> Bool {
        guard bounds.insetBy(dx: -radius, dy: -radius).contains(p) else { return false }
        if text != nil { return true }
        if filled, path.contains(p) { return true }
        let reach = radius + width / 2
        if points.count == 1 { return hypot(points[0].x - p.x, points[0].y - p.y) <= reach }
        for i in 1..<points.count where Self.distance(p, points[i - 1], points[i]) <= reach { return true }
        return false
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Inhalt der Sicherungsdatei: Elemente plus die zuletzt gewählten Werkzeuge.
struct ScratchDocument: Codable {
    /// 3 = Elemente mit Autor/Form/Text (22.09. abends); 2 = Punkte relativ zur Kachelmitte; 1 = oben links,
    /// wird beim Laden verschoben.
    var version = 3
    var strokes: [ScratchStroke]
    var tool: ScratchTool
    var color: Int
    var size: Int
}
