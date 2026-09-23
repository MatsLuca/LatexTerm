import AppKit

/// Reiterleiste eines Platzes mit mehreren Kacheln (Kachel-Layout Stufe 2, 23.09.2026). Liegt oben im
/// Platz über der vorderen Kachel, zeichnet die Reiter selbst (keine Subviews, kein Layout-Zustand)
/// und meldet Klicks an die Split-View: Reiter = nach vorn holen und fokussieren, × = Kachel schließen.
/// Welche Kacheln hier liegen und welche vorn ist, kommt aus dem Layout-Baum (`LayoutTabBar`).
final class PaneTabBarView: NSView, NSViewToolTipOwner {
    struct Tab: Equatable {
        var id: String
        var title: String
        var accent: NSColor
        var front: Bool
        /// Vorne und hat den Tastaturfokus.
        var focused: Bool
    }

    var tabs: [Tab] = [] {
        didSet { if tabs != oldValue { rebuildToolTips(); needsDisplay = true } }
    }
    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    private static let font = AppFonts.mono(size: 11, weight: .semibold)
    private static let tabHeight: CGFloat = 22
    private static let maxTabWidth: CGFloat = 220
    private static let spacing: CGFloat = 4
    /// Luft zwischen Reiter und Kachel darunter.
    private static let bottomInset: CGFloat = 4
    private static let closeSize: CGFloat = 14

    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var hoveredClose = false { didSet { if hoveredClose != oldValue { needsDisplay = true } } }
    private var pressed: (index: Int, onClose: Bool)?
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
    }

    // MARK: Geometrie

    /// Rahmen der Reiter: gleich breit, höchstens `maxTabWidth`, zusammen nie breiter als die Leiste.
    private func tabRects() -> [NSRect] {
        guard !tabs.isEmpty else { return [] }
        let n = CGFloat(tabs.count)
        let width = max(0, min(Self.maxTabWidth, (bounds.width - Self.spacing * (n - 1)) / n)).rounded(.down)
        let y = max(0, bounds.height - Self.bottomInset - Self.tabHeight)
        return tabs.indices.map { i in
            NSRect(x: CGFloat(i) * (width + Self.spacing), y: y, width: width, height: min(Self.tabHeight, bounds.height))
        }
    }

    private func closeRect(in tab: NSRect) -> NSRect {
        NSRect(x: tab.maxX - Self.closeSize - 5, y: tab.midY - Self.closeSize / 2, width: Self.closeSize, height: Self.closeSize)
    }

    /// × nur auf dem Reiter unter der Maus und nur, wenn der Reiter breit genug ist.
    private func showsClose(_ index: Int, _ rect: NSRect) -> Bool { hovered == index && rect.width >= 70 }

    private func hit(_ point: NSPoint) -> (index: Int, onClose: Bool)? {
        for (i, rect) in tabRects().enumerated() where rect.contains(point) {
            return (i, showsClose(i, rect) && closeRect(in: rect).insetBy(dx: -3, dy: -3).contains(point))
        }
        return nil
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeStore.shared.theme
        for (i, rect) in tabRects().enumerated() {
            let tab = tabs[i]
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            if tab.front {
                theme.background.withAlphaComponent(1).setFill()
                path.fill()
                tab.accent.withAlphaComponent(tab.focused ? 0.85 : 0.5).setStroke()
                path.lineWidth = tab.focused ? 1.5 : 1
                path.stroke()
            } else if hovered == i {
                theme.foreground.withAlphaComponent(0.08).setFill()
                path.fill()
            }

            // Punkt in Kachelfarbe, dann der Titel (abgeschnitten), rechts ggf. ×.
            let dot = NSRect(x: rect.minX + 8, y: rect.midY - 4, width: 8, height: 8)
            tab.accent.withAlphaComponent(tab.front ? 1 : 0.55).setFill()
            NSBezierPath(ovalIn: dot).fill()

            let close = showsClose(i, rect)
            let textX = dot.maxX + 6
            let textRight = close ? closeRect(in: rect).minX - 4 : rect.maxX - 8
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.font,
                .foregroundColor: theme.foreground.withAlphaComponent(tab.front ? 0.95 : 0.55),
                .paragraphStyle: style,
            ]
            let lineHeight = ceil(Self.font.ascender - Self.font.descender)
            let textRect = NSRect(x: textX, y: rect.midY - lineHeight / 2, width: max(0, textRight - textX), height: lineHeight)
            (tab.title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: attributes)

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
        pressed = hit(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
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
        return tabs.indices.contains(index) ? tabs[index].title : ""
    }
}
