import AppKit

/// Ziehbarer Steg zwischen zwei Kacheln (Kachel-Layout, 23.09.2026). Liegt genau im Spalt, zeichnet
/// nichts außer beim Hover/Ziehen eine feine Linie und meldet der Split-View Anfang, Position und Ende
/// des Zugs — das Rechnen (Anteile, Mindestgrößen, Sperre für Agenten) macht `LayoutEdit.dragged`.
/// Doppelklick = beide Nachbarn gleich groß.
final class PaneDividerView: NSView {
    private(set) var divider: LayoutDivider
    /// Zug beginnt; die Split-View merkt sich den Ausgangsbaum.
    var onBegin: ((PaneDividerView) -> Void)?
    /// Position entlang der Achse, in Koordinaten der Split-View.
    var onMove: ((PaneDividerView, Double) -> Void)?
    var onEnd: ((PaneDividerView) -> Void)?
    var onDoubleClick: ((PaneDividerView) -> Void)?

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var dragging = false { didSet { if dragging != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    init(divider: LayoutDivider) {
        self.divider = divider
        super.init(frame: divider.rect)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    /// Sonst zöge ein Klick in den Spalt das Fenster (`isMovableByWindowBackground`).
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Neue Geometrie nach einem Relayout; Struktur (Pfad, Index) bleibt beim Ziehen gleich.
    func update(_ divider: LayoutDivider) {
        self.divider = divider
        if frame != divider.rect { frame = divider.rect }
        window?.invalidateCursorRects(for: self)
    }

    private var cursor: NSCursor { divider.axis == .row ? .resizeLeftRight : .resizeUpDown }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(self); return }
        dragging = true
        onBegin?(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let host = superview else { return }
        let point = host.convert(event.locationInWindow, from: nil)
        onMove?(self, Double(divider.axis == .row ? point.x : point.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEnd?(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || dragging else { return }
        let color = ThemeStore.shared.theme.foreground.withAlphaComponent(dragging ? 0.45 : 0.25)
        color.setFill()
        let line: NSRect
        switch divider.axis {
        case .row: line = NSRect(x: bounds.midX - 1, y: bounds.minY + 6, width: 2, height: max(0, bounds.height - 12))
        case .column: line = NSRect(x: bounds.minX + 6, y: bounds.midY - 1, width: max(0, bounds.width - 12), height: 2)
        }
        NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1).fill()
    }
}
