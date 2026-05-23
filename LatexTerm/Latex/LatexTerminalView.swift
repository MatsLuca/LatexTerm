import AppKit
import SwiftTerm

final class OverlayHost: NSView {
    override var isFlipped: Bool { true }

    /// Standardmäßig komplett klick-durchlässig (Terminal bekommt Selektion/Scroll).
    /// Ausnahme: Treffer INNERHALB eines interaktiven Subviews – z.B. die Buttons des
    /// gepinnten Formel-Panels – werden durchgelassen, damit sie Klicks bekommen.
    /// Klicks auf leere Fläche liefern `self` aus `super.hitTest` und bleiben durchlässig.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return (hit !== self) ? hit : nil
    }

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
    /// Schriftgröße ist global: eine Kachel ändert sie, alle übernehmen sie (Cmd ±/0
    /// wirkt damit gleichzeitig über alle Splits). userInfo["size"] = neue Größe.
    static let fontDidChange = Notification.Name("LatexTerm.fontDidChange")

    private var fontObserver: NSObjectProtocol?

    let overlay = OverlayHost()
    var onRangeChanged: (() -> Void)?
    /// Reiner Scroll: Inhalt unverändert, nur neu positionieren → Sofort-Pfad ohne Debounce.
    var onScrolled: (() -> Void)?
    /// Cmd+T: neue Terminal-Kachel rechts anlegen.
    var onSplitRequested: (() -> Void)?
    /// Cmd+W: diese Kachel schließen (Shell beenden).
    var onCloseRequested: (() -> Void)?
    /// Cmd+1…9: auf so viele Kacheln auffüllen (nur erweitern, nie schließen).
    var onEnsurePaneCount: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        notifyUpdateChanges = true
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        font = NSFont.monospacedSystemFont(ofSize: Self.storedFontSize(), weight: .regular)
        // Größenänderung einer beliebigen Kachel auch hier anwenden → alle synchron.
        fontObserver = NotificationCenter.default.addObserver(
            forName: Self.fontDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let size = note.userInfo?["size"] as? CGFloat else { return }
            self.applyFont(size: size)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onRangeChanged?()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScrolled?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.subtracting(.shift) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let a = event.charactersIgnoringModifiers ?? ""
        let b = event.characters ?? ""
        if (a == "t" || b == "t"), !mods.contains(.shift) {
            onSplitRequested?(); return true
        }
        if (a == "w" || b == "w"), !mods.contains(.shift) {
            // performKeyEquivalent wird in View-Reihenfolge durchgereicht (älteste Kachel
            // zuerst). Nur die tatsächlich fokussierte Kachel darf sich schließen – sonst
            // an die nächste weiterreichen, bis die fokussierte dran ist.
            let fr = window?.firstResponder
            let focused = (fr === self) || ((fr as? NSView)?.isDescendant(of: self) ?? false)
            if focused { onCloseRequested?(); return true }
            return super.performKeyEquivalent(with: event)
        }
        if let d = Int(a) ?? Int(b), (1...9).contains(d), !mods.contains(.shift) {
            onEnsurePaneCount?(d); return true
        }
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

    /// Vom Shortcut ausgelöst: global persistieren und an alle Kacheln broadcasten
    /// (inkl. dieser – die Übernahme passiert im `fontDidChange`-Observer via `applyFont`).
    private func setFont(size: CGFloat) {
        guard size != font.pointSize else { return }
        UserDefaults.standard.set(Double(size), forKey: Self.fontSizeKey)
        NotificationCenter.default.post(
            name: Self.fontDidChange, object: nil, userInfo: ["size": size]
        )
    }

    /// Wendet eine Größe lokal an (vom Broadcast) und scannt die Overlays neu.
    private func applyFont(size: CGFloat) {
        guard size != font.pointSize else { return }
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        onRangeChanged?()
    }
}
