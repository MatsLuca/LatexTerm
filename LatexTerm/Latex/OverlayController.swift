import AppKit
import SwiftTerm

final class OverlayController {
    private weak var terminal: LatexTerminalView?
    private var views: [String: MathOverlayView] = [:]
    private var pending = false

    init(terminal: LatexTerminalView) {
        self.terminal = terminal
    }

    func scheduleRescan() {
        if pending { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.pending = false
            self?.rescan()
        }
    }

    private static let verticalSpan: CGFloat = 2.0
    private var lastFontPx: CGFloat = 0

    func rescan() {
        guard let terminal else { return }
        let host = terminal.overlay
        let term = terminal.getTerminal()
        let cell = terminal.cellSize()
        let rows = term.rows
        let fg = terminal.nativeForegroundColor
        let bg = terminal.nativeBackgroundColor
        let fontPx = terminal.font.pointSize
        let span = Self.verticalSpan
        let yPad = cell.height * (span - 1) / 2

        if abs(fontPx - lastFontPx) > 0.1 {
            for (_, v) in views { v.removeFromSuperview() }
            views.removeAll()
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
                        background: bg
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
