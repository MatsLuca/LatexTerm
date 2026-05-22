import AppKit
import SwiftTerm

final class OverlayController {
    private weak var terminal: LatexTerminalView?
    private let layer = FormulaLayer()
    private var pending = false
    private var observer: NSObjectProtocol?

    init(terminal: LatexTerminalView) {
        self.terminal = terminal

        let host = terminal.overlay
        layer.frame = host.bounds
        host.addSubview(layer)

        // Hover-Vorschau ("Ansichts-Modus"): große Formel beim Überfahren
        host.onMouseMoved = { [weak self] p in self?.handleHover(p) }
        host.onMouseExited = { [weak self] in self?.preview.hide() }

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
    }

    func scheduleRescan() {
        if pending { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.pending = false
            self?.rescan()
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
    }

    private func handleHover(_ p: NSPoint) {
        guard let terminal, FormulaSettings.shared.formulasEnabled else { preview.hide(); return }
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
