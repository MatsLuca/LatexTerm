import AppKit

/// Brett-Leiste oben links in der Titelleiste (23.09.2026), Stil „Linie“ wie Chips und Reiter: Name ohne Fläche und
/// Rand, vorderes Brett heller mit 2-pt-Strich in der Akzentfarbe, Hover = leise Fläche, × beim Hover rechts, dahinter
/// „+“. Verdeckte Bretter tragen rechts das Abzeichen ihrer wichtigsten Kachel (wartet › arbeitet › Ergebnis › neu).
/// Zeichnet selbst; Klicks meldet sie an `BoardHostView`.
final class BoardStripView: NSView, NSViewToolTipOwner {
    struct Item: Equatable {
        var id: ObjectIdentifier
        var name: String
        var active: Bool
        var badge: PaneTabBarView.Badge?
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
        didSet { if items != oldValue { rebuildToolTips(); needsDisplay = true } }
    }
    var onSelect: ((ObjectIdentifier) -> Void)?
    var onClose: ((ObjectIdentifier) -> Void)?
    var onAdd: (() -> Void)?

    private enum Target: Equatable { case item(Int), close(Int), plus }
    private var hovered: Target? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed: Target?
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

    private func label(for item: Item) -> String { item.name }

    private func textWidth(_ string: String) -> CGFloat {
        min(Self.maxNameWidth, (string as NSString).size(withAttributes: [.font: Self.font]).width.rounded(.up))
    }

    /// Rechts im Eintrag Platz fürs Abzeichen bzw. ×.
    private static let trailingSlot: CGFloat = closeSize + 4

    private func itemRects() -> [NSRect] {
        var x = Self.leadingInset
        let y = ((Self.height - Self.itemHeight) / 2).rounded()
        return items.map { item in
            let width = Self.padding + textWidth(label(for: item)) + 4 + Self.trailingSlot + 2
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
        for (i, rect) in itemRects().enumerated() {
            let item = items[i]
            let hover = hovered == .item(i) || hovered == .close(i)
            if hover && !item.active {
                theme.foreground.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            if item.active {
                accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 3, y: rect.maxY - 2, width: rect.width - 6, height: 2),
                             xRadius: 1, yRadius: 1).fill()
            }
            let color = theme.foreground.withAlphaComponent(item.active ? 0.92 : 0.5)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let text = NSAttributedString(string: label(for: item), attributes: [
                .font: Self.font, .foregroundColor: color, .paragraphStyle: style])
            let lineHeight = ceil(Self.font.ascender - Self.font.descender)
            let textRect = NSRect(x: rect.minX + Self.padding, y: rect.midY - lineHeight / 2,
                                  width: textWidth(label(for: item)), height: lineHeight)
            text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

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
            guard let self, self.items.contains(where: { $0.badge?.pulse != nil }) else { return }
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
        pressed = target(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
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
        return target(at: local) == nil ? nil : self
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
