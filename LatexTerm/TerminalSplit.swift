import AppKit
import SwiftTerm

/// Eine einzelne Terminal-Kachel: eigener Shell-Prozess, eigener OverlayController
/// (= eigene LaTeX-Overlays). Mehrere Panes leben nebeneinander in `TerminalSplitView`.
/// Übernimmt die Rolle, die früher der `TerminalContainer.Coordinator` für das einzelne
/// Terminal hatte (Process-Delegate + Settings-Observer + Shell-Spawn).
final class TerminalPane: NSObject, LocalProcessTerminalViewDelegate {

    let view: LatexTerminalView
    private let controller: OverlayController
    private var settingsObserver: NSObjectProtocol?

    /// Shell-Prozess beendet → diese Pane soll entfernt werden.
    var onClosed: ((TerminalPane) -> Void)?
    /// Cmd+T in dieser Pane → neue Pane anlegen.
    var onSplitRequested: ((TerminalPane) -> Void)?
    /// Cmd+W in dieser Pane → schließen.
    var onCloseRequested: ((TerminalPane) -> Void)?
    /// Cmd+1…9 in dieser Pane → auf so viele Kacheln auffüllen.
    var onEnsurePaneCount: ((Int) -> Void)?

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

        // Kachel-Styling mit abgerundeten Ecken
        term.wantsLayer = true
        term.layer?.cornerRadius = 8
        term.layer?.masksToBounds = true
        term.layer?.borderWidth = 0
        term.layer?.borderColor = settings.accentColor.withAlphaComponent(0.65).cgColor
        
        // Kachel ist standardmäßig inaktiv (abgedunkelt), bis sie fokussiert wird
        term.alphaValue = 0.65

        self.view = term
        self.controller = OverlayController(terminal: term)
        super.init()

        // Fokus-Visualisierung
        term.onFocusChanged = { [weak self, weak term] focused in
            guard let term else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                term.animator().alphaValue = focused ? 1.0 : 0.65
                term.layer?.borderColor = FormulaSettings.shared.accentColor.withAlphaComponent(0.65).cgColor
                term.layer?.borderWidth = focused ? 1.5 : 0
            }
            // Fokuswechsel übernimmt den zuletzt von DIESER Shell gemeldeten Titel (#21).
            if focused { self?.applyStoredTitle() }
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

        // Auf Einstellungs-Änderungen reagieren
        settingsObserver = NotificationCenter.default.addObserver(
            forName: FormulaSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self, weak term] note in
            let settings = FormulaSettings.shared
            term?.extraLineSpacing = settings.extraLineSpacing
            term?.caretColor = settings.accentColor
            term?.layer?.borderColor = settings.accentColor.withAlphaComponent(0.65).cgColor

            // Nur wenn der Modus selbst eingeschaltet wurde, sofort analysieren —
            // sonst stieße jede (adaptiv gesetzte) accentColor-Änderung gleich die
            // nächste Analyse an.
            let change = note.userInfo?[FormulaSettings.changeKey] as? FormulaSettings.Change
            if change == .isAdaptiveAccent, settings.isAdaptiveAccent {
                self?.scheduleContrastAnalysis()
            }
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
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
        if contrastPending { return }

        // Nur das fokussierte Terminal darf die globale Akzentfarbe anpassen!
        guard isFocused else { return }

        contrastPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self else { return }
            self.contrastPending = false
            self.analyzeContrast()
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
    private let vibrancyView = NSVisualEffectView()
    private var isFirstLayout = true

    /// Lücke (Steg) zwischen den Kacheln in Punkten.
    private static let gap: CGFloat = 8

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
        addPane()   // erste Kachel
    }

    required init?(coder: NSCoder) { fatalError() }

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
        panes.append(pane)
        addSubview(pane.view)
        pane.start(in: directory)
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
        panes.remove(at: idx)
        pane.view.removeFromSuperview()
        guard !panes.isEmpty else { window?.close(); return }
        relayout(animated: true)
        window?.makeFirstResponder(panes[min(idx, panes.count - 1)].view)
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

        let useAnim = animated && !isFirstLayout && window != nil

        if useAnim {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                
                var idx = 0
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
                        
                        let targetFrame = NSRect(x: left, y: top,
                                                 width: max(0, right - left),
                                                 height: max(0, bottom - top))
                        panes[idx].view.animator().frame = targetFrame
                        idx += 1
                    }
                }
            }, completionHandler: nil)
        } else {
            var idx = 0
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
                    
                    panes[idx].view.frame = NSRect(x: left, y: top,
                                                   width: max(0, right - left),
                                                   height: max(0, bottom - top))
                    idx += 1
                }
            }
        }
        isFirstLayout = false
    }
}

private extension NSColor {
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
