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
        term.nativeBackgroundColor = NSColor(red: 23/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1.0)
        term.caretColor = NSColor(red: 232/255.0, green: 94/255.0, blue: 62/255.0, alpha: 1.0)
        term.getTerminal().setCursorStyle(.steadyBlock)
        term.extraLineSpacing = settings.extraLineSpacing  // aus UserDefaults

        self.view = term
        self.controller = OverlayController(terminal: term)
        super.init()

        term.processDelegate = self
        term.onRangeChanged = { [weak controller] in controller?.scheduleRescan() }
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

        // Auf Zeilenabstand-Änderungen reagieren
        settingsObserver = NotificationCenter.default.addObserver(
            forName: FormulaSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak term] _ in
            term?.extraLineSpacing = FormulaSettings.shared.extraLineSpacing
        }
    }

    deinit {
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
    }

    /// Beendet die Shell (SIGTERM). Das Prozess-Ende läuft über `processTerminated`
    /// → `onClosed` und entfernt die Kachel auf demselben Pfad wie ein `exit`.
    func terminate() {
        view.terminate()
    }

    /// Startet die Login-Shell des Users im Home-Verzeichnis.
    func start() {
        let shell = Self.userShell()
        let shellIdiom = "-" + (shell as NSString).lastPathComponent
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.homeDirectoryForCurrentUser.path)
        view.startProcess(executable: shell, execName: shellIdiom)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        controller.scheduleRescan()
    }
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        source.window?.title = title.isEmpty ? "LatexTerm" : title
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
        var result: UnsafeMutablePointer<passwd>? = UnsafeMutablePointer<passwd>.allocate(capacity: 1)
        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 {
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

    /// Lücke (Steg) zwischen den Kacheln in Punkten.
    private static let gap: CGFloat = 8

    /// Farbe des Stegs – etwas heller als der Terminal-Hintergrund (#171414), damit die
    /// Lücke zwischen den Kacheln sichtbar wird. Scheint nur in den `gap`-Bereichen durch.
    private static let gapColor = NSColor(red: 48/255.0, green: 43/255.0, blue: 43/255.0, alpha: 1.0)

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

    override var isFlipped: Bool { true }   // Reihe 0 oben

    // Frame-Layout: SwiftUI/Autoresizing ändert nur unsere Größe – darauf neu kacheln.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    @discardableResult
    func addPane() -> TerminalPane {
        let pane = TerminalPane()
        pane.onClosed = { [weak self] p in self?.removePane(p) }
        pane.onSplitRequested = { [weak self] _ in self?.addPane() }
        pane.onCloseRequested = { [weak self] p in self?.closePane(p) }
        pane.onEnsurePaneCount = { [weak self] n in self?.ensurePaneCount(n) }
        panes.append(pane)
        addSubview(pane.view)
        pane.start()
        relayout()
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
        relayout()
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
    private func relayout() {
        let n = panes.count
        guard n > 0 else { return }
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let g = Self.gap
        let rows = gridRows(for: n, width: W, height: H)
        let counts = rowCounts(n: n, rows: rows)

        var idx = 0
        for r in 0..<rows {
            // Reihen-Kanten (gleich hoch), gerundet.
            let yTop = (H * CGFloat(r) / CGFloat(rows)).rounded()
            let yBot = (H * CGFloat(r + 1) / CGFloat(rows)).rounded()
            let c = counts[r]
            for k in 0..<c {
                let xL = (W * CGFloat(k) / CGFloat(c)).rounded()
                let xR = (W * CGFloat(k + 1) / CGFloat(c)).rounded()
                // Halbe Lücke pro Innenkante → außen bündig, innen voller `gap`.
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
}
