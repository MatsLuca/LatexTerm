import AppKit

/// Reiterleiste eines Platzes mit mehreren Kacheln (Kachel-Layout Stufe 2, 23.09.2026). Liegt oben im
/// Platz über der vorderen Kachel, zeichnet die Reiter selbst (keine Subviews, kein Layout-Zustand)
/// und meldet Klicks an die Split-View: Reiter = nach vorn holen und fokussieren, × = Kachel schließen.
/// Ein Reiter lässt sich wegziehen (Scheibe B): ab ein paar Punkten Weg übernimmt die Split-View den Zug.
/// Verdeckte Reiter tragen ein Abzeichen (Scheibe C), wenn dahinter etwas passiert: Agent wartet (gelb, pulsiert
/// schnell), arbeitet (pulsiert ruhig), ist fertig/gescheitert (Tonfarbe) oder der Inhalt ist neu (Kachelfarbe).
/// Welche Kacheln hier liegen und welche vorn ist, kommt aus dem Layout-Baum (`LayoutTabBar`).
final class PaneTabBarView: NSView, NSViewToolTipOwner {
    /// Was hinter einem verdeckten Reiter los ist — die Farbe bringt die Split-View mit (Theme/Kachel).
    enum Badge: Equatable {
        case attention(NSColor)
        case working(NSColor)
        case outcome(NSColor)
        case news(NSColor)

        var color: NSColor {
            switch self { case .attention(let c), .working(let c), .outcome(let c), .news(let c): return c }
        }
        /// Pulsdauer (halbe Periode); nil = ruhig.
        var pulse: Double? {
            switch self { case .attention: return 0.5; case .working: return 0.9; default: return nil }
        }
    }

    struct Tab: Equatable {
        var id: String
        /// Kachelnummer in Lesereihenfolge (= ⌘n), gedimmt vor dem Titel.
        var number: Int?
        var title: String
        var accent: NSColor
        var front: Bool
        /// Vorne und hat den Tastaturfokus.
        var focused: Bool
        /// Abzeichen (nur verdeckte Reiter) und sein Text für den Tooltip.
        var badge: Badge? = nil
        var badgeText: String? = nil
    }

    var tabs: [Tab] = [] {
        didSet { if tabs != oldValue { rebuildToolTips(); layoutBadges(); needsDisplay = true } }
    }
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    /// Reiter wird gezogen: die Split-View führt den Zug bis zum Loslassen selbst (eigene Ereignisschleife)
    /// und kehrt erst danach zurück.
    var onDrag: ((String, NSEvent) -> Void)?

    private static let font = AppFonts.mono(size: 11, weight: .medium)
    private static let numberFont = AppFonts.mono(size: 11, weight: .bold)
    private static let tabHeight: CGFloat = 24
    private static let maxTabWidth: CGFloat = 220
    private static let spacing: CGFloat = 6
    /// Luft zwischen Reiter und Kachel darunter.
    private static let bottomInset: CGFloat = 4
    private static let closeSize: CGFloat = 14

    private var hovered: Int? { didSet { if hovered != oldValue { layoutBadges(); needsDisplay = true } } }
    /// Je Reiter ein Punkt rechts (verborgen ohne Abzeichen oder solange dort das × steht).
    private var badgeViews: [PaneTabBadgeView] = []
    private static let badgeSize: CGFloat = 6
    private var hoveredClose = false { didSet { if hoveredClose != oldValue { needsDisplay = true } } }
    private var pressed: (index: Int, onClose: Bool)?
    /// Wo gedrückt wurde (eigene Koordinaten) — ab `dragThreshold` Weg ist es ein Zug.
    private var pressedAt: NSPoint?
    private static let dragThreshold: CGFloat = 4
    private var trackingArea: NSTrackingArea?
    private var themeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    override var isFlipped: Bool { true }
    /// Sonst zöge ein Klick auf einen Reiter das Fenster (`isMovableByWindowBackground`).
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildToolTips()
        layoutBadges()
    }

    // MARK: Geometrie

    /// Innenabstand links/rechts, Punkt, Lücke Punkt–Text, Platz fürs Abzeichen rechts.
    private static let padding: CGFloat = 8
    private static let dotSize: CGFloat = 6
    private static let dotGap: CGFloat = 7

    /// Rahmen der Reiter (Richtung „Linie“, 23.09.): so breit wie ihr Text, höchstens `maxTabWidth`. Reicht die
    /// Leiste nicht, werden erst die breitesten gekürzt (gemeinsame Obergrenze), kurze behalten ihren Titel.
    private func tabRects() -> [NSRect] {
        guard !tabs.isEmpty else { return [] }
        let natural = tabs.map { min(Self.maxTabWidth, naturalWidth(of: $0)) }
        let available = max(0, bounds.width - Self.spacing * CGFloat(tabs.count - 1))
        var cap = Self.maxTabWidth
        if natural.reduce(0, +) > available {
            // Wasserstand: Obergrenze so, dass Σ min(w, cap) = available.
            var rest = available
            var open = natural.sorted()
            while let smallest = open.first, smallest * CGFloat(open.count) <= rest {
                rest -= smallest
                open.removeFirst()
            }
            cap = open.isEmpty ? Self.maxTabWidth : (rest / CGFloat(open.count)).rounded(.down)
        }
        let y = max(0, bounds.height - Self.bottomInset - Self.tabHeight)
        var x: CGFloat = 0
        return natural.map { width in
            let w = min(width, cap).rounded(.down)
            defer { x += w + Self.spacing }
            return NSRect(x: x, y: y, width: w, height: min(Self.tabHeight, bounds.height))
        }
    }

    private func label(for tab: Tab) -> NSMutableAttributedString {
        let theme = ThemeStore.shared.theme
        let text = NSMutableAttributedString()
        if let number = tab.number {
            text.append(NSAttributedString(string: "\(number) ", attributes: [
                .font: Self.numberFont, .foregroundColor: theme.foreground.withAlphaComponent(tab.front ? 0.6 : 0.3)]))
        }
        text.append(NSAttributedString(string: tab.title, attributes: [
            .font: Self.font, .foregroundColor: theme.foreground.withAlphaComponent(tab.front ? 0.95 : 0.5)]))
        return text
    }

    private func naturalWidth(of tab: Tab) -> CGFloat {
        let text = label(for: tab).size().width.rounded(.up)
        let badge: CGFloat = tab.badge == nil ? 0 : Self.badgeSize + 7
        return Self.padding + Self.dotSize + Self.dotGap + text + badge + Self.padding
    }

    /// Einfügestelle für einen gezogenen Reiter bei `point` (0 … Anzahl): vor dem ersten Reiter, dessen Mitte
    /// rechts davon liegt.
    func insertionIndex(at point: NSPoint) -> Int {
        let rects = tabRects()
        return rects.firstIndex { point.x < $0.midX } ?? rects.count
    }

    /// Einfügemarke (schmaler Balken, eigene Koordinaten) vor Reiter `index`, bzw. hinter dem letzten.
    func insertionCaret(for index: Int) -> NSRect? {
        let rects = tabRects()
        guard let first = rects.first else { return nil }
        let x: CGFloat
        if index <= 0 { x = first.minX + 1 }
        else if index >= rects.count { x = min(bounds.maxX - 2, rects[rects.count - 1].maxX + Self.spacing / 2) }
        else { x = rects[index].minX - Self.spacing / 2 }
        return NSRect(x: x - 1.5, y: first.minY - 2, width: 3, height: first.height + 4)
    }

    /// Punkt links im Reiter; beim Hover steht an seiner Stelle das ×.
    private func dotRect(in tab: NSRect) -> NSRect {
        NSRect(x: tab.minX + Self.padding, y: tab.midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize)
    }

    private func closeRect(in tab: NSRect) -> NSRect {
        let dot = dotRect(in: tab)
        return NSRect(x: dot.midX - Self.closeSize / 2, y: tab.midY - Self.closeSize / 2, width: Self.closeSize, height: Self.closeSize)
    }

    /// Platz des Abzeichens rechts im Reiter (dort, wo beim Hover das × erscheint).
    private func badgeRect(in tab: NSRect) -> NSRect {
        NSRect(x: tab.maxX - Self.badgeSize - Self.padding, y: tab.midY - Self.badgeSize / 2, width: Self.badgeSize, height: Self.badgeSize)
    }

    /// Abzeichen sichtbar: vorhanden und Reiter breit genug.
    private func showsBadge(_ index: Int, _ rect: NSRect) -> Bool {
        tabs.indices.contains(index) && tabs[index].badge != nil && rect.width >= 50
    }

    private func layoutBadges() {
        let rects = tabRects()
        while badgeViews.count < tabs.count { let view = PaneTabBadgeView(); addSubview(view); badgeViews.append(view) }
        while badgeViews.count > tabs.count { badgeViews.removeLast().removeFromSuperview() }
        for (i, view) in badgeViews.enumerated() {
            guard i < rects.count, showsBadge(i, rects[i]), let badge = tabs[i].badge else { view.isHidden = true; continue }
            view.frame = badgeRect(in: rects[i])
            view.apply(badge)
            view.isHidden = false
        }
    }

    /// × nur auf dem Reiter unter der Maus (anstelle des Punkts).
    private func showsClose(_ index: Int, _ rect: NSRect) -> Bool { hovered == index && rect.width >= 30 }

    private func hit(_ point: NSPoint) -> (index: Int, onClose: Bool)? {
        for (i, rect) in tabRects().enumerated() where rect.contains(point) {
            return (i, showsClose(i, rect) && closeRect(in: rect).insetBy(dx: -3, dy: -3).contains(point))
        }
        return nil
    }

    // MARK: Zeichnen

    /// Richtung „Linie“ (Mats, 23.09.): keine Flächen, keine Ränder. Vorderer Reiter = heller Text + Strich in
    /// Kachelfarbe unten (voll bei Fokus), alle stehen auf einer Haarlinie; Hover = leise Fläche.
    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeStore.shared.theme
        let rects = tabRects()
        if let first = rects.first {
            theme.foreground.withAlphaComponent(0.08).setFill()
            NSRect(x: 0, y: first.maxY - 1, width: bounds.width, height: 1).fill()
        }
        for (i, rect) in rects.enumerated() {
            let tab = tabs[i]
            if hovered == i && !tab.front {
                theme.foreground.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 2), xRadius: 5, yRadius: 5).fill()
            }
            if tab.front {
                tab.accent.withAlphaComponent(tab.focused ? 1 : 0.45).setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.minX + 2, y: rect.maxY - 2, width: rect.width - 4, height: 2),
                             xRadius: 1, yRadius: 1).fill()
            }

            let close = showsClose(i, rect)
            if !close {
                tab.accent.setFill()
                NSBezierPath(ovalIn: dotRect(in: rect)).fill()
            }

            let textX = dotRect(in: rect).maxX + Self.dotGap
            let textRight = showsBadge(i, rect) ? badgeRect(in: rect).minX - 7 : rect.maxX - Self.padding
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let text = label(for: tab)
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            let lineHeight = ceil(Self.font.ascender - Self.font.descender)
            let textRect = NSRect(x: textX, y: rect.midY - lineHeight / 2, width: max(0, textRight - textX), height: lineHeight)
            text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

            if close {
                let box = closeRect(in: rect)
                if hoveredClose {
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
            }
        }
    }

    // MARK: Maus

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func updateHover(_ event: NSEvent) {
        let hit = hit(convert(event.locationInWindow, from: nil))
        hovered = hit?.index
        hoveredClose = hit?.onClose ?? false
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; hoveredClose = false }

    /// Ausgelöst wird beim Loslassen über demselben Ziel — wie bei Knöpfen; Wegziehen bricht ab.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressed = hit(point)
        pressedAt = point
    }

    /// Reiter (nicht ×) ein Stück gezogen → Zug an die Split-View. Danach kommt kein mouseUp mehr hier an.
    override func mouseDragged(with event: NSEvent) {
        guard let pressed, !pressed.onClose, let start = pressedAt, tabs.indices.contains(pressed.index) else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
        let id = tabs[pressed.index].id
        self.pressed = nil
        pressedAt = nil
        // Die Leiste kann während des Zugs aus der Ansicht fallen (Umordnen) — solange am Leben halten.
        withExtendedLifetime(self) { onDrag?(id, event) }
        hovered = nil
        hoveredClose = false
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; pressedAt = nil }
        guard let pressed, let now = hit(convert(event.locationInWindow, from: nil)),
              now.index == pressed.index, now.onClose == pressed.onClose, tabs.indices.contains(now.index) else { return }
        let id = tabs[now.index].id
        if now.onClose { onClose?(id) } else { onSelect?(id) }
    }

    // MARK: Tooltips (voller Titel)

    private func rebuildToolTips() {
        removeAllToolTips()
        for (i, rect) in tabRects().enumerated() { addToolTip(rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1)) }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let data else { return "" }
        let index = Int(bitPattern: data) - 1
        guard tabs.indices.contains(index) else { return "" }
        return [tabs[index].title, tabs[index].badgeText].compactMap { $0 }.joined(separator: " — ")
    }
}

/// Punkt eines Reiter-Abzeichens; pulsiert bei wartendem bzw. arbeitendem Agenten. Nimmt keine Klicks.
private final class PaneTabBadgeView: NSView {
    private let dot = CALayer()
    private var current: PaneTabBarView.Badge?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    func apply(_ badge: PaneTabBarView.Badge) {
        guard badge != current else { return }
        let pulseChanged = badge.pulse != current?.pulse
        current = badge
        dot.backgroundColor = badge.color.cgColor
        // Neu: nur ein Ring in Kachelfarbe — leiser als ein Agent, der etwas will.
        if case .news = badge {
            dot.backgroundColor = badge.color.withAlphaComponent(0.25).cgColor
            dot.borderColor = badge.color.cgColor
            dot.borderWidth = 1.5
        } else {
            dot.borderWidth = 0
        }
        guard pulseChanged else { return }
        dot.removeAnimation(forKey: "badgePulse")
        guard let duration = badge.pulse else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = duration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.add(pulse, forKey: "badgePulse")
    }
}
