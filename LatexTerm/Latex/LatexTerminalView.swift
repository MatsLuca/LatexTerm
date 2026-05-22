import AppKit
import SwiftTerm

final class OverlayHost: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Hover-Tracking für den Formel-Vorschau-Modus. Liefert nur mouseMoved/Exited;
    /// Klicks/Selektion bleiben über hitTest==nil beim Terminal.
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingRef { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        trackingRef = t
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

final class LatexTerminalView: LocalProcessTerminalView {
    static let fontSizeKey = "LatexTerm.fontSize"
    static let defaultFontSize: CGFloat = 13
    static let minFontSize: CGFloat = 6
    static let maxFontSize: CGFloat = 48

    let overlay = OverlayHost()
    var onRangeChanged: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        notifyUpdateChanges = true
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        font = NSFont.monospacedSystemFont(ofSize: Self.storedFontSize(), weight: .regular)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onRangeChanged?()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onRangeChanged?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.subtracting(.shift) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let a = event.charactersIgnoringModifiers ?? ""
        let b = event.characters ?? ""
        if a == "+" || b == "+" || a == "=" || b == "=" {
            adjustFont(by: +1); return true
        }
        if a == "-" || b == "-" {
            adjustFont(by: -1); return true
        }
        if a == "0" || b == "0" {
            setFont(size: Self.defaultFontSize); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func cellSize() -> CGSize {
        return lineCellSize
    }

    private static func storedFontSize() -> CGFloat {
        let v = UserDefaults.standard.double(forKey: fontSizeKey)
        guard v > 0 else { return defaultFontSize }
        return CGFloat(min(max(v, Double(minFontSize)), Double(maxFontSize)))
    }

    private func adjustFont(by delta: CGFloat) {
        let new = max(Self.minFontSize, min(Self.maxFontSize, font.pointSize + delta))
        setFont(size: new)
    }

    private func setFont(size: CGFloat) {
        guard size != font.pointSize else { return }
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        UserDefaults.standard.set(Double(size), forKey: Self.fontSizeKey)
        onRangeChanged?()
    }
}
