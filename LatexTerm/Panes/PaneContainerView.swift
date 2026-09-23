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

    /// Die Kachel, der diese Hülle gehört — Ziel der Kachel-Kürzel (über ihren Host).
    weak var pane: (any Pane)?

    private var themeObserver: NSObjectProtocol?

    // MARK: Kachel-Kürzel

    enum Shortcut: Equatable { case split, close, zoom, paneCount(Int) }

    /// ⌘T, ⌘W, ⌘1…9, ⌘⏎ — genau ⌘, ohne ⇧/⌥/⌃. Beide Zeichenformen prüfen, damit es auf jedem
    /// Tastaturlayout greift.
    static func shortcut(for event: NSEvent) -> Shortcut? {
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return nil }
        let keys = [event.charactersIgnoringModifiers ?? "", event.characters ?? ""]
        if keys.contains("t") { return .split }
        if keys.contains("w") { return .close }
        if keys.contains("\r") { return .zoom }
        if let digit = keys.lazy.compactMap({ Int($0) }).first, (1...9).contains(digit) { return .paneCount(digit) }
        return nil
    }

    /// Der einzige Verteiler der Kachel-Kürzel. `performKeyEquivalent` läuft durch ALLE Kacheln
    /// (älteste zuerst) — nur die Hülle mit dem First Responder antwortet, und nur ihr Inhalt
    /// sieht Tasten überhaupt. ⌘T/⌘W/⌘1–9 gehören immer der Kachel und kommen VOR dem Inhalt dran
    /// (ein WKWebView schluckte sie sonst und reichte sie nur noch ans Menü); ⌘⏎ erst NACH dem
    /// Inhalt, weil die ⌘K-Palette es als Zweitaktion belegt. Kein Inhalt implementiert
    /// Kachel-Kürzel selbst.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let pane, let host = pane.host,
              (window?.firstResponder as? NSView)?.isDescendant(of: self) == true else { return false }
        let shortcut = Self.shortcut(for: event)
        switch shortcut {
        case .split: host.paneRequestsSplit(pane); return true
        case .close: host.paneRequestsClose(pane); return true
        case .paneCount(let count): host.paneRequestsPaneCount(count); return true
        case .zoom, nil: break
        }
        if super.performKeyEquivalent(with: event) { return true }
        guard shortcut == .zoom else { return false }
        host.paneRequestsZoom(pane)
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Die Hülle setzt die Rahmen ihres Inhalts selbst (pinContent / setFrameSize). Autoresizing obendrauf
        // verrechnete jede Zoom-Animation ein zweites Mal — der Inhalt wuchs über die Kachel hinaus, beim
        // Zurückzoomen schrumpfte seine Malfläche auf 0 (Scratchpad nahm nach ⌘⏎ keine Klicks mehr, 22.09.).
        autoresizesSubviews = false
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

    /// Trennlinie wird gezogen (Kachel-Layout): die Hülle folgt der Maus, der Inhalt behält seine
    /// Größe bis zum Loslassen — sonst reflowte ein Terminal bei jedem Mausschritt den ganzen Scrollback
    /// über Zwischenbreiten (verlustbehaftet, s. `pinContent`). Wächst die Kachel, zeigt sich solange der
    /// Hüllen-Grund; beim Loslassen setzt die Split-View per `pinContent` die Endgröße (ein Resize).
    var holdsContent = false

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
        // Schon auf Zielgröße: kein Frame-Wechsel folgt, der den Pin wieder löste — ein stehen-
        // gebliebener Pin schluckte sonst den nächsten echten Resize (Fenstergröße).
        pinnedTargetSize = target == frame.size ? nil : target
        for sub in subviews { sub.frame = inner }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if holdsContent { return }
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
