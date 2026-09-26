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
    /// Schriftgrößen des Text-Werkzeugs je Stärke.
    static let textSizes: [CGFloat] = [13, 18, 28]
    /// Marker deckt nur halb — Text darunter bleibt lesbar.
    static let markerAlpha: CGFloat = 0.35

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Sonst zöge Malen das Fenster (`isMovableByWindowBackground`).
    override var mouseDownCanMoveWindow: Bool { false }

    var strokeCount: Int { strokes.count }

    /// Stand des Bretts für Agenten (25.09.): jede Änderung zählt hoch; `scratch_cards`/`scratch_draw` verlangen den Stand
    /// aus ihrem letzten Blick — wer nicht hingesehen hat, legt nichts ab. Das Präfix unterscheidet App-Starts.
    private var revision = 0
    private let epoch = String(UUID().uuidString.prefix(4)).lowercased()
    var rev: String { "\(epoch)-\(revision)" }

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
        if tool != .none && tool != .text { clearSelection() }
        hoverUID = nil
        hoverEdge = nil
        stateChanged()
    }

    /// Farbe wählen heißt malen wollen: aus dem Radierer zurück zum Stift.
    func selectColor(_ index: Int) {
        colorIndex = max(0, min(index, palette.count - 1))
        if editor != nil { editStyle.textColor = colorIndex; styleEditor(); stateChanged(); return }
        if tool.erases || tool == .none { tool = .pen }
        stateChanged()
    }

    func stepSize(_ delta: Int) {
        let next = sizeIndex + delta
        guard Self.penWidths.indices.contains(next) else { NSSound.beep(); return }
        sizeIndex = next
        if editor != nil { editStyle.size = Self.textSizes[sizeIndex]; styleEditor() }
        stateChanged()
    }

    /// Toolbar: Stärke im Kreis durchschalten.
    func cycleSize() {
        sizeIndex = (sizeIndex + 1) % Self.penWidths.count
        if editor != nil { editStyle.size = Self.textSizes[sizeIndex]; styleEditor() }
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
        let orphans = dropOrphanArrows(after: removed)
        commit(Edit(removed: removed + orphans.removed, swapped: orphans.swapped))
        return removed.count
    }

    /// Nach dem Entfernen von Karten/Bildern (Befund 25.09.: `replace: cards` ließ Pfeile als Waisen „? → ?“ liegen):
    /// Agenten-Pfeile daran samt Spitze gehen mit, Handschrift-Pfeile des Nutzers bleiben als Striche, nur nicht mehr eingerastet.
    private func dropOrphanArrows(after removed: [(index: Int, stroke: ScratchStroke)])
        -> (removed: [(index: Int, stroke: ScratchStroke)], swapped: [(old: ScratchStroke, new: ScratchStroke)]) {
        let gone = Set(removed.map(\.stroke).filter { $0.card || $0.isImage }.map(\.uid)).subtracting(strokes.map(\.uid))
        guard !gone.isEmpty else { return ([], []) }
        var out: [(index: Int, stroke: ScratchStroke)] = [], swaps: [(old: ScratchStroke, new: ScratchStroke)] = []
        for index in linkedStrokes(to: gone).sorted(by: >) {
            let s = strokes[index]
            if s.isClaude {
                out.append((index, strokes.remove(at: index)))
            } else if s.link != nil {
                let fresh = s.unlinked()
                swaps.append((s, fresh))
                strokes[index] = fresh
            }
        }
        return (out, swaps)
    }

    /// Agenten-Zeichnung anhängen, optional vorher eine Ebene leeren — zusammen EIN Undo-Schritt, damit ⌘Z
    /// Mats' Skizze zurückbringt. Gibt die Zahl der entfernten Elemente zurück.
    @discardableResult
    func add(_ items: [ScratchStroke], replacing layer: ScratchLayer?) -> Int {
        let removed = layer.map(remove) ?? []
        guard !items.isEmpty || !removed.isEmpty else { return 0 }
        let orphans = dropOrphanArrows(after: removed)
        strokes.append(contentsOf: items)
        commit(Edit(removed: removed + orphans.removed, added: items, swapped: orphans.swapped))
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
        revision += 1
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
        /// Eingerastete Pfeile von dieser Karte zu diesen Karten.
        var arrows: [ArrowSpec] = []
        /// Ort relativ zu einer anderen Karte (Agenten; `origin` bleibt der absolute Weg).
        var placement = ScratchLayout.Placement()
        /// Ausdrücklich: darf anderes überdecken bzw. außerhalb des Sichtbaren liegen.
        var overlap = false
        var offscreen = false
    }

    struct ArrowSpec {
        var to: String
        var fromSide: ScratchLayout.Side?
        var toSide: ScratchLayout.Side?
        var via: [CGPoint] = []
        /// Ausdrücklich: darf durch fremde Karten laufen.
        var through = false
        var color: Int?
    }

    struct CardResult {
        var added: [ScratchStroke] = []
        var updated: [ScratchStroke] = []
        var removed: [String] = []
        /// Was ohne ausdrückliche Erlaubnis nicht geht (bei `probe` gemeldet, sonst Abbruch).
        var problems: [String] = []
        /// Hinweise, die nichts verhindern (z. B. ein nachgeführter Pfeil läuft jetzt durch eine Karte).
        var notes: [String] = []
        /// Gesetzte Pfeile: von, zu, Punkte.
        var arrows: [(from: String, to: String, points: [CGPoint])] = []
    }

    /// Alle Einträge als EIN Undo-Schritt. Nutzer (⌘V, `author == nil`): ohne Ort sucht `freeSpot` Platz. Agent: jede
    /// neue Karte braucht einen Ort (x/y oder relativ), Überdecken und Außerhalb nur ausdrücklich, Pfeile nicht durch
    /// fremde Karten — sonst wird nichts gesetzt und `problems` nennt, was nicht ging. `probe` rechnet nur.
    func applyCards(_ entries: [CardEntry], author: String?, replacing layer: ScratchLayer? = nil,
                    probe: Bool = false) throws -> CardResult {
        let strict = author != nil
        // Unbekannte id mit Text = neue Karte unter diesem Namen (so kann ein Aufruf sie gleich verbinden).
        for entry in entries where entry.id != nil && !strokes.contains(where: { $0.cardInfo?.id == entry.id }) {
            guard !entry.remove, entry.text?.isEmpty == false else {
                throw PaneArgsError("Karte „\(entry.id!)“ gibt es nicht (ids aus scratch_look; neue Karte braucht text)")
            }
        }
        let saved = strokes
        do {
            let result = try applyCardsUnchecked(entries, author: author, strict: strict, replacing: layer, probe: probe)
            if probe || !result.problems.isEmpty { strokes = saved }
            return result
        } catch {
            strokes = saved
            throw error
        }
    }

    private func applyCardsUnchecked(_ entries: [CardEntry], author: String?, strict: Bool, replacing layer: ScratchLayer?,
                                     probe: Bool) throws -> CardResult {
        var removed = layer.map(remove) ?? []
        var result = CardResult()
        var placedBoxes: [NSRect] = []
        var nextNumber = cardNumbers().max().map { $0 + 1 } ?? 1
        /// Eintrag → Karte, die er angelegt oder geändert hat (Ausgang seiner Pfeile).
        var cardFor: [Int: ScratchStroke] = [:]
        /// Karten, deren Lage/Größe sich geändert hat — die prüft der strenge Weg.
        var placed: [(card: ScratchStroke, entry: CardEntry)] = []
        /// Karte (Rechteck) nach id, so wie sie gerade liegt — auch neu gesetzte dieses Aufrufs.
        func rect(of ref: String) -> NSRect? {
            let (id, part) = Self.cardRef(ref)
            guard let card = (result.added + result.updated).last(where: { $0.cardInfo?.id == id })
                    ?? strokes.last(where: { $0.cardInfo?.id == id }) else { return nil }
            guard let part else { return card.cardRect }
            // Absatz: Höhe des Absatzes, Breite der ganzen Karte — rightOf/leftOf landen neben dem Block, auf Höhe des Punkts.
            let parts = card.cardParts
            guard parts.indices.contains(part - 1) else { return nil }
            let r = parts[part - 1].rect, whole = card.cardRect
            return NSRect(x: whole.minX, y: r.minY, width: whole.width, height: r.height)
        }
        func origin(for entry: CardEntry, size: NSSize, label: String) throws -> CGPoint? {
            if let origin = entry.origin, entry.placement.ref == nil { return origin }
            guard !entry.placement.isEmpty else { return nil }
            do {
                return try ScratchLayout.origin(entry.placement, size: size, refRect: entry.placement.ref.flatMap(rect(of:)))
            } catch let failure as ScratchLayout.Failure {
                throw PaneArgsError("\(label): \(failure.description)")
            }
        }
        for (position, entry) in entries.enumerated() {
            if let id = entry.id, let index = strokes.firstIndex(where: { $0.cardInfo?.id == id }) {
                let old = strokes.remove(at: index)
                removed.append((index, old))
                if entry.remove { result.removed.append(id); continue }
                var info = merge(old.cardInfo ?? ScratchCard(), entry.style)
                if entry.width != nil { info.fixedWidth = true }
                let width = entry.width.map(Self.clampCardWidth) ?? old.cardWidth
                let size = ScratchStroke.cardSize(text: entry.text ?? old.text ?? "", width: width, info: info)
                let copy = old.cardUpdated(text: entry.text, origin: try origin(for: entry, size: size, label: id),
                                           width: entry.width.map(Self.clampCardWidth), color: entry.color, info: info)
                result.updated.append(copy)
                cardFor[position] = copy
                if copy.cardRect != old.cardRect { placed.append((copy, entry)) }
                continue
            }
            guard let text = entry.text, !text.isEmpty else { continue }
            var info = entry.style
            if entry.width != nil { info.fixedWidth = true }
            if let id = entry.id { info.id = id } else {
                info.id = "k\(nextNumber)"
                nextNumber += 1
            }
            let width = entry.width.map(Self.clampCardWidth) ?? ScratchStroke.cardWidth(for: text, info: info)
            let size = ScratchStroke.cardSize(text: text, width: width, info: info)
            let label = entry.id ?? "Karte „\(text.prefix(24))…“"
            var spot = try origin(for: entry, size: size, label: label)
            if spot == nil {
                guard !strict else {
                    throw PaneArgsError("\(label) braucht einen Ort: x/y oder below/above/rightOf/leftOf mit einer Karten-id "
                        + "— erst mit scratch_look ansehen, wo Platz ist, dann bewusst setzen")
                }
                spot = freeSpot(for: size, also: placedBoxes + result.updated.map(\.bounds))
            }
            let card = ScratchStroke(card: text, at: spot!, width: width, color: entry.color ?? 0, author: author, info: info)
            placedBoxes.append(card.bounds)
            result.added.append(card)
            cardFor[position] = card
            placed.append((card, entry))
        }
        let cardsNow = result.updated + result.added
        strokes.append(contentsOf: cardsNow)
        var added = cardsNow
        var swaps: [(old: ScratchStroke, new: ScratchStroke)] = []
        let orphans = dropOrphanArrows(after: removed)
        removed += orphans.removed
        swaps += orphans.swapped
        // Strenger Weg: jede gesetzte Karte liegt frei und im Sichtbaren — oder der Agent hat es ausdrücklich so gewollt.
        if strict {
            let visible = visibleWorldRect
            for (card, entry) in placed {
                let name = card.cardInfo?.id ?? "?"
                let r = card.cardRect
                if !entry.overlap {
                    let others = obstacles(excluding: [card.uid])
                    let hits = ScratchLayout.overlaps(r, others)
                    if !hits.isEmpty {
                        result.problems.append("\(name) \(Self.span(r)) überdeckt \(hits.joined(separator: ", ")) — anderer Ort, "
                            + "schmaler (width), oder overlap: true, wenn das Absicht ist")
                    }
                }
                if !entry.offscreen, !visible.contains(r) {
                    result.problems.append("\(name) \(Self.span(r)) liegt außerhalb des Sichtbaren \(Self.span(visible)) — "
                        + "anderer Ort oder offscreen: true, wenn das Absicht ist")
                }
            }
        }
        // Pfeile an verschobenen/neu gesetzten Karten ziehen mit (Agenten-Pfeile werden neu geführt).
        let moved = Set(result.updated.map(\.uid))
        if !moved.isEmpty {
            let linked = linkedStrokes(to: moved).map { ($0, strokes[$0]) }
            for (index, fresh) in relinked(linked) {
                swaps.append((strokes[index], fresh))
                strokes[index] = fresh
                if let link = fresh.link, link.route != nil {
                    let hits = routeHits(fresh.points, link: link)
                    if !hits.isEmpty { result.notes.append("Pfeil \(name(link.from)) → \(name(link.to)) läuft jetzt durch \(hits.joined(separator: ", "))") }
                }
            }
        }
        // Neue Pfeile.
        for (position, entry) in entries.enumerated() where !entry.arrows.isEmpty && !entry.remove {
            guard let source = cardFor[position] ?? entry.id.flatMap({ id in strokes.last { $0.cardInfo?.id == id } }) else { continue }
            for spec in entry.arrows {
                let (destID, part) = Self.cardRef(spec.to)
                guard let dest = strokes.last(where: { $0.cardInfo?.id == destID }), dest !== source else {
                    throw PaneArgsError("arrowTo: Karte „\(spec.to)“ gibt es nicht")
                }
                if let part, !dest.cardParts.indices.contains(part - 1) {
                    throw PaneArgsError("arrowTo: \(destID) hat keinen Absatz \(part) (Absätze stehen in scratch_look)")
                }
                let route = ScratchRoute(fromSide: spec.fromSide?.rawValue, toSide: spec.toSide?.rawValue,
                                         via: spec.via.isEmpty ? nil : spec.via, toPart: part)
                let arrow = routedArrow(from: source, to: dest, route: route, color: spec.color ?? entry.color ?? source.color, author: author)
                let (from, to) = (source.cardInfo?.id ?? "?", spec.to)
                if strict, !spec.through, !arrow.hits.isEmpty {
                    result.problems.append("Pfeil \(from) → \(to) liefe durch \(arrow.hits.joined(separator: ", ")) — andere Kanten "
                        + "(fromSide/toSide), Zwischenpunkte (via), Karten anders legen, oder through: true, wenn das Absicht ist")
                }
                strokes.append(contentsOf: arrow.strokes)
                added += arrow.strokes
                result.arrows.append((from, to, arrow.strokes[0].points))
            }
        }
        // Neue Pfeile aus dem Stamm: alle Pfeile derselben Karte neu führen, damit sie sich einen Kanal teilen (Gabel).
        let sources = Set(added.compactMap { $0.link?.route != nil ? $0.link?.from : nil })
        if !sources.isEmpty {
            let shafts = strokes.indices.filter { i in strokes[i].link.map { sources.contains($0.from) && $0.route != nil } ?? false }
            let ids = Set(shafts.map { strokes[$0].uid })
            let heads = strokes.indices.filter { strokes[$0].follows.map(ids.contains) ?? false }
            for (index, fresh) in relinked((shafts + heads).map { ($0, strokes[$0]) }) {
                let old = strokes[index]
                strokes[index] = fresh
                if let i = added.firstIndex(where: { $0 === old }) { added[i] = fresh } else { swaps.append((old, fresh)) }
            }
        }
        guard !probe, result.problems.isEmpty else { return result }
        guard !added.isEmpty || !removed.isEmpty || !swaps.isEmpty else { return result }
        commit(Edit(removed: removed, added: added, swapped: swaps))
        return result
    }

    /// Alles auf dem Brett, was eine Karte nicht überdecken soll: Karten, Bilder, Beschriftungen als Rechteck, Striche und
    /// Formen als Linienzug. Agenten-Pfeile zählen nicht (sie werden um die Karten herum geführt).
    func obstacles(excluding uids: Set<String>) -> [ScratchLayout.Obstacle] {
        let routed = Set(strokes.filter { $0.link?.route != nil }.map(\.uid))
        return strokes.compactMap { s in
            guard !uids.contains(s.uid), !routed.contains(s.uid), !(s.follows.map(routed.contains) ?? false) else { return nil }
            if let id = s.cardInfo?.id { return .init(name: id, rect: s.cardRect) }
            if s.isImage { return .init(name: "ein Bild", rect: s.imageRect) }
            if s.text != nil { return .init(name: s.isClaude ? "deine Beschriftung" : "eine Beschriftung", rect: s.bounds) }
            if s.filled { return .init(name: s.isClaude ? "deine Zeichnung" : "die Skizze des Nutzers", rect: s.bounds) }
            return .init(name: s.isClaude ? "deine Zeichnung" : "die Skizze des Nutzers", rect: s.bounds, line: s.points, reach: s.width / 2)
        }
    }

    /// Karten und Bilder als Hindernisse für Pfeile.
    private func arrowObstacles() -> [ScratchLayout.Obstacle] {
        strokes.compactMap { s in
            if let id = s.cardInfo?.id { return .init(name: id, rect: s.cardRect) }
            if s.isImage { return .init(name: "Bild \(s.uid)", rect: s.imageRect) }
            return nil
        }
    }

    private func objectRect(_ s: ScratchStroke) -> NSRect { s.isImage ? s.imageRect : s.cardRect }

    /// „k1“ → (k1, nil), „k1.3“ → (k1, 3): Karte oder einer ihrer Absätze (1-basiert, wie scratch_look sie nennt).
    static func cardRef(_ ref: String) -> (id: String, part: Int?) {
        guard let dot = ref.lastIndex(of: "."), let n = Int(ref[ref.index(after: dot)...]), n >= 1 else { return (ref, nil) }
        return (String(ref[..<dot]), n)
    }
    private func name(_ uid: String) -> String {
        strokes.first { $0.uid == uid }.map { $0.cardInfo?.id ?? "Bild" } ?? "?"
    }
    private func routeHits(_ points: [CGPoint], link: ScratchLink) -> [String] {
        let (from, to) = (strokes.first { $0.uid == link.from }, strokes.first { $0.uid == link.to })
        let skip = Set([from, to].compactMap { $0.map { $0.cardInfo?.id ?? "Bild \($0.uid)" } })
        return arrowObstacles().filter { o in
            !skip.contains(o.name) && zip(points, points.dropFirst()).contains { ScratchLayout.segment($0, $1, hits: o.rect.insetBy(dx: 1, dy: 1)) }
        }.map(\.name)
    }

    private func sides(_ route: ScratchRoute) -> (ScratchLayout.Side?, ScratchLayout.Side?) {
        (route.fromSide.flatMap(ScratchLayout.Side.init(rawValue:)), route.toSide.flatMap(ScratchLayout.Side.init(rawValue:)))
    }

    // MARK: Pfeil aus dem Stamm (Mats, 26.09.)
    // Karte mit Strich links: Strich und Pfeil sind EINE Linie. Der Pfeil wächst aus einem Ende des Stamms — Ziel rechts:
    // der Fuß läuft unten weiter; unten: der Fuß knickt ab; links: der Fuß dreht nach links; oben: der Stamm wächst über
    // die Karte hinaus. Mehrere Pfeile einer Karte teilen sich Fuß und Kanal und gabeln sich erst vor ihren Zielen.
    // Ein Absatz als Ziel bekommt statt der Spitze eine Klammer über seine Höhe. Läuft der Weg durch fremde Karten, oder
    // gibt der Agent Seiten/Zwischenpunkte vor, übernimmt der normale Router.

    /// Rechteck, auf das ein Pfeil zielt: der Absatz (`toPart`) oder das ganze Objekt.
    private func targetRect(_ b: ScratchStroke, _ route: ScratchRoute) -> (rect: NSRect, part: Bool) {
        if let n = route.toPart {
            let parts = b.cardParts
            if parts.indices.contains(n - 1) { return (parts[n - 1].rect.insetBy(dx: -3, dy: -2), true) }
        }
        return (objectRect(b), false)
    }

    private static func stemCard(_ s: ScratchStroke) -> Bool { s.card && s.frameStyle == "mark" && s.showsFrame }

    /// Linkspfeil aus dem Stamm: beginnt über der Ecke und biegt dort nach links (dann fällt der Fuß weg).
    private static func exitsLeft(_ points: [CGPoint], _ card: ScratchStroke) -> Bool {
        let s = card.stem
        return stemCard(card) && abs(points[0].x - s.x) < 1 && points[0].y < s.bottom - 5 && points[1].y > points[0].y + 0.5
    }

    /// Abstand vor dem Ziel (Klammer bzw. Spitze).
    private static let stemGap: CGFloat = 6

    private func stemWay(from a: ScratchStroke, to b: ScratchStroke, route: ScratchRoute) -> [CGPoint]? {
        guard Self.stemCard(a), route.fromSide == nil, route.toSide == nil, route.via == nil else { return nil }
        let r = a.cardRect, s = a.stem, gap = Self.stemGap
        let t = targetRect(b, route).rect
        var way: [CGPoint]
        if t.maxY < r.minY {                                   // ④ oben: der Stamm wächst hinaus
            let start = CGPoint(x: s.x, y: s.top)
            if t.minX > s.x + 12 { way = [start, CGPoint(x: s.x, y: t.midY), CGPoint(x: t.minX - gap, y: t.midY)] }
            else if t.maxX < s.x - 12 { way = [start, CGPoint(x: s.x, y: t.midY), CGPoint(x: t.maxX + gap, y: t.midY)] }
            else { way = [start, CGPoint(x: s.x, y: t.maxY + gap)] }
        } else if t.minX > r.maxX + 8 {                        // ① rechts: der Fuß läuft unten weiter
            let channel = (r.maxX + channelOffset(a, right: true, gap: t.minX - r.maxX)).rounded()
            let y = level(t, s.bottom)
            way = [CGPoint(x: s.x + 3, y: s.bottom), CGPoint(x: channel, y: s.bottom), CGPoint(x: channel, y: y),
                   CGPoint(x: t.minX - gap, y: y)]
        } else if t.maxX < r.minX - 8 {                        // ③ links: der Fuß dreht nach links
            let channel = (s.x - channelOffset(a, right: false, gap: s.x - t.maxX)).rounded()
            let y = level(t, s.bottom)
            way = [CGPoint(x: s.x, y: s.bottom - 10), CGPoint(x: s.x, y: s.bottom), CGPoint(x: channel, y: s.bottom),
                   CGPoint(x: channel, y: y), CGPoint(x: t.maxX + gap, y: y)]
        } else if t.minY > r.maxY {                            // ② unten: der Fuß knickt ab
            let lo = max(s.x + 16, t.minX + 8), hi = min(r.maxX - 8, t.maxX - 8)
            let x = lo <= hi ? min(max(t.midX, lo), hi) : t.midX
            way = [CGPoint(x: s.x + 3, y: s.bottom), CGPoint(x: x, y: s.bottom), CGPoint(x: x, y: t.minY - gap)]
        } else {
            return nil
        }
        way = Self.rounded(ScratchLayout.simplify(way), radius: 7)
        guard way.count >= 2, ScratchLayout.length(way) >= ScratchLayout.minLength else { return nil }
        // Fremde Karten im Weg: lieber der Router, der um sie herum führt.
        let skip = Set([a, b].map { $0.cardInfo?.id ?? "Bild \($0.uid)" })
        let blocked = arrowObstacles().contains { o in
            !skip.contains(o.name) && zip(way, way.dropFirst()).contains { ScratchLayout.segment($0, $1, hits: o.rect.insetBy(dx: 1, dy: 1)) }
        }
        return blocked ? nil : way
    }

    /// Höhe, auf der ein Pfeil seitlich ins Ziel läuft: die Fußhöhe, wenn das Ziel sie überspannt (dann ohne Treppe),
    /// sonst die Mitte des Ziels.
    private func level(_ t: NSRect, _ foot: CGFloat) -> CGFloat {
        foot >= t.minY + 1 && foot <= t.maxY - 1 ? foot : t.midY
    }

    /// Abstand des senkrechten Kanals von der Karte: für alle Pfeile einer Karte zur selben Seite gleich — das knappste
    /// Ziel entscheidet (höchstens 24 pt) —, damit sie sich den Weg teilen und erst vor den Zielen gabeln.
    private func channelOffset(_ a: ScratchStroke, right: Bool, gap: CGFloat) -> CGFloat {
        let r = a.cardRect, x = a.stem.x
        let gaps = strokes.compactMap { s -> CGFloat? in
            guard let link = s.link, link.from == a.uid, let route = link.route,
                  let b = strokes.first(where: { $0.uid == link.to }) else { return nil }
            let t = targetRect(b, route).rect
            if right { return t.minX > r.maxX + 8 ? t.minX - r.maxX : nil }
            return t.maxX < r.minX - 8 ? x - t.maxX : nil
        }
        return min(24, (gaps + [gap]).min()! / 2)
    }

    /// Rechte Winkel mit runden Ecken (wie der Fuß): jede innere Ecke als kurze Kurve aus Punkten.
    private static func rounded(_ points: [CGPoint], radius: CGFloat) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        var out = [points[0]]
        for i in 1..<(points.count - 1) {
            let (a, p, b) = (points[i - 1], points[i], points[i + 1])
            let la = hypot(p.x - a.x, p.y - a.y), lb = hypot(b.x - p.x, b.y - p.y)
            let d = min(radius, la / 2, lb / 2)
            guard d > 0.5 else { out.append(p); continue }
            let p1 = CGPoint(x: p.x - (p.x - a.x) / la * d, y: p.y - (p.y - a.y) / la * d)
            let p2 = CGPoint(x: p.x + (b.x - p.x) / lb * d, y: p.y + (b.y - p.y) / lb * d)
            for k in 0...6 {
                let t = CGFloat(k) / 6, u = 1 - t
                out.append(CGPoint(x: u * u * p1.x + 2 * u * t * p.x + t * t * p2.x, y: u * u * p1.y + 2 * u * t * p.y + t * t * p2.y))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    /// Ende eines gesetzten Pfeils: Klammer über den Absatz (Pfeil aus dem Stamm auf einen Absatz), sonst die Spitze.
    private func arrowTip(_ way: [CGPoint], from a: ScratchStroke, to b: ScratchStroke, route: ScratchRoute) -> [CGPoint] {
        let target = targetRect(b, route)
        guard target.part, Self.stemCard(a), let end = way.last, way.count >= 2 else { return ScratchLayout.head(way) }
        let t = target.rect, gap = Self.stemGap
        if abs(end.x - (t.minX - gap)) < 0.5 { return [CGPoint(x: end.x, y: t.minY), CGPoint(x: end.x, y: t.maxY)] }
        if abs(end.x - (t.maxX + gap)) < 0.5 { return [CGPoint(x: end.x, y: t.minY), CGPoint(x: end.x, y: t.maxY)] }
        if abs(end.y - (t.minY - gap)) < 0.5 || abs(end.y - (t.maxY + gap)) < 0.5 {
            return [CGPoint(x: t.minX, y: end.y), CGPoint(x: t.maxX, y: end.y)]
        }
        return ScratchLayout.head(way)
    }

    /// Weg eines gesetzten Pfeils zwischen zwei Objekten, so wie sie gerade liegen; `own` = der Pfeil selbst (beim
    /// Nachführen), damit er nicht sich selbst ausweicht.
    private func routePoints(from a: ScratchStroke, to b: ScratchStroke, route: ScratchRoute, own: String? = nil) -> ScratchLayout.Route {
        if let way = stemWay(from: a, to: b, route: route) { return ScratchLayout.Route(points: way, hits: []) }
        let (fromSide, toSide) = sides(route)
        let nameA = a.cardInfo?.id ?? "Bild \(a.uid)", nameB = b.cardInfo?.id ?? "Bild \(b.uid)"
        let others = strokes.filter { $0.link != nil && $0.uid != own }.map(\.points)
        return ScratchLayout.route(from: objectRect(a), to: targetRect(b, route).rect, fromSide: fromSide, toSide: toSide,
                                   via: route.via ?? [], obstacles: arrowObstacles(), fromName: nameA, toName: nameB,
                                   others: others)
    }

    /// Eingerasteter Agenten-Pfeil: rechtwinklig von Kante zu Kante, um Karten herum; Spitze als eigener, folgender Strich.
    private func routedArrow(from a: ScratchStroke, to b: ScratchStroke, route: ScratchRoute, color: Int,
                             author: String?) -> (strokes: [ScratchStroke], hits: [String]) {
        let way = routePoints(from: a, to: b, route: route)
        // Aus dem Stamm: so kräftig wie der Strich links (Gruppenfarbe 2,5, sonst 1,5), damit es eine Linie ist.
        let stemmed = Self.stemCard(a) && stemWay(from: a, to: b, route: route) != nil
        let width: CGFloat = stemmed ? (a.color != 0 ? 2.5 : 1.5) : 2
        let shaft = ScratchStroke(line: way.points, color: color, width: width, author: author)
        let (p0, p1) = (way.points[0], way.points[way.points.count - 1])   // `route` liefert immer ≥ 2 Punkte
        shaft.link = ScratchLink(from: a.uid, to: b.uid,
                                 a: CGPoint(x: p0.x - a.points[0].x, y: p0.y - a.points[0].y),
                                 b: CGPoint(x: p1.x - b.points[0].x, y: p1.y - b.points[0].y), route: route)
        let tip = ScratchStroke(line: arrowTip(way.points, from: a, to: b, route: route), color: color, width: width, author: author)
        tip.follows = shaft.uid
        return ([shaft, tip], way.hits)
    }

    private static func span(_ r: NSRect) -> String {
        "(x \(Int(r.minX.rounded()))…\(Int(r.maxX.rounded())), y \(Int(r.minY.rounded()))…\(Int(r.maxY.rounded())))"
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
        // Verwaiste Spitzen von Agenten-Pfeilen (Schaft vor dem 26.09. wegradiert) räumen — Nutzer-Tinte bleibt.
        let ids = Set(strokes.map(\.uid))
        strokes.removeAll { $0.isClaude && ($0.follows.map { !ids.contains($0) } ?? false) }
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
        // Klick neben den offenen Text = fertig, sonst nichts (kein neuer Text, kein Strich).
        let wasEditing = editor != nil
        // Ohne Werkzeug malt nichts — dann darf schon der Fokus-Klick ziehen (Karte oder Fläche).
        if takeFocusClick(event) {
            guard tool == .none else { endEditing(commit: true); return }
            focusClick = false
        }
        endEditing(commit: true)
        if wasEditing, tool == .text { return }
        let p = point(event)
        if tool == .eraser { beginErase(at: p); return }
        if tool == .cutter { beginCut(at: p); return }
        let (option, shift) = (event.modifierFlags.contains(.option), event.modifierFlags.contains(.shift))
        let drawing = tool == .pen || tool == .marker
        // Rechter Kartenrand (Zeiger, Text): Breite ziehen — danach bleibt sie fest.
        if !drawing, let index = widthEdge(at: p) { beginWidthDrag(index, at: p); return }
        // Stift/Marker malen auch über Karten und Bilder (Mats, 26.09.: Pfeile an Karten waren „clunky“, weil
        // Aufsetzen verschob). Verschieben dann am Griff links neben dem Objekt oder mit ⌥.
        if drawing, let index = gripIndex(at: p) { beginObjectDrag([index], at: p); return }
        // Zeiger/Text auf Karte oder Bild: ziehen verschiebt (die ganze Auswahl), ⇧-Klick nimmt dazu/heraus;
        // Doppelklick bearbeitet die Karte, mit dem Text-Werkzeug schon ein Klick.
        if !drawing || option, let index = objectIndex(at: p) {
            if !drawing, strokes[index].card, event.clickCount == 2 || tool == .text, !shift, !dragsFurther(event) {
                beginEditing(strokes[index], at: p)
                return
            }
            let uid = strokes[index].uid
            if shift {
                if selection.remove(uid) == nil { selection.insert(uid) }
                needsDisplay = true
                guard selection.contains(uid) else { return }
            } else if !selection.contains(uid) {
                selection = [uid]
                needsDisplay = true
            }
            beginObjectDrag(strokes.indices.filter { selection.contains(strokes[$0].uid) }, at: p)
            return
        }
        if !shift { clearSelection() }
        if tool == .text { beginTyping(at: p); return }
        if tool == .none {
            // ⇧-Ziehen auf freier Fläche: Rahmen aufziehen = mehrere auswählen; sonst Sicht verschieben.
            if shift { rubberBand = (p, p); return }
            panDrag = (convert(event.locationInWindow, from: nil), pan)
            return
        }
        let width = tool == .marker ? Self.markerWidths[sizeIndex] : Self.penWidths[sizeIndex]
        let stroke = ScratchStroke(start: p, color: colorIndex, width: width, marker: tool == .marker)
        current = stroke
        if !stroke.marker { snapHint = (linkObject(at: p)?.uid, nil) }
        invalidate(stroke.bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        if focusClick { return }
        let p = point(event)
        if objectDrag != nil { continueObjectDrag(to: p); return }
        if widthDrag != nil { continueWidthDrag(to: p); return }
        if let band = rubberBand {
            rubberBand = (band.start, p)
            needsDisplay = true
            return
        }
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
        updateSnapHint(stroke)
    }

    override func mouseUp(with event: NSEvent) {
        if focusClick { focusClick = false; return }
        if objectDrag != nil { endObjectDrag(); return }
        if widthDrag != nil { endWidthDrag(); return }
        if let band = rubberBand {
            rubberBand = nil
            let rect = Self.rect(band.start, band.now)
            for s in strokes where (s.card || s.isImage) && s.bounds.intersects(rect) { selection.insert(s.uid) }
            needsDisplay = true
            return
        }
        if panDrag != nil { panDrag = nil; return }
        if lastErasePoint != nil { endErase(); return }
        if cutting != nil { endCut(); return }
        guard let stroke = current else { return }
        current = nil
        if snapHint != (nil, nil) { snapHint = (nil, nil); needsDisplay = true }
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
        /// Gezogene Objekte (die Auswahl): Platz, Fassung zu Beginn, laufende Fassung.
        var items: [(index: Int, original: ScratchStroke, live: ScratchStroke)]
        var start: CGPoint
        var moved: CGPoint = .zero
        /// Pfeile (und ihre Spitzen) an diesen Objekten: Platz und Fassung zu Beginn.
        var linked: [(index: Int, original: ScratchStroke)] = []
        /// Umriss aller gezogenen Objekte zu Beginn (für Hilfslinien).
        var frame: NSRect
    }
    private var objectDrag: ObjectDrag?
    /// Ohne Werkzeug: Ziehen auf freier Fläche verschiebt die Sicht (Start am Bildschirm, Sicht zu Beginn).
    private var panDrag: (start: CGPoint, pan: CGPoint)?

    private func beginObjectDrag(_ indices: [Int], at p: CGPoint) {
        guard !indices.isEmpty else { return }
        let items = indices.map { index -> (index: Int, original: ScratchStroke, live: ScratchStroke) in
            let original = strokes[index]
            let live = original.copy()
            strokes[index] = live
            return (index, original, live)
        }
        let uids = Set(items.map(\.original.uid))
        let frame = items.dropFirst().reduce(items[0].original.bounds) { $0.union($1.original.bounds) }
        objectDrag = ObjectDrag(items: items, start: p,
                                linked: linkedStrokes(to: uids).filter { !uids.contains(strokes[$0].uid) }.map { ($0, strokes[$0]) },
                                frame: frame)
    }

    private func continueObjectDrag(to p: CGPoint) {
        guard var drag = objectDrag else { return }
        var total = CGPoint(x: p.x - drag.start.x, y: p.y - drag.start.y)
        // Hilfslinien: Kanten und Mitten rasten an anderen Karten/Bildern ein (⌘ beim Ziehen = frei).
        let oldGuides = guides
        guides = []
        if !NSEvent.modifierFlags.contains(.command) {
            let snap = alignmentSnap(drag.frame.offsetBy(dx: total.x, dy: total.y),
                                     skip: Set(drag.items.map(\.original.uid)))
            total.x += snap.dx
            total.y += snap.dy
            guides = snap.guides
        }
        var dirty = drag.items.reduce(NSRect.null) { $0.union($1.live.bounds) }
        for item in drag.items {
            item.live.offset(by: CGPoint(x: total.x - drag.moved.x, y: total.y - drag.moved.y))
            dirty = dirty.union(item.live.bounds)
        }
        drag.moved = total
        for (index, fresh) in relinked(drag.linked) where strokes.indices.contains(index) {
            dirty = dirty.union(strokes[index].bounds).union(fresh.bounds)
            strokes[index] = fresh
        }
        objectDrag = drag
        if !guides.isEmpty || !oldGuides.isEmpty || !selection.isEmpty { needsDisplay = true }
        invalidate(dirty.insetBy(dx: -8, dy: -8))
    }

    private func endObjectDrag() {
        guard let drag = objectDrag else { return }
        objectDrag = nil
        if !guides.isEmpty { guides = []; needsDisplay = true }
        guard hypot(drag.moved.x, drag.moved.y) >= 2 else {
            // Nur geklickt: alles wie vorher.
            for item in drag.items { strokes[item.index] = item.original }
            for (index, original) in drag.linked where strokes.indices.contains(index) { strokes[index] = original }
            needsDisplay = true
            return
        }
        let swaps = drag.linked.compactMap { index, original in
            strokes.indices.contains(index) && strokes[index] !== original ? (old: original, new: strokes[index]) : nil
        }
        // Gezogenes nach oben legen — von hinten entfernen, damit die gemerkten Plätze für Undo stimmen.
        var removed: [(index: Int, stroke: ScratchStroke)] = []
        for item in drag.items.sorted(by: { $0.index > $1.index }) {
            strokes.remove(at: item.index)
            removed.append((item.index, item.original))
        }
        let lives = drag.items.map(\.live)
        strokes.append(contentsOf: lives)
        commit(Edit(removed: removed, added: lives, swapped: swaps))
    }

    // MARK: Auswahl, Hilfslinien, Breite ziehen, Griff (26.09.)

    /// Ausgewählte Karten/Bilder (uids) — Zeiger: Klick wählt, ⇧-Klick nimmt dazu, ⇧-Ziehen zieht einen Rahmen auf.
    private var selection: Set<String> = []
    /// ⇧-Ziehen im Zeiger-Modus: Rahmen in Weltkoordinaten.
    private var rubberBand: (start: CGPoint, now: CGPoint)?
    /// Hilfslinien beim Ziehen (Weltkoordinaten, von → bis).
    private var guides: [(CGPoint, CGPoint)] = []
    /// Beim Malen: Objekt am Anfang des Strichs und unter dem Stift, an denen er als Pfeil einrasten würde.
    private var snapHint: (from: String?, to: String?) = (nil, nil)
    /// Objekt unter dem Zeiger (Stift/Marker: Griff zum Verschieben).
    private var hoverUID: String?
    /// Karte, deren rechter Rand unter dem Zeiger liegt (Zeiger/Text: Breite ziehen).
    private var hoverEdge: String?
    private var widthDrag: (index: Int, original: ScratchStroke, linked: [(index: Int, original: ScratchStroke)])?

    /// Wie weit neben einer Karte ein Strich-Ende noch als „an der Karte“ gilt (vorher 18).
    static let linkReach: CGFloat = 30
    /// Einrastweite der Hilfslinien am Bildschirm.
    static let guideReach: CGFloat = 6

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func clearSelection() {
        guard !selection.isEmpty else { return }
        selection = []
        needsDisplay = true
    }

    private func objectIndex(at p: CGPoint) -> Int? {
        strokes.lastIndex { $0.card ? $0.cardGrabs(p) : $0.isImage && $0.touches(p, radius: 0) }
    }

    /// Karte oder Bild, an dem ein Strich-Ende hier einrasten würde.
    private func linkObject(at p: CGPoint) -> ScratchStroke? {
        strokes.last { ($0.card || $0.isImage) && $0.bounds.insetBy(dx: -Self.linkReach, dy: -Self.linkReach).contains(p) }
    }

    /// Griff links neben dem Objekt unter dem Zeiger (Stift/Marker): sechs Punkte, am Bildschirm immer gleich groß.
    private func gripRect(_ s: ScratchStroke) -> NSRect {
        let r = s.bounds
        return NSRect(x: r.minX - 16 / zoom, y: r.minY, width: 12 / zoom, height: 18 / zoom)
    }

    private func gripIndex(at p: CGPoint) -> Int? {
        guard let uid = hoverUID, let index = strokes.firstIndex(where: { $0.uid == uid }),
              gripRect(strokes[index]).insetBy(dx: -3 / zoom, dy: -3 / zoom).contains(p) else { return nil }
        return index
    }

    /// Rechter Rand einer Karte (±5 pt am Bildschirm).
    private func widthEdge(at p: CGPoint) -> Int? {
        strokes.lastIndex { s in
            guard s.card else { return false }
            let r = s.cardRect
            return abs(p.x - r.maxX) <= 5 / zoom && p.y >= r.minY && p.y <= r.maxY
        }
    }

    private func updateSnapHint(_ stroke: ScratchStroke) {
        guard !stroke.marker, let p0 = stroke.points.first, let p1 = stroke.points.last else { return }
        let target = hypot(p1.x - p0.x, p1.y - p0.y) >= 24 ? linkObject(at: p1)?.uid : nil
        let next = (snapHint.from, snapHint.from != nil && target != snapHint.from ? target : nil)
        guard next != snapHint else { return }
        snapHint = next
        needsDisplay = true
    }

    /// Kanten (links, Mitte, rechts bzw. oben, Mitte, unten) des gezogenen Umrisses an denen anderer Karten/Bilder
    /// im Sichtbaren ausrichten: Verschiebung plus Hilfslinien.
    private func alignmentSnap(_ frame: NSRect, skip: Set<String>) -> (dx: CGFloat, dy: CGFloat, guides: [(CGPoint, CGPoint)]) {
        let reach = Self.guideReach / zoom
        let view = toWorld(bounds)
        let others = strokes.filter { ($0.card || $0.isImage) && !skip.contains($0.uid) && $0.bounds.intersects(view) }.map {
            $0.card ? $0.cardRect : $0.bounds
        }
        func best(_ mine: [CGFloat], _ theirs: (NSRect) -> [CGFloat]) -> (delta: CGFloat, at: CGFloat, rects: [NSRect])? {
            var found: (delta: CGFloat, at: CGFloat, rects: [NSRect])?
            for r in others {
                for a in mine { for b in theirs(r) where abs(b - a) <= reach {
                    if let f = found, abs(f.delta) < abs(b - a) - 0.01 { continue }
                    if let f = found, abs(f.delta - (b - a)) < 0.01 { found = (f.delta, f.at, f.rects + [r]) } else { found = (b - a, b, [r]) }
                } }
            }
            return found
        }
        var guides: [(CGPoint, CGPoint)] = []
        let x = best([frame.minX, frame.midX, frame.maxX]) { [$0.minX, $0.midX, $0.maxX] }
        let y = best([frame.minY, frame.midY, frame.maxY]) { [$0.minY, $0.midY, $0.maxY] }
        let moved = frame.offsetBy(dx: x?.delta ?? 0, dy: y?.delta ?? 0)
        if let x {
            let span = x.rects.reduce(moved) { $0.union($1) }
            guides.append((CGPoint(x: x.at, y: span.minY - 8 / zoom), CGPoint(x: x.at, y: span.maxY + 8 / zoom)))
        }
        if let y {
            let span = y.rects.reduce(moved) { $0.union($1) }
            guides.append((CGPoint(x: span.minX - 8 / zoom, y: y.at), CGPoint(x: span.maxX + 8 / zoom, y: y.at)))
        }
        return (x?.delta ?? 0, y?.delta ?? 0, guides)
    }

    private func beginWidthDrag(_ index: Int, at p: CGPoint) {
        let original = strokes[index]
        widthDrag = (index, original, linkedStrokes(to: [original.uid]).map { ($0, strokes[$0]) })
    }

    private func continueWidthDrag(to p: CGPoint) {
        guard let drag = widthDrag, var info = drag.original.cardInfo else { return }
        info.fixedWidth = true
        let width = min(800, max(ScratchStroke.cardMinWidth, p.x - drag.original.cardRect.minX))
        let before = strokes[drag.index].bounds
        let fresh = drag.original.cardUpdated(text: nil, origin: nil, width: width.rounded(), color: nil, info: info)
        strokes[drag.index] = fresh
        var dirty = before.union(fresh.bounds)
        for (index, linked) in relinked(drag.linked) where strokes.indices.contains(index) {
            dirty = dirty.union(strokes[index].bounds).union(linked.bounds)
            strokes[index] = linked
        }
        invalidate(dirty.insetBy(dx: -4, dy: -4))
    }

    private func endWidthDrag() {
        guard let drag = widthDrag else { return }
        widthDrag = nil
        let live = strokes[drag.index]
        guard live !== drag.original, abs(live.cardWidth - drag.original.cardWidth) >= 1 else {
            strokes[drag.index] = drag.original
            for (index, original) in drag.linked where strokes.indices.contains(index) { strokes[index] = original }
            needsDisplay = true
            return
        }
        let swaps = [(old: drag.original, new: live)] + drag.linked.compactMap { index, original in
            strokes.indices.contains(index) && strokes[index] !== original ? (old: original, new: strokes[index]) : nil
        }
        commit(Edit(swapped: swaps))
    }

    /// Ausgewähltes entfernen (⌫ im Zeiger-Modus) — ein Undo-Schritt, Pfeile daran wie beim Leeren.
    private func deleteSelection() {
        var removed: [(index: Int, stroke: ScratchStroke)] = []
        for index in strokes.indices.reversed() where selection.contains(strokes[index].uid) {
            removed.append((index, strokes.remove(at: index)))
        }
        selection = []
        guard !removed.isEmpty else { return }
        let orphans = dropOrphanArrows(after: removed)
        commit(Edit(removed: removed + orphans.removed, swapped: orphans.swapped))
    }

    // MARK: Zeiger über der Fläche — Griff, Breitenrand

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = point(event)
        let drawing = tool == .pen || tool == .marker
        let edge = drawing || editor != nil ? nil : widthEdge(at: p).map { strokes[$0].uid }
        // Griff bleibt, solange der Zeiger auf dem Objekt oder dem Griff ist.
        var hover: String?
        if drawing {
            hover = gripIndex(at: p) != nil ? hoverUID : objectIndex(at: p).map { strokes[$0].uid }
        }
        if edge != hoverEdge || hover != hoverUID {
            hoverEdge = edge
            hoverUID = hover
            needsDisplay = true
        }
        if edge != nil { NSCursor.resizeLeftRight.set() }
        else if drawing, gripIndex(at: p) != nil { NSCursor.openHand.set() }
        else { cursor.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hoverUID != nil || hoverEdge != nil else { return }
        hoverUID = nil
        hoverEdge = nil
        needsDisplay = true
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
        var rerouted: [String: (way: [CGPoint], tip: [CGPoint])] = [:]
        for (index, original) in originals {
            guard let link = original.link, let a = byUID[link.from], let b = byUID[link.to],
                  let p0 = original.points.first, let p1 = original.points.last else { continue }
            if let route = link.route {
                // Gesetzter Agenten-Pfeil: neu führen statt drehen — bleibt rechtwinklig und weicht Karten aus.
                let way = routePoints(from: a, to: b, route: route, own: original.uid).points
                // Kein Weg (z. B. Karten übereinander): Pfeil bleibt liegen, statt leer zu werden.
                guard way.count >= 2 else { continue }
                rerouted[original.uid] = (way, arrowTip(way, from: a, to: b, route: route))
                result.append((index, original.rerouted(way)))
                continue
            }
            let q0 = CGPoint(x: a.points[0].x + link.a.x, y: a.points[0].y + link.a.y)
            let q1 = CGPoint(x: b.points[0].x + link.b.x, y: b.points[0].y + link.b.y)
            let t = Self.similarity(p0, p1, q0, q1)
            transforms[original.uid] = t
            result.append((index, original.transformed(t.f, scale: t.scale)))
        }
        for (index, original) in originals {
            if let shaft = original.follows, let way = rerouted[shaft], way.way.count >= 2 {
                result.append((index, original.rerouted(way.tip)))
                continue
            }
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
            linkObject(at: p)
        }
        // Ein Pfeil läuft von einer Karte weg zur anderen hin: sein Ende liegt nicht mehr dicht an der ersten, sein Anfang
        // nicht dicht an der zweiten (26.09.: eine Klammer neben zwei gestapelten Karten rastete sonst als Pfeil ein).
        func near(_ p: CGPoint, _ s: ScratchStroke) -> Bool { s.bounds.insetBy(dx: -24, dy: -24).contains(p) }
        if stroke.points.count >= 2, hypot(p1.x - p0.x, p1.y - p0.y) >= 24,
           let a = object(at: p0), let b = object(at: p1), a !== b, !near(p1, a), !near(p0, b) {
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

    // MARK: Text tippen und Karten bearbeiten — neu setzen = neue Tinte

    private var editor: CardEditor?
    /// Karte in Bearbeitung; nil bei neuem Text (`typingAt`).
    private var editing: ScratchStroke?
    /// Neuer Text: obere linke Ecke der künftigen Karte.
    private var typingAt: CGPoint?
    /// Aussehen, das gerade getippt wird (Farbe/Größe lassen sich währenddessen umstellen).
    private var editStyle = ScratchCard()

    /// Text-Werkzeug auf einer Karte: Maustaste wieder los = bearbeiten, gezogen = verschieben.
    private func dragsFurther(_ event: NSEvent) -> Bool {
        guard tool == .text, event.clickCount < 2, let window else { return false }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp { return false }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                window.postEvent(next, atStart: true)
                return true
            }
        }
        return false
    }

    /// Text-Werkzeug ins Leere: Schreibmarke an den Klick, Farbe und Größe aus der Werkzeugleiste, ohne Rahmen.
    private func beginTyping(at p: CGPoint) {
        endEditing(commit: true)
        var style = ScratchCard()
        style.textColor = colorIndex
        style.size = Self.textSizes[sizeIndex]
        style.frame = "none"
        let line = style.font().ascender - style.font().descender + style.font().leading
        typingAt = CGPoint(x: p.x - ScratchStroke.cardPadding.width, y: p.y - ScratchStroke.cardPadding.height - line / 2)
        openEditor(text: "", style: style, title: false, caretAt: nil)
    }

    private func beginEditing(_ card: ScratchStroke, at p: CGPoint? = nil) {
        guard let info = card.cardInfo else { return }
        endEditing(commit: true)
        editing = card
        openEditor(text: (info.title.map { $0 + "\n" } ?? "") + (card.text ?? ""), style: info, title: info.title != nil, caretAt: p)
        invalidate(card.cardRect)
    }

    private func openEditor(text: String, style: ScratchCard, title: Bool, caretAt p: CGPoint?) {
        editStyle = style
        let view = CardEditor(frame: .zero)
        view.hasTitle = title
        view.string = text
        view.onFinish = { [weak self] commit in self?.endEditing(commit: commit) }
        view.onChange = { [weak self] in self?.styleEditor() }
        addSubview(view)
        editor = view
        styleEditor()
        window?.makeFirstResponder(view)
        if let p {
            let local = view.convert(toScreen(p), from: self)
            view.setSelectedRange(NSRange(location: view.characterIndexForInsertion(at: local), length: 0))
        } else {
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
    }

    /// Editor deckungsgleich mit der Karte: gleiche Schrift, Farbe und Einzug im aktuellen Zoom; wächst beim Tippen mit.
    private func styleEditor() {
        guard let view = editor else { return }
        let ink = palette[max(0, min(editStyle.textColor ?? 0, palette.count - 1))]
        let size = max(8, min(editStyle.size ?? ScratchCard.defaultSize, 72)) * zoom
        view.restyle(body: editStyle.font().withSize(size), title: editStyle.font(bold: true).withSize(size), color: ink,
                     align: editStyle.align, accent: ThemeStore.shared.accentColor, zoom: zoom)
        let pad = ScratchStroke.cardPadding
        let origin = editing?.points[0] ?? typingAt ?? .zero
        let (info, body) = split(view.string.isEmpty ? " " : view.string, title: view.hasTitle)
        let width = editWidth(for: body, info: info, origin: origin)
        let height = ScratchStroke.cardSize(text: body, width: width, info: info).height
        let rect = toScreen(NSRect(origin: origin, size: NSSize(width: width, height: height)))
        view.textContainerInset = NSSize(width: pad.width * zoom, height: pad.height * zoom)
        view.textContainer?.containerSize = NSSize(width: max(1, rect.width - 2 * pad.width * zoom), height: .greatestFiniteMagnitude)
        view.frame = rect
    }

    /// Breite beim Tippen (26.09.): so breit wie die längste Zeile, bis an den sichtbaren Rand (mindestens `cardMaxWidth`);
    /// von Hand gezogene oder vom Agenten gesetzte Breiten (`fixedWidth`) bleiben stehen.
    private func editWidth(for body: String, info: ScratchCard, origin: CGPoint) -> CGFloat {
        if let editing, editing.cardInfo?.fixedWidth == true { return editing.cardWidth }
        let edge = toWorld(bounds).maxX - origin.x - 24 / zoom
        let limit = max(ScratchStroke.cardMaxWidth, edge, editing?.cardWidth ?? 0)
        return ScratchStroke.cardWidth(for: body, info: info, limit: limit)
    }

    /// Im Editor steht der Titel als erste Zeile — zum Messen wie die Karte in Titel und Text teilen.
    private func split(_ text: String, title: Bool) -> (ScratchCard, String) {
        var info = editStyle
        info.title = nil
        guard title else { return (info, text) }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        info.title = String(lines[0])
        return (info, lines.count > 1 ? String(lines[1]) : "")
    }

    /// Fertig: Text neu gesetzt (Titel = erste Zeile, falls die Karte einen hatte); leer = Karte weg bzw. nichts angelegt.
    private func endEditing(commit keep: Bool) {
        guard let view = editor else { return }
        let card = editing, origin = typingAt, style = editStyle
        editor = nil
        editing = nil
        typingAt = nil
        let raw = view.string.trimmingCharacters(in: .whitespacesAndNewlines)
        view.onFinish = nil
        view.onChange = nil
        view.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        guard keep else { return }
        if let origin {
            guard !raw.isEmpty else { return }
            let fresh = ScratchStroke(card: raw, at: origin, width: editWidth(for: raw, info: style, origin: origin),
                                      color: 0, author: nil, info: style)
            strokes.append(fresh)
            nameCards()
            commit(Edit(added: [fresh]))
            return
        }
        guard let card, let index = strokes.firstIndex(where: { $0 === card }), var info = card.cardInfo else { return }
        let old = (info.title.map { $0 + "\n" } ?? "") + (card.text ?? "")
        guard raw != old.trimmingCharacters(in: .whitespacesAndNewlines) || style != info else { return }
        if raw.isEmpty {
            strokes.remove(at: index)
            commit(Edit(removed: [(index, card)]))
            return
        }
        info.textColor = style.textColor
        info.size = style.size
        var body = raw
        if info.title != nil {
            let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            info.title = String(lines[0])
            body = lines.count > 1 ? String(lines[1]) : ""
        }
        editing = card
        let width = editWidth(for: body, info: info, origin: card.points[0])
        editing = nil
        let fresh = card.cardUpdated(text: body, origin: nil, width: width, color: nil, info: info)
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
        if editor != nil { styleEditor() }
        if wasNormal != isNormalView { onStateChange?() }   // Mitte-Knopf hell/blass
    }

    /// Zurück in die Normalsicht (Mitte, 100 %) — sanft, wenn gewünscht.
    func resetView(animated: Bool) { move(toPan: .zero, zoom: 1, animated: animated) }

    /// Überblick (Mats, 26.09.: ␣␣ soll „best fit“ machen statt stur zur Mitte): alles Gezeichnete eingepasst,
    /// höchstens 100 %. Steht die Sicht schon so, geht es zur Mitte — zweimal ␣␣ = Normalsicht.
    func fitView(animated: Bool) {
        guard let content = contentBounds(.all) else { return resetView(animated: animated) }
        // Rand: die Werkzeugleiste schwebt an einer Kante, Luft rundherum.
        let margin = ScratchpadToolbar.thickness + 24
        let room = NSSize(width: max(80, bounds.width - 2 * margin), height: max(80, bounds.height - 2 * margin))
        let fit = min(1, room.width / max(content.width, 1), room.height / max(content.height, 1))
        let target = max(Self.zoomRange.lowerBound, fit)
        let targetPan = CGPoint(x: -content.midX * target, y: -content.midY * target)
        if abs(zoom - target) < 0.005, hypot(pan.x - targetPan.x, pan.y - targetPan.y) < 2 {
            return resetView(animated: animated)
        }
        move(toPan: targetPan, zoom: target, animated: animated)
    }

    private func move(toPan target: CGPoint, zoom goal: CGFloat, animated: Bool) {
        springTimer?.invalidate(); springTimer = nil
        guard pan != target || zoom != goal else { return }
        guard animated, window != nil else { setView(pan: target, zoom: goal); return }
        let (startPan, startZoom, started) = (pan, zoom, CACurrentMediaTime())
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - started) / 0.25)
            let e = 1 - pow(1 - t, 3)   // ease-out
            self.setView(pan: CGPoint(x: startPan.x + (target.x - startPan.x) * e, y: startPan.y + (target.y - startPan.y) * e),
                         zoom: startZoom + (goal - startZoom) * e)
            if t >= 1 { timer.invalidate(); self.springTimer = nil; self.setView(pan: target, zoom: goal) }
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

    /// Zweimal Leertaste kurz hintereinander = Überblick (`fitView`).
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

    /// Doppeltipp mit zwei Fingern: Überblick wie ␣␣.
    override func smartMagnify(with event: NSEvent) { fitView(animated: true) }

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
        // Schaft weg = Spitze weg (26.09.: nach dem Radieren eines Pfeils blieb die Spitze als „>“ liegen).
        let shafts = Set(erased.map(\.stroke.uid))
        for index in strokes.indices.reversed() where strokes[index].follows.map(shafts.contains) ?? false {
            erased.append((index, strokes.remove(at: index)))
        }
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

    /// V/P/M/T/E/X Werkzeug (V = Zeiger, T = Text, X = Pixel-Radierer), 1–7 Farbe, +/− Stärke — nur ohne ⌘/⌥/⌃.
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.keyDown(with: event) }
        if key == " " {
            if event.timestamp - lastSpace < 0.4 { fitView(animated: true); lastSpace = 0 } else { lastSpace = event.timestamp }
            return
        }
        // Esc hebt die Auswahl auf, ⌫/⌦ entfernt sie.
        if event.keyCode == 53, !selection.isEmpty { clearSelection(); return }
        if [51, 117].contains(event.keyCode), !selection.isEmpty { deleteSelection(); return }
        switch key {
        case "v": select(.none)
        case "p": select(.pen)
        case "m": select(.marker)
        case "t": select(.text)
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
        drawHints()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Auswahl, Einrast-Ziele, Griff, Breitenrand, Hilfslinien, Auswahlrahmen — nur am Bildschirm, nie im Bild für Agenten.
    private func drawHints() {
        let accent = ThemeStore.shared.accentColor
        let hair = 1 / zoom
        func outline(_ uid: String?, inset: CGFloat, fill: CGFloat, dash: Bool) {
            guard let uid, let s = strokes.first(where: { $0.uid == uid }) else { return }
            let r = (s.card ? s.cardRect : s.bounds).insetBy(dx: -inset / zoom, dy: -inset / zoom)
            let path = NSBezierPath(roundedRect: r, xRadius: 6 / zoom, yRadius: 6 / zoom)
            if fill > 0 { accent.withAlphaComponent(fill).setFill(); path.fill() }
            path.lineWidth = 1.5 * hair
            if dash { path.setLineDash([4 * hair, 3 * hair], count: 2, phase: 0) }
            accent.setStroke(); path.stroke()
        }
        for uid in selection { outline(uid, inset: 4, fill: 0, dash: false) }
        outline(snapHint.from, inset: 6, fill: 0.08, dash: true)
        outline(snapHint.to, inset: 6, fill: 0.12, dash: false)
        if let uid = hoverUID, let s = strokes.first(where: { $0.uid == uid }) {
            let grip = gripRect(s)
            accent.withAlphaComponent(0.85).setFill()
            for row in 0..<3 { for col in 0..<2 {
                let c = CGPoint(x: grip.minX + (3 + CGFloat(col) * 6) / zoom, y: grip.minY + (3 + CGFloat(row) * 6) / zoom)
                NSBezierPath(ovalIn: NSRect(x: c.x - 1.5 * hair, y: c.y - 1.5 * hair, width: 3 * hair, height: 3 * hair)).fill()
            } }
        }
        let edgeUID = widthDrag.map { strokes[$0.index].uid } ?? hoverEdge
        if let uid = edgeUID, let s = strokes.first(where: { $0.uid == uid }) {
            let r = s.cardRect
            let bar = NSBezierPath()
            bar.move(to: CGPoint(x: r.maxX, y: r.minY + 2 * hair))
            bar.line(to: CGPoint(x: r.maxX, y: r.maxY - 2 * hair))
            bar.lineWidth = 2 * hair
            bar.lineCapStyle = .round
            accent.setStroke(); bar.stroke()
        }
        if !guides.isEmpty {
            let line = NSBezierPath()
            for (a, b) in guides { line.move(to: a); line.line(to: b) }
            line.lineWidth = hair
            line.setLineDash([3 * hair, 3 * hair], count: 2, phase: 0)
            accent.setStroke(); line.stroke()
        }
        if let band = rubberBand {
            let path = NSBezierPath(rect: Self.rect(band.start, band.now))
            accent.withAlphaComponent(0.08).setFill(); path.fill()
            path.lineWidth = hair
            accent.setStroke(); path.stroke()
        }
    }

    /// Marker unter die Tinte, damit Markiertes lesbar bleibt; der laufende Strich obenauf.
    private func drawStrokes(in rect: NSRect) {
        leftStems = Set(strokes.compactMap { s -> String? in
            guard let link = s.link, link.route != nil, s.points.count >= 2,
                  let card = strokes.first(where: { $0.uid == link.from }), card.card else { return nil }
            return Self.exitsLeft(s.points, card) ? link.from : nil
        })
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
            // Gruppenfarbe (Befund 25.09.: beim leisen Strich war `color` unsichtbar): Strich kräftig in der Farbe, Titel auch.
            let grouped = stroke.color != 0
            switch stroke.frameStyle {
            case _ where !stroke.showsFrame: break
            case "mark":
                let mark = leftStems.contains(stroke.uid) ? stroke.stemPath : stroke.markPath
                if grouped { mark.lineWidth = 2.5 }
                (grouped ? color.withAlphaComponent(0.9) : textInk.withAlphaComponent(0.55)).setStroke()
                mark.stroke()
            case let style:
                frame.lineWidth = style == "thick" ? 2.5 : stroke.width
                if style == "dashed" { frame.setLineDash([5, 4], count: 2, phase: 0) }
                color.withAlphaComponent(0.75).setStroke()
                frame.stroke()
            }
            let pad = ScratchStroke.cardPadding
            let ink = textInk
            let content = NSMutableAttributedString(attributedString: info.attributed(
                text: text, color: ink, titleColor: grouped && info.textColor == nil ? color : nil))
            for range in stroke.erasedChars.rangeView where range.upperBound <= content.length {
                content.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: range.lowerBound, length: range.count))
            }
            // In Bearbeitung steht der Text im Editor darüber — Rahmen und Fläche bleiben stehen.
            if stroke !== editing {
                content.draw(with: rect.insetBy(dx: pad.width, dy: pad.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
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
    /// Karten, deren Stamm einen Pfeil nach links abgibt — ihr Fuß fällt weg (in `drawStrokes` bestimmt).
    private var leftStems: Set<String> = []

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
        case .text: return .iBeam
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
            case .none, .text: break
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

    private static let items: [Item] = [.tool(.none), .tool(.pen), .tool(.marker), .tool(.text), .tool(.eraser), .tool(.cutter), .divider]
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
        case .tool(.pen): "Stift (P): malt auch über Karten und Bilder — verschieben am Griff links daneben oder mit ⌥; "
            + "ein Strich von Karte zu Karte rastet als Pfeil ein (Ziel leuchtet)"
        case .tool(.marker): "Marker (M)"
        case .tool(.text): "Text (T): klicken und tippen — wird Tinte wie Karten (radierbar, verschiebbar). Klick auf Text bearbeitet, ziehen verschiebt; Esc oder Klick daneben = fertig"
        case .tool(.eraser): "Radierer (E): nimmt ganze Tintenflecken — Striche, Bilder, bei Karten Buchstabe, Rahmen oder Fläche am Stück. Rechtsklick radiert immer"
        case .tool(.cutter): "Pixel-Radierer (X): schneidet aus allem, was er überfährt"
        case .tool(.none): "Zeiger (V): verschieben, Doppelklick bearbeitet, ⇧-Klick/⇧-Ziehen wählt mehrere, ⌫ entfernt; "
            + "rechten Kartenrand ziehen = Breite; ohne Karte: Fläche verschieben"
        case .color(let i): "\(ScratchPalette.names[i]) (\(i + 1))"
        case .size: "Stärke (+ / −) — beim Text die Schriftgröße"
        case .undo: "Rückgängig (⌘Z)"
        case .redo: "Wiederholen (⇧⌘Z)"
        case .clear: "Leeren (⌘⌫) — ⌘S sichert als PNG, ⌘C kopiert als Bild"
        case .home: "Überblick: alles einpassen (zweimal Leertaste, Doppeltipp mit zwei Fingern) — nochmal = Mitte 100 % (⌘0)"
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
        case .home: canvas.fitView(animated: true)
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
            case .home: drawSymbol("viewfinder", in: rect, color: canvas.strokeCount > 0 || !canvas.isNormalView ? dim : faint)
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
        case .text: "character.cursor.ibeam"
        case .eraser: "eraser"
        case .cutter: "eraser.line.dashed"
        case .none: "cursorarrow"
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

/// Eingabefeld über einer Karte bzw. neuem Text: sitzt deckungsgleich auf der Tinte (gleiche Schrift, kein eigener Grund),
/// nur ein leiser Rahmen in der Akzentfarbe zeigt, dass hier getippt wird. ⏎ = neue Zeile; Esc, ⌘⏎ oder Klick daneben
/// = fertig (⌘Z nimmt es zurück). Einfügen immer als reiner Text.
final class CardEditor: NSTextView {
    var onFinish: ((Bool) -> Void)?
    var onChange: (() -> Void)?
    /// Erste Zeile fett (Karte mit Titel).
    var hasTitle = false
    private var bodyAttributes: [NSAttributedString.Key: Any] = [:]
    private var titleAttributes: [NSAttributedString.Key: Any] = [:]
    private var restyling = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isRichText = true
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        focusRingType = .none
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { fatalError() }

    func restyle(body: NSFont, title: NSFont, color: NSColor, align: String?, accent: NSColor, zoom: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        switch align?.lowercased() {
        case "center": paragraph.alignment = .center
        case "right": paragraph.alignment = .right
        default: paragraph.alignment = .left
        }
        paragraph.lineBreakMode = .byWordWrapping
        bodyAttributes = [.font: body, .foregroundColor: color, .paragraphStyle: paragraph]
        titleAttributes = [.font: title, .foregroundColor: color, .paragraphStyle: paragraph]
        insertionPointColor = color
        selectedTextAttributes = [.backgroundColor: accent.withAlphaComponent(0.3)]
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        applyAttributes()
    }

    private func applyAttributes() {
        guard let storage = textStorage else { return }
        restyling = true
        let all = NSRange(location: 0, length: storage.length)
        let firstLine = (storage.string as NSString).range(of: "\n").location
        let titleEnd = hasTitle ? (firstLine == NSNotFound ? storage.length : firstLine) : 0
        storage.beginEditing()
        storage.setAttributes(bodyAttributes, range: all)
        if titleEnd > 0 { storage.setAttributes(titleAttributes, range: NSRange(location: 0, length: titleEnd)) }
        storage.endEditing()
        typingAttributes = hasTitle && selectedRange().location <= titleEnd ? titleAttributes : bodyAttributes
        restyling = false
    }

    override func didChangeText() {
        super.didChangeText()
        guard !restyling else { return }
        onChange?()
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        if !restyling, !bodyAttributes.isEmpty { typingAttributes = hasTitle && charRange.location <= titleEnd ? titleAttributes : bodyAttributes }
    }

    private var titleEnd: Int {
        let n = (string as NSString).range(of: "\n").location
        return n == NSNotFound ? (string as NSString).length : n
    }

    /// Nur Text annehmen — Formatierung aus der Zwischenablage käme sonst mit.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func cancelOperation(_ sender: Any?) { onFinish?(true) }

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
