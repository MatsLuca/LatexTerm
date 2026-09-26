import AppKit

/// Brett-Leiste oben links in der Titelleiste (23.09.2026), Stil „Linie“ wie Chips und Reiter: Name ohne Fläche und
/// Rand, vorderes Brett heller mit 2-pt-Strich in der Akzentfarbe, Hover = leise Fläche, × beim Hover rechts, dahinter
/// „+“. Verdeckte Bretter tragen rechts das Abzeichen ihrer wichtigsten Kachel (wartet › arbeitet › Ergebnis › neu).
/// Zeichnet selbst; Klicks meldet sie an `BoardHostView`. Scheibe 2 (24.09.): Doppelklick = umbenennen (Inline-Feld,
/// ⏎/Esc, leer = automatischer Name), Ziehen = umsortieren (Einfügemarke), bei Enge kürzen, zuletzt nur Nummern.
final class BoardStripView: NSView, NSViewToolTipOwner, NSTextFieldDelegate {
    struct Item: Equatable {
        var id: ObjectIdentifier
        var name: String
        var active: Bool
        var badge: PaneTabBarView.Badge?
        /// KI-Name (26.09.) am vorderen Brett: Punkt wandert durch den Strich, dann pulsiert er am Ende, solange gefragt wird.
        var naming: Naming? = nil
    }

    enum Naming: Equatable {
        case waiting(since: Date, duration: TimeInterval)
        case asking(since: Date)
    }

    static let height: CGFloat = 30
    private static let itemHeight: CGFloat = 22
    private static let font = AppFonts.mono(size: 11, weight: .medium)
    private static let padding: CGFloat = 8
    private static let spacing: CGFloat = 2
    private static let maxNameWidth: CGFloat = 180
    private static let badgeSize: CGFloat = 6
    private static let closeSize: CGFloat = 14
    private static let plusWidth: CGFloat = 22
    /// Luft links zur Ampel.
    private static let leadingInset: CGFloat = 10

    var items: [Item] = [] {
        didSet {
            guard items != oldValue else { return }
            // Neuer Name (KI oder Mats): kurz einblenden statt springen.
            for item in items {
                if let old = oldValue.first(where: { $0.id == item.id }), old.name != item.name { renamedAt[item.id] = Date() }
            }
            rebuildToolTips(); needsDisplay = true
        }
    }
    private var renamedAt: [ObjectIdentifier: Date] = [:]
    private static let fadeDuration: TimeInterval = 0.6
    var onSelect: ((ObjectIdentifier) -> Void)?
    var onClose: ((ObjectIdentifier) -> Void)?
    var onAdd: (() -> Void)?
    var onRename: ((ObjectIdentifier, String) -> Void)?
    var onMove: ((ObjectIdentifier, Int) -> Void)?
    /// Umbenennen beendet (⏎, Esc, Klick daneben) — die Tastatur gehört wieder dem Brett.
    var onEditingEnded: (() -> Void)?
    /// Platz, den die Leiste höchstens belegen darf (setzt `BoardHostView` aus der Fensterbreite).
    var maxWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if maxWidth != oldValue { rebuildToolTips(); needsDisplay = true } }
    }

    private enum Target: Equatable { case item(Int), close(Int), plus }
    private var hovered: Target? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed: Target?
    private var pressPoint: NSPoint?
    /// Laufender Zug: welcher Eintrag, und vor welchem Eintrag er landen würde (0 … count).
    private var drag: (index: Int, gap: Int)? { didSet { needsDisplay = true } }
    private static let dragThreshold: CGFloat = 4
    private var editor: NSTextField?
    private var editingID: ObjectIdentifier?
    private var trackingArea: NSTrackingArea?
    private var themeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometrie

    private static func measure(_ string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// Rechts im Eintrag Platz fürs Abzeichen bzw. ×.
    private static let trailingSlot: CGFloat = closeSize + 4
    /// Rahmen je Eintrag außer dem Text.
    private static let itemChrome: CGFloat = padding + 4 + trailingSlot + 2
    /// Kürzer wird ein verdeckter Name nicht — darunter zeigt die Leiste Nummern.
    private static let minNameWidth: CGFloat = 44

    /// Beschriftung und Textbreite je Eintrag, passend zu `maxWidth` (einmal je Zeichnen/Klick gerechnet).
    private func fitted() -> [(label: String, width: CGFloat)] {
        guard !items.isEmpty else { return [] }
        let natural = items.map { Double(min(Self.maxNameWidth, Self.measure($0.name))) }
        let active = items.firstIndex { $0.active }
        let chrome = Double(Self.leadingInset + Self.plusWidth + 6) + Double(Self.spacing) * Double(items.count)
            + Double(Self.itemChrome) * Double(items.count)
        let available = Double(maxWidth) - chrome
        if let widths = BoardStripFit.names(natural: natural, active: active, available: available,
                                            minWidth: Double(Self.minNameWidth)) {
            return items.indices.map { (items[$0].name, CGFloat(widths[$0])) }
        }
        let numbers = items.indices.map { "\($0 + 1)" }
        let widths = BoardStripFit.numbers(natural: natural, numberWidths: numbers.map { Double(Self.measure($0)) },
                                           active: active, available: available, minWidth: Double(Self.minNameWidth))
        return items.indices.map { ($0 == active ? items[$0].name : numbers[$0], CGFloat(widths[$0])) }
    }

    private func itemRects() -> [NSRect] { itemRects(fitted()) }

    private func itemRects(_ fit: [(label: String, width: CGFloat)]) -> [NSRect] {
        var x = Self.leadingInset
        let y = ((Self.height - Self.itemHeight) / 2).rounded()
        return fit.map { entry in
            let width = entry.width + Self.itemChrome
            defer { x += width + Self.spacing }
            return NSRect(x: x, y: y, width: width, height: Self.itemHeight)
        }
    }

    private func plusRect() -> NSRect {
        let last = itemRects().last?.maxX ?? Self.leadingInset
        return NSRect(x: last + Self.spacing, y: ((Self.height - Self.itemHeight) / 2).rounded(),
                      width: Self.plusWidth, height: Self.itemHeight)
    }

    private func closeRect(in rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - Self.closeSize - 4, y: rect.midY - Self.closeSize / 2, width: Self.closeSize, height: Self.closeSize)
    }

    /// Breite, die die Leiste braucht (Einträge + „+“ + Luft).
    var fittingWidth: CGFloat { plusRect().maxX + 6 }

    private func target(at point: NSPoint) -> Target? {
        for (i, rect) in itemRects().enumerated() where rect.contains(point) {
            let showsClose = hovered == .item(i) || hovered == .close(i)
            if showsClose, closeRect(in: rect).insetBy(dx: -3, dy: -3).contains(point) { return .close(i) }
            return .item(i)
        }
        return plusRect().contains(point) ? .plus : nil
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeStore.shared.theme
        let accent = ThemeStore.shared.accentColor
        let fit = fitted()
        let rects = itemRects(fit)
        for (i, rect) in rects.enumerated() {
            let item = items[i]
            let hover = drag == nil && (hovered == .item(i) || hovered == .close(i))
            let editing = editingID == item.id
            if hover && !item.active {
                theme.foreground.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            if item.active {
                accent.setFill()
                let line = NSRect(x: rect.minX + 3, y: rect.maxY - 2, width: rect.width - 6, height: 2)
                NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1).fill()
                if let naming = item.naming { drawNamingDot(naming, on: line, accent: accent, theme: theme) }
            }
            let dragged = drag?.index == i
            let fade = renamedAt[item.id].map { CGFloat(min(1, Date().timeIntervalSince($0) / Self.fadeDuration)) } ?? 1
            let color = theme.foreground.withAlphaComponent((dragged ? 0.3 : item.active ? 0.92 : 0.5) * (0.15 + 0.85 * fade))
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: fit[i].label, attributes: [
                .font: Self.font, .foregroundColor: color, .paragraphStyle: style])
            let lineHeight = ceil(Self.font.ascender - Self.font.descender)
            let textRect = NSRect(x: rect.minX + Self.padding, y: rect.midY - lineHeight / 2,
                                  width: fit[i].width, height: lineHeight)
            if !editing { text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }

            let box = closeRect(in: rect)
            if hover {
                if hovered == .close(i) {
                    theme.foreground.withAlphaComponent(0.14).setFill()
                    NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                }
                let cross = NSBezierPath()
                let inset = box.insetBy(dx: 4, dy: 4)
                cross.move(to: NSPoint(x: inset.minX, y: inset.minY)); cross.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
                cross.move(to: NSPoint(x: inset.maxX, y: inset.minY)); cross.line(to: NSPoint(x: inset.minX, y: inset.maxY))
                cross.lineWidth = 1.3
                cross.lineCapStyle = .round
                theme.foreground.withAlphaComponent(0.7).setStroke()
                cross.stroke()
            } else if let badge = item.badge {
                drawBadge(badge, in: NSRect(x: box.midX - Self.badgeSize / 2, y: box.midY - Self.badgeSize / 2,
                                            width: Self.badgeSize, height: Self.badgeSize))
            }
        }

        // Einfügemarke beim Ziehen: 2-pt-Strich in der Akzentfarbe in der Lücke.
        if let drag, drag.gap != drag.index, drag.gap != drag.index + 1, !rects.isEmpty {
            let x = drag.gap < rects.count ? rects[drag.gap].minX - Self.spacing / 2 : rects[rects.count - 1].maxX + Self.spacing / 2
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: x - 1, y: rects[0].minY + 2, width: 2, height: rects[0].height - 4),
                         xRadius: 1, yRadius: 1).fill()
        }

        let plus = plusRect()
        if hovered == .plus {
            theme.foreground.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: plus, xRadius: 5, yRadius: 5).fill()
        }
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: plus.midX - 4.5, y: plus.midY)); bar.line(to: NSPoint(x: plus.midX + 4.5, y: plus.midY))
        bar.move(to: NSPoint(x: plus.midX, y: plus.midY - 4.5)); bar.line(to: NSPoint(x: plus.midX, y: plus.midY + 4.5))
        bar.lineWidth = 1.4
        bar.lineCapStyle = .round
        theme.foreground.withAlphaComponent(hovered == .plus ? 0.85 : 0.45).setStroke()
        bar.stroke()
    }

    /// Abzeichen: voller Punkt, „neu“ als Ring. Wartet/arbeitet pulsiert über den Zeichen-Takt (`pulseTimer`) —
    /// ein Brett, das wartet, soll auch in der Leiste auffallen.
    private func drawBadge(_ badge: PaneTabBarView.Badge, in rect: NSRect) {
        let path = NSBezierPath(ovalIn: rect)
        if case .news = badge {
            badge.color.withAlphaComponent(0.25).setFill(); path.fill()
            badge.color.setStroke(); path.lineWidth = 1.5; path.stroke()
        } else {
            let alpha = badge.pulse.map { _ in pulsePhase } ?? 1
            badge.color.withAlphaComponent(alpha).setFill()
            path.fill()
        }
    }

    /// Punkt im Strich des vorderen Bretts: wandert in `duration` von links nach rechts (Mats' Idee 26.09.), danach
    /// pulsiert er am rechten Ende, bis die Antwort da ist. Heller als der Strich, 5 pt.
    private func drawNamingDot(_ naming: Naming, on line: NSRect, accent: NSColor, theme: TerminalTheme) {
        let size: CGFloat = 5
        let progress: CGFloat
        var alpha: CGFloat = 1
        switch naming {
        case .waiting(let since, let duration):
            progress = CGFloat(min(1, max(0, Date().timeIntervalSince(since) / duration)))
        case .asking(let since):
            progress = 1
            let t = Date().timeIntervalSince(since).truncatingRemainder(dividingBy: 1.2) / 1.2
            alpha = CGFloat(0.35 + 0.65 * (0.5 + 0.5 * cos(2 * .pi * t)))
        }
        let x = line.minX + progress * (line.width - size)
        let dot = NSRect(x: x, y: line.midY - size / 2, width: size, height: size)
        (accent.blended(withFraction: 0.55, of: theme.foreground) ?? theme.foreground).withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    // MARK: Puls (wartet/arbeitet an verdeckten Brettern)

    private var pulseTimer: Timer?
    private var pulseStart = Date()
    private var pulsePhase: CGFloat {
        let period = items.contains { if case .attention = $0.badge { return true } else { return false } } ? 1.0 : 1.8
        let t = Date().timeIntervalSince(pulseStart).truncatingRemainder(dividingBy: period) / period
        return CGFloat(0.3 + 0.7 * (0.5 + 0.5 * cos(2 * .pi * t)))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulseTimer?.invalidate()
        guard window != nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            self.renamedAt = self.renamedAt.filter { now.timeIntervalSince($0.value) < Self.fadeDuration }
            guard self.items.contains(where: { $0.badge?.pulse != nil || $0.naming != nil }) || !self.renamedAt.isEmpty
            else { return }
            self.needsDisplay = true
        }
    }

    // MARK: Maus

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { hovered = target(at: convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { hovered = target(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = target(at: point)
        pressPoint = point
        if event.clickCount == 2, case .item(let i) = pressed, items.indices.contains(i) {
            pressed = nil
            beginRename(items[i].id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .item(let i) = pressed, let start = pressPoint, items.count > 1 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard drag != nil || hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
        let gap = itemRects().filter { $0.midX < point.x }.count
        drag = (i, gap)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; pressPoint = nil }
        if let finished = drag {
            drag = nil
            if items.indices.contains(finished.index) { onMove?(items[finished.index].id, finished.gap) }
            return
        }
        guard let pressed, pressed == target(at: convert(event.locationInWindow, from: nil)) else { return }
        switch pressed {
        case .item(let i) where items.indices.contains(i): onSelect?(items[i].id)
        case .close(let i) where items.indices.contains(i): onClose?(items[i].id)
        case .plus: onAdd?()
        default: break
        }
    }

    /// Nur Einträge und „+“ nehmen Klicks; die Luft dazwischen bleibt Fenster-Ziehfläche.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        if let editor, editor.frame.contains(local) { return super.hitTest(point) }
        return target(at: local) == nil ? nil : self
    }

    // MARK: Umbenennen

    /// Inline-Feld über dem Namen (Doppelklick, Menü „Brett umbenennen …“). ⏎ übernimmt, Esc bricht ab, leer =
    /// zurück zum automatischen Namen; Klick daneben übernimmt wie ⏎.
    func beginRename(_ id: ObjectIdentifier) {
        guard editor == nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let rect = itemRects()[index]
        let field = NSTextField(string: items[index].name)
        field.font = Self.font
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = ThemeStore.shared.theme.foreground.withAlphaComponent(0.1)
        field.textColor = ThemeStore.shared.theme.foreground
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        let lineHeight = ceil(Self.font.ascender - Self.font.descender) + 2
        field.frame = NSRect(x: rect.minX + Self.padding - 2, y: rect.midY - lineHeight / 2,
                             width: max(rect.width - Self.padding - Self.trailingSlot + 24, 120), height: lineHeight)
        addSubview(field)
        editor = field
        editingID = id
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    private var cancelRename = false

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename = true
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = editor, let id = editingID else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let cancelled = cancelRename
        cancelRename = false
        editor = nil
        editingID = nil
        field.delegate = nil
        field.removeFromSuperview()
        needsDisplay = true
        if !cancelled { onRename?(id, text) }
        onEditingEnded?()
    }

    // MARK: Tooltips

    private func rebuildToolTips() {
        removeAllToolTips()
        for (i, rect) in itemRects().enumerated() { addToolTip(rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1)) }
        addToolTip(plusRect(), owner: self, userData: UnsafeMutableRawPointer(bitPattern: 999))
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let data else { return "" }
        let index = Int(bitPattern: data)
        if index == 999 { return "Neues Brett (⇧⌘T)" }
        guard items.indices.contains(index - 1) else { return "" }
        return items[index - 1].name + (index <= 9 ? "  (⌃\(index))" : "")
    }
}
