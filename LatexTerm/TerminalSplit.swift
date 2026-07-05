import AppKit
import SwiftTerm

/// Äußere Hülle einer Terminal-Kachel: trägt abgerundete Ecken, Fokus-Rahmen und
/// Dimmung und hält den Terminal-Inhalt per Innenabstand von der Kante weg —
/// SwiftTerm zeichnet ab x=0, ohne Inset klebte der Text Pixel an Pixel am Rahmen.
/// Das Inset lebt bewusst HIER statt im Fork: Zeichnen, Maus-Koordinaten und die
/// Overlay-Grid→Pixel-Mathematik nehmen alle den Terminal-Ursprung 0 an.
final class PaneContainerView: NSView {
    static let contentInset: CGFloat = 4
    override var isFlipped: Bool { true }

    /// Ziel einer laufenden (animierten) Umsortierung. Solange gesetzt, ignorieren
    /// die per Animations-Tick eintrudelnden Zwischengrößen die Subviews.
    private var pinnedTargetSize: NSSize?

    /// Terminal SOFORT auf die Ziel-Geometrie der Umsortierung setzen; die Hülle
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

/// Eine einzelne Terminal-Kachel: eigener Shell-Prozess, eigener OverlayController
/// (= eigene LaTeX-Overlays). Mehrere Panes leben nebeneinander in `TerminalSplitView`.
/// Übernimmt die Rolle, die früher der `TerminalContainer.Coordinator` für das einzelne
/// Terminal hatte (Process-Delegate + Settings-Observer + Shell-Spawn).
final class TerminalPane: NSObject, LocalProcessTerminalViewDelegate {

    let view: LatexTerminalView
    /// Von der Split-View gemountete/layoutete Hülle; `view` (das Terminal) lebt darin.
    let container: PaneContainerView
    private let controller: OverlayController
    private var settingsObserver: NSObjectProtocol?
    /// Aktueller Fokus-Zustand (vom `onFocusChanged`-Callback gepflegt).
    private var hasFocus = false
    /// Fokus-Rahmen nur zeigen, wenn es mehrere Kacheln gibt — bei einer einzelnen
    /// umrandet er nur das ganze Fenster und erklärt nichts. Setzt die Split-View.
    var showsFocusBorder = true {
        didSet { if showsFocusBorder != oldValue { applyFocusStyle(animated: false) } }
    }
    /// Diese Kachel füllt das ganze Fenster — gezoomt (#26) ODER die einzige
    /// Kachel: voller Akzent-Rahmen statt Fokus-Abstufung, der Rahmen ist dann
    /// die Session-Farbkennung des Fensters. Setzt die Split-View.
    var fillsWindow = false {
        didSet { if fillsWindow != oldValue { applyFocusStyle(animated: false) } }
    }

    /// Private OSC-Sequenz für In-Band-Steuerung dieser Pane (#24, Fundament für #25/#27):
    /// `printf '\e]5522;accent=#RRGGBB\a'` in der Pane-Shell setzt die Akzentfarbe.
    /// In-Band statt Socket/Env-Var: reist durch die PTY der Pane → per-Pane by
    /// construction, funktioniert durch SSH, keine Integrations-Infra nötig.
    static let controlOscCode = 5522

    /// Per-Pane-Akzent-Override (OSC `accent=…`): überstimmt die globale Akzentfarbe
    /// für Caret/Fokus-Rahmen DIESER Kachel bis `accent=reset` oder Pane-Ende.
    private var accentOverride: NSColor? {
        didSet { applyAccent(); applyFocusStyle(animated: false) }
    }
    /// Passiv erkannte TUI-Rahmenfarbe dieser Kachel (#24): Claude Code & Co.
    /// zeichnen ihre Box-Rahmen (`╭────╮`) in der Session-Akzentfarbe. Nur aktiv
    /// im adaptiven Modus; schwächer als ein expliziter OSC-Override.
    private var borderAccent: NSColor? {
        didSet { applyAccent(); applyFocusStyle(animated: false) }
    }
    /// Wirksame Akzentfarbe dieser Kachel: OSC-Override > erkannter Rahmen > global.
    var effectiveAccent: NSColor { accentOverride ?? borderAccent ?? FormulaSettings.shared.accentColor }
    /// Pane-EIGENE Farbe (Override oder erkannt) — nil, wenn die Kachel nur der
    /// globalen Farbe folgt. Steuert Hüll-Tint und Session-Persistierung.
    var paneAccent: NSColor? { accentOverride ?? borderAccent }
    /// Optik dieser Kachel hat sich geändert (Akzent/Fokus) → Titlebar-HUD & Co.
    var onStyleChanged: (() -> Void)?

    /// Pane-Farbe als `#RRGGBB` für den Session-Snapshot (#11).
    var accentHex: String? { paneAccent?.srgbHexString }
    /// Restore aus dem Snapshot: verhält sich wie eine ERKANNTE Farbe — die
    /// laufende Detektion darf sie bestätigen, ersetzen oder wieder ausräumen.
    func restoreAccent(hex: String?) {
        guard let hex, let color = NSColor(srgbHex: hex) else { return }
        borderAccent = color
    }

    /// Shell-Prozess beendet → diese Pane soll entfernt werden.
    var onClosed: ((TerminalPane) -> Void)?
    /// Cmd+T in dieser Pane → neue Pane anlegen.
    var onSplitRequested: ((TerminalPane) -> Void)?
    /// Cmd+W in dieser Pane → schließen.
    var onCloseRequested: ((TerminalPane) -> Void)?
    /// Cmd+1…9 in dieser Pane → auf so viele Kacheln auffüllen.
    var onEnsurePaneCount: ((Int) -> Void)?
    /// Cmd+⏎ in dieser Pane → Zoom-Toggle (#26).
    var onZoomRequested: ((TerminalPane) -> Void)?

    override init() {
        let settings = FormulaSettings.shared
        let term = LatexTerminalView(frame: .zero)
        term.nativeForegroundColor = NSColor(red: 230/255.0, green: 225/255.0, blue: 225/255.0, alpha: 1.0)
        // Opaker Hintergrund: die Formel-Overlays maskieren den Quelltext mit einer
        // volldeckenden Box in genau dieser Farbe (Alpha wird in OverlayController.css
        // verworfen). Wäre der Terminal-BG transluzent (Vibrancy darunter), erschiene die
        // opake Maske dunkler als der umgebende Hintergrund. Vibrancy bleibt in den
        // Kachel-Stegen (gapColor) erhalten.
        term.nativeBackgroundColor = NSColor(red: 23/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1.0)
        term.caretColor = settings.accentColor
        // Pulsierender Cursor
        term.getTerminal().setCursorStyle(.blinkBlock)
        term.extraLineSpacing = settings.extraLineSpacing  // aus UserDefaults

        // Kachel-Styling (Ecken/Rahmen/Dimmung) liegt auf der Container-Hülle;
        // ihr Hintergrund füllt das Content-Inset in der Terminal-Farbe auf.
        let box = PaneContainerView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = term.nativeBackgroundColor.cgColor
        box.layer?.borderWidth = 0
        box.layer?.borderColor = settings.accentColor.withAlphaComponent(0.65).cgColor
        // Kachel ist standardmäßig inaktiv (abgedunkelt), bis sie fokussiert wird
        box.alphaValue = 0.65
        box.addSubview(term)

        self.view = term
        self.container = box
        self.controller = OverlayController(terminal: term)
        super.init()

        // Fokus-Visualisierung
        term.onFocusChanged = { [weak self] focused in
            guard let self else { return }
            self.hasFocus = focused
            self.applyFocusStyle(animated: true)
            // Fokuswechsel übernimmt den zuletzt von DIESER Shell gemeldeten Titel (#21).
            if focused { self.applyStoredTitle() }
        }

        term.processDelegate = self
        term.onRangeChanged = { [weak self, weak controller] startY, endY in
            controller?.scheduleRescan(dirtyStart: startY, dirtyEnd: endY)
            self?.scheduleContrastAnalysis()
        }
        term.onNeedsFullRescan = { [weak controller] in controller?.scheduleRescan() }
        term.onScrolled = { [weak controller] in controller?.scheduleReposition() }
        term.onSplitRequested = { [weak self] in
            guard let self else { return }
            self.onSplitRequested?(self)
        }
        term.onCloseRequested = { [weak self] in
            guard let self else { return }
            self.onCloseRequested?(self)
        }
        term.onEnsurePaneCount = { [weak self] n in self?.onEnsurePaneCount?(n) }
        term.onZoomRequested = { [weak self] in
            guard let self else { return }
            self.onZoomRequested?(self)
        }

        // In-Band-Steuerkanal (#24). Der Parser läuft auf dem Feed-Pfad —
        // UI-Änderungen sicherheitshalber auf den Main-Runloop verschieben.
        term.getTerminal().registerOscHandler(code: Self.controlOscCode) { [weak self] data in
            let payload = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.handleControlSequence(payload) }
        }

        // Auf Einstellungs-Änderungen reagieren
        settingsObserver = NotificationCenter.default.addObserver(
            forName: FormulaSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self, weak term] note in
            let settings = FormulaSettings.shared
            term?.extraLineSpacing = settings.extraLineSpacing
            // Globale Akzent-Änderungen nur anwenden, wo kein OSC-Override liegt
            // (applyAccent respektiert den Override von selbst).
            self?.applyAccent()

            // Nur wenn der Modus selbst eingeschaltet wurde, sofort analysieren —
            // sonst stieße jede (adaptiv gesetzte) accentColor-Änderung gleich die
            // nächste Analyse an.
            let change = note.userInfo?[FormulaSettings.changeKey] as? FormulaSettings.Change
            if change == .isAdaptiveAccent {
                if settings.isAdaptiveAccent {
                    self?.scheduleContrastAnalysis()
                } else {
                    // Adaptiv aus → auch die passiv erkannte Rahmenfarbe loslassen,
                    // die Kachel folgt wieder der manuellen globalen Farbe.
                    self?.borderAccent = nil
                }
            }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// Verarbeitet eine OSC-5522-Payload (`key=value`; das Format ist bewusst
    /// erweiterbar — #25 Live-Status und #27 Notifications sollen denselben Kanal
    /// nutzen). Unbekannte Keys/kaputte Payloads werden still ignoriert: die
    /// Sequenz kommt aus untrusted Programm-Output (siehe SECURITY.md).
    private func handleControlSequence(_ payload: String) {
        let parts = payload.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "accent":
            if parts[1] == "reset" {
                accentOverride = nil
            } else if let color = NSColor(srgbHex: String(parts[1])) {
                accentOverride = color
            }
        default:
            break
        }
    }

    /// Caret, Rahmenfarbe und Hüll-Tint auf die wirksame Akzentfarbe setzen.
    /// Der Tint (Terminal-BG leicht Richtung Akzent) greift nur bei Pane-EIGENER
    /// Farbe — ein globaler Tint auf allen Kacheln gleich würde nichts erklären.
    /// Bewusst nur die Hülle (das 4px-Inset-Band): der Terminal-BG selbst muss
    /// unangetastet bleiben, die Formel-Masken malen exakt in seiner Farbe.
    private func applyAccent() {
        view.caretColor = effectiveAccent
        container.layer?.borderColor = effectiveAccent.withAlphaComponent(0.65).cgColor
        let bg = view.nativeBackgroundColor
        let hull = paneAccent.flatMap { bg.blended(withFraction: 0.12, of: $0) } ?? bg
        container.layer?.backgroundColor = hull.cgColor
        onStyleChanged?()
    }

    /// Dimmung immer. Rahmen bei ≥2 Kacheln (`showsFocusBorder`) auf JEDER Kachel
    /// in ihrer Akzentfarbe (Session-Identität auf einen Blick) — die fokussierte
    /// kräftiger und dicker, unfokussierte dünn und zurückgenommen.
    private func applyFocusStyle(animated: Bool) {
        let alpha: CGFloat = hasFocus ? 1.0 : 0.65
        // Fenster-füllend (gezoomt oder einzige Kachel): voller Akzent — der
        // Rahmen IST dann die Session-Kennung; sonst Fokus-Abstufung im Grid.
        let borderWidth: CGFloat = fillsWindow ? 2.0 : (showsFocusBorder ? (hasFocus ? 1.5 : 1.0) : 0)
        let borderColor = effectiveAccent.withAlphaComponent(
            fillsWindow ? 1.0 : (hasFocus ? 0.65 : 0.35)).cgColor
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                container.animator().alphaValue = alpha
                container.layer?.borderColor = borderColor
                container.layer?.borderWidth = borderWidth
            }
        } else {
            container.alphaValue = alpha
            container.layer?.borderColor = borderColor
            container.layer?.borderWidth = borderWidth
        }
        onStyleChanged?()
    }

    private var contrastPending = false

    /// Ist diese Kachel gerade fokussiert (First Responder im oder unterm Terminal-View)?
    private var isFocused: Bool {
        let fr = view.window?.firstResponder
        return (fr === view) || ((fr as? NSView)?.isDescendant(of: view) ?? false)
    }

    /// Wartet 1,8 Sekunden Cooldown ab, bevor die Kontrastanalyse durchgeführt wird.
    func scheduleContrastAnalysis() {
        guard FormulaSettings.shared.isAdaptiveAccent else { return }
        // Eine explizit per OSC gefärbte Kachel ist autoritativ — sie soll die
        // globale adaptive Farbe weder treiben noch von ihr überschrieben werden.
        guard accentOverride == nil else { return }
        if contrastPending { return }

        // Kurze Kadenz nur für den billigen Grid-Scan (~12k Attribut-Reads);
        // die teure Pixel-Analyse (cacheDisplay + Downsampling) behält ihren
        // alten 1,8-s-Mindestabstand über `lastPixelAnalysis`.
        contrastPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.contrastPending = false
            // Stufe 1 (per-Pane, läuft für JEDE Kachel — auch unfokussierte CC-
            // Sessions färben ihre eigene Kachel): TUI-Rahmenfarbe aus dem Grid.
            if let border = self.detectBorderAccent() {
                if !(self.borderAccent?.srgbMatches(border) ?? false) {
                    self.borderAccent = border
                }
                return
            }
            // Kein Rahmen im Blick (hochgescrollt, Vollbild-TUI, mitten im
            // Redraw): eine einmal erkannte Farbe STICKY behalten, bis eindeutig
            // eine andere erkannt wird — das Live-Wegkippen beim Scrollen war
            // sichtbar unschön. Zurücksetzen nur über den Adaptiv-Toggle.
            if self.borderAccent != nil { return }
            // Stufe 2 (global): Pixel-Kontrastanalyse — nur die fokussierte
            // Kachel darf die globale Akzentfarbe anpassen!
            let now = CACurrentMediaTime()
            if self.isFocused, now - self.lastPixelAnalysis > 1.8 {
                self.lastPixelAnalysis = now
                self.analyzeContrast()
            }
        }
    }

    /// Zeitpunkt der letzten Pixel-Kontrastanalyse (drosselt Stufe 2 auf den
    /// alten 1,8-s-Takt, während Stufe 1 alle 0,3 s laufen darf).
    private var lastPixelAnalysis: CFTimeInterval = 0

#if DEBUG
    /// Debug-Log der Akzent-Detektion, direkt als Datei (NSLog/os_log sind beim
    /// Standalone-Lauf unpraktisch auszulesen — Verifikations-Workflow, CLAUDE.md).
    private static let accentLogHandle: FileHandle? = {
        let path = "/tmp/latexterm-accent.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private static func accentLog(_ msg: String) {
        guard let data = (msg + "\n").data(using: .utf8) else { return }
        accentLogHandle?.write(data)
    }
#endif

    /// Sucht von unten nach oben (Claude Codes Input-Box liegt am unteren Rand)
    /// nach einer Viewport-Zeile, die überwiegend aus Box-Drawing-Zeichen
    /// (U+2500–U+257F) in EINER gesättigten Vordergrundfarbe besteht — das ist
    /// ein TUI-Rahmen, seine Farbe der Session-Akzent. Anders als die Pixel-
    /// Analyse liest das die exakten Zell-Attribute aus dem Buffer-Grid: kein
    /// Downsampling, kein Diff-Grün-Rauschen (Box-Zeichen kommen in normalem
    /// Output praktisch nicht vor). Graue/ungesättigte Rahmen (CC ohne /color,
    /// Dim-Borders) liefern bewusst nil → Fallback auf die globale Analyse.
    private func detectBorderAccent() -> NSColor? {
        let term = view.getTerminal()
        let cols = term.cols
        guard cols >= 16 else { return nil }
        let minRun = max(8, cols / 2)
#if DEBUG
        var dbg: [String] = []
#endif
        for row in stride(from: term.rows - 1, through: 0, by: -1) {
            guard let line = term.getLine(row: row) else { continue }
            var boxCells = 0
            var fg: Attribute.Color?
            var mixed = false
            for col in 0..<cols {
                let cell = line[col]
                guard let scalar = cell.getCharacter().unicodeScalars.first,
                      (0x2500...0x257F).contains(scalar.value) else { continue }
                boxCells += 1
                let cellFg = cell.attribute.fg
                if fg == nil { fg = cellFg } else if fg != cellFg { mixed = true; break }
            }
#if DEBUG
            if boxCells >= 4 {
                dbg.append("row \(row): box=\(boxCells)/\(minRun) fg=\(fg.map(String.init(describing:)) ?? "-") mixed=\(mixed)")
            }
#endif
            guard !mixed, boxCells >= minRun, let fg else { continue }
            guard let color = nsColor(from: fg, terminal: term),
                  let srgb = color.usingColorSpace(.sRGB),
                  srgb.saturationComponent > 0.25 else {
#if DEBUG
                dbg.append("row \(row): REJECT color/sat fg=\(String(describing: fg))")
#endif
                continue
            }
#if DEBUG
            Self.accentLog("HIT row \(row) fg=\(String(describing: fg)) → \(color)")
#endif
            return color
        }
#if DEBUG
        // Nichts gefunden: welche Nicht-ASCII-Zeichen stehen unten überhaupt im Grid?
        // (Entlarvt Rahmen aus anderen Unicode-Blöcken, z. B. Block-Elemente U+2580–259F.)
        var nonAscii: [String] = []
        outer: for row in stride(from: term.rows - 1, through: max(0, term.rows - 12), by: -1) {
            guard let line = term.getLine(row: row) else { continue }
            for col in 0..<cols {
                if let sc = line[col].getCharacter().unicodeScalars.first, sc.value > 0x7F {
                    nonAscii.append(String(format: "U+%04X", sc.value))
                    if nonAscii.count >= 24 { break outer }
                }
            }
        }
        Self.accentLog("MISS rows=\(term.rows) cols=\(cols)\n  " + dbg.joined(separator: "\n  ")
                       + "\n  nonascii(bottom12): \(nonAscii.joined(separator: " "))")
#endif
        return nil
    }

    /// Zell-Vordergrundfarbe → NSColor. `defaultColor` (Theme-Grau) zählt nicht
    /// als Akzent; 256er-Indizes löst der Fork-Accessor gegen die live Palette auf.
    private func nsColor(from fg: Attribute.Color, terminal: Terminal) -> NSColor? {
        switch fg {
        case .trueColor(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        case .ansi256(let code):
            guard let c = terminal.ansiColor(code: Int(code)) else { return nil }
            return NSColor(srgbRed: CGFloat(c.red) / 65535, green: CGFloat(c.green) / 65535,
                           blue: CGFloat(c.blue) / 65535, alpha: 1)
        case .defaultColor, .defaultInvertedColor:
            return nil
        }
    }

    /// Skaliert den Terminalinhalt hocheffizient auf 64x64 Pixel herunter, filtert alle
    /// Hintergrundpixel heraus und berechnet den Farbdurchschnitt des reinen Vordergrundtexts.
    private func analyzeContrast() {
        guard FormulaSettings.shared.isAdaptiveAccent else { return }
        let bounds = view.bounds
        guard bounds.width > 20, bounds.height > 20 else { return }

        // Wir blenden den Kachelrahmen aus (10% Rand ignorieren)
        let insetRect = bounds.insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.1)

        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: insetRect) else { return }
        view.cacheDisplay(in: insetRect, to: bitmapRep)

        let targetSize = NSSize(width: 64, height: 64)
        guard let smallRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: smallRep)
        NSGraphicsContext.current = context

        let image = NSImage(size: insetRect.size)
        image.addRepresentation(bitmapRep)
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: insetRect.size),
                   operation: .copy,
                   fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        var sampleCount = 0

        // Hintergrundfarbe des Terminals: RGB(23, 20, 20)
        let bgR: CGFloat = 23/255.0
        let bgG: CGFloat = 20/255.0
        let bgB: CGFloat = 20/255.0

        for y in 0..<64 {
            for x in 0..<64 {
                if let color = smallRep.colorAt(x: x, y: y) {
                    let r = color.redComponent
                    let g = color.greenComponent
                    let b = color.blueComponent
                    
                    // Distanz zur Hintergrundfarbe berechnen (Anti-Hintergrund-Filter)
                    let rDiff = r - bgR
                    let gDiff = g - bgG
                    let bDiff = b - bgB
                    let dist = sqrt(rDiff*rDiff + gDiff*gDiff + bDiff*bDiff)
                    
                    // Pixel nur werten, wenn es signifikant vom Hintergrund abweicht
                    if dist > 0.08 {
                        totalR += r
                        totalG += g
                        totalB += b
                        sampleCount += 1
                    }
                }
            }
        }

        if sampleCount > 0 {
            let avgR = totalR / CGFloat(sampleCount)
            let avgG = totalG / CGFloat(sampleCount)
            let avgB = totalB / CGFloat(sampleCount)
            let avgColor = NSColor(red: avgR, green: avgG, blue: avgB, alpha: 1.0)
            let bestColor = Self.findBestContrastColor(to: avgColor)

            // Farbraumfest vergleichen: die geladene Akzentfarbe (sRGB) wäre per
            // NSColor-`==` nie gleich einer Palettenfarbe (anderer Farbraum).
            if !FormulaSettings.shared.accentColor.srgbMatches(bestColor) {
                FormulaSettings.shared.accentColor = bestColor
            }
        }
    }

    private static let palette: [NSColor] = [
        NSColor(red: 232/255.0, green: 94/255.0, blue: 62/255.0, alpha: 1.0),   // Orange
        NSColor(red: 0/255.0, green: 210/255.0, blue: 255/255.0, alpha: 1.0),   // Electric Cyan
        NSColor(red: 57/255.0, green: 255/255.0, blue: 20/255.0, alpha: 1.0),   // Neon Green
        NSColor(red: 255/255.0, green: 223/255.0, blue: 0/255.0, alpha: 1.0),   // Solar Yellow
        NSColor(red: 189/255.0, green: 0/255.0, blue: 255/255.0, alpha: 1.0),   // Electric Purple
        NSColor(red: 255/255.0, green: 0/255.0, blue: 127/255.0, alpha: 1.0),   // Vaporwave Pink
        NSColor(red: 245/255.0, green: 245/255.0, blue: 247/255.0, alpha: 1.0)  // Frost White
    ]

    private static func findBestContrastColor(to baseColor: NSColor) -> NSColor {
        let r = baseColor.redComponent
        let g = baseColor.greenComponent
        let b = baseColor.blueComponent
        
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        let saturation = maxC == 0 ? 0 : delta / maxC
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        
        // Ist der Vordergrund-Text überwiegend Weiß oder Grau?
        let isWhiteOrGrayText = luminance > 0.65 && saturation < 0.20
        
        var bestColor = palette[0]
        var maxDistance: CGFloat = -1
        
        for color in palette {
            // Wenn der Text weiß/grau ist, weiche auf Buntheiten aus
            if isWhiteOrGrayText && color == palette[6] {
                continue
            }
            
            let rDiff = baseColor.redComponent - color.redComponent
            let gDiff = baseColor.greenComponent - color.greenComponent
            let bDiff = baseColor.blueComponent - color.blueComponent
            let dist = sqrt(rDiff*rDiff + gDiff*gDiff + bDiff*bDiff)
            
            if dist > maxDistance {
                maxDistance = dist
                bestColor = color
            }
        }
        return bestColor
    }

    /// Beendet die Shell (SIGTERM). Das Prozess-Ende läuft über `processTerminated`
    /// → `onClosed` und entfernt die Kachel auf demselben Pfad wie ein `exit`.
    func terminate() {
        view.terminate()
    }

    /// Aktuelles Arbeitsverzeichnis dieser Pane (OSC 7), falls die Shell eins gemeldet hat.
    var currentDirectory: String? { view.currentWorkingDirectory() }

    /// Startet die Login-Shell des Users. `directory` (z.B. das CWD der fokussierten
    /// Kachel bei ⌘T, #8) geht als Arbeitsverzeichnis an den KINDPROZESS
    /// (`startProcess(currentDirectory:)`) statt prozessweit an die ganze App (#20).
    /// Nicht (mehr) existierende Verzeichnisse fallen auf Home zurück.
    func start(in directory: String? = nil) {
        let shell = Self.userShell()
        let shellIdiom = "-" + (shell as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dir = directory ?? home
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
            dir = home
        }
        view.startProcess(executable: shell, execName: shellIdiom, currentDirectory: dir)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        controller.scheduleRescan()
    }
    /// Zuletzt von der Shell dieser Kachel gemeldeter Titel (für Fokuswechsel-Übernahme).
    private var lastTitle = ""

    /// Nur die FOKUSSIERTE Kachel darf den Fenstertitel setzen (#21) — sonst gewinnt
    /// bei mehreren Panes der letzte Schreiber, unabhängig davon, wo man arbeitet.
    /// Unfokussierte Panes merken sich den Titel; der Fokuswechsel holt ihn nach.
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        lastTitle = title
        if isFocused { applyStoredTitle() }
    }

    fileprivate func applyStoredTitle() {
        view.window?.title = lastTitle.isEmpty ? "LatexTerm" : lastTitle
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onClosed?(self)
    }

    private static func userShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else { return "/bin/zsh" }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        // Reiner Out-Pointer: getpwuid_r setzt ihn auf &pwd oder NULL. NULL bei
        // Rückgabewert 0 heißt „kein Eintrag" — pwd ist dann undefiniert.
        var result: UnsafeMutablePointer<passwd>? = nil
        guard getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) == 0, result != nil else {
            return "/bin/zsh"
        }
        let s = String(cString: pwd.pw_shell)
        return s.isEmpty ? "/bin/zsh" : s
    }
}

/// Kachelt beliebig viele `TerminalPane`s in einem automatischen Grid. Cmd+T hängt eine
/// Kachel an, Cmd+W/`exit` entfernt eine; bei jeder Änderung wird neu gekachelt. Die
/// Grid-Form (Reihen × Spalten) wird abhängig von Fensterbreite UND -höhe gewählt, sodass
/// die Zellen einem Ziel-Seitenverhältnis möglichst nahekommen. Reihen sind gleich hoch,
/// jede Reihe teilt die Breite unabhängig auf (Masonry: obere Reihen ggf. eine Spalte mehr).
final class TerminalSplitView: NSView {

    private var panes: [TerminalPane] = []
    /// Gezoomte Kachel (#26): liegt über allen anderen auf voller Fenstergröße.
    /// Das Grid darunter bleibt unangetastet — Entzoomen ist ein normales relayout().
    /// Weak als Robustheitsnetz; jede Grid-Änderung entzoomt ohnehin explizit.
    private weak var zoomedPane: TerminalPane?
    private let vibrancyView = NSVisualEffectView()
    private var isFirstLayout = true
    private var terminateObserver: NSObjectProtocol?

    /// Lücke (Steg) zwischen den Kacheln in Punkten.
    private static let gap: CGFloat = 8

    /// Radius, mit dem macOS die UNTEREN Fensterecken rundet — die Kacheln der
    /// untersten Reihe folgen ihm, damit die Akzent-Outline nicht von der
    /// Fenster-Maske beschnitten wird. Kein API dafür; bei sichtbarem Versatz
    /// (macOS-Update) hier nachjustieren.
    private static let windowCornerRadius: CGFloat = 16.5

    /// Farbe des Stegs – transluzenter Hintergrund, damit die Vibrancy in den Stegen elegant durchschimmert.
    private static let gapColor = NSColor(red: 48/255.0, green: 43/255.0, blue: 43/255.0, alpha: 0.35)

    /// Ziel-Seitenverhältnis (Breite/Höhe) einer Kachel. < 1 = leicht hochkant → erlaubt
    /// mehr Spalten nebeneinander, bevor eine Reihe aufgemacht wird. Höher = früher umbrechen.
    /// 0.82 ergibt auf ~3:2-Fenstern: bis 3 nebeneinander, ab 4 → 2×2, dann auffüllen.
    private static let idealCellAspect: CGFloat = 0.82

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.gapColor.cgColor   // scheint in den Kachel-Lücken durch

        // Session-Restore (#11): letztes Layout (Pane-Anzahl + CWDs) wiederherstellen;
        // ohne/mit korruptem Snapshot startet wie bisher eine Kachel im Home.
        if let snap = SessionStore.load() {
            let accents = snap.paneAccents ?? []
            for (i, dir) in snap.paneDirectories.enumerated() {
                let pane = addPane(startingIn: dir)
                if i < accents.count { pane.restoreAccent(hex: accents[i]) }
            }
        } else {
            addPane()
        }

        // Beim Beenden den aktuellen Stand sichern (CWDs werden live ausgelesen).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveSession() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
    }

    private func saveSession() {
        guard !panes.isEmpty else { return }
        SessionStore.save(SessionSnapshot(paneDirectories: panes.map { $0.currentDirectory },
                                          paneAccents: panes.map { $0.accentHex }))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }

        // Window-Styling für rahmenlosen Premium-Desktop-Blend
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true // Ermöglicht das Verschieben des Fensters am Hintergrund

        // Visual Effect (Vibrancy) einrichten
        vibrancyView.material = .underWindowBackground
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.autoresizingMask = [.width, .height]
        vibrancyView.frame = bounds

        if vibrancyView.superview == nil {
            addSubview(vibrancyView, positioned: .below, relativeTo: nil)
        }

        // Session-Restore legt die Panes VOR dem Fenster-Attach an — HUD nachziehen.
        updateTitlebarHUD()
    }

    override var isFlipped: Bool { true }   // Reihe 0 oben

    // Frame-Layout: SwiftUI/Autoresizing ändert nur unsere Größe – darauf neu kacheln.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout(animated: false)
    }

    @discardableResult
    func addPane(startingIn directory: String? = nil) -> TerminalPane {
        let pane = TerminalPane()
        pane.onClosed = { [weak self] p in self?.removePane(p) }
        // ⌘T: die anfordernde Kachel ist die fokussierte → ihr CWD vererben (#8).
        pane.onSplitRequested = { [weak self] requester in
            self?.addPane(startingIn: requester.currentDirectory)
        }
        pane.onCloseRequested = { [weak self] p in self?.closePane(p) }
        pane.onEnsurePaneCount = { [weak self] n in self?.ensurePaneCount(n) }
        pane.onZoomRequested = { [weak self] p in self?.toggleZoom(p) }
        pane.onStyleChanged = { [weak self] in self?.updateTitlebarHUD() }
        // Grid-Änderung beendet einen aktiven Zoom: die neue Kachel soll sichtbar
        // im Grid entstehen, nicht unsichtbar unter der gezoomten (⌘T/⌘1–9-Policy).
        setZoomedPane(nil)
        panes.append(pane)
        updateTitlebarHUD()
        addSubview(pane.container)
        pane.start(in: directory)
        updateFocusBorders()
        relayout(animated: true)
        // Fokus erst im nächsten Runloop – der frisch hinzugefügte View ist dann bereit.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(pane.view) }
        return pane
    }

    /// Cmd+1…9: auf `n` Kacheln auffüllen – nur erweitern, nie schließen.
    func ensurePaneCount(_ n: Int) {
        while panes.count < n { addPane() }
    }

    /// Cmd+W: Shell beenden UND Kachel sofort entfernen. `terminate()` cancelt den
    /// Exit-Monitor, daher feuert hier kein `processTerminated`/`onClosed` – wir müssen
    /// die UI selbst aufräumen (im Gegensatz zum `exit`-Pfad, der über `onClosed` läuft).
    private func closePane(_ pane: TerminalPane) {
        pane.terminate()
        removePane(pane)
    }

    private func removePane(_ pane: TerminalPane) {
        guard let idx = panes.firstIndex(where: { $0 === pane }) else { return }
        // Auch wenn eine ANDERE (verdeckte) Kachel stirbt: das Grid darunter ändert
        // sich — Zoom beenden, damit der Nutzer den neuen Zustand sieht.
        setZoomedPane(nil)
        panes.remove(at: idx)
        updateTitlebarHUD()
        pane.container.removeFromSuperview()
        guard !panes.isEmpty else { window?.close(); return }
        updateFocusBorders()
        relayout(animated: true)
        window?.makeFirstResponder(panes[min(idx, panes.count - 1)].view)
    }

    /// Rahmen-Regeln: Fokus-Abstufung nur im sichtbaren Grid (≥2 Kacheln, kein
    /// Zoom); eine fenster-füllende Kachel (gezoomt oder einzige) trägt statt-
    /// dessen den vollen Akzent-Rahmen als Session-Kennung (`fillsWindow`).
    private func updateFocusBorders() {
        let multi = panes.count > 1 && zoomedPane == nil
        for pane in panes {
            pane.showsFocusBorder = multi
            pane.fillsWindow = (panes.count == 1) || (pane === zoomedPane)
        }
    }

    // MARK: - Zoom (#26)

    /// ⌘⏎: `pane` über das ganze Fenster ziehen bzw. zurück ins Grid. Kein Umbau
    /// des Grids — nur ein Merker, den relayout() als Sonderfall behandelt.
    /// Einzige Schreibstelle für `zoomedPane`; die Rahmen-Flags der Panes zieht
    /// das (an allen Aufrufstellen folgende) `updateFocusBorders()` nach.
    private func setZoomedPane(_ pane: TerminalPane?) {
        zoomedPane = pane
    }

    private func toggleZoom(_ pane: TerminalPane) {
        guard panes.count > 1 else { return }   // eine Kachel füllt das Fenster eh
        setZoomedPane(zoomedPane === pane ? nil : pane)
        updateFocusBorders()
        updateTitlebarHUD()
        relayout(animated: true)
        window?.makeFirstResponder(pane.view)
    }

    // MARK: - Titlebar-HUD (Session-Punkte + Zoom-Badge)

    private var titlebarHUD: NSTitlebarAccessoryViewController?
    /// Inhalts-Signatur der aktuellen HUD: Rebuild nur bei ECHTER Änderung.
    /// `onStyleChanged` feuert bei jeder Settings-Notification — ein Rebuild
    /// unter dem Cursor würde sonst gelegentlich Klicks auf die Punkte schlucken.
    private var hudSignature = ""

    /// Leiste rechts in der (transparenten) Titelleiste: ein klickbarer Punkt je
    /// Kachel in ihrer Akzentfarbe (Session-Identität auch im Zoom, wo das Grid
    /// verdeckt ist; Klick fokussiert die Pane) — plus die „⤢ Zoom ⌘⏎"-Pille,
    /// solange gezoomt ist. Accessory-VC statt Subview: kollidiert nicht mit
    /// Terminal-Content/Traffic-Lights. Wird bei jeder Stil-/Struktur-Änderung
    /// komplett neu aufgebaut — eine Handvoll kleiner Views, trivial billig.
    private func updateTitlebarHUD() {
        guard let window else { return }
        let showDots = panes.count > 1
        let showZoom = zoomedPane != nil

        let fr = window.firstResponder
        func isFocused(_ pane: TerminalPane) -> Bool {
            (fr === pane.view) || ((fr as? NSView)?.isDescendant(of: pane.view) ?? false)
        }
        let signature = panes.map {
            "\($0.effectiveAccent.srgbHexString ?? "-")\(isFocused($0) ? "*" : "")"
        }.joined(separator: ",") + "|zoom:\(showZoom)"
        if signature == hudSignature, titlebarHUD != nil || !(showDots || showZoom) { return }
        hudSignature = signature

        if let hud = titlebarHUD { hud.removeFromParent(); titlebarHUD = nil }
        guard showDots || showZoom else { return }

        var elements: [NSView] = []
        if showDots {
            for pane in panes {
                let focused = isFocused(pane)
                let dot = PaneDotView(color: pane.effectiveAccent, focused: focused) { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    self.focusPane(pane)
                }
                dot.toolTip = pane.currentDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }
                elements.append(dot)
            }
        }
        if showZoom, let zoomed = zoomedPane {
            elements.append(Self.makeZoomPill(accent: zoomed.effectiveAccent))
        }

        let spacing: CGFloat = 6
        let contentWidth = elements.reduce(0) { $0 + $1.frame.width }
            + spacing * CGFloat(max(0, elements.count - 1))
        let contentHeight = elements.map(\.frame.height).max() ?? 20
        // Wrapper gibt dem Accessory Höhe (≈ Titlebar) und rechts etwas Luft.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth + 10, height: contentHeight + 8))
        var x: CGFloat = 0
        for element in elements {
            element.frame.origin = NSPoint(x: x, y: ((wrapper.frame.height - element.frame.height) / 2).rounded())
            wrapper.addSubview(element)
            x += element.frame.width + spacing
        }

        let vc = NSTitlebarAccessoryViewController()
        vc.view = wrapper
        vc.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(vc)
        titlebarHUD = vc
    }

    private static func makeZoomPill(accent: NSColor) -> NSView {
        let label = NSTextField(labelWithString: "⤢ Zoom   ⌘⏎")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = accent
        label.sizeToFit()
        let pill = NSView(frame: NSRect(x: 0, y: 0,
                                        width: label.frame.width + 16,
                                        height: label.frame.height + 6))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        pill.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.cornerRadius = pill.frame.height / 2
        label.frame.origin = NSPoint(x: 8, y: 3)
        pill.addSubview(label)
        return pill
    }

    /// Klick auf einen Session-Punkt: Kachel fokussieren. Ist gerade eine ANDERE
    /// Kachel gezoomt, WANDERT der Zoom zur angeklickten — die Punkte sind im
    /// Zoom der Session-Umschalter, ein Rückfall ins Grid wäre ein Bruch.
    private func focusPane(_ pane: TerminalPane) {
        if let zoomed = zoomedPane, zoomed !== pane {
            setZoomedPane(pane)
            updateFocusBorders()
            relayout(animated: true)
        }
        window?.makeFirstResponder(pane.view)
        updateTitlebarHUD()
    }

    // MARK: - Grid

    /// Wählt die Reihenzahl für `n` Kacheln so, dass das Zellen-Seitenverhältnis dem Ziel
    /// am nächsten kommt. Bei Gleichstand gewinnt die kleinere Reihenzahl (= mehr Spalten,
    /// breiter). Für die Bewertung zählt die volle Spaltenzahl `ceil(n/rows)` (die schmalsten
    /// Zellen sind der limitierende Faktor).
    private func gridRows(for n: Int, width: CGFloat, height: CGFloat) -> Int {
        guard n > 1, width > 0, height > 0 else { return 1 }
        let targetLog = log(Self.idealCellAspect)
        var bestRows = 1
        var bestScore = CGFloat.greatestFiniteMagnitude
        for rows in 1...n {
            let cols = Int((Double(n) / Double(rows)).rounded(.up))
            let cellAspect = (width / CGFloat(cols)) / (height / CGFloat(rows))
            let score = abs(log(cellAspect) - targetLog)
            if score < bestScore - 1e-9 {   // strikt besser → Gleichstand behält weniger Reihen
                bestScore = score
                bestRows = rows
            }
        }
        return bestRows
    }

    /// Verteilt `n` Kacheln top-heavy auf `rows` Reihen (obere Reihen kriegen die Extra-Kachel).
    private func rowCounts(n: Int, rows: Int) -> [Int] {
        let base = n / rows, rem = n % rows
        return (0..<rows).map { $0 < rem ? base + 1 : base }
    }

    /// Setzt die Frames aller Kacheln gemäß aktuellem Grid. Kanten werden pixelgerundet,
    /// damit keine Lücken/Überlappungen durch Rundung entstehen; `gap` als dunkler Steg.
    private func relayout(animated: Bool = false) {
        let n = panes.count
        guard n > 0 else { return }
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let g = Self.gap
        let rows = gridRows(for: n, width: W, height: H)
        let counts = rowCounts(n: n, rows: rows)

        var frames: [NSRect] = []
        var cornerMasks: [CACornerMask] = []
        var cornerRadii: [CGFloat] = []
        frames.reserveCapacity(n)
        cornerMasks.reserveCapacity(n)
        cornerRadii.reserveCapacity(n)
        for r in 0..<rows {
            let yTop = (H * CGFloat(r) / CGFloat(rows)).rounded()
            let yBot = (H * CGFloat(r + 1) / CGFloat(rows)).rounded()
            let c = counts[r]
            for k in 0..<c {
                let xL = (W * CGFloat(k) / CGFloat(c)).rounded()
                let xR = (W * CGFloat(k + 1) / CGFloat(c)).rounded()
                let left   = xL + (k == 0 ? 0 : g / 2)
                let right  = xR - (k == c - 1 ? 0 : g / 2)
                let top    = yTop + (r == 0 ? 0 : g / 2)
                let bottom = yBot - (r == rows - 1 ? 0 : g / 2)
                frames.append(NSRect(x: left, y: top,
                                     width: max(0, right - left),
                                     height: max(0, bottom - top)))

                // Ecken-Regeln (AppKit flippt die Layer-Geometrie mit, isFlipped
                // → minY = oben):
                // - Obere Außenecken ECKIG: die Kachel sitzt unterhalb der
                //   Titlebar, die Fenster-Rundung ist dort schon vorbei — ein
                //   eigener Radius ergäbe die alte „Doppelabrundung".
                // - Untere Außenecken RUNDEN, mit Fenster-Radius: die Kachel
                //   liegt seit dem Wegfall des SwiftUI-Seitenpaddings IN der
                //   unteren Fenster-Rundung; eine eckige Akzent-Outline würde
                //   dort von der Fenster-Maske abgeschnitten.
                // - Innen-Steg-Ecken runden wie gehabt (8px).
                let topOuter = r == 0, bottomOuter = r == rows - 1
                let leftOuter = k == 0, rightOuter = k == c - 1
                var mask = CACornerMask()
                if !(topOuter && leftOuter)     { mask.insert(.layerMinXMinYCorner) }
                if !(topOuter && rightOuter)    { mask.insert(.layerMaxXMinYCorner) }
                mask.insert(.layerMinXMaxYCorner)
                mask.insert(.layerMaxXMaxYCorner)
                cornerMasks.append(mask)
                cornerRadii.append(bottomOuter ? Self.windowCornerRadius : 8)
            }
        }

        // Zoom-Sonderfall (#26): die gezoomte Kachel bekommt statt ihres Grid-Frames
        // die vollen Bounds und wird per Subview-Reorder über alle anderen gehoben;
        // deren Grid-Frames bleiben unverändert darunter liegen. Alle Ecken sind
        // dann Außenkanten → keine eigene Rundung, die Fenster-Rundung übernimmt.
        if let z = zoomedPane, let zi = panes.firstIndex(where: { $0 === z }) {
            frames[zi] = bounds
            // Oben eckig (unter der Titlebar), unten dem Fenster-Radius folgen.
            cornerMasks[zi] = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            cornerRadii[zi] = Self.windowCornerRadius
            addSubview(z.container)   // re-add hebt den View ans Ende der Subview-Liste (= nach vorn)
        }

        for (pane, mask) in zip(panes, cornerMasks) { pane.container.layer?.maskedCorners = mask }
        for (pane, radius) in zip(panes, cornerRadii) { pane.container.layer?.cornerRadius = radius }

        // Terminals in beiden Zweigen VOR dem Frame-Set auf die Zielgröße pinnen:
        // genau EIN PTY-Resize (+ Scrollback-Reflow) pro Umsortierung, egal wie
        // viele Zwischengrößen die Animation produziert.
        for (pane, frame) in zip(panes, frames) { pane.container.pinContent(forTargetSize: frame.size) }

        if animated && !isFirstLayout && window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for (pane, frame) in zip(panes, frames) { pane.container.animator().frame = frame }
            }
        } else {
            for (pane, frame) in zip(panes, frames) { pane.container.frame = frame }
        }
        isFirstLayout = false
    }
}

/// Klickbarer Session-Punkt in der Titlebar-HUD: trägt die Akzentfarbe seiner
/// Kachel, der fokussierte bekommt vollen Alpha + hellen Ring. Die Klickfläche
/// (18×18) ist bewusst größer als der gemalte Kreis (12×12).
private final class PaneDotView: NSView {
    private let onClick: () -> Void

    /// Ohne das frisst der Fenster-Drag den Klick: `isMovableByWindowBackground`
    /// + nicht-opaker View ⇒ AppKit deutet mouseDown als „Fenster anfassen".
    override var mouseDownCanMoveWindow: Bool { false }

    init(color: NSColor, focused: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        let circle = CALayer()
        circle.frame = CGRect(x: 3, y: 3, width: 12, height: 12)
        circle.cornerRadius = 6
        circle.backgroundColor = color.withAlphaComponent(focused ? 1.0 : 0.55).cgColor
        circle.borderWidth = focused ? 1.5 : 0
        circle.borderColor = NSColor.white.withAlphaComponent(0.8).cgColor
        layer?.addSublayer(circle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }
}

private extension NSColor {
    /// Strikter `#RRGGBB`-Parser für den OSC-Steuerkanal (#24). Bewusst eng:
    /// die Payload kommt aus untrusted Programm-Output — alles außer exakt
    /// 6 Hex-Ziffern (optionales `#`) wird verworfen statt geraten.
    convenience init?(srgbHex: String) {
        var hex = srgbHex
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit),
              let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    /// `#RRGGBB`-Form für den Session-Snapshot (Gegenstück zu `init(srgbHex:)`).
    var srgbHexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// Farbraumfester Vergleich über sRGB-Komponenten. NSColor-`==` vergleicht den
    /// Farbraum mit — eine aus UserDefaults geladene Farbe wäre nie `==` zu einer
    /// Palettenfarbe, obwohl sie visuell identisch ist (#18). Die Toleranz deckt
    /// Rundungsverluste der Konvertierung/Persistierung ab.
    func srgbMatches(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        let eps: CGFloat = 0.5 / 255
        return abs(a.redComponent - b.redComponent) < eps
            && abs(a.greenComponent - b.greenComponent) < eps
            && abs(a.blueComponent - b.blueComponent) < eps
            && abs(a.alphaComponent - b.alphaComponent) < eps
    }
}
