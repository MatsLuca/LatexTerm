import AppKit

/// Anzeige während Mats eine Kachel zieht (Kachel-Layout Stufe 2, Scheibe B): der Platz, an dem sie
/// landen wird, genau so, wie das Layout ihn nach dem Loslassen rechnet (die Split-View legt dafür das
/// Ergebnis schon an), die Einfügemarke in einer Reiterleiste, die Quelle abgeblendet und ein Schildchen
/// mit dem Titel am Mauszeiger. Liegt über allen Kacheln und lässt jeden Klick durch — die Maus gehört
/// während des Zugs der Ereignisschleife der Split-View.
final class PaneDropOverlayView: NSView {
    /// Titel und Farbe der gezogenen Kachel (Schildchen am Mauszeiger).
    var title = "" { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    /// Mausposition (eigene Koordinaten).
    var cursor: NSPoint = .zero { didSet { if cursor != oldValue { needsDisplay = true } } }
    /// Wo die Kachel gerade steht (sichtbar) — abgeblendet.
    var source: NSRect? { didSet { if source != oldValue { needsDisplay = true } } }
    /// Wo sie landen wird; nil = hier kein Ziel.
    var preview: NSRect? { didSet { if preview != oldValue { needsDisplay = true } } }
    /// Einfügemarke in einer Reiterleiste.
    var caret: NSRect? { didSet { if caret != oldValue { needsDisplay = true } } }
    /// Kurzer Hinweis am Schildchen, warum hier nichts geht („zu eng“).
    var note: String? { didSet { if note != oldValue { needsDisplay = true } } }

    private static let font = AppFonts.mono(size: 11, weight: .semibold)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let theme = ThemeStore.shared.theme

        if let source {
            theme.background.withAlphaComponent(0.55).setFill()
            let path = NSBezierPath(roundedRect: source, xRadius: 8, yRadius: 8)
            path.fill()
            let dashed = NSBezierPath(roundedRect: source.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            dashed.lineWidth = 1.5
            dashed.setLineDash([6, 4], count: 2, phase: 0)
            accent.withAlphaComponent(0.5).setStroke()
            dashed.stroke()
        }

        if let preview {
            let path = NSBezierPath(roundedRect: preview.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            accent.withAlphaComponent(0.18).setFill()
            path.fill()
            path.lineWidth = 2
            accent.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }

        if let caret {
            accent.setFill()
            NSBezierPath(roundedRect: caret, xRadius: 1.5, yRadius: 1.5).fill()
        }

        drawTag(theme: theme)
    }

    /// Schildchen rechts unter dem Mauszeiger: Punkt in Kachelfarbe + Titel (+ Hinweis), am Fensterrand
    /// nach innen geklappt, damit es sichtbar bleibt.
    private func drawTag(theme: TerminalTheme) {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: Self.font, .foregroundColor: theme.foreground.withAlphaComponent(0.95)])
        if let note {
            text.append(NSAttributedString(string: "  · \(note)", attributes: [
                .font: Self.font, .foregroundColor: theme.foreground.withAlphaComponent(0.5)]))
        }
        let textWidth = min(260, ceil(text.size().width))
        let height: CGFloat = 22
        let width = 8 + 8 + 6 + textWidth + 10
        var origin = NSPoint(x: cursor.x + 14, y: cursor.y + 12)
        if origin.x + width > bounds.maxX - 4 { origin.x = cursor.x - 14 - width }
        if origin.y + height > bounds.maxY - 4 { origin.y = cursor.y - 12 - height }
        let box = NSRect(x: origin.x, y: origin.y, width: width, height: height)

        // Schwebe-Grund ohne Rand, 6-pt-Punkt (Stil „Linie“).
        let path = NSBezierPath(roundedRect: box, xRadius: LineStyle.hoverRadius, yRadius: LineStyle.hoverRadius)
        theme.background.withAlphaComponent(0.96).setFill()
        path.fill()

        let d = LineStyle.dotSize
        accent.withAlphaComponent(note == nil ? 1 : 0.5).setFill()
        NSBezierPath(ovalIn: NSRect(x: box.minX + 9, y: box.midY - d / 2, width: d, height: d)).fill()

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
        let lineHeight = ceil(Self.font.ascender - Self.font.descender)
        text.draw(with: NSRect(x: box.minX + 22, y: box.midY - lineHeight / 2, width: textWidth, height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
