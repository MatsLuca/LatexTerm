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
            + "— eigene Ebene in Cyan, ⌘Z nimmt deinen Beitrag als einen Schritt zurück. Karten (Text im Rahmen, verschiebbar) "
            + "legst du per scratch_cards ab, der Nutzer per ⌘V (Text → Karten, Screenshot → Bild) — gemeinsame Pinnwand fürs Brainstorming. "
            + "Alles ist Tinte: Radierer nimmt Striche/Buchstaben, Pixel-Radierer schneidet; Pfeile zwischen Karten rasten ein. Bleibt über einen Neustart erhalten.",
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
        case "cards", "karten": return .cards
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
            // look <pfad> [as=<wer>] — mit `as` kommt dazu, was sich seit dem letzten Blick dieses Betrachters geändert hat.
            guard words.count >= 2 else { throw PaneArgsError("look braucht einen absoluten Pfad für das PNG") }
            let path = (words[1] as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw PaneArgsError("look braucht einen absoluten Pfad für das PNG") }
            let viewer = words.dropFirst(2).first { $0.hasPrefix("as=") }.map { String($0.dropFirst(3)) }
            return try look(writingTo: path, viewer: viewer)
        case "draw":
            var replace: ScratchLayer?
            for option in words.dropFirst() {
                guard option.hasPrefix("replace="), let layer = ScratchLayer(rawValue: String(option.dropFirst(8))) else {
                    throw PaneArgsError("draw kennt nur replace=claude|mats|all, nicht „\(option)“")
                }
                replace = layer
            }
            return try draw(body, replacing: replace)
        case "cards":
            var replace: ScratchLayer?
            for option in words.dropFirst() {
                guard option.hasPrefix("replace="), let layer = ScratchLayer(rawValue: String(option.dropFirst(8))) else {
                    throw PaneArgsError("cards kennt nur replace=claude|cards|mats|all, nicht „\(option)“")
                }
                replace = layer
            }
            return try cards(body, replacing: replace)
        case "clear":
            guard let layer = Self.clearLayer(head) else { throw PaneArgsError("clear kennt claude, mats oder all") }
            let removed = root.canvas.clear(layer)
            return Self.json(["removed": removed, "left": root.canvas.strokeCount])
        default:
            throw PaneArgsError("scratchpad versteht „\(head.prefix(40))“ nicht — look <pfad>, draw, cards, clear <wer>")
        }
    }

    private func look(writingTo path: String, viewer: String?) throws -> String {
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
            "cards": canvas.cards.map { card in
                var entry: [String: Any] = ["id": card.cardInfo?.id ?? "", "text": card.text ?? "",
                                            "visible": card.visibleText ?? NSNull(),
                                            "author": card.isClaude ? "claude" : "mats", "bounds": Self.rect(card.bounds),
                                            "color": ScratchPalette.names[max(0, min(card.color, ScratchPalette.names.count - 1))]]
                if let info = card.cardInfo, let data = try? JSONEncoder().encode(info),
                   var style = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    style["id"] = nil
                    if let title = style.removeValue(forKey: "title") { entry["title"] = title }
                    if let t = info.textColor { style["textColor"] = ScratchPalette.names[max(0, min(t, ScratchPalette.names.count - 1))] }
                    if !style.isEmpty { entry["style"] = style }
                }
                return entry
            },
            "links": canvas.elements.compactMap { s -> [String: Any]? in
                guard let link = s.link else { return nil }
                let name = { (uid: String) in canvas.elements.first { $0.uid == uid }.map { $0.cardInfo?.id ?? "Bild" } ?? "?" }
                return ["from": name(link.from), "to": name(link.to), "by": s.isClaude ? "claude" : "mats"]
            },
            "images": canvas.elements.filter(\.isImage).map { ["bounds": Self.rect($0.bounds), "by": $0.isClaude ? "claude" : "mats",
                                                               "cut": !$0.cuts.isEmpty] as [String: Any] },
            "order": ScratchChanges.readingOrder(canvas.cards).compactMap { $0.cardInfo?.id },
            "groups": ScratchChanges.groups(canvas.cards).map { $0.compactMap { $0.cardInfo?.id } }.filter { $0.count > 1 },
            "changes": changes(for: viewer) ?? NSNull(),
            "colors": ScratchPalette.names,
            "claudeColor": ScratchPalette.names[ScratchPalette.claude],
        ])
    }

    /// Letzter Stand, den ein Betrachter gesehen hat (nur im Speicher: nach einem Neustart beginnt der Vergleich neu).
    private var seen: [String: [String: ScratchChanges.Snap]] = [:]

    /// Änderungen seit dem letzten `look` dieses Betrachters; nil = erster Blick (oder ohne Betrachter).
    private func changes(for viewer: String?) -> [String: Any]? {
        guard let viewer else { return nil }
        let now = ScratchChanges.snapshot(root.canvas.elements)
        defer { seen[viewer] = now }
        guard let before = seen[viewer] else { return nil }
        return ScratchChanges.diff(before, now)
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
        delegate?.contentHasNews()
        let box = items.map(\.bounds).reduce(items[0].bounds) { $0.union($1) }
        return Self.json(["added": items.count, "removed": removed, "fitted": result.fitted,
                          "bounds": Self.rect(box), "visible": Self.rect(canvas.visibleWorldRect),
                          "warnings": result.warnings])
    }

    /// `cards` + JSON-Liste (oder `{"cards": [...]}`). Eintrag ohne `id` = neue Karte (`text` Pflicht), mit `id` = diese
    /// Karte ändern/verschieben, mit `remove: true` = entfernen. Felder: text, title, x, y (obere linke Ecke), width,
    /// color (Rahmen), textColor, font, size, bold, italic, frame, fill, align. Ohne x/y sucht das Scratchpad Platz.
    private func cards(_ body: String, replacing: ScratchLayer?) throws -> String {
        guard let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            throw PaneArgsError("cards braucht JSON: [{\"text\": \"…\"}]")
        }
        let list = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["cards"] as? [[String: Any]]) ?? []
        guard !list.isEmpty, list.count <= 80 else { throw PaneArgsError("cards: 1–80 Einträge") }
        func number(_ v: Any?) -> CGFloat? { (v as? NSNumber).map { CGFloat($0.doubleValue) } }
        func color(_ v: Any?, _ key: String) throws -> Int? {
            guard let name = v as? String else { return nil }
            guard let index = ScratchPalette.index(named: name) else {
                throw PaneArgsError("\(key) „\(name)“ unbekannt (\(ScratchPalette.names.joined(separator: ", ")))")
            }
            return index
        }
        var entries: [ScratchpadCanvas.CardEntry] = []
        for raw in list {
            var entry = ScratchpadCanvas.CardEntry()
            entry.id = raw["id"] as? String
            entry.remove = raw["remove"] as? Bool ?? false
            entry.text = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.id == nil {
                guard let text = entry.text, !text.isEmpty else { throw PaneArgsError("neue Karte braucht text") }
                guard !entry.remove else { throw PaneArgsError("remove braucht eine id") }
                _ = text
            }
            if let one = raw["arrowTo"] as? String { entry.arrowTo = [one] } else { entry.arrowTo = raw["arrowTo"] as? [String] ?? [] }
            if let text = entry.text, text.count > 3000 { throw PaneArgsError("Kartentext zu lang (max 3000 Zeichen)") }
            if let x = number(raw["x"]), let y = number(raw["y"]) { entry.origin = CGPoint(x: x, y: y) }
            entry.width = number(raw["width"])
            entry.color = try color(raw["color"], "color")
            entry.style.textColor = try color(raw["textColor"], "textColor")
            entry.style.title = raw["title"] as? String
            entry.style.font = raw["font"] as? String
            entry.style.size = number(raw["size"]).map { max(8, min($0, 72)) }
            entry.style.bold = raw["bold"] as? Bool
            entry.style.italic = raw["italic"] as? Bool
            entry.style.fill = raw["fill"] as? Bool
            if let frame = raw["frame"] as? String {
                guard ScratchCard.frames.contains(frame.lowercased()) else {
                    throw PaneArgsError("frame „\(frame)“ unbekannt (\(ScratchCard.frames.joined(separator: ", ")))")
                }
                entry.style.frame = frame.lowercased()
            }
            if let align = raw["align"] as? String {
                guard ["left", "center", "right"].contains(align.lowercased()) else { throw PaneArgsError("align: left, center, right") }
                entry.style.align = align.lowercased()
            }
            entries.append(entry)
        }
        let result = try root.canvas.applyCards(entries, author: ScratchStroke.claude, replacing: replacing)
        delegate?.contentHasNews()
        func brief(_ card: ScratchStroke) -> [String: Any] { ["id": card.cardInfo?.id ?? "", "bounds": Self.rect(card.bounds)] }
        return Self.json(["added": result.added.map(brief), "updated": result.updated.map(brief), "removed": result.removed,
                          "visible": Self.rect(root.canvas.visibleWorldRect)])
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

    /// Kachel zu = Zeichnung weg (wie ein Terminal seinen Inhalt verliert). Nicht beim Beenden der App: auch dann
    /// kommt `willClose` (Fenster gehen zu), die Datei muss aber für den Restore bleiben — sonst war die Zeichnung
    /// nach ⌥⌘R weg (Befund 24.09.). Verwaiste Dateien räumt `pruneOrphans`.
    func willClose() {
        root.canvas.onChange = nil
        root.canvas.onSaveRequest = nil
        root.canvas.onSendRequest = nil
        root.onSend = nil
        guard !AppLifecycle.isTerminating else { return }
        try? FileManager.default.removeItem(at: file)
    }

    func snapshotArgs() -> [String: String]? { ["id": id.uuidString] }

    /// Abgedunkelt wird nur das Papier (und die Leiste) — die Tinte bleibt voll lesbar (Mats, 24.09.).
    func setDimmed(_ dimmed: Bool) -> Bool {
        root.setDimmed(dimmed)
        return true
    }

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
    case pen, marker, eraser, cutter
    /// Kein Werkzeug (nach Fokusverlust, Mats 24.09.): Ziehen verschiebt Karten/Bilder oder die Fläche, malt nie.
    case none

    var label: String {
        switch self {
        case .none: "kein Werkzeug"
        case .pen: "Stift"
        case .marker: "Marker"
        case .eraser: "Radierer"
        case .cutter: "Pixel-Radierer"
        }
    }

    /// Beide Radierer: Zeiger als Kreis, Stärke = Radius.
    var erases: Bool { self == .eraser || self == .cutter }
}

/// Radier-Schnitt am Element (Pinnwand Runde 3): Spur des Pixel-Radierers (Linienzug mit Radius) oder ein
/// weggenommener Buchstabe einer Karte (Rechteck). Hängt am Element und wandert mit, wenn es verschoben wird.
struct ScratchCut: Codable, Equatable {
    var points: [CGPoint] = []
    var radius: CGFloat = 0
    var rect: NSRect?
    /// Ganzer Tintenfleck einer Karte weg (Radierer, Mats 24.09.): "fill" = Fläche, "frame" = Rahmen,
    /// "chars" = Zeichen `location`..<`location+length` (ein Buchstabe = ein Fleck).
    var part: String?
    var location: Int?
    var length: Int?

    static func chars(_ range: NSRange) -> ScratchCut { ScratchCut(part: "chars", location: range.location, length: range.length) }

    func covers(_ p: CGPoint, slack: CGFloat = 0) -> Bool {
        if part != nil { return false }
        if let rect { return rect.insetBy(dx: -slack, dy: -slack).contains(p) }
        guard let first = points.first else { return false }
        let reach = radius + slack
        if points.count == 1 { return hypot(first.x - p.x, first.y - p.y) <= reach }
        for i in 1..<points.count where ScratchCut.distance(p, points[i - 1], points[i]) <= reach { return true }
        return false
    }

    var path: NSBezierPath {
        if part != nil { return NSBezierPath() }
        if let rect { return NSBezierPath(rect: rect) }
        let path = NSBezierPath()
        path.lineWidth = radius * 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.line(to: first) }
        for p in points.dropFirst() { path.line(to: p) }
        return path
    }

    func mapped(_ f: (CGPoint) -> CGPoint, scale: CGFloat) -> ScratchCut {
        var c = self
        c.points = points.map(f)
        c.radius = radius * scale
        if let rect {
            // Rechteck-Schnitte (Buchstaben) sitzen nur auf Karten, die nie gedreht werden: verschieben reicht.
            let o = f(rect.origin)
            c.rect = NSRect(origin: o, size: rect.size)
        }
        return c
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Eingerasteter Pfeil (Runde 3, B): ein Strich von Karte zu Karte. `a`/`b` = Anfang/Ende relativ zur oberen linken
/// Ecke der jeweiligen Karte; wandert eine Karte, wird der Strich so gedreht und gestreckt, dass die Enden bleiben.
struct ScratchLink: Codable, Equatable {
    var from: String
    var to: String
    var a: CGPoint
    var b: CGPoint
}

/// Wessen Elemente: alle, nur die des Nutzers, nur die des Agenten, nur die Karten des Agenten.
enum ScratchLayer: String {
    case all, mats, claude, cards
}

/// Name und Aussehen einer Karte. Alles optional — nil heißt Terminal-Look: Monoschrift der App in Terminal-Vordergrund,
/// linksbündig, ohne Rahmen und Fläche — nackter Text auf dem Papier wie Claude Codes Antworten im Terminal, nur ein
/// leiser Strich links mit kurzem, rund abknickendem Fuß als Trenner (Mats, 24.09., Variante H4).
/// Agenten dürfen frei abweichen (Schrift, Größe, Farben, Rahmen), um zu gewichten oder zu gruppieren.
struct ScratchCard: Codable, Equatable {
    /// Stabiler Name („k3“), über den Agenten eine Karte verschieben, ändern, entfernen.
    var id: String?
    /// Fette erste Zeile.
    var title: String?
    /// mono (Standard) | system | serif | rounded | Name einer installierten Schrift.
    var font: String?
    var size: CGFloat?
    var bold: Bool?
    var italic: Bool?
    /// Palettenindex der Schrift; nil = Tinte.
    var textColor: Int?
    /// mark (Standard: Strich links mit Fuß) | line | dashed | thick | none.
    var frame: String?
    /// Fläche leicht in der Rahmenfarbe getönt (Standard false).
    var fill: Bool?
    /// left (Standard) | center | right.
    var align: String?

    static let defaultSize: CGFloat = 13
    static let fonts = ["mono", "system", "serif", "rounded"]
    static let frames = ["mark", "line", "dashed", "thick", "none"]

    func font(bold forceBold: Bool = false) -> NSFont {
        let size = max(8, min(size ?? Self.defaultSize, 72))
        let weight: NSFont.Weight = (bold ?? false) || forceBold ? .semibold : .regular
        var result: NSFont
        switch self.font?.lowercased() {
        case nil, "", "mono", "terminal", "monospace": result = AppFonts.mono(size: size, weight: weight)
        case "system", "sans", "sans-serif": result = NSFont.systemFont(ofSize: size, weight: weight)
        case "serif":
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            result = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        case "rounded":
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            result = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        default:
            result = NSFont(name: self.font!, size: size) ?? AppFonts.mono(size: size, weight: weight)
            if weight != .regular { result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask) }
        }
        if italic == true { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
        return result
    }

    /// Satz der Karte: Titel (fett) über dem Text, Ausrichtung, Farbe.
    func attributed(text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        switch align?.lowercased() {
        case "center": paragraph.alignment = .center
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        paragraph.lineBreakMode = .byWordWrapping
        let result = NSMutableAttributedString()
        if let title, !title.isEmpty {
            result.append(NSAttributedString(string: title + (text.isEmpty ? "" : "\n"), attributes: [
                .font: font(bold: true), .foregroundColor: color, .paragraphStyle: paragraph]))
        }
        result.append(NSAttributedString(string: text, attributes: [
            .font: font(), .foregroundColor: color, .paragraphStyle: paragraph]))
        return result
    }
}

/// Farben als Index ins Theme — ein Theme-Wechsel färbt die ganze Zeichnung mit um.
enum ScratchPalette {
    static let names = ["Tinte", "Rot", "Gelb", "Grün", "Cyan", "Blau", "Violett"]
    /// Standardfarbe des Agenten — hebt sich von Mats' Tinte ab.
    static let claude = ScratchSVG.cyan

    /// Farbe per Namen (deutsch wie `names` oder englisch); nil = unbekannt.
    static func index(named name: String) -> Int? {
        let aliases = ["tinte": 0, "ink": 0, "weiß": 0, "white": 0, "schwarz": 0, "black": 0, "grau": 0, "gray": 0,
                       "rot": 1, "red": 1, "gelb": 2, "yellow": 2, "grün": 3, "gruen": 3, "green": 3, "cyan": 4,
                       "blau": 5, "blue": 5, "violett": 6, "violet": 6, "lila": 6, "purple": 6]
        return aliases[name.lowercased()]
    }

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
    /// Karte (24.09., Brainstorm-Pinnwand): umbrochener Text im Rahmen, `points[0]` = obere linke Ecke,
    /// `cardWidth` = Breite. Mats legt sie per ⌘V ab, Agenten per `call cards`; verschiebbar per Ziehen.
    /// `cardInfo` = Name (id) und Aussehen; nil = kein Karte.
    var cardInfo: ScratchCard?
    let cardWidth: CGFloat
    var card: Bool { cardInfo != nil }
    /// Stabiler Name des Elements über Verschieben/Ändern hinweg — für „seit deinem letzten Blick“ (`look as=…`).
    var uid = String(UUID().uuidString.prefix(8))
    /// Radier-Schnitte (Pixel-Radierer, weggenommene Buchstaben).
    var cuts: [ScratchCut] = []
    /// Eingerasteter Pfeil zwischen zwei Karten.
    var link: ScratchLink?
    /// Pfeilspitze o. ä.: folgt dem Pfeil mit dieser uid.
    var follows: String?
    /// Bild (⌘V): PNG, `points[0]` = obere linke Ecke, Breite `cardWidth`, Höhe `imageHeight`.
    var imageData: Data?
    var imageHeight: CGFloat = 0
    private var cachedImage: NSImage?
    private var cachedPath: NSBezierPath?
    private var cachedTextRect: NSRect?

    private enum CodingKeys: String, CodingKey {
        case points, color, width, marker, author, smooth, filled, dashed, text, fontSize, anchor, bold, card, cardWidth, cardInfo, uid, cuts, link, follows, imageData, imageHeight
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
        cardInfo = nil
        cardWidth = 0
    }

    /// Karte mit oberer linker Ecke `origin`; `color` = Rahmen, Aussehen sonst aus `info`.
    init(card text: String, at origin: CGPoint, width: CGFloat, color: Int, author: String?, info: ScratchCard) {
        points = [origin]
        self.color = max(0, min(color, ScratchPalette.names.count - 1))
        self.width = 1.2
        marker = false
        self.author = author
        smooth = false
        filled = false
        dashed = false
        self.text = text
        fontSize = info.size ?? ScratchCard.defaultSize
        anchor = .start
        bold = false
        cardInfo = info
        cardWidth = width
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
        cardInfo = nil
        cardWidth = 0
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
        if let uid = try c.decodeIfPresent(String.self, forKey: .uid) { self.uid = uid }
        cuts = try c.decodeIfPresent([ScratchCut].self, forKey: .cuts) ?? []
        link = try c.decodeIfPresent(ScratchLink.self, forKey: .link)
        follows = try c.decodeIfPresent(String.self, forKey: .follows)
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        imageHeight = try c.decodeIfPresent(CGFloat.self, forKey: .imageHeight) ?? 0
        // Erste Karten (24.09. mittags) trugen nur `card: true`.
        cardInfo = try c.decodeIfPresent(ScratchCard.self, forKey: .cardInfo)
            ?? ((try c.decodeIfPresent(Bool.self, forKey: .card)) == true ? ScratchCard() : nil)
        cardWidth = try c.decodeIfPresent(CGFloat.self, forKey: .cardWidth) ?? 0
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
        try c.encode(uid, forKey: .uid)
        if !cuts.isEmpty { try c.encode(cuts, forKey: .cuts) }
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(follows, forKey: .follows)
        if let imageData {
            try c.encode(imageData, forKey: .imageData)
            try c.encode(imageHeight, forKey: .imageHeight)
            try c.encode(cardWidth, forKey: .cardWidth)
        }
        if !smooth { try c.encode(smooth, forKey: .smooth) }
        if filled { try c.encode(filled, forKey: .filled) }
        if dashed { try c.encode(dashed, forKey: .dashed) }
        if let text {
            try c.encode(text, forKey: .text)
            try c.encode(fontSize, forKey: .fontSize)
            try c.encode(anchor, forKey: .anchor)
            if bold { try c.encode(bold, forKey: .bold) }
            if let cardInfo {
                try c.encode(cardInfo, forKey: .cardInfo)
                try c.encode(cardWidth, forKey: .cardWidth)
            }
        }
    }

    var isClaude: Bool { author == Self.claude }

    /// Kopie, um `d` verschoben — Verschieben ist ein Undo-Schritt „alte raus, Kopie rein“.
    func moved(by d: CGPoint) -> ScratchStroke {
        guard let data = try? JSONEncoder().encode(self),
              let copy = try? JSONDecoder().decode(ScratchStroke.self, from: data) else { return self }
        copy.offset(by: d)
        return copy
    }

    func offset(by d: CGPoint) {
        points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        cuts = cuts.map { $0.mapped({ CGPoint(x: $0.x + d.x, y: $0.y + d.y) }, scale: 1) }
        cachedPath = nil
        cachedTextRect = nil
        cachedGlyphs = nil
    }

    fileprivate func withUID(_ uid: String, cuts: [ScratchCut]) -> ScratchStroke {
        self.uid = uid
        self.cuts = cuts
        return self
    }

    /// Unabhängige Kopie (gleiche uid) — Grundlage aller Änderungen als Undo-Schritt „tauschen“.
    func copy() -> ScratchStroke { moved(by: .zero) }

    /// Kopie, abgebildet durch Drehung+Streckung+Verschiebung (eingerastete Pfeile folgen ihren Karten).
    func transformed(_ f: (CGPoint) -> CGPoint, scale: CGFloat) -> ScratchStroke {
        let c = copy()
        c.points = points.map(f)
        c.cuts = cuts.map { $0.mapped(f, scale: scale) }
        c.cachedPath = nil
        return c
    }

    /// Gerader Linienzug (Pfeile eines Agenten).
    init(line: [CGPoint], color: Int, width: CGFloat, author: String?) {
        points = line
        self.color = max(0, min(color, ScratchPalette.names.count - 1))
        self.width = width
        marker = false
        self.author = author
        smooth = false
        filled = false
        dashed = false
        text = nil
        fontSize = 16
        anchor = .start
        bold = false
        cardInfo = nil
        cardWidth = 0
    }

    /// Bild (⌘V) mit oberer linker Ecke `origin` und Anzeigegröße `size`.
    init(image png: Data, at origin: CGPoint, size: NSSize, author: String?) {
        points = [origin]
        color = 0
        width = 0
        marker = false
        self.author = author
        smooth = false
        filled = false
        dashed = false
        text = nil
        fontSize = 16
        anchor = .start
        bold = false
        cardInfo = nil
        cardWidth = size.width
        imageData = png
        imageHeight = size.height
    }

    var isImage: Bool { imageData != nil }
    var imageRect: NSRect { NSRect(origin: points[0], size: NSSize(width: cardWidth, height: imageHeight)) }
    var image: NSImage? {
        if cachedImage == nil, let imageData { cachedImage = NSImage(data: imageData) }
        return cachedImage
    }

    /// Liegt `p` in einem Radier-Schnitt? Dort ist vom Element nichts mehr zu sehen.
    func isCut(_ p: CGPoint) -> Bool { cuts.contains { $0.covers(p) } }

    // MARK: Buchstaben einer Karte

    private var cachedGlyphs: [(range: NSRange, rect: NSRect)]?

    /// Rechteck je Zeichen (Weltkoordinaten), wie die Karte es setzt — der Radierer nimmt einzelne Buchstaben weg.
    var glyphRects: [(range: NSRange, rect: NSRect)] {
        if let cachedGlyphs { return cachedGlyphs }
        guard let info = cardInfo, let text else { return [] }
        let content = info.attributed(text: text, color: .white)
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: cardWidth - 2 * Self.cardPadding.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let origin = CGPoint(x: points[0].x + Self.cardPadding.width, y: points[0].y + Self.cardPadding.height)
        var result: [(range: NSRange, rect: NSRect)] = []
        let glyphs = layout.glyphRange(for: container)
        for g in glyphs.location..<NSMaxRange(glyphs) {
            let chars = layout.characterRange(forGlyphRange: NSRange(location: g, length: 1), actualGlyphRange: nil)
            let substring = (content.string as NSString).substring(with: chars)
            guard !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let r = layout.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: container)
            result.append((chars, r.offsetBy(dx: origin.x, dy: origin.y)))
        }
        cachedGlyphs = result
        return result
    }

    /// Was von der Karte noch zu lesen ist (Titel + Text, radierte Buchstaben als „·“); nil = unversehrt.
    var visibleText: String? {
        guard card, !cuts.isEmpty, let text else { return nil }
        let full = (cardInfo?.title.map { $0 + (text.isEmpty ? "" : "\n") } ?? "") + text
        var chars = Array(full.utf16)
        var changed = false
        for (range, rect) in glyphRects where isCut(CGPoint(x: rect.midX, y: rect.midY)) || erasedChars.contains(range.location) {
            for i in range.location..<min(NSMaxRange(range), chars.count) { chars[i] = 0xB7; changed = true }
        }
        return changed ? String(decoding: chars, as: UTF16.self) : nil
    }

    // MARK: Tintenflecken einer Karte

    var erasedChars: IndexSet {
        var set = IndexSet()
        for cut in cuts where cut.part == "chars" {
            if let l = cut.location, let n = cut.length { set.insert(integersIn: l..<(l + n)) }
        }
        return set
    }
    var showsFill: Bool { (cardInfo?.fill ?? false) && !cuts.contains { $0.part == "fill" } }
    var frameStyle: String { cardInfo?.frame?.lowercased() ?? "mark" }
    var showsFrame: Bool { frameStyle != "none" && !cuts.contains { $0.part == "frame" } }

    /// Trenner der Standardkarte: leiser Strich links auf Höhe des Textes, unten ein kurzer Fuß mit runder Ecke.
    var markPath: NSBezierPath {
        let rect = cardRect, pad = Self.cardPadding
        let x = rect.minX + 1, top = rect.minY + pad.height - 1, bottom = rect.maxY - pad.height + 4
        let path = NSBezierPath()
        path.move(to: CGPoint(x: x, y: top))
        path.line(to: CGPoint(x: x, y: bottom - 3))
        path.curve(to: CGPoint(x: x + 3, y: bottom), controlPoint1: CGPoint(x: x, y: bottom - 1.3),
                   controlPoint2: CGPoint(x: x + 1.3, y: bottom))
        path.line(to: CGPoint(x: x + 6, y: bottom))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        return path
    }

    /// Trifft ein Kreis um `p` den Rahmen bzw. den Trenner?
    func frameTouches(_ p: CGPoint, radius r: CGFloat) -> Bool {
        guard showsFrame else { return false }
        if frameStyle == "mark" { return markPath.bounds.insetBy(dx: -r - 3, dy: -r - 3).contains(p) }
        return Self.distanceToEdge(p, cardRect) <= r + 3
    }
    /// Buchstaben, die noch da sind (nicht als Fleck radiert).
    var liveGlyphs: [(range: NSRange, rect: NSRect)] {
        let gone = erasedChars
        return glyphRects.filter { !gone.contains($0.range.location) }
    }
    /// Nichts mehr übrig — die Karte kann weg.
    var isFullyErased: Bool { card && !showsFill && !showsFrame && liveGlyphs.isEmpty }

    /// Treffer auf sichtbare Tinte der Karte: Fläche, Rahmen oder ein Buchstabe.
    func cardTouches(_ p: CGPoint, radius r: CGFloat) -> Bool {
        let rect = cardRect
        guard rect.insetBy(dx: -r - 3, dy: -r - 3).contains(p), !isCut(p) else { return false }
        if showsFill, rect.contains(p) { return true }
        if frameTouches(p, radius: r) { return true }
        let reach = NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        return liveGlyphs.contains { $0.rect.intersects(reach) }
    }

    /// Greifen zum Verschieben/Bearbeiten: die ganze Karte, auch zwischen den Buchstaben einer nackten Karte —
    /// radiert trifft nur, was noch Tinte ist (`cardTouches`).
    func cardGrabs(_ p: CGPoint) -> Bool {
        guard cardRect.contains(p), !isCut(p) else { return false }
        return showsFill || showsFrame || !liveGlyphs.isEmpty
    }

    /// Abstand zum Rand eines Rechtecks (innen wie außen).
    static func distanceToEdge(_ p: CGPoint, _ r: NSRect) -> CGFloat {
        if r.contains(p) { return min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y) }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
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

    static let cardPadding = CGSize(width: 10, height: 8)
    static let cardMaxWidth: CGFloat = 360
    static let cardMinWidth: CGFloat = 80

    /// Breite für eine neue Karte: kurzer Text so schmal wie nötig, langer umbrochen auf `cardMaxWidth`.
    static func cardWidth(for text: String, info: ScratchCard) -> CGFloat {
        let content = info.attributed(text: text, color: .white)
        var longest: CGFloat = 0
        (content.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: content.length), options: .byLines) { _, range, _, _ in
            longest = max(longest, content.attributedSubstring(from: range).size().width)
        }
        return min(cardMaxWidth, max(cardMinWidth, (longest + 2 * cardPadding.width + 4).rounded(.up)))
    }

    static func cardSize(text: String, width: CGFloat, info: ScratchCard) -> NSSize {
        let inner = info.attributed(text: text, color: .white).boundingRect(
            with: NSSize(width: width - 2 * cardPadding.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: width, height: (inner.height + 2 * cardPadding.height).rounded(.up))
    }

    /// Rahmen der Karte (Weltkoordinaten).
    var cardRect: NSRect {
        let size = Self.cardSize(text: text ?? "", width: cardWidth, info: cardInfo ?? ScratchCard())
        return NSRect(origin: points[0], size: size)
    }

    /// Kopie mit anderem Text/Ort/Breite/Farbe/Aussehen (Karte ändern = alte raus, Kopie rein — ein Undo-Schritt).
    func cardUpdated(text: String?, origin: CGPoint?, width: CGFloat?, color: Int?, info: ScratchCard) -> ScratchStroke {
        let newText = text ?? self.text ?? ""
        let newWidth = width ?? cardWidth
        // Nur verschoben/umgefärbt: dieselbe Tinte samt Radier-Schnitten. Neuer Satz = neue Tinte (Mats, 24.09.).
        if newText == self.text, newWidth == cardWidth, info == cardInfo {
            let copy = moved(by: origin.map { CGPoint(x: $0.x - points[0].x, y: $0.y - points[0].y) } ?? .zero)
            guard let color, color != self.color else { return copy }
            return ScratchStroke(card: newText, at: copy.points[0], width: newWidth, color: color, author: author, info: info)
                .withUID(uid, cuts: copy.cuts)
        }
        let copy = ScratchStroke(card: newText, at: origin ?? points[0], width: newWidth, color: color ?? self.color,
                                 author: author, info: info)
        copy.uid = uid
        return copy
    }

    /// Rechteck der Beschriftung: Anker auf der Grundlinie, links/mittig/rechts ausgerichtet.
    var textRect: NSRect {
        if let cachedTextRect { return cachedTextRect }
        if card {
            let rect = cardRect
            cachedTextRect = rect
            return rect
        }
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
        if isImage { return imageRect }
        if text != nil { return textRect.insetBy(dx: -2, dy: -2) }
        return path.bounds.insetBy(dx: -width, dy: -width)
    }

    /// Berührt ein Kreis um `p` das Element? (Abstand zu jedem Teilstück, nicht nur zu den Punkten; Flächen und
    /// Beschriftungen auch innen.)
    func touches(_ p: CGPoint, radius: CGFloat) -> Bool {
        guard bounds.insetBy(dx: -radius, dy: -radius).contains(p) else { return false }
        if card { return cardTouches(p, radius: radius) }
        if isCut(p) { return false }
        if isImage || text != nil { return true }
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
    /// 4 = Karten (24.09.); 3 = Elemente mit Autor/Form/Text (22.09. abends); 2 = Punkte relativ zur Kachelmitte; 1 = oben links,
    /// wird beim Laden verschoben.
    var version = 4
    var strokes: [ScratchStroke]
    var tool: ScratchTool
    var color: Int
    var size: Int
}

/// „Seit deinem letzten Blick“ (Pinnwand E, 24.09.): Stand je Element, Vergleich, Lesereihenfolge und Gruppen der Karten.
enum ScratchChanges {
    struct Snap: Equatable {
        var author: String
        var kind: String
        var bounds: NSRect
        var text: String?
        var cardID: String?
        var look: String
    }

    static func snapshot(_ elements: [ScratchStroke]) -> [String: Snap] {
        var result: [String: Snap] = [:]
        for e in elements {
            let kind = e.card ? "card" : e.isImage ? "image" : e.text != nil ? "text" : e.isClaude ? "shape" : "stroke"
            var look = "\(e.color)"
            if let info = e.cardInfo, let data = try? JSONEncoder().encode(info) { look += String(decoding: data, as: UTF8.self) }
            let title = e.cardInfo?.title.map { $0 + " — " } ?? ""
            look += "|cuts\(e.cuts.count)"
            result[e.uid] = Snap(author: e.isClaude ? "claude" : "mats", kind: kind, bounds: e.bounds,
                                 text: e.visibleText ?? e.text.map { title + $0 }, cardID: e.cardInfo?.id, look: look)
        }
        return result
    }

    static func diff(_ before: [String: Snap], _ now: [String: Snap]) -> [String: Any] {
        var moved: [[String: Any]] = [], edited: [[String: Any]] = [], addedCards: [[String: Any]] = [], removedCards: [[String: Any]] = []
        var added: [String: [NSRect]] = [:], removed: [String: [NSRect]] = [:]
        func label(_ s: Snap) -> String { s.cardID ?? s.kind }
        for (uid, snap) in now {
            guard let old = before[uid] else {
                if snap.kind == "card" { addedCards.append(["id": label(snap), "by": snap.author, "text": snap.text ?? "", "bounds": rect(snap.bounds)]) }
                else { added["\(snap.author)|\(snap.kind)", default: []].append(snap.bounds) }
                continue
            }
            let dx = snap.bounds.midX - old.bounds.midX, dy = snap.bounds.midY - old.bounds.midY
            if hypot(dx, dy) >= 4 {
                moved.append(["what": snap.kind == "card" ? label(snap) : snap.kind, "from": rect(old.bounds), "to": rect(snap.bounds)])
            }
            if old.text != snap.text || old.look != snap.look {
                var e: [String: Any] = ["what": label(snap)]
                if old.text != snap.text { e["before"] = old.text ?? ""; e["after"] = snap.text ?? "" } else { e["look"] = true }
                edited.append(e)
            }
        }
        for (uid, old) in before where now[uid] == nil {
            if old.kind == "card" { removedCards.append(["id": label(old), "text": old.text ?? ""]) }
            else { removed["\(old.author)|\(old.kind)", default: []].append(old.bounds) }
        }
        func groups(_ d: [String: [NSRect]]) -> [[String: Any]] {
            d.map { key, boxes in
                let parts = key.split(separator: "|")
                let box = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
                return ["by": String(parts[0]), "kind": String(parts[1]), "count": boxes.count, "bounds": rect(box)]
            }
        }
        var result: [String: Any] = [:]
        if !addedCards.isEmpty { result["cardsAdded"] = addedCards }
        if !removedCards.isEmpty { result["cardsRemoved"] = removedCards }
        if !moved.isEmpty { result["moved"] = moved }
        if !edited.isEmpty { result["edited"] = edited }
        if !added.isEmpty { result["added"] = groups(added) }
        if !removed.isEmpty { result["erased"] = groups(removed) }
        return result
    }

    /// Lesereihenfolge: Zeilen (Karten, deren Mitte in die Höhe der ersten passt), darin von links nach rechts.
    static func readingOrder(_ cards: [ScratchStroke]) -> [ScratchStroke] {
        var rest = cards.sorted { $0.bounds.minY < $1.bounds.minY }
        var order: [ScratchStroke] = []
        while let first = rest.first {
            let row = rest.filter { $0.bounds.midY <= first.bounds.maxY }
            order += row.sorted { $0.bounds.minX < $1.bounds.minX }
            rest.removeAll { card in row.contains { $0 === card } }
        }
        return order
    }

    /// Karten, die nah beieinander liegen (≤ 28 pt Abstand), bilden eine Gruppe — in Lesereihenfolge.
    static func groups(_ cards: [ScratchStroke]) -> [[ScratchStroke]] {
        let ordered = readingOrder(cards)
        var parent = Array(ordered.indices)
        func find(_ i: Int) -> Int { parent[i] == i ? i : find(parent[i]) }
        for i in ordered.indices { for j in ordered.indices where j > i {
            if ordered[i].bounds.insetBy(dx: -14, dy: -14).intersects(ordered[j].bounds.insetBy(dx: -14, dy: -14)) {
                parent[find(j)] = find(i)
            }
        } }
        var buckets: [Int: [ScratchStroke]] = [:], keys: [Int] = []
        for i in ordered.indices {
            let root = find(i)
            if buckets[root] == nil { keys.append(root) }
            buckets[root, default: []].append(ordered[i])
        }
        return keys.map { buckets[$0]! }
    }

    private static func rect(_ r: NSRect) -> [String: Double] {
        ["x": (Double(r.minX) * 10).rounded() / 10, "y": (Double(r.minY) * 10).rounded() / 10,
         "w": (Double(r.width) * 10).rounded() / 10, "h": (Double(r.height) * 10).rounded() / 10]
    }
}
