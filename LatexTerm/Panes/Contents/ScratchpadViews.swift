import AppKit

/// Wurzel der Scratchpad-Kachel: Malfläche über die ganze Kachel, Werkzeugleiste schwebt oben links.
/// Hochkant, solange die Kachel hoch genug ist, sonst quer.
final class ScratchpadView: NSView {
    let canvas = ScratchpadCanvas()
    private let toolbar = ScratchpadToolbar()
    /// Kurzer Hinweis — derselbe Baustein wie in Vorschau/Web (LineToast).
    private let note = PreviewPill()
    /// ➤ in der Werkzeugleiste (true = mit ⌥: Ziel immer auswählen).
    var onSend: ((Bool) -> Void)?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        addSubview(toolbar)
        toolbar.canvas = canvas
        toolbar.onSend = { [weak self] choose in self?.onSend?(choose) }
        canvas.onStateChange = { [weak toolbar] in toolbar?.needsDisplay = true }
        addSubview(note)
    }

    func setDimmed(_ dimmed: Bool) {
        canvas.dimmed = dimmed
        toolbar.alphaValue = dimmed ? 0.65 : 1
    }

    /// Wo das Auswahlmenü des Senden-Knopfs aufgeht.
    var sendAnchor: (view: NSView, rect: NSRect) { (toolbar, toolbar.sendRect) }

    /// Kurzer Hinweis unten mittig (Senden ging/ging nicht), blendet sich selbst aus.
    func showNote(_ text: String) {
        note.flash(text, hold: 2.4)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func apply(_ theme: TerminalTheme) {
        canvas.apply(theme)
        toolbar.apply(theme)
        note.applyTheme(theme)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let length = ScratchpadToolbar.length, thickness = ScratchpadToolbar.thickness, margin: CGFloat = 8
        toolbar.vertical = newSize.height - 2 * margin >= length || newSize.width - 2 * margin < length
        toolbar.frame = toolbar.vertical
            ? NSRect(x: margin, y: margin, width: thickness, height: length)
            : NSRect(x: margin, y: margin, width: length, height: thickness)
        note.layoutIn(bounds)
    }
}

// MARK: - Malfläche

final class ScratchpadCanvas: NSView {
    /// Zeichnung oder Werkzeug geändert → sichern, Chip neu.
    var onChange: (() -> Void)?
    /// ⌘S → Sichern-Dialog (macht der Inhalt).
    var onSaveRequest: (() -> Void)?
    /// ⇧⌘⏎ → an Agent schicken (true = mit ⌥: Ziel immer auswählen).
    var onSendRequest: ((Bool) -> Void)?
    /// Werkzeugleiste neu zeichnen.
    var onStateChange: (() -> Void)?

    private(set) var tool: ScratchTool = .pen
    private(set) var colorIndex = 0
    private(set) var sizeIndex = 1
    private(set) var palette = [NSColor](repeating: .white, count: ScratchPalette.names.count)
    private var paper: NSColor = .black
    /// Kachel nicht fokussiert: Papier abgedunkelt, Tinte unverändert.
    var dimmed = false { didSet { if dimmed != oldValue { needsDisplay = true } } }
    private var ground: NSColor { dimmed ? PaneContainerView.dimmedGround(paper) : paper }

    private var strokes: [ScratchStroke] = []
    private var current: ScratchStroke?
    private var erased: [(index: Int, stroke: ScratchStroke)] = []
    private var lastErasePoint: CGPoint?
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    /// Ein Undo-Schritt: entfernte Elemente (Index zur Zeit des Entfernens, in dieser Reihenfolge) und
    /// danach angehängte. Deckt Strich, Radierzug, Leeren und Agenten-Zeichnen (auch mit Ersetzen) ab.
    private struct Edit {
        var removed: [(index: Int, stroke: ScratchStroke)] = []
        var added: [ScratchStroke] = []
        /// Am Platz ausgetauscht (radiert, Pfeil nachgezogen, Karte neu gesetzt): alte → neue Fassung.
        var swapped: [(old: ScratchStroke, new: ScratchStroke)] = []
    }

    static let penWidths: [CGFloat] = [1.5, 3, 6]
    static let markerWidths: [CGFloat] = [10, 18, 30]
    static let eraserRadii: [CGFloat] = [6, 14, 28]
    /// Marker deckt nur halb — Text darunter bleibt lesbar.
    static let markerAlpha: CGFloat = 0.35

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Sonst zöge Malen das Fenster (`isMovableByWindowBackground`).
    override var mouseDownCanMoveWindow: Bool { false }

    var strokeCount: Int { strokes.count }

    func count(_ layer: ScratchLayer) -> Int { strokes.filter { Self.matches($0, layer) }.count }

    private static func matches(_ stroke: ScratchStroke, _ layer: ScratchLayer) -> Bool {
        switch layer {
        case .all: true
        case .claude: stroke.isClaude
        case .mats: !stroke.isClaude
        case .cards: stroke.card && stroke.isClaude
        }
    }

    /// Umriss aller Elemente einer Ebene (Weltkoordinaten); nil = keine.
    func contentBounds(_ layer: ScratchLayer) -> NSRect? {
        let list = strokes.filter { Self.matches($0, layer) }
        guard let first = list.first else { return nil }
        return list.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
    }

    /// Was die Kachel in der Normalsicht zeigt (Weltkoordinaten, Mitte = 0,0) — egal, wohin Mats gerade zoomt.
    var visibleWorldRect: NSRect {
        NSRect(x: -bounds.width / 2, y: -bounds.height / 2, width: bounds.width, height: bounds.height)
    }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var inkColor: NSColor { palette[colorIndex] }
    private var eraserRadius: CGFloat { Self.eraserRadii[sizeIndex] }
    /// Radierer in Zeichnungs-Koordinaten: am Bildschirm immer gleich groß, egal wie weit gezoomt.
    private var worldEraserRadius: CGFloat { eraserRadius / zoom }

    func apply(_ theme: TerminalTheme) {
        paper = theme.background.withAlphaComponent(1)
        palette = ScratchPalette.colors(theme)
        needsDisplay = true
        cursorChanged()
    }

    // MARK: Werkzeuge

    func select(_ tool: ScratchTool) {
        self.tool = tool
        stateChanged()
    }

    /// Farbe wählen heißt malen wollen: aus dem Radierer zurück zum Stift.
    func selectColor(_ index: Int) {
        colorIndex = max(0, min(index, palette.count - 1))
        if tool.erases || tool == .none { tool = .pen }
        stateChanged()
    }

    func stepSize(_ delta: Int) {
        let next = sizeIndex + delta
        guard Self.penWidths.indices.contains(next) else { NSSound.beep(); return }
        sizeIndex = next
        stateChanged()
    }

    /// Toolbar: Stärke im Kreis durchschalten.
    func cycleSize() {
        sizeIndex = (sizeIndex + 1) % Self.penWidths.count
        stateChanged()
    }

    private func stateChanged() {
        cursorChanged()
        onStateChange?()
        onChange?()
    }

    // MARK: Bearbeiten

    /// Elemente einer Ebene entfernen (ein Undo-Schritt); gibt die Anzahl zurück.
    @discardableResult
    func clear(_ layer: ScratchLayer = .all) -> Int {
        let removed = remove(layer)
        guard !removed.isEmpty else { return 0 }
        commit(Edit(removed: removed))
        return removed.count
    }

    /// Agenten-Zeichnung anhängen, optional vorher eine Ebene leeren — zusammen EIN Undo-Schritt, damit ⌘Z
    /// Mats' Skizze zurückbringt. Gibt die Zahl der entfernten Elemente zurück.
    @discardableResult
    func add(_ items: [ScratchStroke], replacing layer: ScratchLayer?) -> Int {
        let removed = layer.map(remove) ?? []
        guard !items.isEmpty || !removed.isEmpty else { return 0 }
        strokes.append(contentsOf: items)
        commit(Edit(removed: removed, added: items))
        return removed.count
    }

    /// Von hinten entfernen: der gemerkte Index ist dann zugleich der ursprüngliche.
    private func remove(_ layer: ScratchLayer) -> [(index: Int, stroke: ScratchStroke)] {
        var removed: [(index: Int, stroke: ScratchStroke)] = []
        for index in strokes.indices.reversed() where Self.matches(strokes[index], layer) {
            removed.append((index, strokes.remove(at: index)))
        }
        return removed
    }

    func undo() {
        guard let edit = undoStack.popLast() else { NSSound.beep(); return }
        strokes.removeAll { stroke in edit.added.contains { $0 === stroke } }
        for e in edit.removed.reversed() { strokes.insert(e.stroke, at: min(e.index, strokes.count)) }
        for pair in edit.swapped.reversed() {
            if let i = strokes.firstIndex(where: { $0 === pair.new }) { strokes[i] = pair.old }
        }
        redoStack.append(edit)
        edited()
    }

    func redo() {
        guard let edit = redoStack.popLast() else { NSSound.beep(); return }
        strokes.removeAll { stroke in edit.removed.contains { $0.stroke === stroke } }
        strokes.append(contentsOf: edit.added)
        for pair in edit.swapped {
            if let i = strokes.firstIndex(where: { $0 === pair.old }) { strokes[i] = pair.new }
        }
        undoStack.append(edit)
        edited()
    }

    /// Neuer Schritt: Redo verfällt.
    private func commit(_ edit: Edit) {
        undoStack.append(edit)
        redoStack.removeAll()
        edited()
    }

    private func edited() {
        needsDisplay = true
        onStateChange?()
        onChange?()
    }

    // MARK: Karten (Brainstorm-Pinnwand, 24.09.)

    /// Ein Auftrag an die Karten: neue anlegen (ohne `id`), bestehende ändern/verschieben (`id` + Felder) oder
    /// entfernen (`id` + `remove`). Nicht angegebene Felder bleiben.
    struct CardEntry {
        var id: String?
        var remove = false
        var text: String?
        var origin: CGPoint?
        var width: CGFloat?
        var color: Int?
        /// Nur gesetzte Felder zählen (auf das bisherige Aussehen gelegt).
        var style = ScratchCard()
        /// Eingerastete Pfeile von dieser Karte zu diesen (ids).
        var arrowTo: [String] = []
    }

    struct CardResult {
        var added: [ScratchStroke] = []
        var updated: [ScratchStroke] = []
        var removed: [String] = []
    }

    /// Alle Einträge als EIN Undo-Schritt. Ohne Ort sucht `freeSpot` Platz; Karten eines Aufrufs stapeln sich.
    func applyCards(_ entries: [CardEntry], author: String?, replacing layer: ScratchLayer? = nil) throws -> CardResult {
        // Unbekannte id mit Text = neue Karte unter diesem Namen (so kann ein Aufruf sie gleich verbinden).
        for entry in entries where entry.id != nil && !strokes.contains(where: { $0.cardInfo?.id == entry.id }) {
            guard !entry.remove, entry.text?.isEmpty == false else {
                throw PaneArgsError("Karte „\(entry.id!)“ gibt es nicht (ids aus scratch_look; neue Karte braucht text)")
            }
        }
        var removed = layer.map(remove) ?? []
        var result = CardResult()
        var placedBoxes: [NSRect] = []
        var nextNumber = cardNumbers().max().map { $0 + 1 } ?? 1
        /// Eintrag → Karte, die er angelegt oder geändert hat (Ausgang seiner Pfeile).
        var cardFor: [Int: ScratchStroke] = [:]
        for (position, entry) in entries.enumerated() {
            if let id = entry.id, let index = strokes.firstIndex(where: { $0.cardInfo?.id == id }) {
                let old = strokes.remove(at: index)
                removed.append((index, old))
                if entry.remove { result.removed.append(id); continue }
                let info = merge(old.cardInfo ?? ScratchCard(), entry.style)
                let copy = old.cardUpdated(text: entry.text, origin: entry.origin,
                                           width: entry.width.map(Self.clampCardWidth), color: entry.color, info: info)
                result.updated.append(copy)
                cardFor[position] = copy
                continue
            }
            guard let text = entry.text, !text.isEmpty else { continue }
            var info = entry.style
            if let id = entry.id { info.id = id } else {
                info.id = "k\(nextNumber)"
                nextNumber += 1
            }
            let width = entry.width.map(Self.clampCardWidth) ?? ScratchStroke.cardWidth(for: text, info: info)
            let size = ScratchStroke.cardSize(text: text, width: width, info: info)
            let origin = entry.origin ?? freeSpot(for: size, also: placedBoxes + result.updated.map(\.bounds))
            let card = ScratchStroke(card: text, at: origin, width: width, color: entry.color ?? (author == nil ? colorIndex : ScratchPalette.claude),
                                     author: author, info: info)
            placedBoxes.append(card.bounds)
            result.added.append(card)
            cardFor[position] = card
        }
        var added = result.updated + result.added
        strokes.append(contentsOf: added)
        // Pfeile an verschobenen/neu gesetzten Karten ziehen mit.
        var swaps: [(old: ScratchStroke, new: ScratchStroke)] = []
        let moved = Set(result.updated.map(\.uid))
        if !moved.isEmpty {
            let linked = linkedStrokes(to: moved).map { ($0, strokes[$0]) }
            for (index, fresh) in relinked(linked) {
                swaps.append((strokes[index], fresh))
                strokes[index] = fresh
            }
        }
        // Neue Pfeile (arrowTo).
        for (position, entry) in entries.enumerated() where !entry.arrowTo.isEmpty && !entry.remove {
            guard let source = cardFor[position] ?? entry.id.flatMap({ id in strokes.last { $0.cardInfo?.id == id } }) else { continue }
            for target in entry.arrowTo {
                guard let dest = strokes.last(where: { $0.cardInfo?.id == target }), dest !== source else {
                    throw PaneArgsError("arrowTo: Karte „\(target)“ gibt es nicht")
                }
                let arrow = Self.arrow(from: source, to: dest, color: entry.color ?? ScratchPalette.claude, author: author)
                strokes.append(contentsOf: arrow)
                added += arrow
            }
        }
        guard !added.isEmpty || !removed.isEmpty || !swaps.isEmpty else { return result }
        commit(Edit(removed: removed, added: added, swapped: swaps))
        return result
    }

    /// Gerader, eingerasteter Pfeil von Rand zu Rand zweier Objekte, Spitze als eigener, folgender Strich.
    static func arrow(from a: ScratchStroke, to b: ScratchStroke, color: Int, author: String?) -> [ScratchStroke] {
        let ra = a.bounds.insetBy(dx: -6, dy: -6), rb = b.bounds.insetBy(dx: -6, dy: -6)
        let ca = CGPoint(x: ra.midX, y: ra.midY), cb = CGPoint(x: rb.midX, y: rb.midY)
        let d = CGPoint(x: cb.x - ca.x, y: cb.y - ca.y)
        func exit(_ r: NSRect, _ c: CGPoint, _ dir: CGPoint) -> CGPoint {
            let tx = dir.x == 0 ? CGFloat.infinity : (r.width / 2) / abs(dir.x)
            let ty = dir.y == 0 ? CGFloat.infinity : (r.height / 2) / abs(dir.y)
            let t = min(tx, ty)
            return CGPoint(x: c.x + dir.x * t, y: c.y + dir.y * t)
        }
        let p0 = exit(ra, ca, d), p1 = exit(rb, cb, CGPoint(x: -d.x, y: -d.y))
        let shaft = ScratchStroke(line: [p0, p1], color: color, width: 2, author: author)
        shaft.link = ScratchLink(from: a.uid, to: b.uid,
                                 a: CGPoint(x: p0.x - a.points[0].x, y: p0.y - a.points[0].y),
                                 b: CGPoint(x: p1.x - b.points[0].x, y: p1.y - b.points[0].y))
        let angle = atan2(p1.y - p0.y, p1.x - p0.x)
        let head = [angle + .pi * 0.85, angle - .pi * 0.85].map { phi in CGPoint(x: p1.x + cos(phi) * 11, y: p1.y + sin(phi) * 11) }
        let tip = ScratchStroke(line: [head[0], p1, head[1]], color: color, width: 2, author: author)
        tip.follows = shaft.uid
        return [shaft, tip]
    }

    private static func clampCardWidth(_ w: CGFloat) -> CGFloat { min(800, max(ScratchStroke.cardMinWidth, w)) }

    private func merge(_ base: ScratchCard, _ patch: ScratchCard) -> ScratchCard {
        var r = base
        if let v = patch.title { r.title = v.isEmpty ? nil : v }
        if let v = patch.font { r.font = v }
        if let v = patch.size { r.size = v }
        if let v = patch.bold { r.bold = v }
        if let v = patch.italic { r.italic = v }
        if let v = patch.textColor { r.textColor = v }
        if let v = patch.frame { r.frame = v }
        if let v = patch.fill { r.fill = v }
        if let v = patch.align { r.align = v }
        return r
    }

    private func cardNumbers() -> [Int] {
        strokes.compactMap { $0.cardInfo?.id }.compactMap { $0.hasPrefix("k") ? Int($0.dropFirst()) : nil }
    }

    /// Karten ohne Namen (erste Fassung, Mats' ⌘V) bekommen einen — sonst könnte kein Agent sie ansprechen.
    private func nameCards() {
        var next = cardNumbers().max().map { $0 + 1 } ?? 1
        for stroke in strokes where stroke.card && stroke.cardInfo?.id == nil {
            stroke.cardInfo?.id = "k\(next)"
            next += 1
        }
    }

    /// Obere linke Ecke für eine Karte `size`, die nichts überdeckt. Zuerst im sichtbaren Bereich (Spalten von rechts,
    /// darin von oben); ist der voll, in Spalten rechts neben allem Vorhandenen — dort stapeln sich weitere Karten
    /// untereinander, statt weit unter der Zeichnung zu landen.
    func freeSpot(for size: NSSize, also extra: [NSRect] = []) -> CGPoint {
        let area = visibleWorldRect.insetBy(dx: 24, dy: 24)
        let boxes = strokes.map(\.bounds) + extra
        let obstacles = boxes.map { $0.insetBy(dx: -8, dy: -8) }
        func scan(xs: [CGFloat], top: CGFloat, bottom: CGFloat) -> CGPoint? {
            for x in xs {
                var y = top
                while y + size.height <= bottom {
                    let rect = NSRect(origin: CGPoint(x: x, y: y), size: size)
                    if let hit = obstacles.first(where: { $0.intersects(rect) }) {
                        y = max(y + 12, hit.maxY + 1)
                    } else {
                        return rect.origin
                    }
                }
            }
            return nil
        }
        let visibleXs = Array(stride(from: area.maxX - size.width, through: area.minX, by: -12))
        if let spot = scan(xs: visibleXs, top: area.minY, bottom: area.maxY) { return spot }
        // Rechts daneben: Spalten ab dem rechten Rand der Zeichnung (ohne Karten), je eine Kartenbreite weiter.
        let drawing = strokes.filter { !$0.card }.map(\.bounds)
        let startX = max(area.minX, (drawing.map(\.maxX).max() ?? area.maxX) + 24)
        let top = min(area.minY, boxes.map(\.minY).min() ?? area.minY)
        let height = max(area.height, (boxes.map(\.maxY).max() ?? area.maxY) - top) + size.height + 48
        let columns = (0..<40).map { startX + CGFloat($0) * (size.width + 16) }
        if let spot = scan(xs: columns, top: top, bottom: top + height) { return spot }
        return CGPoint(x: startX, y: (boxes.map(\.maxY).max() ?? area.minY) + 16)
    }

    /// Bild aus der Zwischenablage (Screenshot): höchstens 1600 px gespeichert, höchstens 420 pt breit gezeigt,
    /// am Zeiger oder in freiem Platz.
    private func pasteImage(_ image: NSImage) {
        guard let rep = image.representations.first else { NSSound.beep(); return }
        var pixels = NSSize(width: max(rep.pixelsWide, 1), height: max(rep.pixelsHigh, 1))
        if pixels.width <= 1 || pixels.height <= 1 { pixels = image.size }
        let shrink = min(1, 1600 / max(pixels.width, pixels.height))
        let target = NSSize(width: (pixels.width * shrink).rounded(), height: (pixels.height * shrink).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { NSSound.beep(); return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
        let points = image.size.width > 1 ? image.size : target
        let scale = min(1, 420 / max(points.width, 1))
        let size = NSSize(width: (points.width * scale).rounded(), height: (points.height * scale).rounded())
        var origin: CGPoint?
        if let window {
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(local) { origin = toWorld(local) }
        }
        let element = ScratchStroke(image: png, at: origin ?? freeSpot(for: size), size: size, author: nil)
        strokes.append(element)
        commit(Edit(added: [element]))
    }

    /// Alle Elemente in Zeichenreihenfolge (für den Vergleich „seit dem letzten Blick“).
    var elements: [ScratchStroke] { strokes }

    /// Karten für Agenten (`call look`).
    var cards: [ScratchStroke] { strokes.filter(\.card) }

    /// ⌘V: Text aus der Zwischenablage an den Zeiger (sonst in freien Platz). Eine Liste wird zu einer Karte je
    /// Punkt, untereinander; `split: false` legt alles in eine Karte. Aussehen: Terminal-Look.
    private func pasteCards(split: Bool) {
        let board = NSPasteboard.general
        let raw = board.string(forType: .string) ?? ""
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let image = NSImage(pasteboard: board) { pasteImage(image) } else { NSSound.beep() }
            return
        }
        let items = split ? CardText.items(raw) : [CardText.unwrap(raw)].filter { !$0.isEmpty }
        guard !items.isEmpty else { NSSound.beep(); return }
        var origin: CGPoint?
        if let window {
            let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(local) { origin = toWorld(local) }
        }
        var entries: [CardEntry] = []
        var y = origin?.y ?? 0
        for item in items {
            let width = ScratchStroke.cardWidth(for: item, info: ScratchCard())
            entries.append(CardEntry(text: item, origin: origin.map { CGPoint(x: $0.x, y: y) }, width: width))
            y += ScratchStroke.cardSize(text: item, width: width, info: ScratchCard()).height + 10
        }
        _ = try? applyCards(entries, author: nil)
    }

    // MARK: Sichern

    func restore(_ doc: ScratchDocument) {
        strokes = doc.strokes
        // v1 lag in Kachel-Koordinaten (oben links = 0,0): Zeichnung auf die Mitte legen.
        if doc.version < 2, let first = strokes.first {
            let box = strokes.map(\.bounds).reduce(first.bounds) { $0.union($1) }
            let shift = CGPoint(x: -box.midX, y: -box.midY)
            strokes.forEach { $0.offset(by: shift) }
        }
        nameCards()
        tool = .none   // Kachel startet ohne Fokus, also ohne Werkzeug
        colorIndex = max(0, min(doc.color, ScratchPalette.names.count - 1))
        sizeIndex = max(0, min(doc.size, Self.penWidths.count - 1))
        needsDisplay = true
    }

    func document() -> ScratchDocument {
        ScratchDocument(strokes: strokes, tool: tool, color: colorIndex, size: sizeIndex)
    }

    /// PNG in doppelter Auflösung, zugeschnitten auf die Zeichnung (+ Rand), auf dem Papier des Themes.
    /// Leer → die sichtbare Fläche.
    func pngData() -> Data? {
        let rect = strokes.isEmpty
            ? toWorld(bounds)
            : strokes.map(\.bounds).reduce(strokes[0].bounds) { $0.union($1) }.insetBy(dx: -16, dy: -16).integral
        return render(rect, scale: 2, under: nil, over: nil)
    }

    /// Bild für einen Agenten: Normalsicht plus alles Gezeichnete, mit Koordinatenraster (Beschriftung am Rand)
    /// und — falls etwas außerhalb liegt — dem sichtbaren Bereich gestrichelt. Längste Seite ≤ `maxSide` Pixel.
    func lookImage(maxSide: CGFloat) -> (png: Data, region: NSRect, scale: CGFloat, grid: CGFloat)? {
        let visible = visibleWorldRect
        guard visible.width >= 1, visible.height >= 1 else { return nil }
        var region = visible
        if let content = contentBounds(.all) { region = region.union(content.insetBy(dx: -16, dy: -16)) }
        region = region.integral
        let scale = min(2, maxSide / max(region.width, region.height))
        let span = max(region.width, region.height)
        let grid = [25, 50, 100, 200, 250, 500, 1000, 2000, 5000].map { CGFloat($0) }.first { span / $0 <= 16 } ?? 10000
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11 / scale, weight: .regular)
        let (dim, faint) = (palette[0].withAlphaComponent(0.55), palette[0].withAlphaComponent(0.13))
        let under: (NSRect) -> Void = { rect in
            let line = 1 / scale
            var x = (rect.minX / grid).rounded(.up) * grid
            while x <= rect.maxX {
                (x == 0 ? dim.withAlphaComponent(0.3) : faint).setFill()
                NSRect(x: x - line / 2, y: rect.minY, width: line, height: rect.height).fill()
                x += grid
            }
            var y = (rect.minY / grid).rounded(.up) * grid
            while y <= rect.maxY {
                (y == 0 ? dim.withAlphaComponent(0.3) : faint).setFill()
                NSRect(x: rect.minX, y: y - line / 2, width: rect.width, height: line).fill()
                y += grid
            }
        }
        let over: (NSRect) -> Void = { rect in
            let attributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: dim]
            let pad = 3 / scale
            var x = (rect.minX / grid).rounded(.up) * grid
            while x <= rect.maxX {
                ("\(Int(x))" as NSString).draw(at: NSPoint(x: x + pad, y: rect.minY + pad), withAttributes: attributes)
                x += grid
            }
            var y = (rect.minY / grid).rounded(.up) * grid
            while y <= rect.maxY {
                if y > rect.minY + grid / 2 {
                    ("\(Int(y))" as NSString).draw(at: NSPoint(x: rect.minX + pad, y: y + pad), withAttributes: attributes)
                }
                y += grid
            }
            if rect.width > visible.width + 1 || rect.height > visible.height + 1 {
                let frame = NSBezierPath(rect: visible)
                frame.lineWidth = 1.5 / scale
                frame.setLineDash([6 / scale, 4 / scale], count: 2, phase: 0)
                dim.setStroke()
                frame.stroke()
            }
        }
        guard let png = render(region, scale: scale, under: under, over: over) else { return nil }
        return (png, region, scale, grid)
    }

    /// Zeichnet einen Weltausschnitt in ein Bitmap. Geflippter Kontext wie die View — sonst stünde Text kopf.
    private func render(_ rect: NSRect, scale: CGFloat, under: ((NSRect) -> Void)?, over: ((NSRect) -> Void)?) -> Data? {
        let pixelsWide = Int((rect.width * scale).rounded(.up)), pixelsHigh = Int((rect.height * scale).rounded(.up))
        guard rect.width >= 1, rect.height >= 1, pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: CGFloat(pixelsWide) / scale, height: CGFloat(pixelsHigh) / scale)
        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let context = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: rep.size.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.translateX(by: -rect.minX, yBy: -rect.minY)
        flip.concat()
        paper.setFill()
        rect.fill()
        under?(rect)
        drawStrokes(in: rect)
        over?(rect)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func copyImage() {
        guard let png = pngData() else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    // MARK: Maus

    /// Erstklick-Regel: Klick in eine Kachel, die nicht den Fokus hat, holt nur den Fokus und malt nicht —
    /// sonst hinterlässt jedes „reinklicken, um ⌘⏎ zu drücken" einen Punkt. Gilt bis zum Loslassen.
    private var focusClick = false
    /// Zeitstempel des Klicks, der uns den Fokus gebracht hat. AppKit macht die angeklickte View schon
    /// VOR `mouseDown` zum First Responder — in `mouseDown` ist der Fokus also immer schon da.
    private var focusedByClickAt: TimeInterval?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let event = NSApp.currentEvent, [.leftMouseDown, .rightMouseDown].contains(event.type),
           event.window === window, hitTest(superview?.convert(event.locationInWindow, from: nil) ?? .zero) === self {
            focusedByClickAt = event.timestamp
        }
        return ok
    }

    /// Nimmt den Fokus; true = der Klick war nur zum Fokussieren und wird geschluckt.
    private func takeFocusClick(_ event: NSEvent) -> Bool {
        window?.makeFirstResponder(self)
        focusClick = focusedByClickAt == event.timestamp
        focusedByClickAt = nil
        return focusClick
    }

    override func mouseDown(with event: NSEvent) {
        // Ohne Werkzeug malt nichts — dann darf schon der Fokus-Klick ziehen (Karte oder Fläche).
        if takeFocusClick(event) {
            guard tool == .none else { return }
            focusClick = false
        }
        endEditing(commit: true)
        let p = point(event)
        if tool == .eraser { beginErase(at: p); return }
        if tool == .cutter { beginCut(at: p); return }
        // Auf einer Karte oder einem Bild: ziehen verschiebt, Doppelklick bearbeitet die Karte (⌥ = trotzdem malen).
        if !event.modifierFlags.contains(.option), let index = strokes.lastIndex(where: { $0.card ? $0.cardGrabs(p) : $0.isImage && $0.touches(p, radius: 0) }) {
            if event.clickCount == 2, strokes[index].card { beginEditing(strokes[index]); return }
            beginObjectDrag(index, at: p)
            return
        }
        if tool == .none {
            panDrag = (convert(event.locationInWindow, from: nil), pan)
            return
        }
        let width = tool == .marker ? Self.markerWidths[sizeIndex] : Self.penWidths[sizeIndex]
        let stroke = ScratchStroke(start: p, color: colorIndex, width: width, marker: tool == .marker)
        current = stroke
        invalidate(stroke.bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        if focusClick { return }
        let p = point(event)
        if objectDrag != nil { continueObjectDrag(to: p); return }
        if let drag = panDrag {
            let now = convert(event.locationInWindow, from: nil)
            springTimer?.invalidate(); springTimer = nil
            setView(pan: CGPoint(x: drag.pan.x + now.x - drag.start.x, y: drag.pan.y + now.y - drag.start.y), zoom: zoom)
            return
        }
        if lastErasePoint != nil { continueErase(to: p); return }
        if cutting != nil { continueCut(to: p); return }
        guard let stroke = current else { return }
        let before = stroke.bounds
        if event.modifierFlags.contains(.shift) {
            stroke.straighten(to: p)
        } else if let last = stroke.points.last, hypot(p.x - last.x, p.y - last.y) >= 0.8 {
            stroke.append(p)
        }
        invalidate(before.union(stroke.bounds))
    }

    override func mouseUp(with event: NSEvent) {
        if focusClick { focusClick = false; return }
        if objectDrag != nil { endObjectDrag(); return }
        if panDrag != nil { panDrag = nil; return }
        if lastErasePoint != nil { endErase(); return }
        if cutting != nil { endCut(); return }
        guard let stroke = current else { return }
        current = nil
        if !stroke.marker { attachLink(stroke) }
        strokes.append(stroke)
        commit(Edit(added: [stroke]))
    }

    /// Rechtsklick bzw. Zwei-Finger-Klick radiert, egal welches Werkzeug gewählt ist.
    override func rightMouseDown(with event: NSEvent) {
        if takeFocusClick(event) { return }
        beginErase(at: point(event))
    }
    override func rightMouseDragged(with event: NSEvent) { if !focusClick { continueErase(to: point(event)) } }
    override func rightMouseUp(with event: NSEvent) {
        if focusClick { focusClick = false; return }
        endErase()
    }

    // MARK: Karten und Bilder ziehen — eingerastete Pfeile ziehen mit

    private struct ObjectDrag {
        var index: Int
        var original: ScratchStroke
        var live: ScratchStroke
        var start: CGPoint
        var moved: CGPoint = .zero
        /// Pfeile (und ihre Spitzen) an diesem Objekt: Platz und Fassung zu Beginn.
        var linked: [(index: Int, original: ScratchStroke)] = []
    }
    private var objectDrag: ObjectDrag?
    /// Ohne Werkzeug: Ziehen auf freier Fläche verschiebt die Sicht (Start am Bildschirm, Sicht zu Beginn).
    private var panDrag: (start: CGPoint, pan: CGPoint)?

    private func beginObjectDrag(_ index: Int, at p: CGPoint) {
        let original = strokes[index]
        let live = original.copy()
        strokes[index] = live
        objectDrag = ObjectDrag(index: index, original: original, live: live, start: p,
                                linked: linkedStrokes(to: [original.uid]).map { ($0, strokes[$0]) })
    }

    private func continueObjectDrag(to p: CGPoint) {
        guard var drag = objectDrag else { return }
        let total = CGPoint(x: p.x - drag.start.x, y: p.y - drag.start.y)
        var dirty = drag.live.bounds
        drag.live.offset(by: CGPoint(x: total.x - drag.moved.x, y: total.y - drag.moved.y))
        drag.moved = total
        dirty = dirty.union(drag.live.bounds)
        for (index, fresh) in relinked(drag.linked) where strokes.indices.contains(index) {
            dirty = dirty.union(strokes[index].bounds).union(fresh.bounds)
            strokes[index] = fresh
        }
        objectDrag = drag
        invalidate(dirty.insetBy(dx: -4, dy: -4))
    }

    private func endObjectDrag() {
        guard let drag = objectDrag else { return }
        objectDrag = nil
        guard hypot(drag.moved.x, drag.moved.y) >= 2 else {
            // Nur geklickt: alles wie vorher.
            strokes[drag.index] = drag.original
            for (index, original) in drag.linked where strokes.indices.contains(index) { strokes[index] = original }
            needsDisplay = true
            return
        }
        let swaps = drag.linked.compactMap { index, original in
            strokes.indices.contains(index) && strokes[index] !== original ? (old: original, new: strokes[index]) : nil
        }
        // Gezogenes nach oben legen.
        strokes.remove(at: drag.index)
        strokes.append(drag.live)
        commit(Edit(removed: [(drag.index, drag.original)], added: [drag.live], swapped: swaps))
    }

    /// Plätze der Pfeile, die an einem dieser Objekte hängen, samt ihrer Spitzen.
    private func linkedStrokes(to uids: Set<String>) -> [Int] {
        let shafts = strokes.indices.filter { i in strokes[i].link.map { uids.contains($0.from) || uids.contains($0.to) } ?? false }
        let shaftIDs = Set(shafts.map { strokes[$0].uid })
        let heads = strokes.indices.filter { strokes[$0].follows.map(shaftIDs.contains) ?? false }
        return shafts + heads
    }

    /// Pfeile an ihre Karten anpassen: Enden bleiben an den gemerkten Punkten, die Handschrift wird gedreht/gestreckt.
    /// `originals` = Fassungen, von denen aus gerechnet wird (Beginn des Zugs) — so häuft sich kein Rundungsfehler.
    private func relinked(_ originals: [(index: Int, original: ScratchStroke)]) -> [(Int, ScratchStroke)] {
        var byUID: [String: ScratchStroke] = [:]
        for s in strokes where s.card || s.isImage { byUID[s.uid] = s }
        var transforms: [String: (f: (CGPoint) -> CGPoint, scale: CGFloat)] = [:]
        var result: [(Int, ScratchStroke)] = []
        for (index, original) in originals {
            guard let link = original.link, let a = byUID[link.from], let b = byUID[link.to],
                  let p0 = original.points.first, let p1 = original.points.last else { continue }
            let q0 = CGPoint(x: a.points[0].x + link.a.x, y: a.points[0].y + link.a.y)
            let q1 = CGPoint(x: b.points[0].x + link.b.x, y: b.points[0].y + link.b.y)
            let t = Self.similarity(p0, p1, q0, q1)
            transforms[original.uid] = t
            result.append((index, original.transformed(t.f, scale: t.scale)))
        }
        for (index, original) in originals {
            guard let shaft = original.follows, let t = transforms[shaft] else { continue }
            result.append((index, original.transformed(t.f, scale: t.scale)))
        }
        return result
    }

    /// Drehung + Streckung + Verschiebung, die p0→q0 und p1→q1 abbildet.
    static func similarity(_ p0: CGPoint, _ p1: CGPoint, _ q0: CGPoint, _ q1: CGPoint) -> (f: (CGPoint) -> CGPoint, scale: CGFloat) {
        let v = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y), w = CGPoint(x: q1.x - q0.x, y: q1.y - q0.y)
        let lv = hypot(v.x, v.y)
        guard lv > 1 else { return ({ CGPoint(x: $0.x + q0.x - p0.x, y: $0.y + q0.y - p0.y) }, 1) }
        let scale = hypot(w.x, w.y) / lv
        let angle = atan2(w.y, w.x) - atan2(v.y, v.x)
        let (c, s) = (cos(angle) * scale, sin(angle) * scale)
        return ({ p in
            let dx = p.x - p0.x, dy = p.y - p0.y
            return CGPoint(x: q0.x + c * dx - s * dy, y: q0.y + s * dx + c * dy)
        }, scale)
    }

    /// Neuer Strich: beginnt er an einer Karte und endet an einer anderen, rastet er als Pfeil ein; ein kleiner
    /// Strich nahe dem Ende eines Pfeils (die Spitze) folgt diesem.
    private func attachLink(_ stroke: ScratchStroke) {
        guard let p0 = stroke.points.first, let p1 = stroke.points.last else { return }
        func object(at p: CGPoint) -> ScratchStroke? {
            strokes.last { ($0.card || $0.isImage) && $0.bounds.insetBy(dx: -18, dy: -18).contains(p) }
        }
        if stroke.points.count >= 2, hypot(p1.x - p0.x, p1.y - p0.y) >= 24,
           let a = object(at: p0), let b = object(at: p1), a !== b {
            stroke.link = ScratchLink(from: a.uid, to: b.uid,
                                      a: CGPoint(x: p0.x - a.points[0].x, y: p0.y - a.points[0].y),
                                      b: CGPoint(x: p1.x - b.points[0].x, y: p1.y - b.points[0].y))
            return
        }
        let box = stroke.bounds
        guard max(box.width, box.height) <= 60 else { return }
        let center = CGPoint(x: box.midX, y: box.midY)
        if let shaft = strokes.last(where: { s in
            s.link != nil && [s.points.first, s.points.last].compactMap { $0 }.contains { hypot($0.x - center.x, $0.y - center.y) <= 40 }
        }) {
            stroke.follows = shaft.uid
        }
    }

    // MARK: Pixel-Radierer — schneidet aus Strichen, Buchstaben, Bildern; der Schnitt hängt am Element

    private var cutting: (last: CGPoint, touched: [String: (old: ScratchStroke, live: ScratchStroke)])?

    private func beginCut(at p: CGPoint) {
        cutting = (p, [:])
        cut(from: p, to: p)
    }

    private func continueCut(to p: CGPoint) {
        guard let last = cutting?.last else { return }
        cut(from: last, to: p)
        cutting?.last = p
    }

    private func cut(from a: CGPoint, to b: CGPoint) {
        guard var state = cutting else { return }
        let r = worldEraserRadius
        let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / max(2 / zoom, r / 2)))
        var dirty = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)).insetBy(dx: -r - 2, dy: -r - 2)
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let q = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            for index in strokes.indices where state.touched[strokes[index].uid] == nil && strokes[index].touches(q, radius: r) {
                let old = strokes[index]
                let live = old.copy()
                live.cuts.append(ScratchCut(points: [a], radius: r))
                strokes[index] = live
                state.touched[old.uid] = (old, live)
                dirty = dirty.union(old.bounds)
            }
        }
        for (_, pair) in state.touched { pair.live.cuts[pair.live.cuts.count - 1].points.append(b) }
        cutting = state
        invalidate(dirty)
    }

    private func endCut() {
        guard let state = cutting else { return }
        cutting = nil
        guard !state.touched.isEmpty else { return }
        commit(Edit(swapped: state.touched.values.map { (old: $0.old, new: $0.live) }))
    }

    // MARK: Karte bearbeiten (Doppelklick) — neu setzen = neue Tinte

    private var editor: CardEditor?
    private var editing: ScratchStroke?

    private func beginEditing(_ card: ScratchStroke) {
        guard let info = card.cardInfo else { return }
        endEditing(commit: true)
        let rect = toScreen(card.cardRect)
        let view = CardEditor(frame: rect.insetBy(dx: ScratchStroke.cardPadding.width * zoom - 2, dy: ScratchStroke.cardPadding.height * zoom - 2))
        view.font = info.font().withSize((info.size ?? ScratchCard.defaultSize) * zoom)
        view.textColor = palette[max(0, min(info.textColor ?? 0, palette.count - 1))]
        view.backgroundColor = paper
        view.insertionPointColor = palette[0]
        view.string = (info.title.map { $0 + "\n" } ?? "") + (card.text ?? "")
        view.onFinish = { [weak self] commit in self?.endEditing(commit: commit) }
        addSubview(view)
        editor = view
        editing = card
        window?.makeFirstResponder(view)
        view.selectAll(nil)
    }

    /// Fertig: Text neu gesetzt (Titel = erste Zeile, falls die Karte einen hatte); leer = Karte weg.
    private func endEditing(commit keep: Bool) {
        guard let view = editor, let card = editing else { return }
        editor = nil
        editing = nil
        let raw = view.string.trimmingCharacters(in: .whitespacesAndNewlines)
        view.onFinish = nil
        view.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard keep, let index = strokes.firstIndex(where: { $0 === card }), var info = card.cardInfo else { return }
        let old = (info.title.map { $0 + "\n" } ?? "") + (card.text ?? "")
        guard raw != old.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if raw.isEmpty {
            strokes.remove(at: index)
            commit(Edit(removed: [(index, card)]))
            return
        }
        var body = raw
        if info.title != nil {
            let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            info.title = String(lines[0])
            body = lines.count > 1 ? String(lines[1]) : ""
        }
        let fresh = card.cardUpdated(text: body, origin: nil, width: nil, color: nil, info: info)
        fresh.cuts = []
        strokes[index] = fresh
        commit(Edit(swapped: [(card, fresh)]))
    }

    private func point(_ event: NSEvent) -> CGPoint { toWorld(convert(event.locationInWindow, from: nil)) }

    // MARK: Ansicht — Mittelpunkt-Anker, Verschieben, Zoomen

    /// Die Zeichnung hängt an der Mitte der Kachel (Weltpunkt 0,0 = Kachelmitte in der Normalsicht): wird die
    /// Kachel größer oder kleiner, wächst bzw. schrumpft der Rand gleichmäßig rundherum. `pan`/`zoom` sind
    /// die Abweichung von der Normalsicht (Trackpad: zwei Finger verschieben, Aufziehen zoomt). Seit 24.09. bleibt
    /// die Sicht bei Größenwechsel (⌘⏎) und Fokusverlust stehen; zurück per Mitte-Knopf, ␣␣, ⌘0 oder Doppeltipp.
    private(set) var pan: CGPoint = .zero
    private(set) var zoom: CGFloat = 1
    static let zoomRange: ClosedRange<CGFloat> = 0.2...8
    private var springTimer: Timer?

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    func toWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - center.x - pan.x) / zoom, y: (p.y - center.y - pan.y) / zoom)
    }
    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: center.x + pan.x + p.x * zoom, y: center.y + pan.y + p.y * zoom)
    }
    func toWorld(_ r: NSRect) -> NSRect {
        let a = toWorld(r.origin), b = toWorld(CGPoint(x: r.maxX, y: r.maxY))
        return NSRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
    private func toScreen(_ r: NSRect) -> NSRect {
        let a = toScreen(r.origin), b = toScreen(CGPoint(x: r.maxX, y: r.maxY))
        return NSRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
    /// Neu zeichnen, was ein Weltbereich am Bildschirm belegt.
    private func invalidate(_ world: NSRect) { setNeedsDisplay(toScreen(world).insetBy(dx: -2, dy: -2)) }

    var isNormalView: Bool { pan == .zero && zoom == 1 }

    private func setView(pan: CGPoint, zoom: CGFloat) {
        let wasNormal = isNormalView
        self.pan = pan
        self.zoom = zoom
        needsDisplay = true
        cursorChanged()
        if wasNormal != isNormalView { onStateChange?() }   // Mitte-Knopf hell/blass
    }

    /// Zurück in die Normalsicht (Mitte, 100 %) — sanft, wenn gewünscht.
    func resetView(animated: Bool) {
        springTimer?.invalidate(); springTimer = nil
        guard !isNormalView else { return }
        guard animated, window != nil else { setView(pan: .zero, zoom: 1); return }
        let (startPan, startZoom, started) = (pan, zoom, CACurrentMediaTime())
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - started) / 0.25)
            let e = 1 - pow(1 - t, 3)   // ease-out
            self.setView(pan: CGPoint(x: startPan.x * (1 - e), y: startPan.y * (1 - e)),
                         zoom: startZoom + (1 - startZoom) * e)
            if t >= 1 { timer.invalidate(); self.springTimer = nil; self.setView(pan: .zero, zoom: 1) }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    // Größenwechsel (⌘⏎ rein/raus) und Fokusverlust lassen die Sicht, wo sie ist (Mats, 24.09.) — der Weltpunkt in
    // der Kachelmitte bleibt in der Mitte. Zurück zur Mitte: Knopf in der Leiste, zweimal Leertaste, ⌘0, Doppeltipp.

    /// Fokus weg = kein Werkzeug mehr (Mats, 24.09.): wer zurückklickt, um etwas zu ziehen, radiert nicht aus Versehen.
    /// Ausnahme: der Fokus geht an das Eingabefeld einer Karte.
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, editor == nil, tool != .none { select(.none) }
        return ok
    }

    /// Zweimal Leertaste kurz hintereinander = zur Mitte.
    private var lastSpace: TimeInterval = 0

    /// Zwei Finger (oder Mausrad) verschieben die Fläche.
    override func scrollWheel(with event: NSEvent) {
        springTimer?.invalidate(); springTimer = nil
        let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        setView(pan: CGPoint(x: pan.x + event.scrollingDeltaX * factor, y: pan.y + event.scrollingDeltaY * factor), zoom: zoom)
    }

    /// Aufziehen/Zusammenziehen zoomt um den Punkt unter dem Zeiger.
    override func magnify(with event: NSEvent) {
        springTimer?.invalidate(); springTimer = nil
        let screen = convert(event.locationInWindow, from: nil)
        let anchor = toWorld(screen)
        let next = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * (1 + event.magnification)))
        setView(pan: CGPoint(x: screen.x - center.x - anchor.x * next, y: screen.y - center.y - anchor.y * next), zoom: next)
    }

    /// Doppeltipp mit zwei Fingern: zurück zur Mitte.
    override func smartMagnify(with event: NSEvent) { resetView(animated: true) }

    // MARK: Radieren (ganze Striche — ein Zug über viele Striche ist EIN Undo-Schritt)

    /// Karten, aus denen der Radierer gerade Buchstaben nimmt (alte → laufende Fassung).
    private var eraseSwaps: [String: (old: ScratchStroke, live: ScratchStroke)] = [:]

    private func beginErase(at p: CGPoint) {
        erased = []
        eraseSwaps = [:]
        lastErasePoint = p
        erase(at: p)
    }

    /// Zwischen zwei Mauspunkten nachtasten, sonst rutscht ein schneller Zug durch dünne Striche.
    private func continueErase(to p: CGPoint) {
        guard let last = lastErasePoint else { return }
        let steps = max(1, Int(hypot(p.x - last.x, p.y - last.y) / max(2 / zoom, worldEraserRadius / 2)))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            erase(at: CGPoint(x: last.x + (p.x - last.x) * t, y: last.y + (p.y - last.y) * t))
        }
        lastErasePoint = p
    }

    private func endErase() {
        lastErasePoint = nil
        var swaps: [(old: ScratchStroke, new: ScratchStroke)] = []
        for pair in eraseSwaps.values {
            // Nichts mehr übrig: die Karte geht ganz (Undo bringt die alte Fassung an ihren Platz).
            if pair.live.isFullyErased, let index = strokes.firstIndex(where: { $0 === pair.live }) {
                strokes.remove(at: index)
                erased.append((index, pair.old))
            } else {
                swaps.append((old: pair.old, new: pair.live))
            }
        }
        eraseSwaps = [:]
        guard !erased.isEmpty || !swaps.isEmpty else { return }
        commit(Edit(removed: erased, swapped: swaps))
        erased = []
    }

    /// Ganze Striche und Bilder gehen; aus Karten nimmt der Radierer die berührten Buchstaben (Rahmen: ein Stück).
    private func erase(at p: CGPoint) {
        let r = worldEraserRadius
        while let index = strokes.lastIndex(where: { $0.touches(p, radius: r) }) {
            let stroke = strokes[index]
            if stroke.card {
                eraseFromCard(index, at: p, radius: r)
                return
            }
            strokes.remove(at: index)
            erased.append((index, stroke))
            invalidate(stroke.bounds)
        }
    }

    private func eraseFromCard(_ index: Int, at p: CGPoint, radius r: CGFloat) {
        let card = strokes[index]
        // Tintenflecken (Mats, 24.09.): was zusammenhängt und dieselbe Farbe hat, geht am Stück — jeder Buchstabe,
        // der ganze Rahmen, die ganze Fläche. Buchstaben zuerst (sie liegen obenauf), dann Rahmen, dann Fläche.
        let reach = NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        let rect = card.cardRect
        let glyphs = card.liveGlyphs.filter { $0.rect.intersects(reach) }
        var cut: [ScratchCut] = glyphs.map { .chars($0.range) }
        if cut.isEmpty, card.frameTouches(p, radius: r) { cut = [ScratchCut(part: "frame")] }
        if cut.isEmpty, card.showsFill, rect.contains(p) { cut = [ScratchCut(part: "fill")] }
        guard !cut.isEmpty else { return }
        let live: ScratchStroke
        if let pair = eraseSwaps[card.uid] { live = pair.live } else {
            live = card.copy()
            strokes[index] = live
            eraseSwaps[card.uid] = (card, live)
        }
        live.cuts += cut
        invalidate(card.bounds)
    }

    // MARK: Tasten

    /// P/M/E/X Werkzeug (X = Pixel-Radierer), 1–7 Farbe, +/− Stärke — nur ohne ⌘/⌥/⌃.
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.keyDown(with: event) }
        if key == " " {
            if event.timestamp - lastSpace < 0.4 { resetView(animated: true); lastSpace = 0 } else { lastSpace = event.timestamp }
            return
        }
        switch key {
        case "p": select(.pen)
        case "m": select(.marker)
        case "e": select(.eraser)
        case "x": select(.cutter)
        case "+", "=": stepSize(1)
        case "-": stepSize(-1)
        default:
            if let digit = Int(key), (1...palette.count).contains(digit) { selectColor(digit - 1) } else { super.keyDown(with: event) }
        }
    }

    /// ⌘Z/⇧⌘Z, ⌘⌫ leeren, ⌘S als PNG sichern, ⌘C als Bild kopieren, ⌘V Text als Karten (Liste = je Punkt eine,
    /// ⇧⌘V = alles in eine), ⇧⌘⏎ an Agent schicken. Kachel-Kürzel (⌘W …)
    /// verteilt vorher die Hülle.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard window?.firstResponder === self, mods == .command || mods == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        let shift = mods.contains(.shift)
        if key == "\r" || event.keyCode == 36 || event.keyCode == 76 {   // ⏎ / Ziffernblock-Enter
            guard shift else { return super.performKeyEquivalent(with: event) }   // ⌘⏎ = Zoom (Hülle)
            onSendRequest?(false)
            return true
        }
        switch (key, shift) {
        case ("z", false): undo()
        case ("z", true): redo()
        case ("s", false): onSaveRequest?()
        case ("c", false): copyImage()
        case ("v", false): pasteCards(split: true)
        case ("v", true): pasteCards(split: false)
        case ("0", false): resetView(animated: true)
        default:
            guard event.keyCode == 51, !shift else { return super.performKeyEquivalent(with: event) }   // ⌫
            clear()
        }
        return true
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        ground.setFill()
        dirtyRect.fill()
        NSGraphicsContext.saveGraphicsState()
        let view = NSAffineTransform()
        view.translateX(by: center.x + pan.x, yBy: center.y + pan.y)
        view.scale(by: zoom)
        view.concat()
        drawStrokes(in: toWorld(dirtyRect))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Marker unter die Tinte, damit Markiertes lesbar bleibt; der laufende Strich obenauf.
    private func drawStrokes(in rect: NSRect) {
        let visible = strokes.filter { $0.bounds.intersects(rect) }
        for stroke in visible where stroke.marker { draw(stroke) }
        for stroke in visible where !stroke.marker { draw(stroke) }
        if let current { draw(current) }
    }

    /// Mit Radier-Schnitten: Element in eigener Ebene zeichnen, Schnitte daraus löschen — nur dieses Element verliert Pixel.
    private func draw(_ stroke: ScratchStroke) {
        guard !stroke.cuts.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return drawInk(stroke) }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawInk(stroke)
        context.setBlendMode(.clear)
        for cut in stroke.cuts {
            if cut.rect != nil { cut.path.fill() } else { cut.path.stroke() }
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawInk(_ stroke: ScratchStroke) {
        if stroke.isImage {
            stroke.image?.draw(in: stroke.imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let color = palette[max(0, min(stroke.color, palette.count - 1))]
        let ink = stroke.marker ? color.withAlphaComponent(Self.markerAlpha) : color
        if let info = stroke.cardInfo, let text = stroke.text {
            let rect = stroke.cardRect
            let frame = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            if stroke.showsFill {
                color.withAlphaComponent(0.08).setFill()
                frame.fill()
            }
            let textInk = palette[max(0, min(info.textColor ?? 0, palette.count - 1))]
            switch stroke.frameStyle {
            case _ where !stroke.showsFrame: break
            case "mark":
                textInk.withAlphaComponent(0.55).setStroke()
                stroke.markPath.stroke()
            case let style:
                frame.lineWidth = style == "thick" ? 2.5 : stroke.width
                if style == "dashed" { frame.setLineDash([5, 4], count: 2, phase: 0) }
                color.withAlphaComponent(0.75).setStroke()
                frame.stroke()
            }
            let pad = ScratchStroke.cardPadding
            let ink = textInk
            let content = NSMutableAttributedString(attributedString: info.attributed(text: text, color: ink))
            for range in stroke.erasedChars.rangeView where range.upperBound <= content.length {
                content.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: range.lowerBound, length: range.count))
            }
            content.draw(with: rect.insetBy(dx: pad.width, dy: pad.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
        } else if let text = stroke.text {
            (text as NSString).draw(at: stroke.textRect.origin, withAttributes: [.font: stroke.font, .foregroundColor: ink])
        } else if stroke.filled {
            ink.setFill()
            stroke.path.fill()
        } else {
            ink.setStroke()
            stroke.path.stroke()
        }
    }

    // MARK: Zeiger — Kreis in Werkzeuggröße

    private var cursor = NSCursor.crosshair

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: cursor)
    }

    private func cursorChanged() {
        cursor = makeCursor()
        window?.invalidateCursorRects(for: self)
    }

    private func makeCursor() -> NSCursor {
        let diameter: CGFloat
        switch tool {
        case .pen: diameter = max(Self.penWidths[sizeIndex] * zoom, 4)
        case .marker: diameter = min(Self.markerWidths[sizeIndex] * zoom, 120)
        case .eraser, .cutter: diameter = eraserRadius * 2   // Radierer: fest am Bildschirm
        case .none: return .openHand
        }
        let side = ceil(diameter) + 4
        let (tool, ink, rim, paper) = (self.tool, inkColor, palette[0], self.paper)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
            circle.lineWidth = 1
            switch tool {
            case .pen: ink.setFill(); circle.fill(); rim.setStroke(); circle.stroke()
            case .marker: ink.withAlphaComponent(Self.markerAlpha).setFill(); circle.fill(); ink.setStroke(); circle.stroke()
            case .eraser:
                paper.withAlphaComponent(0.5).setFill(); circle.fill()
                rim.setStroke(); circle.stroke()
            case .none: break
            case .cutter:
                paper.withAlphaComponent(0.5).setFill(); circle.fill()
                circle.setLineDash([2, 2], count: 2, phase: 0)
                rim.setStroke(); circle.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}

// MARK: - Werkzeugleiste

final class ScratchpadToolbar: NSView {
    weak var canvas: ScratchpadCanvas?
    /// ➤ geklickt (true = mit ⌥).
    var onSend: ((Bool) -> Void)?
    var vertical = true { didSet { if vertical != oldValue { needsDisplay = true; updateToolTips() } } }

    private enum Item {
        case tool(ScratchTool), color(Int), size, undo, redo, clear, home, send, divider
    }

    private static let items: [Item] = [.tool(.pen), .tool(.marker), .tool(.eraser), .tool(.cutter), .divider]
        + ScratchPalette.names.indices.map { .color($0) }
        + [.divider, .size, .divider, .undo, .redo, .clear, .home, .divider, .send]

    static let cell: CGFloat = 26
    private static let dividerSize: CGFloat = 7
    private static let padding: CGFloat = 4
    static var thickness: CGFloat { cell + 2 * padding }
    static var length: CGFloat {
        2 * padding + items.reduce(0) { sum, item in
            if case .divider = item { return sum + dividerSize }
            return sum + cell
        }
    }

    private var background: NSColor = .darkGray
    private var foreground: NSColor = .white
    private var dim: NSColor = .gray
    private var faint: NSColor = .darkGray
    private var hovered: Int?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ theme: TerminalTheme) {
        background = theme.background.withAlphaComponent(LineStyle.groundAlpha)
        foreground = theme.foreground.withAlphaComponent(1)
        dim = theme.dim
        faint = theme.faint
        needsDisplay = true
    }

    /// Rechteck des Senden-Knopfs (Anker für das Auswahlmenü).
    var sendRect: NSRect {
        zip(Self.items, frames).first { if case .send = $0.0 { return true } else { return false } }?.1 ?? bounds
    }

    /// Rechteck je Eintrag entlang der Leiste.
    private var frames: [NSRect] {
        var offset = Self.padding
        return Self.items.map { item in
            var size = Self.cell
            if case .divider = item { size = Self.dividerSize }
            defer { offset += size }
            return vertical
                ? NSRect(x: Self.padding, y: offset, width: Self.cell, height: size)
                : NSRect(x: offset, y: Self.padding, width: size, height: Self.cell)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateToolTips()
    }

    // Owner ist die Leiste selbst: AppKit hält Tooltip-Owner NICHT fest — ein temporärer
    // NSString als Owner war beim Feuern des Tooltip-Timers schon freigegeben (Absturz 23.09.).
    private func updateToolTips() {
        removeAllToolTips()
        for (item, rect) in zip(Self.items, frames) where toolTip(for: item) != nil {
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    private func toolTip(for item: Item) -> String? {
        switch item {
        case .tool(.pen): "Stift (P)"
        case .tool(.marker): "Marker (M)"
        case .tool(.eraser): "Radierer (E): nimmt ganze Tintenflecken — Striche, Bilder, bei Karten Buchstabe, Rahmen oder Fläche am Stück. Rechtsklick radiert immer"
        case .tool(.cutter): "Pixel-Radierer (X): schneidet aus allem, was er überfährt"
        case .tool(.none): nil
        case .color(let i): "\(ScratchPalette.names[i]) (\(i + 1))"
        case .size: "Stärke (+ / −)"
        case .undo: "Rückgängig (⌘Z)"
        case .redo: "Wiederholen (⇧⌘Z)"
        case .clear: "Leeren (⌘⌫) — ⌘S sichert als PNG, ⌘C kopiert als Bild"
        case .home: "Zur Mitte (zweimal Leertaste, ⌘0, Doppeltipp mit zwei Fingern)"
        case .send: "An Claude/Codex schicken (⇧⌘⏎) — landet als Bild in deren Eingabe; ⌥-Klick: Ziel wählen"
        case .divider: nil
        }
    }

    // MARK: Maus

    override func mouseDown(with event: NSEvent) {
        guard let canvas else { return }
        window?.makeFirstResponder(canvas)
        guard let index = index(at: event) else { return }
        switch Self.items[index] {
        case .tool(let tool): canvas.select(tool)
        case .color(let i): canvas.selectColor(i)
        case .size: canvas.cycleSize()
        case .undo: canvas.undo()
        case .redo: canvas.redo()
        case .clear: canvas.clear()
        case .home: canvas.resetView(animated: true)
        case .send: onSend?(event.modifierFlags.contains(.option))
        case .divider: break
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: event)) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        needsDisplay = true
    }

    private func index(at event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return frames.firstIndex { $0.contains(p) }
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas else { return }
        // Schwebe-Grund (Stil „Linie“): Fläche ohne Rand; gewähltes Werkzeug = Strich an der Außenkante.
        let ground = NSBezierPath(roundedRect: bounds, xRadius: LineStyle.groundRadius, yRadius: LineStyle.groundRadius)
        background.setFill(); ground.fill()

        for (index, (item, rect)) in zip(Self.items, frames).enumerated() {
            let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: LineStyle.hoverRadius, yRadius: LineStyle.hoverRadius)
            if hovered == index, !isDivider(item) {
                foreground.withAlphaComponent(LineStyle.hover).setFill(); highlight.fill()
            }
            switch item {
            case .tool(let tool):
                let selected = canvas.tool == tool
                if selected {
                    let mark = vertical
                        ? NSRect(x: rect.minX - 2, y: rect.minY + 5, width: LineStyle.underline, height: rect.height - 10)
                        : NSRect(x: rect.minX + 5, y: rect.maxY, width: rect.width - 10, height: LineStyle.underline)
                    ThemeStore.shared.accentColor.setFill()
                    NSBezierPath(roundedRect: mark, xRadius: 1, yRadius: 1).fill()
                }
                drawSymbol(symbol(for: tool), in: rect, color: selected ? foreground : dim)
            case .color(let i):
                let dot = NSBezierPath(ovalIn: centered(14, in: rect))
                canvas.palette[i].setFill(); dot.fill()
                if canvas.colorIndex == i {
                    let ring = NSBezierPath(ovalIn: centered(20, in: rect))
                    ring.lineWidth = 1.5
                    foreground.setStroke(); ring.stroke()
                }
            case .size:
                let diameter: CGFloat = [4, 8, 13][canvas.sizeIndex]
                let dot = NSBezierPath(ovalIn: centered(diameter, in: rect))
                if canvas.tool.erases {
                    dot.lineWidth = 1.5; foreground.setStroke(); dot.stroke()
                } else {
                    canvas.inkColor.setFill(); dot.fill()
                }
            case .undo: drawSymbol("arrow.uturn.backward", in: rect, color: canvas.canUndo ? dim : faint)
            case .redo: drawSymbol("arrow.uturn.forward", in: rect, color: canvas.canRedo ? dim : faint)
            case .clear: drawSymbol("trash", in: rect, color: canvas.strokeCount > 0 ? dim : faint)
            case .home: drawSymbol("scope", in: rect, color: canvas.isNormalView ? faint : dim)
            case .send: drawSymbol("paperplane", in: rect, color: canvas.strokeCount > 0 ? foreground : faint)
            case .divider:
                let line = vertical
                    ? NSRect(x: rect.minX + 5, y: rect.midY - 0.5, width: rect.width - 10, height: 1)
                    : NSRect(x: rect.midX - 0.5, y: rect.minY + 5, width: 1, height: rect.height - 10)
                faint.setFill(); line.fill()
            }
        }
    }

    private func isDivider(_ item: Item) -> Bool {
        if case .divider = item { return true }
        return false
    }

    private func symbol(for tool: ScratchTool) -> String {
        switch tool {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .eraser: "eraser"
        case .cutter: "eraser.line.dashed"
        case .none: "hand.raised"
        }
    }

    private func centered(_ diameter: CGFloat, in rect: NSRect) -> NSRect {
        NSRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

extension ScratchpadToolbar: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        zip(Self.items, frames).first { $0.1.contains(point) }.flatMap { toolTip(for: $0.0) } ?? ""
    }
}

/// Text aus dem Terminal für Karten aufbereiten: Terminal-Auswahl ist hart umbrochen und eingerückt — Zeilen
/// wieder zu Absätzen fügen; Aufzählungen (1. / 1) / - / * / •) und Leerzeilen trennen Punkte.
enum CardText {
    private static let marker = try! NSRegularExpression(pattern: #"^\s*(\d{1,3}[.)]|[-*•–])\s+"#)

    static func isItemStart(_ line: String) -> Bool {
        marker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Punkte einer Liste (ein Satz davor wird eigene Karte); ohne Aufzählungszeichen die Absätze.
    static func items(_ raw: String) -> [String] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let hasList = lines.filter(isItemStart).count >= 2
        var items: [String] = []
        var current: [String] = []
        func flush() {
            let text = current.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { items.append(text) }
            current = []
        }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if hasList, isItemStart(line) { flush() }
            current.append(trimmed)
        }
        flush()
        return items
    }

    /// Alles als ein Text; Absätze bleiben getrennt, Zeilen darin werden gefügt.
    static func unwrap(_ raw: String) -> String {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraphs: [String] = []
        var current: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || isItemStart(line) {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                current = trimmed.isEmpty ? [] : [trimmed]
            } else {
                current.append(trimmed)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
        return paragraphs.joined(separator: "\n")
    }
}

/// Eingabefeld über einer Karte (Doppelklick): ⌘⏎ oder Klick daneben übernimmt, Esc verwirft.
final class CardEditor: NSTextView {
    var onFinish: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isRichText = false
        allowsUndo = true
        textContainerInset = NSSize(width: 2, height: 2)
        textContainer?.lineFragmentPadding = 0
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { fatalError() }

    override func cancelOperation(_ sender: Any?) { onFinish?(false) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           event.keyCode == 36 || event.keyCode == 76 {
            onFinish?(true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { DispatchQueue.main.async { [weak self] in self?.onFinish?(true) } }
        return ok
    }
}
