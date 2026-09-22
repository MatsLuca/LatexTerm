import AppKit

/// Äußere Hülle einer Kachel: trägt abgerundete Ecken, Fokus-Rahmen, Dimmung und Tint und
/// hält den Inhalt per Innenabstand von der Kante weg — SwiftTerm zeichnet ab x=0, ohne Inset
/// klebte der Text Pixel an Pixel am Rahmen. Das Inset lebt bewusst HIER statt im Fork:
/// Zeichnen, Maus-Koordinaten und die Overlay-Grid→Pixel-Mathematik nehmen alle den
/// Terminal-Ursprung 0 an.
///
/// Kachel-Protokoll (22.09.2026): die Hülle besitzt die komplette Kachel-Optik, für jede
/// Kachelart genau einmal. Die Kachel setzt nur ihre eigene Farbe (`ownAccent`) und den
/// Zustand (`hasFocus`); Rahmen-Regeln (`showsFocusBorder`, `fillsWindow`) setzt die
/// Split-View. Einstellungen (Theme, Akzent, Rahmen, Dimmung, Innenabstand) hört die Hülle
/// selbst — der Inhalt kennt weder `layer.border` noch Alpha noch Ecken.
final class PaneContainerView: NSView {
    /// Innenabstand aus den Darstellungs-Einstellungen (`ThemeStore.padding`, Runde 28).
    static var contentInset: CGFloat { ThemeStore.shared.padding }
    override var isFlipped: Bool { true }

    /// Ohne das frisst der Fenster-Drag Klicks auf nicht-opaken Inhalt
    /// (`isMovableByWindowBackground`): ein Zeichenbrett zöge beim Malen das Fenster.
    override var mouseDownCanMoveWindow: Bool { false }

    /// Kachel-EIGENE Farbe (OSC-Override, erkannter Rahmen, Projektfarbe) — nil, wenn die
    /// Kachel nur der globalen Akzentfarbe folgt. Treibt Rahmen und Tint.
    var ownAccent: NSColor? {
        didSet { if !Self.same(ownAccent, oldValue) { restyle() } }
    }
    /// Wirksame Akzentfarbe: eigene Farbe, sonst die globale.
    var effectiveAccent: NSColor { ownAccent ?? ThemeStore.shared.accentColor }

    /// Trägt die Kachel gerade den Tastaturfokus?
    var hasFocus = false {
        didSet { if hasFocus != oldValue { restyle(animated: true) } }
    }
    /// Fokus-Rahmen nur zeigen, wenn es mehrere Kacheln gibt — bei einer einzelnen
    /// umrandet er nur das ganze Fenster und erklärt nichts. Setzt die Split-View.
    var showsFocusBorder = true {
        didSet { if showsFocusBorder != oldValue { restyle() } }
    }
    /// Diese Kachel füllt das ganze Fenster — gezoomt (#26) ODER die einzige Kachel: voller
    /// Akzent-Rahmen statt Fokus-Abstufung, der Rahmen ist dann die Session-Farbkennung des
    /// Fensters. Setzt die Split-View.
    var fillsWindow = false {
        didSet { if fillsWindow != oldValue { restyle() } }
    }

    private var themeObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        restyle()
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let change = note.userInfo?[ThemeStore.changeKey] as? ThemeStore.Change else { return }
            switch change {
            case .theme, .appearance:
                // Padding-Änderung: Inhalt neu einpassen (setFrameSize rechnet den Inset frisch).
                self.setFrameSize(self.frame.size)
                self.restyle()
            case .accent:
                self.restyle()
            case .panes:
                self.restyle(animated: true)
            case .font, .lineSpacing, .adaptiveAccent, .prompt:
                break
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    /// Rahmen, Dimmung und Grund aus Zustand + Einstellungen — die einzige Stelle dafür.
    /// Dimmung immer. Rahmen bei ≥2 Kacheln (`showsFocusBorder`) auf JEDER Kachel in ihrer
    /// Akzentfarbe (Session-Identität auf einen Blick) — die fokussierte kräftiger und
    /// dicker, unfokussierte dünn und zurückgenommen. Der Tint (Grund leicht Richtung Akzent)
    /// greift nur bei Kachel-EIGENER Farbe — ein globaler Tint auf allen Kacheln gleich würde
    /// nichts erklären. Er färbt nur das Inset-Band: der Terminal-Grund selbst bleibt exakt die
    /// Theme-Farbe, die Hülle ist opak (Formel-Masken und einheitliche Stege brauchen das).
    func restyle(animated: Bool = false) {
        let store = ThemeStore.shared
        let base = store.theme.background.withAlphaComponent(1)
        let hull = store.paneBorders ? (ownAccent.map { base.blended(withFraction: 0.12, of: $0) ?? base } ?? base) : base
        layer?.backgroundColor = hull.cgColor

        let alpha: CGFloat = (hasFocus || !store.focusDimming) ? 1.0 : 0.65
        // Fenster-füllend (gezoomt oder einzige Kachel): voller Akzent — der
        // Rahmen IST dann die Session-Kennung; sonst Fokus-Abstufung im Grid.
        var borderWidth: CGFloat = fillsWindow ? 2.0 : (showsFocusBorder ? (hasFocus ? 1.5 : 1.0) : 0)
        if !store.paneBorders { borderWidth = 0 }   // Darstellung → „Kachel-Akzentrahmen“ aus
        let borderColor = effectiveAccent.withAlphaComponent(
            fillsWindow ? 1.0 : (hasFocus ? 0.65 : 0.35)).cgColor
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = alpha
                layer?.borderColor = borderColor
                layer?.borderWidth = borderWidth
            }
        } else {
            alphaValue = alpha
            layer?.borderColor = borderColor
            layer?.borderWidth = borderWidth
        }
    }

    private static func same(_ a: NSColor?, _ b: NSColor?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.srgbMatches(b)
        default: return false
        }
    }

    /// Ziel einer laufenden (animierten) Umsortierung. Solange gesetzt, ignorieren
    /// die per Animations-Tick eintrudelnden Zwischengrößen die Subviews.
    private var pinnedTargetSize: NSSize?

    /// Inhalt SOFORT auf die Ziel-Geometrie der Umsortierung setzen; die Hülle
    /// animiert hinterher und gibt den Inhalt progressiv frei (masksToBounds).
    /// Ohne das Pinning setzte `animator().frame` den Frame pro Animations-Tick
    /// (~13× in 0,22s) → ebenso viele PTY-Resizes: SwiftTerm reflowt bei JEDER
    /// Spaltenänderung den kompletten Scrollback (verlustbehaftet über
    /// Zwischenbreiten!), und laufende TUIs zeichnen bei jeder Zwischenbreite neu —
    /// deren Fragmente vermüllen den Scrollback dauerhaft.
    func pinContent(forTargetSize target: NSSize) {
        let inner = NSRect(origin: .zero, size: target)
            .insetBy(dx: Self.contentInset, dy: Self.contentInset)
        guard inner.width > 0, inner.height > 0 else { pinnedTargetSize = nil; return }
        pinnedTargetSize = target
        for sub in subviews { sub.frame = inner }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let target = pinnedTargetSize {
            // Zwischengröße der Animation → Inhalt steht schon auf dem Ziel.
            // Ziel erreicht → Pin lösen (jede Umsortierung pinnt ohnehin neu).
            if newSize == target { pinnedTargetSize = nil }
            return
        }
        // Direkter Frame-Set außerhalb einer Umsortierung (Robustheits-Fallback):
        // synchron mitziehen, damit der Inhalt der Hülle nie einen Tick hinterherläuft.
        let inner = bounds.insetBy(dx: Self.contentInset, dy: Self.contentInset)
        guard inner.width > 0, inner.height > 0 else { return }
        for sub in subviews { sub.frame = inner }
    }
}
