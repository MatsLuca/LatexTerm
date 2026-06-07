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

    /// Voller Rescan: alle Zeilen neu parsen. Für Settings/Font/Resize/Initial, wo sich
    /// Geometrie oder Konfiguration ändern und der Pro-Zeile-Cache nicht greift.
    func scheduleRescan() {
        needsFullScan = true
        armRescan()
    }

    /// Inkrementeller Rescan: nur `startY..endY` gilt als „dirty". Die Werte sind
    /// viewport-relativ (SwiftTerm `getUpdateRange`), aber **nur ein Hint** – die
    /// eigentliche Wahrheit ist der Content-Hash pro Zeile (s. `rescan()`), weil
    /// SwiftTerm den Bereich über zwei Pfade in inkonsistenten Koordinaten meldet.
    func scheduleRescan(dirtyStart startY: Int, dirtyEnd endY: Int) {
        dirtyStart = min(dirtyStart, min(startY, endY))
        dirtyEnd   = max(dirtyEnd,   max(startY, endY))
        armRescan()
    }

    private func armRescan() {
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

    // Span 1.0: jede *Inline*-Formel wird in ihre eigene Zeile skaliert und ragt nie in
    // Nachbarzeilen. Große Inline-Formeln werden klein – per Hover gibt's den Großmodus.
    // (Mehrzeilige $$-Blöcke spannen dagegen ihren ganzen Quell-Zeilenbereich, s. blockBox.)
    private static let verticalSpan: CGFloat = 1.0
    private var lastFontPx: CGFloat = 0
    private var lastConfigJSON: String?
    private var pendingClear = false
    private var lastEmpty = false

    // Inkrementelle Detection (#2). Pro Viewport-Zeile werden die Inline-Treffer
    // zusammen mit einem Content-Hash gecacht; unveränderte Zeilen überspringen den
    // `LaTeXDetector.find`-Parse. `needsFullScan` erzwingt einen kompletten Durchlauf
    // (Settings/Font/Resize/Initial), `dirtyStart/End` sammelt den gemeldeten
    // Änderungsbereich über das Debounce-Fenster. `lastItemsJSON` erlaubt, den
    // `sync()`-Call (IPC zur WebView) zu überspringen, wenn sich nichts geändert hat.
    private var rowCache: [Int: (hash: Int, hits: [LaTeXHit])] = [:]
    private var needsFullScan = true
    private var dirtyStart = Int.max
    private var dirtyEnd = -1
    private var lastItemsJSON: String?

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
        lastItemsJSON = nil
        rowCache.removeAll()
        needsFullScan = true
    }

    func rescan() {
        guard let terminal else { return }
        let settings = FormulaSettings.shared

        // Dirty-Zustand dieses Durchlaufs übernehmen und zurücksetzen (ein während des
        // Scans erneut gemeldeter Bereich armt sauber den nächsten Durchlauf).
        let full = needsFullScan
        needsFullScan = false
        let dStart = dirtyStart, dEnd = dirtyEnd
        dirtyStart = Int.max; dirtyEnd = -1

        // Inhalt ändert sich → laufende Vorschau schließen (Hover triggert neu)
        preview.hide()

        // Formeln deaktiviert → Layer leeren und abbrechen
        guard settings.formulasEnabled else {
            if !lastEmpty { layer.run("clearAll();"); lastEmpty = true }
            hitboxes.removeAll()
            rowCache.removeAll()
            lastItemsJSON = nil
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

        // Schriftgröße geändert → kompletter Neuaufbau (KaTeX bei neuer Größe re-rendern).
        // Der Pro-Zeile-Cache bleibt gültig: `find()`-Treffer hängen nur am Text, nicht an
        // der Geometrie – nur die abgeleiteten Item-Positionen ändern sich.
        var clear = pendingClear
        pendingClear = false
        if abs(fontPx - lastFontPx) > 0.1 {
            clear = true
            lastFontPx = fontPx
        }

        // Absoluter Scrollback-Offset: Keys an die absolute Buffer-Zeile binden,
        // damit Scrollen Overlays nur neu positioniert statt sie neu zu erzeugen.
        let yDisp = term.buffer.yDisp

        // Sichtbares Grid als Strings einlesen (für `findBlocks` und Geometrie). Leere Zellen
        // liefern als code 0 ein NULL-Zeichen (\u{0}), das KaTeX im Strict-Mode ablehnt; 1:1
        // in ein Leerzeichen wandeln – erhält die Spalten-Positionen für startCol/endCol.
        // Pro Zeile zugleich das `isWrapped`-Flag erfassen (eine getLine-Runde):
        // markiert, dass die Zeile die Fortsetzung der vorigen ist → für die
        // Rekonstruktion logischer (weich-umgebrochener) Zeilen, s.u.
        var rowTexts: [String] = []; rowTexts.reserveCapacity(rows)
        var wrappedFlags = [Bool](repeating: false, count: rows)
        for vr in 0..<rows {
            let line = term.getLine(row: vr)
            rowTexts.append(line?
                .translateToString(trimRight: false)
                .replacingOccurrences(of: "\u{0}", with: " ") ?? "")
            wrappedFlags[vr] = line?.isWrapped ?? false
        }

        var items: [[String: Any]] = []
        hitboxes.removeAll()
        var scanned = 0

        // 1) Mehrzeilige Display-Blöcke ($$..$$, \[..\]): echtes displayMode, das Overlay
        //    spannt den ganzen Quell-Zeilenbereich – der Platz ist im Text schon reserviert.
        //    `findBlocks` läuft direkt auf den Strings (keine Grid→String-Rückwandlung mehr).
        //    Block-berührte Zeilen werden maskiert, damit die Inline-Erkennung sie nicht
        //    doppelt trifft; diese Zeilen werden stets frisch gescannt (nicht gecacht).
        var blockMasked: [Int: [Character]] = [:]
        for b in LaTeXDetector.findBlocks(in: rowTexts) {
            let box = blockBox(b, rowTexts: rowTexts, cell: cell)
            let key = "B|\(b.startRow + yDisp)|\(b.startCol)|\(b.body)"
            items.append([
                "key": key,
                "x": box.minX, "y": box.minY, "w": box.width, "h": box.height,
                "latex": b.body,
                "display": true
            ])
            hitboxes[key] = (rect: box, latex: b.body)
            for r in b.startRow...b.endRow {
                var chars = blockMasked[r] ?? Array(rowTexts[r])
                let from = (r == b.startRow) ? b.startCol : 0
                let to = (r == b.endRow) ? min(b.endCol, chars.count) : chars.count
                var c = from
                while c < to { chars[c] = " "; c += 1 }
                blockMasked[r] = chars
            }
        }

        // 2) Inline-Formeln. Aufeinanderfolgende weich-umgebrochene Zeilen werden zu einer
        //    logischen Zeile zusammengefasst (`findWrapped`), damit eine über den Umbruch
        //    laufende Formel erkannt wird (#1). Der Pro-Zeile-Cache (#2) bleibt für den
        //    Normalfall erhalten: nur echte Mehrzeilen-Gruppen werden frisch via findWrapped
        //    gescannt, Einzelzeilen behalten den Cache-Pfad (Viewport-Zeile + Content-Hash;
        //    Range nur ein Hint, der Hash ist die Wahrheit).

        // Fortsetzungs-Flags: continues[vr] ⇒ vr setzt vr-1 fort (= isWrapped). continues[0]
        // gilt als false. An Block-Grenzen brechen, damit Block-Zeilen nie in eine logische
        // Gruppe geraten – sie laufen weiter über den Block-/Frisch-Pfad.
        var continues = [Bool](repeating: false, count: rows)
        if rows > 1 { for vr in 1..<rows { continues[vr] = wrappedFlags[vr] } }
        for r in blockMasked.keys {
            if r < rows { continues[r] = false }
            if r + 1 < rows { continues[r + 1] = false }
        }

        // Emittiert eine (ggf. über mehrere Rows laufende) Formel. Mehrzeiler: in das
        // breiteste Quell-Segment rendern (geringste Skalierung = beste Lesbarkeit); die
        // übrigen Segmente mit einem reinen Hintergrund-Item (leeres latex) maskieren, damit
        // kein roher Fragment-Text durchscheint. displayMode wird durchgereicht.
        func emitFormula(startRow: Int, startCol: Int, endRow: Int, endCol: Int,
                         body: String, display: Bool) {
            let key = "\(startRow + yDisp)|\(startCol)|\(body)"
            func box(row: Int, fromCol: Int, toCol: Int) -> CGRect {
                CGRect(x: CGFloat(fromCol) * cell.width,
                       y: CGFloat(row) * cell.height - yPad,
                       width: CGFloat(toCol - fromCol) * cell.width,
                       height: cell.height * span)
            }
            func appendItem(_ k: String, _ f: CGRect, _ latex: String, _ disp: Bool) {
                items.append([
                    "key": k, "x": f.minX, "y": f.minY, "w": f.width, "h": f.height,
                    "latex": latex, "display": disp
                ])
            }
            if startRow == endRow {
                let f = box(row: startRow, fromCol: startCol, toCol: endCol)
                appendItem(key, f, body, display)
                hitboxes[key] = (rect: f, latex: body)   // grobe Hitbox; per onBounds verfeinert
                return
            }
            var segs: [(row: Int, from: Int, to: Int)] = []
            for r in startRow...endRow {
                let from = (r == startRow) ? startCol : 0
                let to   = (r == endRow)   ? endCol   : rowTexts[r].count
                segs.append((r, from, to))
            }
            let renderIdx = segs.indices.max {
                (segs[$0].to - segs[$0].from) < (segs[$1].to - segs[$1].from)
            } ?? 0
            for (i, seg) in segs.enumerated() {
                let f = box(row: seg.row, fromCol: seg.from, toCol: seg.to)
                if i == renderIdx {
                    appendItem(key, f, body, display)
                    hitboxes[key] = (rect: f, latex: body)
                } else {
                    appendItem("M|\(startRow + yDisp)|\(startCol)|\(seg.row)", f, "", false)
                }
            }
        }

        var vr = 0
        while vr < rows {
            var groupEnd = vr
            while groupEnd + 1 < rows, continues[groupEnd + 1] { groupEnd += 1 }

            if groupEnd == vr {
                // Einzelzeile: Cache-Pfad (bzw. block-maskierte Zeile frisch) wie bisher.
                let hits: [LaTeXHit]
                if let masked = blockMasked[vr] {
                    hits = LaTeXDetector.find(in: String(masked)); rowCache[vr] = nil; scanned += 1
                } else {
                    let text = rowTexts[vr]; let h = text.hashValue
                    let inRange = vr >= dStart && vr <= dEnd
                    if full || inRange || rowCache[vr]?.hash != h {
                        hits = LaTeXDetector.find(in: text); rowCache[vr] = (hash: h, hits: hits); scanned += 1
                    } else { hits = rowCache[vr]!.hits }
                }
                for hit in hits {
                    emitFormula(startRow: vr, startCol: hit.startCol, endRow: vr,
                                endCol: hit.endCol, body: hit.body, display: hit.displayMode)
                }
            } else {
                // Mehrzeilen-Gruppe: immer frisch via findWrapped (Wraps sind selten/billig).
                let slice = Array(rowTexts[vr...groupEnd])
                var sliceCont = [Bool](repeating: true, count: slice.count); sliceCont[0] = false
                for r in vr...groupEnd { rowCache[r] = nil }   // nicht einzeln gecacht
                scanned += slice.count
                for wh in LaTeXDetector.findWrapped(rows: slice, continues: sliceCont) {
                    emitFormula(startRow: vr + wh.startRow, startCol: wh.startCol,
                                endRow: vr + wh.endRow, endCol: wh.endCol,
                                body: wh.body, display: wh.displayMode)
                }
            }
            vr = groupEnd + 1
        }

        let configJSON = Self.json([
            "fontPx": fontPx,
            "cellH": cell.height,
            "fg": Self.css(fg),
            "bg": Self.css(bg),
            "userScale": scale
        ])
        let itemsJSON = Self.json(items)

        // sync() schickt JSON über die Prozessgrenze in die WebView. Nur senden, wenn nötig:
        // bei clear/Config-Änderung immer, sonst nur wenn sich die Items wirklich geändert
        // haben (spart IPC bei schnellem Nicht-Formel-Output, z.B. `yes`).
        let configChanged = clear || configJSON != lastConfigJSON
        var js = ""
        if clear { js += "clearAll();" }
        if configChanged { js += "setConfig(\(configJSON));"; lastConfigJSON = configJSON }
        if configChanged || itemsJSON != lastItemsJSON { js += "sync(\(itemsJSON));" }
        if !js.isEmpty { layer.run(js); lastItemsJSON = itemsJSON }

        lastEmpty = items.isEmpty

        #if DEBUG
        if ProcessInfo.processInfo.environment["LATEXTERM_SCAN_LOG"] != nil {
            NSLog("[LatexTerm] rescan: %d/%d Zeilen geparst (full=%@ dirty=%d…%d blocks=%d synced=%@)",
                  scanned, rows, full ? "y" : "n", dStart, dEnd, blockMasked.isEmpty ? 0 : 1,
                  js.contains("sync(") ? "y" : "n")
        }
        #endif
    }

    // MARK: - Block-Geometrie

    /// Enge Pixel-Box um die Quellzellen eines Blocks: min/max belegte Spalte über alle
    /// Block-Zeilen, volle Zeilenhöhe von Start- bis Schlusszeile (gibt der Display-Formel
    /// echten vertikalen Platz, sodass sie nicht in Nachbarzeilen skaliert werden muss).
    private func blockBox(_ b: LaTeXBlock, rowTexts: [String], cell: CGSize) -> CGRect {
        var minCol = Int.max, maxCol = 0
        for r in b.startRow...b.endRow {
            let chars = Array(rowTexts[r])
            let from = (r == b.startRow) ? b.startCol : 0
            let to = (r == b.endRow) ? min(b.endCol, chars.count) : chars.count
            var c = from
            while c < to {
                if chars[c] != " " { minCol = min(minCol, c); maxCol = max(maxCol, c) }
                c += 1
            }
        }
        if minCol == Int.max { minCol = b.startCol; maxCol = b.startCol }
        return CGRect(
            x: CGFloat(minCol) * cell.width,
            y: CGFloat(b.startRow) * cell.height,
            width: CGFloat(maxCol - minCol + 1) * cell.width,
            height: CGFloat(b.endRow - b.startRow + 1) * cell.height
        )
    }

    // MARK: - JSON / Farb-Helfer

    // `.sortedKeys`: deterministische Schlüsselreihenfolge, damit der String-Vergleich
    // von Config/Items (zum Überspringen unnötiger sync()-Calls) verlässlich ist.
    private static func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
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
