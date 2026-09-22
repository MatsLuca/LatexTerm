import AppKit
import UniformTypeIdentifiers

/// Malfläche (Kachel-Protokoll, Schritt 6; ausgebaut 22.09.): Stift, Marker, Radierer, sieben Farben aus dem
/// Theme, drei Stärken, ⌘Z/⇧⌘Z, ⌘S sichert als PNG, ⌘C kopiert als Bild. Die Zeichnung wird bei jeder
/// Änderung unter `Application Support/LatexTerm/scratchpads/<id>.json` gesichert und kommt nach ⌥⌘R
/// wieder; ⌘W schließt die Kachel samt Zeichnung.
final class ScratchpadContent: PaneContent {
    static let kind = "scratchpad"
    static let displayName = "Neues Scratchpad"
    static let manual = PaneKindManual(
        summary: "Malfläche zum Skizzieren mit Maus oder Trackpad (Mats zeichnet, nicht Claude): Stift, Marker, "
            + "Radierer, Farben. Bleibt über einen Neustart erhalten. Mit `save <pfad>` als PNG ablegen, um die Skizze anzusehen.",
        actions: [PaneKindAction(name: "clear", summary: "Fläche leeren (rückgängig machbar)"),
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
    }

    var view: NSView { root }
    var keyView: NSView { root.canvas }
    var title: String { "Scratchpad" }
    var chip: StatusChip? {
        let canvas = root.canvas
        let count = canvas.strokeCount
        return StatusChip(tone: canvas.inkColor,
                          tooltip: "\(canvas.tool.label) · \(ScratchPalette.names[canvas.colorIndex]) · \(count == 1 ? "1 Strich" : "\(count) Striche")")
    }
    var closeGuard: CloseGuard {
        let count = root.canvas.strokeCount
        return count == 0 ? .free : .busy("hat eine Zeichnung (\(count == 1 ? "1 Strich" : "\(count) Striche"))")
    }

    func applyTheme(_ theme: TerminalTheme) {
        root.apply(theme)
        delegate?.contentStyleChanged()
    }

    func receive(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "clear": root.canvas.clear(); return true
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

    /// Kachel zu = Zeichnung weg (wie ein Terminal seinen Inhalt verliert). Nicht beim Beenden der App:
    /// dort ruft niemand `willClose`, die Datei bleibt für den Restore.
    func willClose() {
        root.canvas.onChange = nil
        root.canvas.onSaveRequest = nil
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

/// Farben als Index ins Theme — ein Theme-Wechsel färbt die ganze Zeichnung mit um.
enum ScratchPalette {
    static let names = ["Tinte", "Rot", "Gelb", "Grün", "Cyan", "Blau", "Violett"]

    static func colors(_ theme: TerminalTheme) -> [NSColor] {
        [theme.foreground, theme.red, theme.yellow, theme.green, theme.cyan, theme.blue, theme.violet]
            .map { $0.withAlphaComponent(1) }
    }
}

/// Ein Strich: Punkte in Zeichnungs-Koordinaten (0,0 = Kachelmitte in der Normalsicht; bis v1: oben links),
/// Pfad geglättet und zwischengespeichert.
final class ScratchStroke: Codable {
    var points: [CGPoint]
    let color: Int
    let width: CGFloat
    let marker: Bool
    private var cachedPath: NSBezierPath?

    private enum CodingKeys: String, CodingKey { case points, color, width, marker }

    init(start: CGPoint, color: Int, width: CGFloat, marker: Bool) {
        points = [start]
        self.color = color
        self.width = width
        self.marker = marker
    }

    func offset(by d: CGPoint) {
        points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        cachedPath = nil
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

    /// Quadratische Kurven durch die Mittelpunkte — glättet das Zittern der Maus, ohne Ecken zu verlieren.
    var path: NSBezierPath {
        if let cachedPath { return cachedPath }
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        if points.count < 3 {
            path.line(to: points.last!)   // ein Klick ohne Ziehen hinterlässt einen Punkt
        } else {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.curve(to: mid, controlPoint: points[i])
            }
            path.line(to: points.last!)
        }
        cachedPath = path
        return path
    }

    var bounds: NSRect { path.bounds.insetBy(dx: -width, dy: -width) }

    /// Berührt ein Kreis um `p` den Strich? (Abstand zu jedem Teilstück, nicht nur zu den Punkten.)
    func touches(_ p: CGPoint, radius: CGFloat) -> Bool {
        let reach = radius + width / 2
        guard bounds.insetBy(dx: -radius, dy: -radius).contains(p) else { return false }
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

/// Inhalt der Sicherungsdatei: Striche plus die zuletzt gewählten Werkzeuge.
struct ScratchDocument: Codable {
    /// 2 = Punkte relativ zur Kachelmitte (22.09.); 1 = oben links, wird beim Laden verschoben.
    var version = 2
    var strokes: [ScratchStroke]
    var tool: ScratchTool
    var color: Int
    var size: Int
}
