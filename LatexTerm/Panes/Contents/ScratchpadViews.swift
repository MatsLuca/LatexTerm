import AppKit

/// Wurzel der Scratchpad-Kachel: Malfläche über die ganze Kachel, Werkzeugleiste schwebt oben links.
/// Hochkant, solange die Kachel hoch genug ist, sonst quer.
final class ScratchpadView: NSView {
    let canvas = ScratchpadCanvas()
    private let toolbar = ScratchpadToolbar()

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        canvas.autoresizingMask = [.width, .height]
        addSubview(canvas)
        addSubview(toolbar)
        toolbar.canvas = canvas
        canvas.onStateChange = { [weak toolbar] in toolbar?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func apply(_ theme: TerminalTheme) {
        canvas.apply(theme)
        toolbar.apply(theme)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let length = ScratchpadToolbar.length, thickness = ScratchpadToolbar.thickness, margin: CGFloat = 8
        toolbar.vertical = newSize.height - 2 * margin >= length || newSize.width - 2 * margin < length
        toolbar.frame = toolbar.vertical
            ? NSRect(x: margin, y: margin, width: thickness, height: length)
            : NSRect(x: margin, y: margin, width: length, height: thickness)
    }
}

// MARK: - Malfläche

final class ScratchpadCanvas: NSView {
    /// Zeichnung oder Werkzeug geändert → sichern, Chip neu.
    var onChange: (() -> Void)?
    /// ⌘S → Sichern-Dialog (macht der Inhalt).
    var onSaveRequest: (() -> Void)?
    /// Werkzeugleiste neu zeichnen.
    var onStateChange: (() -> Void)?

    private(set) var tool: ScratchTool = .pen
    private(set) var colorIndex = 0
    private(set) var sizeIndex = 1
    private(set) var palette = [NSColor](repeating: .white, count: ScratchPalette.names.count)
    private var paper: NSColor = .black

    private var strokes: [ScratchStroke] = []
    private var current: ScratchStroke?
    private var erased: [(index: Int, stroke: ScratchStroke)] = []
    private var lastErasePoint: CGPoint?
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    private enum Edit {
        case add(ScratchStroke)
        case erase([(index: Int, stroke: ScratchStroke)])
        case clear([ScratchStroke])
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
        if tool == .eraser { tool = .pen }
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

    func clear() {
        guard !strokes.isEmpty else { return }
        commit(.clear(strokes))
        strokes.removeAll()
        needsDisplay = true
    }

    func undo() {
        guard let edit = undoStack.popLast() else { NSSound.beep(); return }
        switch edit {
        case .add(let stroke): strokes.removeAll { $0 === stroke }
        case .erase(let list): for e in list.reversed() { strokes.insert(e.stroke, at: min(e.index, strokes.count)) }
        case .clear(let old): strokes = old
        }
        redoStack.append(edit)
        edited()
    }

    func redo() {
        guard let edit = redoStack.popLast() else { NSSound.beep(); return }
        switch edit {
        case .add(let stroke): strokes.append(stroke)
        case .erase(let list): for e in list { strokes.removeAll { $0 === e.stroke } }
        case .clear: strokes.removeAll()
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

    // MARK: Sichern

    func restore(_ doc: ScratchDocument) {
        strokes = doc.strokes
        // v1 lag in Kachel-Koordinaten (oben links = 0,0): Zeichnung auf die Mitte legen.
        if doc.version < 2, let first = strokes.first {
            let box = strokes.map(\.bounds).reduce(first.bounds) { $0.union($1) }
            let shift = CGPoint(x: -box.midX, y: -box.midY)
            strokes.forEach { $0.offset(by: shift) }
        }
        tool = doc.tool
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
        guard rect.width >= 1, rect.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * 2), pixelsHigh: Int(rect.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = rect.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: rect.height)
        flip.scaleX(by: 1, yBy: -1)
        flip.translateX(by: -rect.minX, yBy: -rect.minY)
        flip.concat()
        paper.setFill()
        rect.fill()
        drawStrokes(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private func copyImage() {
        guard let png = pngData() else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    // MARK: Maus

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = point(event)
        if tool == .eraser { beginErase(at: p); return }
        let width = tool == .marker ? Self.markerWidths[sizeIndex] : Self.penWidths[sizeIndex]
        let stroke = ScratchStroke(start: p, color: colorIndex, width: width, marker: tool == .marker)
        current = stroke
        invalidate(stroke.bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if lastErasePoint != nil { continueErase(to: p); return }
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
        if lastErasePoint != nil { endErase(); return }
        guard let stroke = current else { return }
        current = nil
        strokes.append(stroke)
        commit(.add(stroke))
    }

    /// Rechtsklick bzw. Zwei-Finger-Klick radiert, egal welches Werkzeug gewählt ist.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        beginErase(at: point(event))
    }
    override func rightMouseDragged(with event: NSEvent) { continueErase(to: point(event)) }
    override func rightMouseUp(with event: NSEvent) { endErase() }

    private func point(_ event: NSEvent) -> CGPoint { toWorld(convert(event.locationInWindow, from: nil)) }

    // MARK: Ansicht — Mittelpunkt-Anker, Verschieben, Zoomen

    /// Die Zeichnung hängt an der Mitte der Kachel (Weltpunkt 0,0 = Kachelmitte in der Normalsicht): wird die
    /// Kachel größer oder kleiner, wächst bzw. schrumpft der Rand gleichmäßig rundherum. `pan`/`zoom` sind
    /// die Abweichung von der Normalsicht (Trackpad: zwei Finger verschieben, Aufziehen zoomt). Jeder
    /// Größenwechsel (⌘⏎, Raster) und das Verlassen der Kachel federn zurück in die Normalsicht.
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

    private var isNormalView: Bool { pan == .zero && zoom == 1 }

    private func setView(pan: CGPoint, zoom: CGFloat) {
        self.pan = pan
        self.zoom = zoom
        needsDisplay = true
        cursorChanged()
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

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { resetView(animated: true) }
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { resetView(animated: true) }
        return ok
    }

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

    private func beginErase(at p: CGPoint) {
        erased = []
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
        guard !erased.isEmpty else { return }
        commit(.erase(erased))
        erased = []
    }

    private func erase(at p: CGPoint) {
        while let index = strokes.lastIndex(where: { $0.touches(p, radius: worldEraserRadius) }) {
            let stroke = strokes.remove(at: index)
            erased.append((index, stroke))
            invalidate(stroke.bounds)
        }
    }

    // MARK: Tasten

    /// P/M/E Werkzeug, 1–7 Farbe, +/− Stärke — nur ohne ⌘/⌥/⌃.
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.keyDown(with: event) }
        switch key {
        case "p": select(.pen)
        case "m": select(.marker)
        case "e": select(.eraser)
        case "+", "=": stepSize(1)
        case "-": stepSize(-1)
        default:
            if let digit = Int(key), (1...palette.count).contains(digit) { selectColor(digit - 1) } else { super.keyDown(with: event) }
        }
    }

    /// ⌘Z/⇧⌘Z, ⌘⌫ leeren, ⌘S als PNG sichern, ⌘C als Bild kopieren. Kachel-Kürzel (⌘W …) verteilt vorher die Hülle.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard window?.firstResponder === self, mods == .command || mods == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        let key = event.charactersIgnoringModifiers?.lowercased()
        let shift = mods.contains(.shift)
        switch (key, shift) {
        case ("z", false): undo()
        case ("z", true): redo()
        case ("s", false): onSaveRequest?()
        case ("c", false): copyImage()
        case ("0", false): resetView(animated: true)
        default:
            guard event.keyCode == 51, !shift else { return super.performKeyEquivalent(with: event) }   // ⌫
            clear()
        }
        return true
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill()
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

    private func draw(_ stroke: ScratchStroke) {
        let color = palette[max(0, min(stroke.color, palette.count - 1))]
        (stroke.marker ? color.withAlphaComponent(Self.markerAlpha) : color).setStroke()
        stroke.path.stroke()
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
        case .eraser: diameter = eraserRadius * 2   // Radierer: fest am Bildschirm
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
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }
}

// MARK: - Werkzeugleiste

final class ScratchpadToolbar: NSView {
    weak var canvas: ScratchpadCanvas?
    var vertical = true { didSet { if vertical != oldValue { needsDisplay = true; updateToolTips() } } }

    private enum Item {
        case tool(ScratchTool), color(Int), size, undo, redo, clear, divider
    }

    private static let items: [Item] = [.tool(.pen), .tool(.marker), .tool(.eraser), .divider]
        + ScratchPalette.names.indices.map { .color($0) }
        + [.divider, .size, .divider, .undo, .redo, .clear]

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
        background = theme.badgeBackground
        foreground = theme.foreground.withAlphaComponent(1)
        dim = theme.dim
        faint = theme.faint
        needsDisplay = true
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

    private func updateToolTips() {
        removeAllToolTips()
        for (item, rect) in zip(Self.items, frames) {
            if let text = toolTip(for: item) { addToolTip(rect, owner: text as NSString, userData: nil) }
        }
    }

    private func toolTip(for item: Item) -> String? {
        switch item {
        case .tool(.pen): "Stift (P)"
        case .tool(.marker): "Marker (M)"
        case .tool(.eraser): "Radierer (E) — Rechtsklick radiert immer"
        case .color(let i): "\(ScratchPalette.names[i]) (\(i + 1))"
        case .size: "Stärke (+ / −)"
        case .undo: "Rückgängig (⌘Z)"
        case .redo: "Wiederholen (⇧⌘Z)"
        case .clear: "Leeren (⌘⌫) — ⌘S sichert als PNG, ⌘C kopiert als Bild"
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
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        background.setFill(); pill.fill()
        faint.setStroke(); pill.lineWidth = 1; pill.stroke()

        for (index, (item, rect)) in zip(Self.items, frames).enumerated() {
            let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            if hovered == index, !isDivider(item) {
                foreground.withAlphaComponent(0.08).setFill(); highlight.fill()
            }
            switch item {
            case .tool(let tool):
                let selected = canvas.tool == tool
                if selected { foreground.withAlphaComponent(0.16).setFill(); highlight.fill() }
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
                if canvas.tool == .eraser {
                    dot.lineWidth = 1.5; foreground.setStroke(); dot.stroke()
                } else {
                    canvas.inkColor.setFill(); dot.fill()
                }
            case .undo: drawSymbol("arrow.uturn.backward", in: rect, color: canvas.canUndo ? dim : faint)
            case .redo: drawSymbol("arrow.uturn.forward", in: rect, color: canvas.canRedo ? dim : faint)
            case .clear: drawSymbol("trash", in: rect, color: canvas.strokeCount > 0 ? dim : faint)
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
