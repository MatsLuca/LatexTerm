import AppKit
import os

/// Kachelt beliebig viele Kacheln (`any Pane`) in einem automatischen Grid. Cmd+T hängt eine
/// Kachel an, Cmd+W/`exit` entfernt eine; bei jeder Änderung wird neu gekachelt. Die
/// Grid-Form (Reihen × Spalten) wird abhängig von Fensterbreite UND -höhe gewählt, sodass
/// die Zellen einem Ziel-Seitenverhältnis möglichst nahekommen. Reihen sind gleich hoch,
/// jede Reihe teilt die Breite unabhängig auf (Masonry: obere Reihen ggf. eine Spalte mehr).
final class TerminalSplitView: NSView {

    /// Regel (Kachel-Protokoll): die Split-View spricht nur `Pane`. `as? TerminalPane` steht an
    /// genau drei kommentierten Stellen — Quickstart (Start in einer Home-Kachel), Session-Status
    /// und Identität im Steuerkanal (`status`, `info`).
    private var panes: [any Pane] = []
    /// Gezoomte Kachel (#26): liegt über allen anderen auf voller Fenstergröße.
    /// Das Grid darunter bleibt unangetastet — Entzoomen ist ein normales relayout().
    /// Weak als Robustheitsnetz; jede Grid-Änderung entzoomt ohnehin explizit.
    private weak var zoomedPane: (any Pane)?
    private let vibrancyView = NSVisualEffectView()
    private var isFirstLayout = true
    private var newHomeObserver: NSObjectProtocol?
    private var newAppPaneObserver: NSObjectProtocol?

    private var showHomeObserver: NSObjectProtocol?
    private var paneCommandObserver: NSObjectProtocol?
    private var quickstartObserver: NSObjectProtocol?

    /// Lücke (Steg) zwischen den Kacheln in Punkten.
    private static let gap: CGFloat = 8

    /// Radius, mit dem macOS die UNTEREN Fensterecken rundet — die Kacheln der
    /// untersten Reihe folgen ihm, damit die Akzent-Outline nicht von der
    /// Fenster-Maske beschnitten wird. Kein API dafür; bei sichtbarem Versatz
    /// (macOS-Update) hier nachjustieren.
    private static let windowCornerRadius: CGFloat = 16.5

    /// Farbe des Stegs (aus dem Theme, transluzent), damit die Vibrancy in den Stegen durchschimmert.
    private static var gapColor: NSColor { ThemeStore.shared.theme.gap }
    private var themeObserver: NSObjectProtocol?

    /// Ziel-Seitenverhältnis (Breite/Höhe) einer Kachel. < 1 = leicht hochkant → erlaubt
    /// mehr Spalten nebeneinander, bevor eine Reihe aufgemacht wird. Höher = früher umbrechen.
    /// 0.82 ergibt auf ~3:2-Fenstern: bis 3 nebeneinander, ab 4 → 2×2, dann auffüllen.
    private static let idealCellAspect: CGFloat = 0.82

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.gapColor.cgColor   // scheint in den Kachel-Lücken durch
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.layer?.backgroundColor = Self.gapColor.cgColor }

        // Erste Kachel = Projekt-Launcher (Mats' Entscheidung 24.08.). Der Session-Snapshot (#11)
        // wird bei jedem Beenden geschrieben, als Startlayout aber nur einmal nach „Neu starten“ /
        // „Beenden und Kacheln merken“ benutzt (Marke im Snapshot, `SessionStore.takeRestore`).
        if let plan = Self.restoreQueue.claim() {
            restore(plan)
            // Fenster, die macOS nach dem Beenden nicht wieder öffnet, kommen als Kacheln hierher.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restoreLeftovers() }
        } else {
            addPane(home: true)
        }

        // ⌘N (Menü „Neue Home-Kachel"): nur das Key-Fenster reagiert.
        newHomeObserver = NotificationCenter.default.addObserver(
            forName: .latexTermNewHomePane, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.addPane(home: true)
        }

        // Menü „Kachel → Neues …“ (aus der Registry): App-Kachel im Key-Fenster.
        newAppPaneObserver = NotificationCenter.default.addObserver(
            forName: .latexTermNewAppPane, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.window?.isKeyWindow == true, let kind = note.userInfo?["kind"] as? String,
                  let args = PaneKindRegistry.menuArgs(for: kind) else { return }
            do { try self.addAppPane(kind: kind, args: args) } catch {
                Logger(subsystem: "com.mats.LatexTerm", category: "panes").error("Neue Kachel \(kind, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // `latexterm://home` (Widget-Klick): nicht stapeln — unberührte Home-Kachel fokussieren, sonst anhängen.
        showHomeObserver = NotificationCenter.default.addObserver(
            forName: .latexTermShowHome, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.window?.isKeyWindow == true else { return }
            if let fresh = self.panes.first(where: { $0.kind == "home" }) { self.focusPane(fresh) }
            else { self.focusPane(self.addPane(home: true)) }
        }

        // Menü „Kachel“: Aktion auf die fokussierte Kachel des Key-Fensters (Fallback: erste).
        paneCommandObserver = NotificationCenter.default.addObserver(
            forName: .latexTermPaneCommand, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.window?.isKeyWindow == true,
                  let cmd = note.userInfo?["command"] as? PaneCommand,
                  let pane = self.panes.first(where: { self.isFocused($0) }) ?? self.panes.first else { return }
            switch cmd {
            case .split: self.paneRequestsSplit(pane)
            case .close: self.paneRequestsClose(pane)
            case .zoom: self.paneRequestsZoom(pane)
            case .find: _ = pane.handle(.find)
            }
        }

        // Dock-Menü „Quickstart": neue Home-Kachel im Key-Fenster (ohne Key-Fenster: im ersten
        // sichtbaren) und sofort starten — gleicher Weg wie ein Klick in der Kachel.
        quickstartObserver = NotificationCenter.default.addObserver(
            forName: .latexTermQuickstart, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let q = note.userInfo?["quickstart"] as? ProjekteData.Quickstart, self.window != nil else { return }
            // Key-Fenster, sonst erstes sichtbares, beim Kaltstart das erste überhaupt.
            let target = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first
            guard self.window === target else { return }
            self.runQuickstart(q)
        }

        Self.live.append(Weak(self))

        // Notification-Klick → Pane fokussieren + zoomen (#30). Der Zugriff
        // setzt zugleich den UNUserNotificationCenter-Delegate früh.
        SessionNotifier.shared.onActivatePane = { id in
            _ = ControlServer.shared.router.route(ControlRequest(cmd: "activate", pane: id.uuidString))
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let newHomeObserver { NotificationCenter.default.removeObserver(newHomeObserver) }
        if let newAppPaneObserver { NotificationCenter.default.removeObserver(newAppPaneObserver) }
        if let showHomeObserver { NotificationCenter.default.removeObserver(showHomeObserver) }
        if let quickstartObserver { NotificationCenter.default.removeObserver(quickstartObserver) }
        if let paneCommandObserver { NotificationCenter.default.removeObserver(paneCommandObserver) }
    }

    /// Quickstart ausführen: eine noch unberührte Home-Kachel (Kaltstart: die einzige) wird
    /// direkt benutzt, sonst entsteht eine neue — gleicher Startweg wie ein Klick in der Kachel.
    func runQuickstart(_ q: ProjekteData.Quickstart) {
        Logger(subsystem: "com.mats.LatexTerm", category: "quickstart").notice("runQuickstart \(q.key, privacy: .public) in \(q.path, privacy: .public); panes \(self.panes.count)")
        QuickstartStore.shared.pending = nil
        // Terminal-Cast 1/3: gestartet wird in einer Home-Kachel, und die ist ein TerminalPane.
        // Eine Home-Kachel, die gleich eine Session fortsetzt (Neustart), ist nicht unberührt.
        let fresh = (panes.count == 1 && panes[0].kind == "home")
            ? (panes[0] as? TerminalPane).flatMap { $0.hasPendingResume ? nil : $0 } : nil
        let pane = fresh ?? addPane(home: true)
        focusPane(pane)
        // Quickstart: nur die Kachelfarbe — der Prompt startet sofort einen Turn, ein getipptes
        // /color würde dort als Eingabe in die Warteschlange fallen.
        pane.launch(in: q.path, command: q.command, label: q.label, accent: q.accent?.nsColor, accentName: q.accent?.name)
    }

    /// Kollisionsschutz für Projektfarben (Runde 25): trägt eine andere offene Kachel den Namen
    /// schon, kommt die erste freie Alternative der Familie dran, danach der Rest der Palette
    /// (ohne red — das bleibt der Hand vorbehalten). Nur für diese Kachel, nichts wird gespeichert.
    func distinctAccentName(_ wanted: String, alternatives: [String], palette: [String],
                            excluding me: any Pane) -> String {
        let taken = Set(panes.compactMap { $0 !== me ? $0.accentName : nil })
        let order = [wanted] + alternatives + palette.filter { $0 != "red" }
        return order.first { !taken.contains($0) } ?? wanted
    }

    // MARK: - Session-Snapshot (#11)

    private struct Weak { weak var view: TerminalSplitView?; init(_ v: TerminalSplitView) { view = v } }
    /// Alle Fenster in Entstehungsreihenfolge — der Snapshot beim Beenden ist EINE Datei für alle
    /// (früher schrieb jedes Fenster seine eigene, das letzte gewann).
    private static var live: [Weak] = []

    /// Stand aller offenen Fenster; CWDs und Session-Identitäten werden live ausgelesen.
    static func sessionSnapshot(restoreOnce: Bool) -> SessionSnapshot {
        live.removeAll { $0.view == nil }
        let windows = live.compactMap(\.view).filter { $0.window != nil }.map { $0.windowSnapshot() }
        return SessionSnapshot(windows: windows.filter { !$0.panes.isEmpty }, restoreOnce: restoreOnce)
    }

    private func windowSnapshot() -> SessionSnapshot.Window {
        SessionSnapshot.Window(entries: panes.map { pane in
            (snapshot: pane.snapshot().map {
                var s = $0; s.id = pane.id.uuidString; s.openedBy = pane.openedBy; return s
            }, focused: isFocused(pane), zoomed: pane === zoomedPane)
        })
    }

    /// Beim ersten Zugriff einmal von der Platte geholt, dann fensterweise verteilt.
    private static var restoreQueue = RestoreQueue(SessionStore.takeRestore() ?? [])
    /// Fokus und Zoom des wiederhergestellten Fensters — gesetzt wird erst mit Fenster.
    private var pendingRestoreLayout: (focused: (any Pane)?, zoomed: (any Pane)?)?

    /// Kacheln eines gespeicherten Fensters in derselben Reihenfolge anlegen.
    private func restore(_ plan: SessionSnapshot.Window) {
        let restored = plan.panes.map { restorePane($0) }
        pendingRestoreLayout = (focused: plan.focused.flatMap { restored.indices.contains($0) ? restored[$0] : nil },
                                zoomed: plan.zoomed.flatMap { restored.indices.contains($0) ? restored[$0] : nil })
    }

    /// Eine Kachel wie gespeichert: Agenten-Session → Home, das sie per „Weiter“ fortsetzt
    /// (gleicher Befehl, Farbe, Vorhang wie der Klick); sonst Shell im Verzeichnis oder Home.
    /// Die alte Kachel-ID wird wiederverwendet (gleiche `LATEXTERM_PANE_ID` für die fortgesetzte Session),
    /// ebenso „geöffnet von“ — außer die ID ist schon vergeben.
    @discardableResult
    private func restorePane(_ saved: PaneSnapshot) -> any Pane {
        let taken = Set(ControlServer.shared.router.panes.map { $0.id.uppercased() })
        let id = saved.id.flatMap(UUID.init(uuidString:)).flatMap { taken.contains($0.uuidString) ? nil : $0 } ?? UUID()
        let pane: any Pane
        switch RestoreStep(saved) {
        case .home:
            pane = addPane(home: true, id: id)
        case .app(let kind, let args):
            // Art unbekannt (älterer Build) oder Args ungültig: der Platz bleibt als Home erhalten.
            pane = (try? addAppPane(kind: kind, args: args, id: id)) ?? addPane(home: true, id: id)
        case .shell(let cwd):
            pane = addPane(startingIn: cwd, id: id)
        case .resume(let agent, let sessionID, let cwd, let accentName):
            let home = addPane(home: true, id: id)
            home.resumeSession(HomePaneView.PendingResume(agent: agent, sessionID: sessionID,
                                                          cwd: cwd, accentName: accentName))
            pane = home
        }
        pane.openedBy = saved.openedBy
        return pane
    }

    private func restoreLeftovers() {
        let leftovers = Self.restoreQueue.drain()
        guard !leftovers.isEmpty else { return }
        let focused = panes.first(where: { isFocused($0) }), zoomed = zoomedPane
        for window in leftovers { window.panes.forEach { restorePane($0) } }
        // Nach den Fokus-Sprüngen der neuen Kacheln (addPane fokussiert im nächsten Durchlauf).
        DispatchQueue.main.async { [weak self] in self?.applyRestoredLayout(focused: focused, zoomed: zoomed) }
    }

    private func applyRestoredLayout(focused: (any Pane)?, zoomed: (any Pane)?) {
        let alive = { (p: (any Pane)?) in p.flatMap { p in self.panes.contains { $0 === p } ? p : nil } }
        if let zoomed = alive(zoomed), panes.count > 1 {
            setZoomedPane(zoomed)
            updateFocusBorders()
            relayout(animated: false)
        }
        if let target = alive(focused) ?? alive(zoomed) { window?.makeFirstResponder(target.focusTarget) }
        updateTitlebarHUD()
    }

    /// Für Home: alle anderen Kacheln aus allen Fenstern, mit expliziter Session-Identität.
    func homePaneSummary(excluding me: any Pane) -> [HomePaneInfo] {
        ControlServer.shared.router.panes.compactMap { p in
            guard p.id != me.id.uuidString, let cwd = p.cwd else { return nil }
            let name = p.agent.map { $0 == "codex" ? "Codex" : "Claude" }
            return HomePaneInfo(id: p.id, path: cwd, agent: p.agent, sessionID: p.sessionID,
                                state: p.state, label: [name, (cwd as NSString).lastPathComponent].compactMap { $0 }.joined(separator: " · "))
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        firstResponderObservation = nil
        guard let window = window else { return }

        // Wiederhergestelltes Fenster: Fokus/Zoom nach den Fokus-Sprüngen der angelegten Kacheln.
        if let layout = pendingRestoreLayout {
            pendingRestoreLayout = nil
            DispatchQueue.main.async { [weak self] in
                self?.applyRestoredLayout(focused: layout.focused, zoomed: layout.zoomed)
            }
        }

        // Kaltstart per URL/Dock-Plugin: die Anforderung kam, bevor es ein Fenster gab.
        if let q = QuickstartStore.shared.pending {
            QuickstartStore.shared.pending = nil
            DispatchQueue.main.async { [weak self] in self?.runQuickstart(q) }
        }

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

        // Steuerkanal (#28): dieses Fenster als Ziel für `latexterm`-Kommandos.
        ControlServer.shared.register(self)

        // Die eine Fokus-Wahrheit: der First Responder des Fensters. Keine Inhaltsansicht
        // meldet Fokus selbst — ein WKWebView könnte das gar nicht (innerer Responder).
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            self?.syncFocus()
        }

        // Dock-Streifen-Bug: bei automatisch ausgeblendetem Dock meldet AppKit
        // zeitweise ein `visibleFrame`, das unten noch die Dock-Höhe reserviert;
        // Kantenziehen und Rectangle-„Maximize“ enden dann ~80 px über dem Rand.
        // Nach jedem Resize/Move prüfen und das Fenster auf den Boden ziehen.
        if dockGapObserver == nil {
            dockGapObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak self] _ in self?.closeDockGapIfNeeded() }
            dockGapMoveObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] n in
                guard let w = n.object as? NSWindow, !w.inLiveResize else { return }
                self?.closeDockGapIfNeeded()
            }
        }
    }

    private var dockGapObserver: NSObjectProtocol?
    private var dockGapMoveObserver: NSObjectProtocol?
    private var firstResponderObservation: NSKeyValueObservation?

    /// First Responder hat gewechselt: jede Hülle erfährt, ob sie ihn enthält (die Hülle
    /// animiert nur bei echter Änderung — ein Wechsel innerhalb einer Kachel, etwa in die
    /// ⌘F-Suchleiste, flackert nicht), dann Fenstertitel und Titelleiste nachziehen.
    private func syncFocus() {
        for pane in panes { pane.container.hasFocus = isFocused(pane) }
        updateWindowTitle()
        updateTitlebarHUD()
    }

    /// Fenstertitel = Titel der fokussierten Kachel; ohne Fokus in einer Kachel bleibt er stehen.
    private func updateWindowTitle() {
        guard let window, let pane = panes.first(where: { isFocused($0) }) else { return }
        let title = pane.title
        if window.title != title { window.title = title }
    }

    /// Fenster füllt Breite und Oberkante des sichtbaren Bereichs, endet aber
    /// genau auf dessen Unterkante, obwohl das Dock automatisch ausgeblendet ist
    /// → Reserve-Streifen ist ein Phantom; Fenster bis zum Bildschirmrand ziehen.
    private func closeDockGapIfNeeded() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen else { return }
        let autohide = UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
        guard autohide else { return }
        let f = window.frame, vis = screen.visibleFrame, full = screen.frame
        let gap = vis.minY - full.minY
        guard gap > 8,
              abs(f.minY - vis.minY) < 2,
              abs(f.maxY - vis.maxY) < 2,
              abs(f.width - vis.width) < 2 else { return }
        var target = f
        target.origin.y = full.minY
        target.size.height = f.maxY - full.minY
        window.setFrame(target, display: true)
    }

    override var isFlipped: Bool { true }   // Reihe 0 oben

    // Frame-Layout: SwiftUI/Autoresizing ändert nur unsere Größe – darauf neu kacheln.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout(animated: false)
    }

    /// Terminal- oder Home-Kachel anhängen.
    @discardableResult
    func addPane(startingIn directory: String? = nil, home: Bool = false, focus: Bool = true,
                 id: UUID = UUID()) -> TerminalPane {
        let pane = TerminalPane(id: id)
        mount(pane)
        if home {
            pane.showHome()
        } else {
            pane.start(in: directory)
        }
        settle(pane, focus: focus)
        return pane
    }

    /// App-Kachel (Scratchpad, …) aus der Registry anhängen; Fehler = unbekannte Art oder Args.
    @discardableResult
    func addAppPane(kind: String, args: [String: String] = [:], focus: Bool = true,
                    id: UUID = UUID()) throws -> AppPane {
        let pane = try PaneKindRegistry.makeAppPane(kind: kind, args: args, id: id)
        mount(pane)
        settle(pane, focus: focus)
        return pane
    }

    /// Einhängen, für jede Kachelart gleich. Grid-Änderung beendet einen aktiven Zoom: die neue
    /// Kachel soll sichtbar im Grid entstehen, nicht unsichtbar unter der gezoomten (⌘T/⌘1–9-Policy).
    private func mount(_ pane: any Pane) {
        pane.host = self
        // Standard: von Hand geöffnet. Steuerkanal (Agent) und Restore setzen es danach selbst.
        pane.openedBy = PaneOpener.user
        setZoomedPane(nil)
        panes.append(pane)
        updateTitlebarHUD()
        addSubview(pane.container)
    }

    /// Nach dem Einhängen: Rahmen, Raster, Fokus — erst im nächsten Runloop, dann ist die View bereit.
    /// `focus: false` (Steuerkanal `new-pane` mit `focus: false`): die Kachel entsteht daneben, die
    /// Tastatur bleibt, wo Mats gerade tippt — ein Agent, der eine Vorschau öffnet, stiehlt keine Eingabe.
    private func settle(_ pane: any Pane, focus: Bool = true) {
        updateFocusBorders()
        relayout(animated: true)
        guard focus else { return }
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(pane.focusTarget) }
    }

    /// Cmd+1…9: auf `n` Kacheln auffüllen – nur erweitern, nie schließen.
    func ensurePaneCount(_ n: Int) {
        while panes.count < n { addPane() }
    }

    /// Cmd+W: Kachel beenden (`willClose`) UND sofort entfernen. `terminate()` cancelt den
    /// Exit-Monitor, daher feuert hier kein `processTerminated`/`paneDidClose` – wir müssen
    /// die UI selbst aufräumen (im Gegensatz zum `exit`-Pfad, der über `paneDidClose` läuft).
    private func closePane(_ pane: any Pane) {
        pane.willClose()
        removePane(pane)
    }

    private func removePane(_ pane: any Pane) {
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
        window?.makeFirstResponder(panes[min(idx, panes.count - 1)].focusTarget)
    }

    /// Rahmen-Regeln: Fokus-Abstufung nur im sichtbaren Grid (≥2 Kacheln, kein
    /// Zoom); eine fenster-füllende Kachel (gezoomt oder einzige) trägt statt-
    /// dessen den vollen Akzent-Rahmen als Session-Kennung (`fillsWindow`).
    private func updateFocusBorders() {
        let multi = panes.count > 1 && zoomedPane == nil
        for pane in panes {
            pane.container.showsFocusBorder = multi
            pane.container.fillsWindow = (panes.count == 1) || (pane === zoomedPane)
        }
        updateTitlebarHUD()
    }

    // MARK: - Zoom (#26)

    /// ⌘⏎: `pane` über das ganze Fenster ziehen bzw. zurück ins Grid. Kein Umbau
    /// des Grids — nur ein Merker, den relayout() als Sonderfall behandelt.
    /// Einzige Schreibstelle für `zoomedPane`; die Rahmen-Flags der Panes zieht
    /// das (an allen Aufrufstellen folgende) `updateFocusBorders()` nach.
    private func setZoomedPane(_ pane: (any Pane)?) {
        zoomedPane = pane
    }

    private func toggleZoom(_ pane: any Pane) {
        guard panes.count > 1 else { return }   // eine Kachel füllt das Fenster eh
        setZoomedPane(zoomedPane === pane ? nil : pane)
        updateFocusBorders()
        updateTitlebarHUD()
        relayout(animated: true)
        window?.makeFirstResponder(pane.focusTarget)
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
    /// Chips je Kachel in der HUD, per Pane-ID; Struktur (welche Kacheln, Zoom) in `hudSignature`.
    private var hudChips: [UUID: PaneChipView] = [:]

    /// Titelleisten-HUD (15.09.2026: Chips statt Punkte + schwebender Pille). Ein Chip je Kachel:
    /// Punkt in Kachelfarbe, daneben der Statustext aus `Pane.statusChip` — fokussierte
    /// Kachel lang, andere kurz, ab fünf Kacheln nur ein Zeichen. Ruhende Kacheln zeigen nur den
    /// Punkt (und den nur ab zwei Kacheln); ein Chip mit Text erscheint auch bei einer einzigen.
    /// Bleibt stehen und wird in place aktualisiert (die Uhr tickt sekündlich, gleiche Breite dank
    /// Monospace-Ziffern); nur wenn sich Struktur oder Gesamtbreite ändern, wird das Accessory neu
    /// angelegt — wie früher bei jedem Zustandswechsel.
    private func updateTitlebarHUD() {
        guard let window else { return }
        let mode = CockpitSettings.shared.statusBadgeMode
        let showZoom = zoomedPane != nil
        let showDots = panes.count > 1

        // Platz in der Titelleiste: Fensterbreite minus Ampel (links) und Luft. Stufen von
        // ausführlich nach knapp — die erste, die passt, gewinnt (Mats, 15.09.: „alle in voller
        // Größe, solange sie nicht links in Richtung Ampel volllaufen").
        let zoomWidth: CGFloat = showZoom ? 120 : 0
        let available = window.frame.width - 92 - 24 - zoomWidth
        enum Level { case allLong, focusedLong, allShort, glyph }
        let levels: [Level] = [.allLong, .focusedLong, .allShort, .glyph]
        var specs: [(pane: any Pane, spec: PaneChipView.Spec)] = []
        for level in levels {
            specs = []
            for pane in panes {
                let chip = pane.statusChip
                let focused = isFocused(pane)
                let text: String?
                switch level {
                case .allLong: text = chip.long
                case .focusedLong: text = focused ? chip.long : chip.short
                case .allShort: text = chip.short
                case .glyph: text = chip.glyph
                }
                let shown = mode == .off ? nil : text
                guard showDots || shown != nil else { continue }
                let long = level == .allLong || (level == .focusedLong && focused)
                specs.append((pane, PaneChipView.Spec(
                    color: pane.effectiveAccent, tone: chip.tone, focused: focused, text: shown,
                    pulsing: chip.pulsing, urgent: chip.urgent, tooltip: chip.tooltip,
                    maxWidth: long ? 360 : 160)))
            }
            let width = specs.reduce(CGFloat(0)) { $0 + PaneChipView.width(for: $1.spec) }
                + 6 * CGFloat(max(0, specs.count - 1))
            if width <= available || level == .glyph { break }
        }

        guard !specs.isEmpty || showZoom else {
            if let hud = titlebarHUD { hud.removeFromParent() }
            titlebarHUD = nil; hudChips = [:]; hudSignature = ""
            return
        }

        let structure = specs.map { $0.pane.id.uuidString }.joined(separator: ",")
            + "|zoom:\(showZoom ? zoomedPane?.effectiveAccent.srgbHexString ?? "-" : "")"
        if structure == hudSignature, let hud = titlebarHUD {
            for (pane, spec) in specs { hudChips[pane.id]?.apply(spec) }
            if Self.layoutHUD(hud.view) { return }   // Breite unverändert → fertig
        }

        // Struktur oder Breite neu: Accessory frisch anlegen.
        if let hud = titlebarHUD { hud.removeFromParent(); titlebarHUD = nil }
        hudChips = [:]
        let wrapper = NSView(frame: .zero)
        for (pane, spec) in specs {
            let chip = PaneChipView { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.focusPane(pane)
            }
            chip.apply(spec)
            hudChips[pane.id] = chip
            wrapper.addSubview(chip)
        }
        if showZoom, let zoomed = zoomedPane {
            wrapper.addSubview(Self.makeZoomPill(accent: zoomed.effectiveAccent))
        }
        _ = Self.layoutHUD(wrapper)

        let vc = NSTitlebarAccessoryViewController()
        vc.view = wrapper
        vc.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(vc)
        titlebarHUD = vc
        hudSignature = structure
    }

    /// Elemente nebeneinander setzen, Wrapper auf Inhalt + Luft. false = Breite hat sich geändert
    /// (der Aufrufer legt das Accessory dann neu an, damit die Titelleiste den Platz neu vergibt).
    @discardableResult
    private static func layoutHUD(_ wrapper: NSView) -> Bool {
        let elements = wrapper.subviews
        let spacing: CGFloat = 6
        let contentWidth = elements.reduce(0) { $0 + $1.frame.width }
            + spacing * CGFloat(max(0, elements.count - 1))
        let contentHeight = elements.map(\.frame.height).max() ?? 20
        let size = NSSize(width: contentWidth + 10, height: contentHeight + 8)
        let unchanged = wrapper.frame.size == size
        if !unchanged { wrapper.setFrameSize(size) }
        var x: CGFloat = 0
        for element in elements {
            element.frame.origin = NSPoint(x: x, y: ((size.height - element.frame.height) / 2).rounded())
            x += element.frame.width + spacing
        }
        return unchanged
    }

    private static func makeZoomPill(accent: NSColor) -> NSView {
        let label = NSTextField(labelWithString: "⤢ Zoom   ⌘⏎")
        label.font = AppFonts.mono(size: 11, weight: .semibold)
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

    /// Ist diese Kachel gerade fokussiert (First Responder im/unterm Terminal-View)?
    private func isFocused(_ pane: any Pane) -> Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: pane.container) ?? false
    }

    // MARK: - Session-Status → Notification (#30)

    private func isObserved(_ pane: any Pane) -> Bool {
        NSApp.isActive && window?.isKeyWindow == true && isFocused(pane)
    }

    /// Hintergrundfenster behalten ihren First Responder. Erst das Key-Fenster zählt als
    /// beobachtet; Einstellung „Agenten → nur wenn unbeobachtet“ aus = immer melden.
    private func isUnobserved(_ pane: any Pane) -> Bool {
        !CockpitSettings.shared.notifyOnlyUnobserved || !isObserved(pane)
    }

    /// Notification-Klick: App nach vorn, Pane fokussieren und (im Grid) zoomen —
    /// der Nutzer will JETZT mit genau dieser Session sprechen.
    private func activatePane(id: UUID) {
        guard let pane = panes.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if panes.count > 1 {
            setZoomedPane(pane)
            updateFocusBorders()
            relayout(animated: true)
        }
        window?.makeFirstResponder(pane.focusTarget)
        updateTitlebarHUD()
    }

    /// Klick auf einen Session-Punkt: Kachel fokussieren. Ist gerade eine ANDERE
    /// Kachel gezoomt, WANDERT der Zoom zur angeklickten — die Punkte sind im
    /// Zoom der Session-Umschalter, ein Rückfall ins Grid wäre ein Bruch.
    private func focusPane(_ pane: any Pane) {
        if let zoomed = zoomedPane, zoomed !== pane {
            setZoomedPane(pane)
            updateFocusBorders()
            relayout(animated: true)
        }
        window?.makeFirstResponder(pane.focusTarget)
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
    /// Fensterbreite entscheidet, wie ausführlich die Titelleisten-Chips sein dürfen.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateTitlebarHUD()
    }

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

// MARK: - Rückkanal der Kacheln

extension TerminalSplitView: PaneHost {
    /// ⌘T: die anfordernde Kachel ist die fokussierte → ihr CWD vererben (#8).
    func paneRequestsSplit(_ pane: any Pane) { addPane(startingIn: pane.currentDirectory) }
    func paneRequestsClose(_ pane: any Pane) { closePane(pane) }
    func paneDidClose(_ pane: any Pane) { removePane(pane) }
    func paneRequestsZoom(_ pane: any Pane) { toggleZoom(pane) }
    func paneRequestsPaneCount(_ count: Int) { ensurePaneCount(count) }

    func paneStyleChanged(_ pane: any Pane) {
        updateWindowTitle()
        updateTitlebarHUD()
    }

    /// Nur melden, wenn die Kachel gerade niemand ansieht — App im Hintergrund, Fenster
    /// hinten oder andere Kachel fokussiert (abschaltbar: „nur wenn unbeobachtet“).
    func paneRequestsAttention(_ pane: any Pane, title: String, body: String?) {
#if DEBUG
        TerminalPane.statusLog("NOTIFY? title=\(title) appActive=\(NSApp.isActive) focused=\(isFocused(pane))")
#endif
        guard isUnobserved(pane) else { return }
        SessionNotifier.shared.notify(paneID: pane.id, title: title, body: body)
    }

    func paneIsObserved(_ pane: any Pane) -> Bool { isObserved(pane) }

    func paneRequestsFreshTerminal(focus: Bool) -> TerminalPane {
        let fresh = addPane(home: true)
        if focus { focusPane(fresh) }
        return fresh
    }

    func paneRequestsFocus(paneID: String) {
        _ = ControlServer.shared.router.route(ControlRequest(cmd: "focus", pane: paneID))
    }
}

// MARK: - Steuerkanal (#28)

/// Ausführung der `latexterm`-CLI-Kommandos. Lebt in DIESER Datei, damit die
/// Pane-Verwaltung (`panes`, `toggleZoom`, …) privat bleiben kann. Der
/// `ControlServer` ruft `handleControl` synchron auf dem Main-Thread.
extension TerminalSplitView: ControlCommandHandler {
    var isActiveControlWindow: Bool { window?.isKeyWindow == true }
    var controlPanes: [PaneInfo] { window == nil ? [] : panes.map { info(for: $0) } }


    func handleControl(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case "list-panes":
            return ControlResponse(ok: true, panes: panes.map { info(for: $0) })

        case "pane-kinds":
            return ControlResponse(ok: true, kinds: PaneKindRegistry.kinds, kindInfos: PaneKindRegistry.infos)

        case "new-pane":
            // Wer öffnet: die Kachel des Aufrufers (CLI/MCP schicken ihre LATEXTERM_PANE_ID mit).
            let opener = request.paneID.flatMap(UUID.init(uuidString:))?.uuidString
            let kind = request.kind ?? "terminal"
            let args = request.args ?? [:]
            if kind != "terminal", request.cwd != nil || request.exec != nil {
                return .failure("--cwd und --exec gibt es nur für terminal")
            }
            switch kind {
            case "terminal", "home":
                guard args.isEmpty else { return .failure("\(kind) kennt kein --arg") }
                let pane = addPane(startingIn: request.cwd, home: kind == "home", focus: request.focus ?? true)
                pane.openedBy = opener
                if let exec = request.exec, !exec.isEmpty {
                    // Sofort in die PTY — der Kernel puffert, die Shell liest das
                    // Kommando, sobald sie bereit ist (kein Delay/Poll nötig).
                    pane.view.send(txt: exec + "\r")
                }
                return ControlResponse(ok: true, pane: info(for: pane))
            default:
                do {
                    let pane = try addAppPane(kind: kind, args: args, focus: request.focus ?? true)
                    pane.openedBy = opener
                    return ControlResponse(ok: true, pane: info(for: pane))
                }
                catch { return .failure(String(describing: error)) }
            }

        case "close-pane":
            guard let pane = resolvePane(request.pane ?? request.paneID) else {
                return .failure("Kachel nicht gefunden: „\(request.pane ?? request.paneID ?? "kein Ziel angegeben")“ — `latexterm list-panes` zeigt Index und ID")
            }
            if !(request.force ?? false), case .busy(let reason) = pane.closeGuard {
                return .failure("Kachel \(info(for: pane).index) \(reason)")
            }
            let snapshot = info(for: pane)
            closePane(pane)
            return ControlResponse(ok: true, pane: snapshot)

        case "status":
            // Session-Status des Bridge-Mods — derselbe Inhalt wie OSC 5522 `status=…`, aber
            // NICHT über die TTY: ein fremder Schreiber in der Leitung zerreißt die Escape-
            // Sequenzen, die Claude Code gerade malt (Artefakte wie „;255;255;255m").
            guard let pane = resolvePane(request.pane ?? request.paneID) else {
                return .failure("Kachel nicht gefunden: „\(request.pane ?? request.paneID ?? "kein Ziel angegeben")“")
            }
            guard let text = request.text, !text.isEmpty else {
                return .failure("status braucht eine Payload")
            }
            // Terminal-Cast 2/3: Hook-Status gibt es nur für Agenten-Sessions in einer Shell.
            guard let terminal = pane as? TerminalPane else {
                return .failure("Kachel (\(pane.kind)) hat keine Agenten-Session")
            }
            guard terminal.applyHookStatus(text, agent: request.agent, sessionID: request.sessionID,
                                           turnID: request.turnID, sourceGroup: request.sourceGroup) else {
                return .failure("Ungültiges oder veraltetes Session-Ereignis")
            }
            return ControlResponse(ok: true)

        case "send", "zoom", "focus", "activate":
            guard let pane = resolvePane(request.pane ?? request.paneID) else {
                return .failure("Kachel nicht gefunden: „\(request.pane ?? request.paneID ?? "kein Ziel angegeben")“ — `latexterm list-panes` zeigt Index und ID")
            }
            switch request.cmd {
            case "send":
                guard let text = request.text, !text.isEmpty else {
                    return .failure("send braucht einen Text")
                }
                guard pane.receive(text, enter: request.enter ?? true) else {
                    return .failure(pane.kind == "home" ? "Home-Kachel hat noch keine Shell, die Text annimmt"
                                    : "Kachel (\(pane.kind)) versteht „\(text.prefix(40))“ nicht")
                }
            case "zoom":
                toggleZoom(pane)
            case "activate":
                activatePane(id: pane.id)
            default:
                NSApp.activate(ignoringOtherApps: true)
                window?.makeKeyAndOrderFront(nil)
                focusPane(pane)
            }
            return ControlResponse(ok: true, pane: info(for: pane))

        default:
            return .failure("Unbekanntes Kommando „\(request.cmd)“")
        }
    }

    private func info(for pane: any Pane) -> PaneInfo {
        // Terminal-Cast 3/3: Session-Zustand und Identität liefert nur ein Terminal.
        let terminal = pane as? TerminalPane
        let identity = terminal?.agentSession.identity
        let state: String
        switch terminal?.sessionState ?? .none {
        case .none: state = identity == nil ? "none" : "ready"
        case .working: state = "working"
        case .awaitingInput: state = "awaitingInput"
        }
        return PaneInfo(id: pane.id.uuidString,
                        index: (panes.firstIndex(where: { $0 === pane }) ?? 0) + 1,
                        cwd: pane.currentDirectory,
                        focused: isActiveControlWindow && isFocused(pane),
                        zoomed: pane === zoomedPane,
                        state: state, agent: identity?.agent,
                        sessionID: identity?.sessionID,
                        windowID: window.map { String($0.windowNumber) },
                        kind: pane.kind,
                        title: String(pane.title.prefix(120)),
                        args: terminal == nil ? pane.snapshot()?.args : nil,
                        foreground: terminal?.foregroundProcessName,
                        openedBy: pane.openedBy)
    }

    /// Löst den Ziel-Selektor des CLI auf eine Kachel auf. Semantik: reine Ziffern
    /// sind IMMER der 1-basierte Index aus `list-panes` (nie UUID-Präfix — vorhersagbar
    /// schlägt bequem); alles andere matcht case-insensitiv als UUID-Präfix, aber nur
    /// bei GENAU einem Treffer. Mehrdeutig = nil: `send` in die falsche Shell wäre
    /// Command-Execution, da ist ein Fehler die sichere Antwort.
    private func resolvePane(_ selector: String?) -> (any Pane)? {
        guard let selector, !selector.isEmpty else { return nil }
        if let index = Int(selector) {
            guard (1...panes.count).contains(index) else { return nil }
            return panes[index - 1]
        }
        let prefix = selector.uppercased()
        let matches = panes.filter { $0.id.uuidString.hasPrefix(prefix) }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Chip in der Titelleisten-HUD (15.09.2026, ersetzt `PaneDotView` + die schwebende Pille):
/// Punkt in Kachelfarbe (fokussiert = voll + heller Ring; pulsiert bei Arbeit, schneller bei
/// „braucht dich") und daneben der Statustext in der Tonfarbe. Ohne Text nur der Punkt (18 px
/// Klickfläche wie früher). Klick fokussiert die Kachel. `apply` aktualisiert in place — die Uhr
/// tickt so ohne Neuaufbau.
private final class PaneChipView: NSView {
    struct Spec: Equatable {
        var color: NSColor
        var tone: NSColor
        var focused: Bool
        var text: String?
        var pulsing: Bool
        var urgent: Bool
        var tooltip: String?
        var maxWidth: CGFloat
    }

    private static let height: CGFloat = 20
    private static let font = AppFonts.mono(size: 11, weight: .semibold)

    /// Breite, die `apply(spec)` ergeben wird — zum Vorab-Messen, welche Textstufe in die Leiste passt.
    static func width(for spec: Spec) -> CGFloat {
        guard let text = spec.text else { return 18 }
        let measured = (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return 6 + 12 + 6 + min(measured, spec.maxWidth) + 9
    }

    private let onClick: () -> Void
    private let circle = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var spec: Spec?

    /// Ohne das frisst der Fenster-Drag den Klick: `isMovableByWindowBackground`
    /// + nicht-opaker View ⇒ AppKit deutet mouseDown als „Fenster anfassen".
    override var mouseDownCanMoveWindow: Bool { false }

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: Self.height))
        wantsLayer = true
        circle.cornerRadius = 6
        layer?.addSublayer(circle)
        label.font = Self.font
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }

    func apply(_ spec: Spec) {
        guard spec != self.spec else { return }
        let old = self.spec
        self.spec = spec
        toolTip = spec.tooltip

        let dotColor = spec.urgent ? spec.tone : spec.color
        circle.backgroundColor = dotColor.withAlphaComponent(spec.focused ? 1.0 : 0.55).cgColor
        circle.borderWidth = spec.focused ? 1.5 : 0
        circle.borderColor = ThemeStore.shared.theme.foreground.withAlphaComponent(0.8).cgColor

        let height = Self.height
        if let text = spec.text {
            label.isHidden = false
            label.textColor = spec.tone
            if text != old?.text || spec.maxWidth != old?.maxWidth {
                label.stringValue = text
                label.sizeToFit()
                label.frame.size.width = min(label.frame.width, spec.maxWidth)
            }
            setFrameSize(NSSize(width: 6 + 12 + 6 + label.frame.width + 9, height: height))
            circle.frame = CGRect(x: 6, y: 4, width: 12, height: 12)
            label.frame.origin = NSPoint(x: 24, y: ((height - label.frame.height) / 2).rounded())
            layer?.cornerRadius = height / 2
            layer?.borderWidth = 1
            layer?.backgroundColor = spec.tone.withAlphaComponent(0.10).cgColor
            layer?.borderColor = spec.tone.withAlphaComponent(0.45).cgColor
        } else {
            label.isHidden = true
            setFrameSize(NSSize(width: 18, height: height))
            circle.frame = CGRect(x: 3, y: 4, width: 12, height: 12)
            layer?.borderWidth = 0
            layer?.backgroundColor = nil
            layer?.borderColor = nil
        }

        if spec.pulsing {
            if circle.animation(forKey: "sessionPulse") == nil || old?.urgent != spec.urgent {
                circle.removeAnimation(forKey: "sessionPulse")
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.35
                pulse.duration = spec.urgent ? 0.5 : 0.9
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                circle.add(pulse, forKey: "sessionPulse")
            }
        } else {
            circle.removeAnimation(forKey: "sessionPulse")
        }
    }
}

extension NSColor {
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
