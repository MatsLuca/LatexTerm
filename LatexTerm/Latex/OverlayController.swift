import AppKit
import SwiftTerm

final class OverlayController {
    private weak var terminal: LatexTerminalView?
    private var views: [String: MathOverlayView] = [:]
    private var pending = false
    private var observer: NSObjectProtocol?

    init(terminal: LatexTerminalView) {
        self.terminal = terminal

        // Bei Einstellungsänderungen alle Overlays invalidieren und neu scannen
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

    private static let verticalSpan: CGFloat = 2.0
    private var lastFontPx: CGFloat = 0

    /// Entfernt alle existierenden Overlays (erzwingt komplettes Re-Render beim nächsten Scan).
    private func invalidateAll() {
        for (_, v) in views { v.removeFromSuperview() }
        views.removeAll()
        lastFontPx = 0
    }

    func rescan() {
        guard let terminal else { return }
        let settings = FormulaSettings.shared

        // Formeln deaktiviert → alle entfernen und abbrechen
        guard settings.formulasEnabled else {
            if !views.isEmpty { invalidateAll() }
            return
        }

        let host = terminal.overlay
        let term = terminal.getTerminal()
        let cell = terminal.cellSize()
        let rows = term.rows
        let fg = settings.formulaColor          // Formelfarbe aus Settings
        let bg = terminal.nativeBackgroundColor
        let fontPx = terminal.font.pointSize
        let scale = settings.formulaScale       // Formelgröße aus Settings
        let span = Self.verticalSpan
        let yPad = cell.height * (span - 1) / 2

        // Schriftgrößenänderung → alle Overlays invalidieren
        if abs(fontPx - lastFontPx) > 0.1 {
            invalidateAll()
            lastFontPx = fontPx
        }

        var seen = Set<String>()

        for vr in 0..<rows {
            guard let line = term.getLine(row: vr) else { continue }
            let text = line.translateToString(trimRight: false)
            for hit in LaTeXDetector.find(in: text) {
                let key = "\(vr)|\(hit.startCol)|\(hit.body)"
                seen.insert(key)
                let frame = CGRect(
                    x: CGFloat(hit.startCol) * cell.width,
                    y: CGFloat(vr) * cell.height - yPad,
                    width: CGFloat(hit.endCol - hit.startCol) * cell.width,
                    height: cell.height * span
                )
                if let v = views[key] {
                    if v.frame != frame { v.frame = frame }
                } else {
                    let v = MathOverlayView(
                        latex: hit.body,
                        displayMode: false,
                        fontPx: fontPx,
                        baseRowHeight: cell.height,
                        foreground: fg,
                        background: bg,
                        scale: scale
                    )
                    v.frame = frame
                    host.addSubview(v)
                    views[key] = v
                }
            }
        }

        for (k, v) in views where !seen.contains(k) {
            v.removeFromSuperview()
            views.removeValue(forKey: k)
        }
    }
}
