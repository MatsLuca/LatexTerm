import AppKit

/// Die großen Knöpfe der ⌘T-Auswahl (`KachelWahlContent`): füllen die Kachel lückenlos, Raster nach Kachelform
/// (breit = nebeneinander, hoch = untereinander). Zeichnet selbst — Fläche mit Verlauf in der Tonfarbe, Lichthof
/// hinter dem Symbol, Titel + Untertitel, Tastenkappe mit der Nummer. Kleine Bewegungen: Knöpfe gleiten beim Öffnen
/// nacheinander herein, Hover hebt an, Drücken senkt. Braucht vom Rest der App nur Theme und `Tone`.
final class KachelWahlView: NSView {
    enum Action: Equatable {
        case home, terminal
        case app(String)
        /// Neue Claude-Session in diesem Ordner (`~` wird aufgelöst).
        case claude(String)
    }

    struct Tile {
        var title: String
        var subtitle: String
        /// SF-Symbol-Name.
        var symbol: String
        var tone: Tone
        var action: Action
    }

    var onPick: ((Tile) -> Void)?
    var onCancel: (() -> Void)?

    private let tiles: [Tile]
    private var rects: [NSRect] = []
    private var columns = 1
    private var selected = 0 { didSet { if selected != oldValue { animate() } } }
    private var hovered: Int? { didSet { if hovered != oldValue { animate() } } }
    private var pressed: Int? { didSet { if pressed != oldValue { animate() } } }
    private var theme = ThemeStore.shared.theme

    // Bewegung: je Knopf ein Hover-Wert (0…1) und ein Druck-Wert, dazu der Einblend-Zeitpunkt.
    private var lift: [CGFloat]
    private var press: [CGFloat]
    private var appearStart: CFTimeInterval?
    private var timer: Timer?

    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 12
    private static let footer: CGFloat = 22
    private static let appearDuration: CFTimeInterval = 0.32
    private static let appearStagger: CFTimeInterval = 0.06

    init(tiles: [Tile]) {
        self.tiles = tiles
        lift = Array(repeating: 0, count: tiles.count)
        press = Array(repeating: 0, count: tiles.count)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        setAccessibilityRole(.group)
        setAccessibilityLabel("Neue Kachel")
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, appearStart == nil { appearStart = CACurrentMediaTime(); animate() }
    }

    /// Zum Testen/Rendern ohne Fenster: Einblenden überspringen.
    func finishAppearing() { appearStart = -100; needsDisplay = true }

    // MARK: Raster

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTiles()
    }

    private var showsFooter: Bool { bounds.height >= 260 && bounds.width >= 320 }

    /// Spaltenzahl so wählen, dass die Knöpfe möglichst quadratisch werden; füllt immer die ganze Fläche.
    private func layoutTiles() {
        let n = tiles.count
        guard n > 0 else { rects = []; return }
        var area = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        if showsFooter { area.size.height -= Self.footer }
        var best = (cols: 1, score: CGFloat.infinity)
        for cols in 1...n {
            let rows = Int(ceil(Double(n) / Double(cols)))
            let w = (area.width - CGFloat(cols - 1) * Self.gap) / CGFloat(cols)
            let h = (area.height - CGFloat(rows - 1) * Self.gap) / CGFloat(rows)
            guard w > 0, h > 0 else { continue }
            let score = abs(log(w / h)) + (cols * rows > n ? 0.15 : 0)   // leere Plätze leicht bestrafen
            if score < best.score { best = (cols, score) }
        }
        columns = best.cols
        let rows = Int(ceil(Double(n) / Double(columns)))
        let h = (area.height - CGFloat(rows - 1) * Self.gap) / CGFloat(rows)
        rects = (0..<n).map { i in
            let row = i / columns
            // Letzte Reihe mit weniger Knöpfen: die füllen sie ganz aus.
            let inRow = row == rows - 1 ? n - row * columns : columns
            let col = i - row * columns
            let w = (area.width - CGFloat(inRow - 1) * Self.gap) / CGFloat(inRow)
            return NSRect(x: area.minX + CGFloat(col) * (w + Self.gap), y: area.minY + CGFloat(row) * (h + Self.gap),
                          width: w, height: h).integral
        }
        needsDisplay = true
    }

    private func index(at point: NSPoint) -> Int? { rects.firstIndex(where: { $0.contains(point) }) }

    // MARK: Bewegung

    private func animate() {
        needsDisplay = true
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
    }

    private func step() {
        var moving = false
        let active = isActive
        for i in tiles.indices {
            let wantLift: CGFloat = (i == hovered || (active && i == selected && hovered == nil)) ? 1 : 0
            let wantPress: CGFloat = i == pressed ? 1 : 0
            lift[i] += (wantLift - lift[i]) * 0.22
            press[i] += (wantPress - press[i]) * 0.35
            if abs(wantLift - lift[i]) > 0.005 || abs(wantPress - press[i]) > 0.005 { moving = true }
            else { lift[i] = wantLift; press[i] = wantPress }
        }
        if let start = appearStart,
           CACurrentMediaTime() - start < Self.appearDuration + Self.appearStagger * Double(tiles.count) { moving = true }
        needsDisplay = true
        if !moving { timer?.invalidate(); timer = nil }
    }

    private func appear(_ i: Int) -> CGFloat {
        guard let start = appearStart else { return 0 }
        let t = (CACurrentMediaTime() - start - Self.appearStagger * Double(i)) / Self.appearDuration
        let x = CGFloat(min(max(t, 0), 1))
        return 1 - pow(1 - x, 3)   // ease-out
    }

    private var isActive: Bool { window?.isKeyWindow == true && window?.firstResponder === self }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        theme.background.setFill()
        dirtyRect.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let fg = theme.foreground
        let active = isActive || appearStart == -100

        for (i, tile) in tiles.enumerated() where rects.indices.contains(i) {
            let shown = appear(i)
            guard shown > 0 else { continue }
            let l = lift[i], p = press[i]
            let focused = active && i == selected
            let tone = tile.tone.color
            var r = rects[i]
            let side = min(r.width, r.height)
            let radius = min(22, max(12, side * 0.09))

            ctx.saveGState()
            ctx.setAlpha(shown)
            // Einblenden: von leicht unten und etwas kleiner; Drücken senkt den Knopf.
            let scale = (0.965 + 0.035 * shown) * (1 - 0.015 * p)
            ctx.translateBy(x: r.midX, y: r.midY + (1 - shown) * 10)
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -r.midX, y: -r.midY)

            // Fläche: Grund + Verlauf in Tonfarbe (oben kräftiger), Hover hebt ihn an.
            let shape = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
            fg.withAlphaComponent(0.03 + 0.02 * l).setFill()
            shape.fill()
            let top = tone.withAlphaComponent(0.13 + 0.10 * l)
            let bottom = tone.withAlphaComponent(0.02 + 0.03 * l)
            NSGradient(starting: top, ending: bottom)?.draw(in: shape, angle: -90)

            // Lichthof hinter dem Symbol.
            let iconSize = max(30, min(side * 0.27, 112))
            let showSubtitle = r.height >= 170 && r.width >= 170
            let titleSize = max(13, min(side * 0.068, 24))
            let subSize = max(11, min(side * 0.042, 14))
            let titleFont = Self.rounded(titleSize, .semibold)
            let subFont = NSFont.systemFont(ofSize: subSize, weight: .regular)
            let titleH = ceil(titleFont.ascender - titleFont.descender)
            let subH = showSubtitle ? ceil(subFont.ascender - subFont.descender) + 4 : 0
            let spacing = iconSize * 0.34
            let block = iconSize + spacing + titleH + subH
            let iconTop = r.midY - block / 2
            let iconCenter = NSPoint(x: r.midX, y: iconTop + iconSize / 2)
            let haloR = iconSize * (1.15 + 0.15 * l)
            if let halo = NSGradient(colors: [tone.withAlphaComponent(0.26 + 0.14 * l), tone.withAlphaComponent(0)]) {
                ctx.saveGState()
                shape.addClip()
                halo.draw(fromCenter: iconCenter, radius: 0, toCenter: iconCenter, radius: haloR, options: [])
                ctx.restoreGState()
            }

            // Rand: Haarlinie, im Hover in Tonfarbe, mit Tastatur gewählt kräftig.
            let inset: CGFloat = focused ? 1 : 0.5
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: radius - inset, yRadius: radius - inset)
            ring.lineWidth = focused ? 2 : 1
            (focused ? tone.withAlphaComponent(0.9) : fg.withAlphaComponent(0.07).blended(withFraction: l * 0.6, of: tone) ?? tone).setStroke()
            ring.stroke()

            // Symbol, im Hover etwas größer.
            let iconScale = 1 + 0.06 * l - 0.03 * p
            if let image = Self.symbol(tile.symbol, size: iconSize, color: tone.blended(withFraction: 0.15 * l, of: .white) ?? tone) {
                let s = image.size
                let fit = min(iconSize / s.height, iconSize * 1.35 / s.width) * iconScale
                let dw = s.width * fit, dh = s.height * fit
                image.draw(in: NSRect(x: iconCenter.x - dw / 2, y: iconCenter.y - dh / 2, width: dw, height: dh),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }

            // Titel und Untertitel.
            var y = iconTop + iconSize + spacing
            centered(tile.title, in: r, y: y, height: titleH,
                     attrs: [.font: titleFont, .foregroundColor: fg.withAlphaComponent(0.86 + 0.1 * l)])
            y += titleH + 4
            if showSubtitle {
                centered(tile.subtitle, in: r, y: y, height: subH,
                         attrs: [.font: subFont, .foregroundColor: fg.withAlphaComponent(0.45 + 0.1 * l)])
            }

            // Tastenkappe mit der Nummer oben links.
            if i < 9 {
                let cap = NSRect(x: r.minX + 12, y: r.minY + 12, width: 20, height: 20)
                let capPath = NSBezierPath(roundedRect: cap, xRadius: 5, yRadius: 5)
                fg.withAlphaComponent(0.05 + 0.04 * l).setFill()
                capPath.fill()
                capPath.lineWidth = 1
                fg.withAlphaComponent(0.12 + 0.08 * l).setStroke()
                capPath.stroke()
                // Ziffer optisch mittig: Grundlinie so, dass die Versalhöhe in der Kappe zentriert sitzt
                // (`centered` taugt hier nicht — es zieht 20 pt Rand von der Breite ab, bei 20 pt Kappe bleibt nichts).
                let digit = "\(i + 1)" as NSString
                let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg.withAlphaComponent(0.5 + 0.3 * l)]
                let width = digit.size(withAttributes: attrs).width
                let baseline = cap.midY + font.capHeight / 2
                digit.draw(at: NSPoint(x: cap.midX - width / 2, y: baseline - font.ascender), withAttributes: attrs)
            }
            ctx.restoreGState()
            r = .zero
        }

        if showsFooter, let last = rects.last {
            let hint = "1–\(min(9, tiles.count)) oder Klick  ·  ⌘T nochmal = Terminal  ·  esc schließt"
            let y = min(bounds.maxY - Self.margin - 14, last.maxY + 8)
            centered(hint, in: bounds, y: y, height: 14,
                     attrs: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: fg.withAlphaComponent(0.28)])
        }
    }

    private func centered(_ text: String, in rect: NSRect, y: CGFloat, height: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let size = (text as NSString).size(withAttributes: attrs)
        let w = min(size.width, rect.width - 20)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        var attrs = attrs
        attrs[.paragraphStyle] = style
        (text as NSString).draw(with: NSRect(x: rect.midX - w / 2, y: y, width: w, height: height),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }

    private static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let desc = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: desc, size: size) ?? base
    }

    private static var symbolCache: [String: NSImage] = [:]

    private static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)|\(Int(size))|\(color.description)"
        if let hit = symbolCache[key] { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        let image = base.withSymbolConfiguration(config)
        if symbolCache.count > 96 { symbolCache.removeAll() }
        symbolCache[key] = image
        return image
    }

    // MARK: Maus

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressed = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, pressed == index(at: convert(event.locationInWindow, from: nil)) else { return }
        selected = pressed
        pick(pressed)
    }

    // MARK: Tastatur

    override func becomeFirstResponder() -> Bool { animate(); return true }
    override func resignFirstResponder() -> Bool { animate(); return true }

    override func keyDown(with event: NSEvent) {
        let n = tiles.count
        guard n > 0, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return super.keyDown(with: event) }
        hovered = nil
        switch event.keyCode {
        case 123: selected = (selected - 1 + n) % n                      // ←
        case 124: selected = (selected + 1) % n                          // →
        case 126: if selected - columns >= 0 { selected -= columns }     // ↑
        case 125: selected = min(selected + columns, n - 1)              // ↓
        case 36, 76, 49: pick(selected)                                  // ⏎, Enter, Leertaste
        case 53: onCancel?()                                             // esc
        default:
            if let chars = event.charactersIgnoringModifiers, let k = Int(chars), (1...min(9, n)).contains(k) {
                selected = k - 1
                pick(k - 1)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func pick(_ i: Int) {
        guard tiles.indices.contains(i) else { return }
        onPick?(tiles[i])
    }
}
