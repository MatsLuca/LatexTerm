import AppKit

/// Umschalter im Stil „Linie“ (UI-Inventar B2): Reiter ohne Kapsel — gewählter Eintrag = heller Text + 2-pt-Strich
/// in Akzentfarbe, Hover = leise Fläche. Ersetzt `NSSegmentedControl` (Home: Bereich, Agent). Zeichnet selbst,
/// keine Subviews; die API folgt dem Segmented Control, damit Aufrufer kaum umbauen.
final class LineTabsView: NSView, NSViewToolTipOwner {
    struct Item: Equatable {
        var title: String
        /// Zahl hinter dem Titel mit Punkt davor (z. B. fällige Aufgaben); nil = keine.
        var count: Int? = nil
        var countTone: Tone = .due
        var enabled = true
        var tooltip: String? = nil
    }

    var items: [Item] { didSet { if items != oldValue { invalidateIntrinsicContentSize(); rebuildToolTips(); needsDisplay = true } } }
    var selectedSegment: Int { didSet { if selectedSegment != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    /// Akzent des Strichs; nil = globale Akzentfarbe.
    var accent: NSColor? { didSet { needsDisplay = true } }
    var font: NSFont = LineStyle.font() { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Nutzer hat einen anderen Eintrag gewählt (nicht bei programmatischem Setzen).
    var onChange: ((Int) -> Void)?

    private static let spacing: CGFloat = 14
    private static let padding: CGFloat = 5
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed: Int?
    private var themeObserver: NSObjectProtocol?

    init(titles: [String]) {
        items = titles.map { Item(title: $0) }
        selectedSegment = 0
        super.init(frame: .zero)
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
        setAccessibilityRole(.radioGroup)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setLabel(_ title: String, forSegment i: Int) { guard items.indices.contains(i) else { return }; items[i].title = title }
    func setCount(_ count: Int?, forSegment i: Int) { guard items.indices.contains(i) else { return }; items[i].count = count }
    func setToolTip(_ tip: String?, forSegment i: Int) { guard items.indices.contains(i) else { return }; items[i].tooltip = tip }
    func setEnabled(_ on: Bool, forSegment i: Int) { guard items.indices.contains(i) else { return }; items[i].enabled = on }

    // MARK: Geometrie

    private func countText(_ item: Item) -> String? { item.count.map { "\($0)" } }

    private func width(of item: Item) -> CGFloat {
        var w = Self.padding * 2 + textWidth(item.title, font)
        if let c = countText(item) { w += 6 + LineStyle.dotSize + 4 + textWidth(c, countFont) }
        return w
    }

    private var countFont: NSFont { AppFonts.mono(size: font.pointSize, weight: .bold) }

    private func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: f]).width.rounded(.up)
    }

    private func rects() -> [NSRect] {
        var x: CGFloat = 0
        return items.map { item in
            let w = width(of: item)
            defer { x += w + Self.spacing - Self.padding * 2 }
            return NSRect(x: x, y: 0, width: w, height: bounds.height)
        }
    }

    override var intrinsicContentSize: NSSize {
        let total = items.map(width(of:)).reduce(0, +) + CGFloat(max(0, items.count - 1)) * (Self.spacing - Self.padding * 2)
        return NSSize(width: total, height: LineStyle.tabHeight)
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        let fg = LineStyle.fg
        let accent = self.accent ?? ThemeStore.shared.accentColor
        for (i, rect) in rects().enumerated() {
            let item = items[i]
            let usable = isEnabled && item.enabled
            let selected = i == selectedSegment
            if usable, hovered == i, !selected {
                fg.withAlphaComponent(LineStyle.hover).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 1), xRadius: LineStyle.hoverRadius, yRadius: LineStyle.hoverRadius).fill()
            }
            let alpha: CGFloat = !usable ? LineStyle.faint : (selected ? LineStyle.textFocused : (hovered == i ? 0.75 : LineStyle.text))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg.withAlphaComponent(alpha)]
            let size = (item.title as NSString).size(withAttributes: attrs)
            var x = rect.minX + Self.padding
            let y = rect.midY - size.height / 2 + 0.5
            (item.title as NSString).draw(at: NSPoint(x: x, y: y.rounded()), withAttributes: attrs)
            x += size.width.rounded(.up)
            if let c = countText(item) {
                x += 6
                let dot = NSRect(x: x, y: (rect.midY - LineStyle.dotSize / 2).rounded(), width: LineStyle.dotSize, height: LineStyle.dotSize)
                item.countTone.color.withAlphaComponent(usable ? 1 : 0.4).setFill()
                NSBezierPath(ovalIn: dot).fill()
                x = dot.maxX + 4
                let cAttrs: [NSAttributedString.Key: Any] = [.font: countFont, .foregroundColor: fg.withAlphaComponent(selected ? LineStyle.numberFocused : LineStyle.number + 0.1)]
                let cs = (c as NSString).size(withAttributes: cAttrs)
                (c as NSString).draw(at: NSPoint(x: x, y: (rect.midY - cs.height / 2 + 0.5).rounded()), withAttributes: cAttrs)
            }
            if selected {
                accent.withAlphaComponent(usable ? 1 : 0.4).setFill()
                let line = NSRect(x: rect.minX + LineStyle.underlineInset, y: rect.maxY - LineStyle.underline,
                                  width: rect.width - LineStyle.underlineInset * 2, height: LineStyle.underline)
                NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    // MARK: Maus

    private func index(at point: NSPoint) -> Int? {
        rects().firstIndex { $0.insetBy(dx: -Self.spacing / 2 + Self.padding, dy: 0).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { hovered = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard isEnabled, let i = pressed, i == index(at: convert(event.locationInWindow, from: nil)),
              items[i].enabled, i != selectedSegment else { return }
        selectedSegment = i
        onChange?(i)
    }

    // MARK: Tooltips

    private func rebuildToolTips() {
        removeAllToolTips()
        for (i, rect) in rects().enumerated() where items[i].tooltip != nil {
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildToolTips()
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        index(at: point).flatMap { items[$0].tooltip } ?? ""
    }
}

/// Knopf im Stil „Linie“ (UI-Inventar B1): Symbol/Text in Mono, Hover = leise Fläche, ohne Rand und Bezel.
/// Rechts optional ein gedimmter Hinweis (Tastenkürzel).
final class LineButton: NSView {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var hint: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var font: NSFont = LineStyle.font() { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Hauptknopf: Text in dieser Farbe + Strich unten (nie gefüllt); nil = normaler Knopf.
    var accent: NSColor? { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    /// Wie die Reiter (5), damit Knopftext und Reitertext bündig untereinander stehen.
    private static let padding: CGFloat = 5
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }

    init(title: String, hint: String? = nil) {
        self.title = title
        self.hint = hint
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        var w = Self.padding * 2 + (title as NSString).size(withAttributes: [.font: font]).width
        if let hint { w += 12 + (hint as NSString).size(withAttributes: [.font: font]).width }
        return NSSize(width: w.rounded(.up), height: LineStyle.tabHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fg = LineStyle.fg
        if hovered || pressed {
            fg.withAlphaComponent(pressed ? LineStyle.hover * 2 : LineStyle.hover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: LineStyle.hoverRadius, yRadius: LineStyle.hoverRadius).fill()
        }
        let color = accent ?? fg.withAlphaComponent(hovered ? LineStyle.textFocused : 0.75)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: Self.padding, y: (bounds.midY - size.height / 2 + 0.5).rounded()), withAttributes: attrs)
        if let accent {
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: LineStyle.underlineInset, y: bounds.maxY - LineStyle.underline,
                                             width: bounds.width - LineStyle.underlineInset * 2, height: LineStyle.underline),
                         xRadius: 1, yRadius: 1).fill()
        }
        if let hint {
            let hAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg.withAlphaComponent(LineStyle.number)]
            let hs = (hint as NSString).size(withAttributes: hAttrs)
            (hint as NSString).draw(at: NSPoint(x: bounds.maxX - Self.padding - hs.width, y: (bounds.midY - hs.height / 2 + 0.5).rounded()), withAttributes: hAttrs)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

extension LineStyle {
    /// Auswahl in senkrechten Listen (UI-Inventar B3): leise Fläche + 2-pt-Strich links in Tonfarbe — die Kante
    /// folgt der Leserichtung (waagerechte Leisten: unten, Listen: links). Unfokussiert nur halb so deutlich.
    static func drawRowSelection(in bounds: NSRect, tint: NSColor, emphasized: Bool, inset: CGFloat = 2) {
        let rect = bounds.insetBy(dx: inset, dy: 1)
        fg.withAlphaComponent(emphasized ? 0.10 : 0.05).setFill()
        NSBezierPath(roundedRect: rect, xRadius: hoverRadius, yRadius: hoverRadius).fill()
        let h = min(rect.height - 10, 22)
        let bar = NSRect(x: rect.minX + 1, y: rect.midY - h / 2, width: underline, height: h)
        tint.withAlphaComponent(emphasized ? 1 : 0.45).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }
}

/// Gezeichneter Status-Punkt (6 pt) statt eines „●“-Zeichens — Größe und Lage hängen nicht mehr an der Schrift.
/// `pulse` = halbe Periode in Sekunden (0,9 arbeitet, 0,5 wartet), nil = ruhig.
final class LineDotView: NSView {
    var color: NSColor? { didSet { layer?.backgroundColor = color?.cgColor; isHidden = color == nil } }
    var pulse: Double? { didSet { if pulse != oldValue { updatePulse() } } }
    var diameter: CGFloat = LineStyle.dotSize { didSet { invalidateIntrinsicContentSize(); layer?.cornerRadius = diameter / 2 } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = diameter / 2
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    private func updatePulse() {
        layer?.removeAnimation(forKey: "linePulse")
        guard let pulse, window != nil else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0
        a.toValue = 0.3
        a.duration = pulse
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(a, forKey: "linePulse")
    }
}

/// Abzeichen „Punkt · Text“ (UI-Inventar B6) statt getönter Kapsel: Punkt in Tonfarbe, Text gedimmt.
final class LineBadgeView: NSView {
    private let dot = LineDotView()
    private let label = NSTextField(labelWithString: "")

    init(text: String, color: NSColor, font: NSFont = LineStyle.font(11)) {
        super.init(frame: .zero)
        dot.color = color
        label.stringValue = text
        label.font = font
        label.textColor = LineStyle.fg.withAlphaComponent(0.7)
        label.lineBreakMode = .byTruncatingTail
        for v in [dot, label] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: LineStyle.dotSize),
            dot.heightAnchor.constraint(equalToConstant: LineStyle.dotSize),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension LineStyle {
    /// Schwebe-Grund (UI-Inventar B4, Mats 23.09.: „ja, so“): die einzige erlaubte Fläche — Leisten über fremdem Inhalt
    /// (PDF, Bild, Webseite, Skizze) brauchen einen Grund, sonst sind sie nicht lesbar. Kein Rand, kein Schatten.
    static func applyGround(to view: NSView, theme: TerminalTheme) {
        view.wantsLayer = true
        view.layer?.cornerRadius = groundRadius
        view.layer?.borderWidth = 0
        view.layer?.shadowOpacity = 0
        view.layer?.backgroundColor = theme.background.withAlphaComponent(groundAlpha).cgColor
    }
}

/// Kurzer Hinweis (LineToast): Tonfarbe des Punkts aus dem ersten Zeichen der Meldung.
enum LineToast {
    static func tone(for text: String) -> NSColor {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("⚠") || t.hasPrefix("✗") || t.lowercased().hasPrefix("fehler") { return Tone.error.color }
        if t.hasPrefix("✓") || t.hasPrefix("⬇") || t.hasPrefix("➤") { return Tone.running.color }
        if t.hasPrefix("↻") || t.hasPrefix("neu") { return Tone.start.color }
        return LineStyle.fg.withAlphaComponent(LineStyle.number)
    }
}

/// Zeilenauswahl im Stil „Linie“ für beliebige Listen (Seitenleiste, …): wie Home/⌘K.
final class LineRowView: NSTableRowView {
    var tint: NSColor?
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        LineStyle.drawRowSelection(in: bounds, tint: tint ?? ThemeStore.shared.accentColor, emphasized: isEmphasized)
    }
}

extension LineStyle {
    /// Fortschritt als 2-pt-Strich (UI-Inventar B7) zum Einbetten in Fließtext: Bahn fg 10 %, Füllung `color`,
    /// auf die Mitte der x-Höhe von `font` gesetzt.
    static func progressAttachment(fraction: Double, width: CGFloat, color: NSColor, font: NSFont) -> NSAttributedString {
        let height: CGFloat = 8
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let y = (rect.height - underline) / 2
            fg.withAlphaComponent(track).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: rect.width, height: underline), xRadius: 1, yRadius: 1).fill()
            let f = max(0, min(1, fraction))
            if f > 0 {
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: max(2, rect.width * f), height: underline), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.xHeight - height) / 2, width: width, height: height)
        return NSAttributedString(attachment: attachment)
    }
}

extension LineStyle {
    /// Nummer einer gemerkten Stelle (UI-Inventar B6) — PDF, Web (CSS in `WebSupport`) und Bild zeichnen dieselbe Form:
    /// 15 pt hoch, Radius 3, Mono 10 fett, schwarz auf Akzent, links neben der ersten Zeile.
    static let markSize: CGFloat = 15
    static func markFont(size: CGFloat = 10) -> NSFont { AppFonts.mono(size: size, weight: .bold) }
}

extension LineStyle {
    /// Karte über allem (UI-Inventar B8: ⌘K, Formel-Popover) — die zweite Ebene über dem Raster. Eine Form für beide:
    /// Radius 12, Rand fg 10 %, Schatten 45 %; Grund = Terminal-Grund leicht aufgehellt (oder vorgegeben).
    static let cardRadius: CGFloat = 12
    static func applyCard(to view: NSView, background: NSColor?) {
        let theme = ThemeStore.shared.theme
        view.wantsLayer = true
        view.layer?.cornerRadius = cardRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = theme.foreground.withAlphaComponent(0.10).cgColor
        view.layer?.backgroundColor = (background ?? theme.background.lightened(by: 0.05)).cgColor
        view.layer?.shadowColor = NSColor.black.cgColor
        view.layer?.shadowOpacity = 0.45
        view.layer?.shadowRadius = 24
        view.layer?.shadowOffset = CGSize(width: 0, height: -8)
    }
}
