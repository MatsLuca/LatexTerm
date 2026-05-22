import AppKit
import SwiftTerm

final class OverlayController {
    private weak var terminal: LatexTerminalView?
    private let layer = FormulaLayer()
    private var pending = false
    private var observer: NSObjectProtocol?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    init(terminal: LatexTerminalView) {
        self.terminal = terminal

        let host = terminal.overlay
        layer.frame = host.bounds
        host.addSubview(layer)

        // Hover-Vorschau ("Ansichts-Modus"): große Formel beim Überfahren
        host.onMouseMoved = { [weak self] p in self?.handleHover(p) }
        host.onMouseExited = { [weak self] in
            guard let self, !self.preview.pinned else { return }
            self.preview.hide()
        }

        // Klick auf eine Formel pinnt die Vorschau (mit Copy-Buttons); Klick daneben
        // bzw. Esc schließt sie wieder. Klicks außerhalb von Formeln gehen normal ans
        // Terminal (Selektion/Scroll) – wir schlucken nur Treffer auf einer Formel.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleMouseDown(event) ?? event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }

        // Echte gerenderte Bounds aus der WebView → enge Hitboxen
        layer.onBounds = { [weak self] tight in self?.applyTightBounds(tight) }

        // Bei Einstellungsänderungen alles neu aufbauen (Farbe/Scale/Spacing) und neu scannen
        observer = NotificationCenter.default.addObserver(
            forName: FormulaSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateAll()
            self?.scheduleRescan()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func scheduleRescan() {
        if pending { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.pending = false
            self?.rescan()
        }
    }

    // MARK: - Scroll

    // Scrollen ist kein "Vorgang", sondern eine schnelle Folge statischer Zustände.
    // Würden wir die Overlays bei jedem Zwischenschritt neu setzen, flackert die
    // out-of-process WebView (Neupositionieren + Divs an den Rändern an/aus).
    // Stattdessen: beim ersten Scroll-Event den Layer ausblenden und einen Idle-Timer
    // armen. Solange Events fließen (inkl. Trackpad-Momentum) bleibt er aus. Erst wenn
    // ~90 ms keins mehr kommt = "wieder statisch", wird neu positioniert und – nach dem
    // ersten Bounds-Report, also wenn die WebView die neuen Positionen gezeichnet hat –
    // wieder eingeblendet (kein Aufpoppen an falscher Stelle).
    private var isScrolling = false
    private var scrollIdleWork: DispatchWorkItem?
    private var revealOnNextBounds = false
    private static let scrollIdle: TimeInterval = 0.15

    func scheduleReposition() {
        if !isScrolling {
            isScrolling = true
            revealOnNextBounds = false   // evtl. ausstehendes Reveal abbrechen
            preview.hide()
            layer.isHidden = true
        }
        scrollIdleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scrollSettled() }
        scrollIdleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrollIdle, execute: work)
    }

    private func scrollSettled() {
        isScrolling = false
        revealOnNextBounds = true
        rescan()   // positioniert die Divs neu, Layer noch versteckt
        // Fallback: ohne sichtbare Formel feuert onBounds nicht – dann trotzdem
        // einblenden (leerer Layer, unkritisch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.revealOnNextBounds else { return }
            self.revealOnNextBounds = false
            self.layer.isHidden = false
        }
    }

    // MARK: - Privat

    // Span 1.0: jede Formel wird in ihre eigene Zeile skaliert und ragt nie in
    // Nachbarzeilen. Große Formeln werden klein – per Hover gibt's den Großmodus.
    private static let verticalSpan: CGFloat = 1.0
    private var lastFontPx: CGFloat = 0
    private var lastConfigJSON: String?
    private var pendingClear = false
    private var lastEmpty = false

    // Hover-Vorschau. Hitbox je Formel-Key: startet grob (Quelltext-Box) und wird
    // durch die echten gerenderten Bounds aus der WebView eng nachgezogen.
    private let preview = FormulaPreview()
    private var hitboxes: [String: (rect: CGRect, latex: String)] = [:]
    private static let hoverPad: CGFloat = 2   // kleine Toleranz fürs Treffen

    /// Ersetzt grobe Hitboxen durch die echten gerenderten Pixel-Bounds.
    private func applyTightBounds(_ tight: [String: CGRect]) {
        for (key, rect) in tight where hitboxes[key] != nil {
            hitboxes[key]!.rect = rect.insetBy(dx: -Self.hoverPad, dy: -Self.hoverPad)
        }
        // Nach dem Settle-Rescan: jetzt sind die neuen Positionen gezeichnet → einblenden.
        if revealOnNextBounds {
            revealOnNextBounds = false
            layer.isHidden = false
        }
    }

    /// Klick: liegt er in einer Formel-Hitbox → pinnen und schlucken (kein Terminal-
    /// Select). Klick im gepinnten Panel → durchlassen (Buttons). Sonst → ggf. schließen.
    private func handleMouseDown(_ event: NSEvent) -> NSEvent? {
        guard let terminal, FormulaSettings.shared.formulasEnabled,
              let win = terminal.window, event.window === win else { return event }
        let p = terminal.overlay.convert(event.locationInWindow, from: nil)

        if preview.pinned, preview.frame.contains(p) { return event }   // Button-Klick

        for hb in hitboxes.values where hb.rect.contains(p) {
            preview.show(
                latex: hb.latex,
                over: hb.rect,
                in: terminal.overlay,
                fontPx: terminal.font.pointSize,
                foreground: FormulaSettings.shared.formulaColor,
                background: terminal.nativeBackgroundColor
            )
            preview.pin()
            return nil   // Treffer → schlucken, damit keine Terminal-Selektion startet
        }

        if preview.pinned { preview.hide() }
        return event
    }

    /// Esc schließt ein gepinntes Panel (und schluckt die Taste nur dann).
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if preview.pinned, event.keyCode == 53 { preview.hide(); return nil }
        return event
    }

    private func handleHover(_ p: NSPoint) {
        guard let terminal, FormulaSettings.shared.formulasEnabled else { preview.hide(); return }
        if preview.pinned { return }   // gepinnt: Hover ändert nichts
        for hb in hitboxes.values where hb.rect.contains(p) {
            preview.show(
                latex: hb.latex,
                over: hb.rect,
                in: terminal.overlay,
                fontPx: terminal.font.pointSize,
                foreground: FormulaSettings.shared.formulaColor,
                background: terminal.nativeBackgroundColor
            )
            return
        }
        preview.hide()
    }

    /// Erzwingt kompletten Neuaufbau aller Formeln beim nächsten Scan.
    private func invalidateAll() {
        pendingClear = true
        lastFontPx = 0
        lastConfigJSON = nil
    }

    func rescan() {
        guard let terminal else { return }
        let settings = FormulaSettings.shared

        // Inhalt ändert sich → laufende Vorschau schließen (Hover triggert neu)
        preview.hide()

        // Formeln deaktiviert → Layer leeren und abbrechen
        guard settings.formulasEnabled else {
            if !lastEmpty { layer.run("clearAll();"); lastEmpty = true }
            hitboxes.removeAll()
            return
        }

        let term = terminal.getTerminal()
        let cell = terminal.cellSize()
        let rows = term.rows
        let fg = settings.formulaColor
        let bg = terminal.nativeBackgroundColor
        let fontPx = terminal.font.pointSize
        let scale = settings.formulaScale
        let span = Self.verticalSpan
        let yPad = cell.height * (span - 1) / 2

        // Schriftgröße geändert → kompletter Neuaufbau (KaTeX bei neuer Größe re-rendern)
        var clear = pendingClear
        pendingClear = false
        if abs(fontPx - lastFontPx) > 0.1 {
            clear = true
            lastFontPx = fontPx
        }

        // Absoluter Scrollback-Offset: Keys an die absolute Buffer-Zeile binden,
        // damit Scrollen Overlays nur neu positioniert statt sie neu zu erzeugen.
        let yDisp = term.buffer.yDisp

        var items: [[String: Any]] = []
        hitboxes.removeAll()
        for vr in 0..<rows {
            guard let line = term.getLine(row: vr) else { continue }
            // Leere Grid-Zellen liefern als code 0 ein NULL-Zeichen (\u{0}), das KaTeX
            // im Strict-Mode mit "Unexpected character" ablehnt. 1:1 in ein Leerzeichen
            // wandeln – erhält die Spalten-Positionen für startCol/endCol.
            let text = line.translateToString(trimRight: false)
                .replacingOccurrences(of: "\u{0}", with: " ")
            for hit in LaTeXDetector.find(in: text) {
                let key = "\(vr + yDisp)|\(hit.startCol)|\(hit.body)"
                let frame = CGRect(
                    x: CGFloat(hit.startCol) * cell.width,
                    y: CGFloat(vr) * cell.height - yPad,
                    width: CGFloat(hit.endCol - hit.startCol) * cell.width,
                    height: cell.height * span
                )
                items.append([
                    "key": key,
                    "x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height,
                    "latex": hit.body,
                    "display": false
                ])
                // grobe Hitbox; wird per onBounds eng nachgezogen
                hitboxes[key] = (rect: frame, latex: hit.body)
            }
        }

        let configJSON = Self.json([
            "fontPx": fontPx,
            "cellH": cell.height,
            "fg": Self.css(fg),
            "bg": Self.css(bg),
            "userScale": scale
        ])

        var js = ""
        if clear { js += "clearAll();" }
        if clear || configJSON != lastConfigJSON {
            js += "setConfig(\(configJSON));"
            lastConfigJSON = configJSON
        }
        js += "sync(\(Self.json(items)));"
        layer.run(js)

        lastEmpty = items.isEmpty
    }

    // MARK: - JSON / Farb-Helfer

    private static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    private static func css(_ c: NSColor) -> String {
        guard let rgb = c.usingColorSpace(.sRGB) else { return "transparent" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return "rgb(\(r),\(g),\(b))"
    }
}
