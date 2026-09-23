import AppKit

/// Bildansicht der Vorschau: eingepasst und zentriert, nie über 1:1 (ein Bildpixel = ein Bildschirmpixel)
/// vergrößert, solange „eingepasst“ gilt. Doppelklick = 1:1 an der Klickstelle bzw. zurück, Ziehen verschiebt,
/// Pinch zoomt frei, ⌥-Ziehen markiert einen Bereich (für die Übergabe an eine Session).
final class ImagePreviewView: NSScrollView {
    let canvas = ImageCanvas()
    private(set) var isFitted = true
    private(set) var pixelSize = NSSize.zero
    private(set) var pointSize = NSSize.zero
    var onZoomChange: (() -> Void)?
    private var magnifyObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = CenteringClipView()
        documentView = canvas
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 0.02
        maxMagnification = 32
        drawsBackground = true
        canvas.onDoubleClick = { [weak self] point in self?.toggleZoom(at: point) }
        magnifyObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.isFitted = false
            self.canvas.needsDisplay = true
            self.onZoomChange?()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let magnifyObserver { NotificationCenter.default.removeObserver(magnifyObserver) }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    var hasImage: Bool { canvas.image != nil }

    func applyTheme(_ theme: TerminalTheme) {
        backgroundColor = theme.background.withAlphaComponent(1)
        canvas.checker = (theme.background.lightened(by: 0.07), theme.background.lightened(by: 0.12))
        canvas.needsDisplay = true
    }

    func clear() {
        canvas.image = nil
        canvas.marks = []
        canvas.pending = nil
        canvas.frame = .zero
    }

    /// Neues Bild; `keepView` = Zoom und Ausschnitt vom vorigen behalten (Neuladen nach Änderung).
    func show(_ image: NSImage, keepView: Bool, fit: Bool) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let bitmap = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        if let bitmap, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 {
            pixelSize = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
            pointSize = NSSize(width: CGFloat(bitmap.pixelsWide) / scale, height: CGFloat(bitmap.pixelsHigh) / scale)
        } else {
            // Vektor (SVG, PDF-Bild): natürliche Größe in Punkten.
            pointSize = image.size
            pixelSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        }
        let origin = contentView.bounds.origin
        let keep = keepView && hasImage && !isFitted
        canvas.image = image
        canvas.frame = NSRect(origin: .zero, size: pointSize)
        canvas.needsDisplay = true
        if keep {
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        } else if fit || !keepView {
            fitToView()
        }
    }

    /// Scale, bei der das Bild ganz sichtbar ist, höchstens 1:1.
    var fitScale: CGFloat {
        guard pointSize.width > 0, pointSize.height > 0 else { return 1 }
        let available = NSSize(width: max(bounds.width - 24, 40), height: max(bounds.height - 24, 40))
        return min(1, available.width / pointSize.width, available.height / pointSize.height)
    }

    func fitToView() {
        isFitted = true
        magnification = fitScale
        canvas.needsDisplay = true
        onZoomChange?()
    }

    func setZoom(_ value: CGFloat) {
        isFitted = false
        let center = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        setMagnification(min(max(value, minMagnification), maxMagnification), centeredAt: center)
        canvas.needsDisplay = true
        onZoomChange?()
    }

    private func toggleZoom(at point: NSPoint) {
        guard hasImage else { return }
        if isFitted {
            isFitted = false
            let target: CGFloat = fitScale < 0.999 ? 1 : 2
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                animator().setMagnification(target, centeredAt: point)
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                animator().magnification = fitScale
            }
            isFitted = true
        }
        canvas.needsDisplay = true
        onZoomChange?()
    }

    override func layout() {
        super.layout()
        if isFitted, hasImage { magnification = fitScale }
    }
}

/// Zentriert das Dokument, solange es kleiner als der sichtbare Bereich ist.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Zeichnet das Bild über einem dezenten Schachbrett (nur unter transparenten Stellen sichtbar), ab doppelter
/// Vergrößerung pixelgenau, darüber die markierten Bereiche (nummeriert) und den gerade gezogenen (gestrichelt).
final class ImageCanvas: NSView {
    var image: NSImage?
    var checker: (NSColor, NSColor) = (.darkGray, .gray)
    /// Gemerkte Bereiche in Anzeige-Punkten (oben links).
    var marks: [NSRect] = [] { didSet { needsDisplay = true } }
    var pending: NSRect? { didSet { needsDisplay = true } }
    var onDoubleClick: ((NSPoint) -> Void)?
    var onRegion: ((NSRect) -> Void)?
    /// ← / → (Ordner-Modus): -1 / +1; true = verbraucht.
    var onArrow: ((Int) -> Bool)?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let tile: CGFloat = 8
        let rect = bounds.intersection(dirtyRect)
        checker.0.setFill()
        rect.fill()
        checker.1.setFill()
        var y = floor(rect.minY / tile) * tile
        while y < rect.maxY {
            var x = floor(rect.minX / tile) * tile
            while x < rect.maxX {
                if (Int(x / tile) + Int(y / tile)) % 2 == 0 { NSRect(x: x, y: y, width: tile, height: tile).intersection(bounds).fill() }
                x += tile
            }
            y += tile
        }
        let magnification = enclosingScrollView?.magnification ?? 1
        NSGraphicsContext.current?.imageInterpolation = magnification >= 2 ? .none : .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawMarks(scale: magnification)
    }

    private func drawMarks(scale: CGFloat) {
        let accent = ThemeStore.shared.accentColor
        let line = 2 / max(scale, 0.05)
        for (index, rect) in marks.enumerated() {
            accent.withAlphaComponent(0.12).setFill()
            rect.fill()
            accent.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = line
            path.stroke()
            // Nummer wie in PDF/Web (`LineStyle.mark*`): 15-pt-Kästchen, Radius 3, links neben der Stelle; bildschirmfest.
            let k = 1 / max(scale, 0.05)
            let label = NSAttributedString(string: "\(index + 1)", attributes: [.font: LineStyle.markFont(size: 10 * k), .foregroundColor: NSColor.black])
            let side = LineStyle.markSize * k
            let width = max(side, label.size().width + 6 * k)
            let badge = NSRect(x: rect.minX - width - 4 * k, y: rect.minY, width: width, height: side)
            accent.setFill()
            NSBezierPath(roundedRect: badge, xRadius: 3 * k, yRadius: 3 * k).fill()
            let size = label.size()
            label.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        }
        if let pending {
            accent.withAlphaComponent(0.1).setFill()
            pending.fill()
            accent.setStroke()
            let path = NSBezierPath(rect: pending)
            path.lineWidth = line
            path.setLineDash([6 * line, 4 * line], count: 2, phase: 0)
            path.stroke()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: if onArrow?(-1) == true { return }
        case 124: if onArrow?(1) == true { return }
        default: break
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) { return trackRegion(from: event) }
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            return
        }
        guard let clip = enclosingScrollView?.contentView else { return }
        dragStart = (event.locationInWindow, clip.bounds.origin)
        NSCursor.closedHand.push()
    }

    /// ⌥-Ziehen: Bereich aufziehen (gestrichelt), beim Loslassen melden.
    private func trackRegion(from event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds)
            pending = rect
            if next.type == .leftMouseUp { break }
        }
        guard let rect = pending, rect.width > 4, rect.height > 4 else {
            pending = nil
            return
        }
        onRegion?(rect)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let scroll = enclosingScrollView else { return }
        let magnification = scroll.magnification
        let dx = (event.locationInWindow.x - dragStart.mouse.x) / magnification
        let dy = (event.locationInWindow.y - dragStart.mouse.y) / magnification
        let target = NSPoint(x: dragStart.origin.x - dx, y: dragStart.origin.y + dy)
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: target, size: scroll.contentView.bounds.size)).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}
