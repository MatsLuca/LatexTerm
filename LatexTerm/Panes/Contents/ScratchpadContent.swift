import AppKit

/// Erste App-Kachel (Kachel-Protokoll, Schritt 6): eine Malfläche. Ziehen malt in der
/// Vordergrundfarbe des Themes, ⌘Z nimmt den letzten Strich weg, ⌘⌫ oder `latexterm send
/// --pane N clear` leert. Flüchtig — nach ⌥⌘R kommt die Kachel nicht wieder.
final class ScratchpadContent: PaneContent {
    static let kind = "scratchpad"
    static let displayName = "Scratchpad"

    weak var delegate: PaneContentDelegate?
    private let canvas = ScratchpadCanvas()

    init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, kind: Self.kind)
    }

    var view: NSView { canvas }
    var title: String { "Scratchpad" }

    func applyTheme(_ theme: TerminalTheme) {
        canvas.paper = theme.background.withAlphaComponent(1)
        canvas.ink = theme.foreground.withAlphaComponent(1)
    }

    func receive(_ text: String) -> Bool {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "clear": canvas.clear(); return true
        case "undo": canvas.undo(); return true
        default: return false
        }
    }
}

/// Die Malfläche selbst: Striche als Punktlisten, gezeichnet als Bézier-Pfade mit runden Enden.
final class ScratchpadCanvas: NSView {
    var paper: NSColor = .black { didSet { needsDisplay = true } }
    var ink: NSColor = .white { didSet { needsDisplay = true } }

    private var strokes: [NSBezierPath] = []
    private var current: NSBezierPath?
    private static let lineWidth: CGFloat = 2.5

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Sonst zöge Malen das Fenster (`isMovableByWindowBackground`).
    override var mouseDownCanMoveWindow: Bool { false }

    func clear() {
        strokes.removeAll(); current = nil
        needsDisplay = true
    }

    func undo() {
        guard !strokes.isEmpty else { NSSound.beep(); return }
        strokes.removeLast()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let path = NSBezierPath()
        path.lineWidth = Self.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let p = convert(event.locationInWindow, from: nil)
        path.move(to: p)
        path.line(to: p)   // ein Klick ohne Ziehen hinterlässt einen Punkt
        current = path
        setNeedsDisplay(dirtyRect(around: p, p))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let path = current else { return }
        let last = path.currentPoint
        let p = convert(event.locationInWindow, from: nil)
        path.line(to: p)
        setNeedsDisplay(dirtyRect(around: last, p))
    }

    override func mouseUp(with event: NSEvent) {
        guard let path = current else { return }
        strokes.append(path)
        current = nil
    }

    /// ⌘Z: letzter Strich weg · ⌘⌫: alles leeren. Kachel-Kürzel (⌘W …) gehen an der Fläche vorbei
    /// zur Hülle.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        if event.charactersIgnoringModifiers == "z" { undo(); return true }
        if event.keyCode == 51 { clear(); return true }   // ⌫
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        paper.setFill()
        dirtyRect.fill()
        ink.setStroke()
        for path in strokes where path.bounds.insetBy(dx: -Self.lineWidth, dy: -Self.lineWidth).intersects(dirtyRect) {
            path.stroke()
        }
        current?.stroke()
    }

    private func dirtyRect(around a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .insetBy(dx: -Self.lineWidth * 2, dy: -Self.lineWidth * 2)
    }
}
