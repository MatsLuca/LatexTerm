import AppKit
import os

/// Kachelt beliebig viele Kacheln (`any Pane`). Cmd+T hängt eine Kachel an, Cmd+W/`exit` entfernt
/// eine; bei jeder Änderung wird neu angeordnet.
///
/// Kachel-Layout (23.09.2026, Bauplan claude-werkstatt `plans/kachel-layout_2026-09-23.md`): die
/// Anordnung ist ein Baum (`LayoutNode`) — die eine Wahrheit für Frames, Lesereihenfolge (Index,
/// Chips) und Trennlinien. Ohne eigenen Zustand rechnet ihn die Automatik (`AutoLayout.build`) aus
/// Kacheln, Begleitern und Fenstergröße: ohne Begleiter exakt das frühere Raster, mit Begleitern
/// steht jede Kachel ihres Agenten in einer Nebenspalte rechts neben ihm. Zieht Mats eine Trennlinie
/// oder ordnet ein Agent an, wird der Baum angepasst (`manualLayout`) und neue Kacheln werden nur noch
/// eingesetzt, ohne den Rest umzuwerfen; „Automatisch anordnen“ gibt ihn zurück.
///
/// Reiter (Stufe 2, 23.09.2026): ein Platz kann mehrere Kacheln halten (die Nebenspalte ab dem vierten
/// Begleiter, `als_reiter`). Vorn liegt die zuletzt gezeigte (`shownAt`); die übrigen haben denselben
/// Frame, sind aber verborgen. Wer eine verdeckte Kachel fokussiert (Reiter, Chip, ⌘1–9, Steuerkanal),
/// holt sie vorher nach vorn (`reveal`).
final class TerminalSplitView: NSView {

    /// Regel (Kachel-Protokoll): die Split-View spricht nur `Pane`. `as? TerminalPane` steht an
    /// genau drei kommentierten Stellen — Quickstart (Start in einer Home-Kachel), Session-Status
    /// und Identität im Steuerkanal (`status`, `info`).
    private var panes: [any Pane] = []
    /// Gezoomte Kachel (#26): liegt über allen anderen auf voller Fenstergröße.
    /// Das Grid darunter bleibt unangetastet — Entzoomen ist ein normales relayout().
    /// Weak als Robustheitsnetz; jede Grid-Änderung entzoomt ohnehin explizit.
    private weak var zoomedPane: (any Pane)?

    // Kachel-Layout
    /// Angepasste Anordnung (Mats zog eine Trennlinie, ein Agent ordnete an); nil = Automatik.
    private var manualLayout: LayoutNode?
    /// Kachel → Kachel, neben der sie steht (Begleiter, meist: der Agent, der sie geöffnet hat).
    private var companionOf: [UUID: UUID] = [:]
    /// Kacheln, deren Wunschform nach dem Laden schon einmal gemeldet wurde — danach wird für sie
    /// nicht mehr umgeordnet (ein neu geladenes PDF anderer Form lässt das Layout stehen).
    private var settledPreferences: Set<UUID> = []
    /// Stege, an denen Mats ziehen kann (je Teilungsgrenze einer).
    private var dividerViews: [PaneDividerView] = []
    /// Reiterleisten (je Platz mit mehreren Kacheln eine) und die Leisten, die sie gerade zeigen.
    private var tabBarViews: [PaneTabBarView] = []
    private var currentTabBars: [LayoutTabBar] = []
    /// Wann eine Kachel zuletzt nach vorn kam (Zähler) — bei Reitern liegt die zuletzt gezeigte vorn,
    /// automatisch wie angepasst. Die eine Wahrheit dafür; der Baum trägt es nur mit (`withFront`).
    private var shownAt: [String: Int] = [:]
    private var shownClock = 0
    /// Verdeckte Reiter, deren Inhalt sich seither geändert hat (Abzeichen „neu“, Scheibe C) — bis sie vorn sind.
    private var newsPanes: Set<UUID> = []
    /// Laufender Zug an einer Trennlinie: Ausgangsbaum und Linie.
    private var dragOrigin: (tree: LayoutNode, divider: LayoutDivider)?
    /// Laufender Zug einer Kachel (am Reiter oder Titelleisten-Chip): welche, und die Anzeige des Ziels.
    private var paneDrag: (pane: String, overlay: PaneDropOverlayView)?
    /// Stand-Nummer der Anordnung (`LayoutReport.revision`): wächst mit jeder Änderung. Agenten müssen
    /// die zuletzt gelesene mitschicken, um umzuordnen — so ordnet keiner auf einem veralteten Bild um.
    private var layoutRevision = 0

    private let vibrancyView = NSVisualEffectView()
    private var isFirstLayout = true
    private var newHomeObserver: NSObjectProtocol?
    private var newAppPaneObserver: NSObjectProtocol?

    private var showHomeObserver: NSObjectProtocol?
    private var paneCommandObserver: NSObjectProtocol?
    private var quickstartObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    /// Tab/Fenster wurde geschlossen — gehört nicht mehr in den Snapshot.
    private var windowClosed = false

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

    /// Kleinste Kachelbreite/-höhe beim Ziehen einer Trennlinie (pt).
    private static let dragMinimum: Double = 120
    /// Höhe der Reiterleiste über einem Platz mit mehreren Kacheln (pt, inkl. Luft zur Kachel).
    private static let tabBarHeight: CGFloat = 30
    /// Kachel ziehen: so nah am Fensterrand (pt) zählt der Rand statt der Kachel darunter.
    private static let windowDropBand: CGFloat = 14
    /// Kachel ziehen: kleiner als das darf durch einen Wurf keine Kachel werden (Breite, Höhe in pt).
    private static let dropMinimum = CGSize(width: 120, height: 90)

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
        if let claimed = Self.restoreQueue.claimTab() {
            restore(claimed.window)
            restoredTab = (group: claimed.window.tabGroup ?? 0, ownWindow: claimed.ownWindow,
                           selected: claimed.window.selected == true)
            // Nur das erste Fenster öffnet die übrigen Tabs; Nachzügler finden die Schlange leer.
            if !Self.restoreStarted {
                Self.restoreStarted = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restoreLeftovers() }
            }
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
            case .rearrange: self.rearrangeAutomatically()
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
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
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
        let views = live.compactMap(\.view).filter { $0.window != nil && !$0.windowClosed }
        // Tab-Leisten zusammenhängend und in Anzeige-Reihenfolge (Tabs lassen sich verschieben).
        let order = SessionSnapshot.tabOrder(count: views.count) { i in
            views[i].window?.tabGroup?.windows.compactMap { w in views.firstIndex { $0.window === w } }
        }
        let windows = order.map { entry -> SessionSnapshot.Window in
            let view = views[entry.index]
            var snapshot = view.windowSnapshot()
            snapshot.tabGroup = entry.group
            snapshot.selected = view.window.map { $0.tabGroup?.selectedWindow === $0 }
            return snapshot
        }
        return SessionSnapshot(windows: windows.filter { !$0.panes.isEmpty }, restoreOnce: restoreOnce)
    }

    private func windowSnapshot() -> SessionSnapshot.Window {
        let hidden = hiddenTabIDs
        return SessionSnapshot.Window(entries: panes.map { pane in
            (snapshot: pane.snapshot().map {
                var s = $0; s.id = pane.id.uuidString; s.openedBy = pane.openedBy
                s.companionOf = companionOf[pane.id]?.uuidString
                s.hidden = hidden.contains(pane.id.uuidString) ? true : nil
                return s
            }, focused: isFocused(pane), zoomed: pane === zoomedPane)
        }, layout: manualLayout)
    }

    /// Beim ersten Zugriff einmal von der Platte geholt, dann fensterweise verteilt.
    private static var restoreQueue = RestoreQueue(SessionStore.takeRestore() ?? [])
    /// Nur das erste wiederhergestellte Fenster öffnet die übrigen Tabs.
    private static var restoreStarted = false
    /// Wiederhergestellter Tab: beginnt er eine eigene Leiste, war er der sichtbare Tab?
    private var restoredTab: (group: Int, ownWindow: Bool, selected: Bool)?
    /// Beim Wiederherstellen: erstes Fenster je Leiste — die übrigen Tabs hängen sich daran.
    private static var restoreAnchors: [Int: Weak] = [:]
    /// Fokus und Zoom des wiederhergestellten Fensters — gesetzt wird erst mit Fenster.
    private var pendingRestoreLayout: (focused: (any Pane)?, zoomed: (any Pane)?)?

    /// Kacheln eines gespeicherten Fensters in derselben Reihenfolge anlegen.
    private func restore(_ plan: SessionSnapshot.Window) {
        var idMap: [String: UUID] = [:]
        let restored = plan.panes.map { saved -> any Pane in
            let pane = restorePane(saved)
            if let old = saved.id?.uppercased() { idMap[old] = pane.id }
            return pane
        }
        restoreRelations(plan.panes, idMap: idMap)
        restoreFrontTabs(plan.panes, idMap: idMap)
        // Angepasste Anordnung mit den (ggf. neuen) Kachel-IDs; was nicht zurückkam, fällt heraus.
        if let saved = plan.layout,
           let mapped = saved.mappingPanes({ idMap[$0.uppercased()]?.uuidString })?
               .normalized(keeping: Set(panes.map { $0.id.uuidString })),
           mapped.paneIDs.count > 1 {
            manualLayout = mapped
            layoutChanged()
        }
        pendingRestoreLayout = (focused: plan.focused.flatMap { restored.indices.contains($0) ? restored[$0] : nil },
                                zoomed: plan.zoomed.flatMap { restored.indices.contains($0) ? restored[$0] : nil })
    }

    /// Begleiter-Beziehungen aus dem Snapshot, übersetzt auf die wiederhergestellten Kachel-IDs.
    private func restoreRelations(_ saved: [PaneSnapshot], idMap: [String: UUID]) {
        for entry in saved {
            guard let old = entry.id?.uppercased(), let pane = idMap[old],
                  let target = entry.companionOf?.uppercased(), let anchor = idMap[target], anchor != pane else { continue }
            companionOf[pane] = anchor
        }
    }

    /// Reiter, die beim Beenden vorn lagen, liegen wieder vorn: sichtbare Kacheln gelten als zuletzt gezeigt.
    private func restoreFrontTabs(_ saved: [PaneSnapshot], idMap: [String: UUID]) {
        for entry in saved where entry.hidden != true {
            guard let old = entry.id?.uppercased(), let id = idMap[old], let pane = panes.first(where: { $0.id == id }) else { continue }
            markShown(pane)
        }
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
            // Begleiter-Beziehungen setzt der Aufrufer danach aus dem Snapshot (`restoreRelations`).
            pane = (try? addAppPane(kind: kind, args: args, placement: .own, id: id)) ?? addPane(home: true, id: id)
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

    /// Übrige Fenster des Snapshots als Tabs öffnen (jedes neue Fenster holt sich im `init` seinen
    /// Plan). Was danach niemand geholt hat, kommt als Kacheln hierher — keine Session geht verloren.
    private func restoreLeftovers() {
        let remaining = Self.restoreQueue.count
        guard remaining > 0, let open = WindowTabs.open else { mergeLeftovers(); Self.selectRestoredTabs(); return }
        for _ in 0..<remaining { open() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.mergeLeftovers()
            Self.selectRestoredTabs()
        }
    }

    /// Je Leiste den Tab nach vorn, der beim Beenden sichtbar war; Key wird der der ersten Leiste.
    private static func selectRestoredTabs() {
        let selected = live.compactMap(\.view).filter { $0.restoredTab?.selected == true }
        for view in selected.reversed() {
            guard let window = view.window else { continue }
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        }
        for view in live.compactMap(\.view) { view.restoredTab = nil }
        restoreAnchors = [:]
    }

    private func mergeLeftovers() {
        let leftovers = Self.restoreQueue.drain()
        guard !leftovers.isEmpty else { return }
        let focused = panes.first(where: { isFocused($0) }), zoomed = zoomedPane
        for window in leftovers {
            var idMap: [String: UUID] = [:]
            for saved in window.panes {
                let pane = restorePane(saved)
                if let old = saved.id?.uppercased() { idMap[old] = pane.id }
            }
            restoreRelations(window.panes, idMap: idMap)
            restoreFrontTabs(window.panes, idMap: idMap)
        }
        layoutChanged()
        relayout(animated: false)
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

        // Tab-Leiste: sichtbar ab dem ersten Fenster. Ein wiederhergestellter Tab, der beim Beenden
        // in einer anderen Leiste stand, löst sich wieder heraus.
        if let tab = restoredTab {
            let anchor = Self.restoreAnchors[tab.group]?.view?.window
            if anchor == nil { Self.restoreAnchors[tab.group] = Weak(self) }
            WindowTabs.prepare(window, anchor: anchor)
            if anchor == nil, tab.ownWindow {
                DispatchQueue.main.async { [weak window] in
                    guard let window, (window.tabGroup?.windows.count ?? 1) > 1 else { return }
                    window.moveTabToNewWindow(nil)
                }
            }
        } else {
            WindowTabs.prepare(window, anchor: WindowTabs.frontmost(excluding: window))
        }
        // Tab (bzw. Fenster) zu: Kacheln aufräumen wie ⌘W — sonst lebten ihre Prozesse weiter.
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.windowClosed = true
            self.panes.forEach { $0.willClose() }
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
        updateTabBarContents()
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

    /// Wohin eine neue Kachel kommt (Kachel-Layout).
    enum PanePlacement {
        /// Eigenständig: Terminal, Home, neue Agenten-Session, Wiederherstellen.
        case own
        /// Neben diese Kachel (ein Agent öffnete sie per Steuerkanal/MCP).
        case beside(UUID)
        /// Von Hand geöffnete App-Kachel: neben die fokussierte Kachel.
        case besideFocused
    }

    /// Terminal- oder Home-Kachel anhängen.
    @discardableResult
    func addPane(startingIn directory: String? = nil, home: Bool = false, focus: Bool = true,
                 placement: PanePlacement = .own, id: UUID = UUID()) -> TerminalPane {
        let pane = TerminalPane(id: id)
        mount(pane, placement: placement)
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
                    placement: PanePlacement = .besideFocused, id: UUID = UUID()) throws -> AppPane {
        let pane = try PaneKindRegistry.makeAppPane(kind: kind, args: args, id: id)
        mount(pane, placement: placement)
        settle(pane, focus: focus)
        return pane
    }

    /// Einhängen, für jede Kachelart gleich. Grid-Änderung beendet einen aktiven Zoom: die neue
    /// Kachel soll sichtbar im Grid entstehen, nicht unsichtbar unter der gezoomten (⌘T/⌘1–9-Policy).
    private func mount(_ pane: any Pane, placement: PanePlacement) {
        pane.host = self
        // Standard: von Hand geöffnet. Steuerkanal (Agent) und Restore setzen es danach selbst.
        pane.openedBy = PaneOpener.user
        cancelDividerDrag()
        cancelPaneDrag()
        let focused = panes.first(where: { isFocused($0) })
        setZoomedPane(nil)
        panes.append(pane)
        markShown(pane)
        switch placement {
        case .own: break
        case .beside(let anchor):
            if anchor != pane.id, panes.contains(where: { $0.id == anchor }) { companionOf[pane.id] = anchor }
        case .besideFocused:
            if let focused { companionOf[pane.id] = focused.id }
        }
        if manualLayout != nil { insertIntoManualLayout(pane, focused: focused) }
        // Landet die neue Kachel als Reiter vor der, in der Mats gerade tippt, bleibt seine vorn — die neue
        // kommt nur nach vorn, wenn sie selbst den Fokus bekommt (`settle`).
        if let focused, hiddenTabIDs.contains(focused.id.uuidString) { markShown(focused) }
        layoutChanged()
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
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panes.contains(where: { $0 === pane }) else { return }
            self.reveal(pane)
            self.window?.makeFirstResponder(pane.focusTarget)
        }
    }

    /// ⌘1…9: zur Kachel `n` in Lesereihenfolge springen (verdeckte Reiter kommen nach vorn).
    func jumpToPane(_ n: Int) {
        let ordered = displayPanes
        guard ordered.indices.contains(n - 1) else { NSSound.beep(); return }
        focusPane(ordered[n - 1])
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
        // Nur wer die geschlossene Kachel fokussiert hatte, bekommt den Nachbarn — schließt ein Agent eine
        // andere Kachel, bleibt die Tastatur, wo Mats gerade tippt (Live-Befund 23.09.).
        let hadFocus = isFocused(pane) || panes.first(where: { isFocused($0) }) == nil
        // Reiter-Nachbarn: geht die vordere, bekommt die zuletzt gezeigte dahinter Platz und Fokus.
        let mates = placeMembers(of: pane).filter { $0 !== pane }
        // Auch wenn eine ANDERE (verdeckte) Kachel stirbt: das Grid darunter ändert
        // sich — Zoom beenden, damit der Nutzer den neuen Zustand sieht.
        setZoomedPane(nil)
        cancelDividerDrag()
        cancelPaneDrag()
        panes.remove(at: idx)
        shownAt[pane.id.uuidString] = nil
        newsPanes.remove(pane.id)
        // Layout: ihr Platz fällt an ihre Nachbarn im Block; ihre Begleiter werden eigenständig.
        companionOf[pane.id] = nil
        for (companion, anchor) in companionOf where anchor == pane.id { companionOf[companion] = nil }
        settledPreferences.remove(pane.id)
        if let root = manualLayout { manualLayout = LayoutEdit.remove(pane.id.uuidString, from: root) }
        if panes.count <= 1 { manualLayout = nil }
        layoutChanged()
        updateTitlebarHUD()
        pane.container.removeFromSuperview()
        guard !panes.isEmpty else { window?.close(); return }
        updateFocusBorders()
        relayout(animated: true)
        guard hadFocus else { return }
        let successor = mates.max { (shownAt[$0.id.uuidString] ?? 0) < (shownAt[$1.id.uuidString] ?? 0) }
            ?? panes[min(idx, panes.count - 1)]
        let visible = frontOfPlace(of: successor) ?? successor
        window?.makeFirstResponder(visible.focusTarget)
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
        let ordered = displayPanes   // Chips in Lesereihenfolge des Layouts
        for level in levels {
            specs = []
            for pane in ordered {
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
            chip.onDrag = { [weak self, weak pane] event in
                guard let self, let pane else { return false }
                return self.dragPane(pane.id.uuidString, with: event)
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
        reveal(pane)
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
        reveal(pane)
        if let zoomed = zoomedPane, zoomed !== pane {
            setZoomedPane(pane)
            updateFocusBorders()
            relayout(animated: true)
        }
        window?.makeFirstResponder(pane.focusTarget)
        updateTitlebarHUD()
    }

    // MARK: - Layout

    /// Setzt die Frames aller Kacheln gemäß aktuellem Layout-Baum.
    /// Fensterbreite entscheidet, wie ausführlich die Titelleisten-Chips sein dürfen.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateTitlebarHUD()
    }

    /// Der Baum, der gerade gilt: angepasst (bereinigt, jede Kachel drin) oder von der Automatik.
    private func effectiveLayout() -> LayoutNode? {
        rawLayout()?.withFront { self.shownAt[$0] ?? 0 }
    }

    private func rawLayout() -> LayoutNode? {
        let ids = Set(panes.map { $0.id.uuidString })
        if var manual = manualLayout?.normalized(keeping: ids) {
            // Sicherheitsnetz: jede Kachel steht im Baum — sonst läge sie unsichtbar unter den anderen.
            for pane in panes where !manual.paneIDs.contains(pane.id.uuidString) {
                manual = LayoutEdit.insert(pane.id.uuidString, companionOf: nil, anchorCompanions: [], focusBlock: [],
                                           preference: pane.layoutPreference, anchorPreference: .flexible,
                                           into: manual, bounds: bounds, gap: Double(Self.gap))
            }
            return manual
        }
        let items = panes.map { pane in
            LayoutItem(id: pane.id.uuidString, companionOf: companionOf[pane.id]?.uuidString,
                       preference: pane.layoutPreference)
        }
        return AutoLayout.build(items, width: Double(bounds.width), height: Double(bounds.height), gap: Double(Self.gap))
    }

    /// Kacheln in Lesereihenfolge des Layouts (links → rechts, oben → unten): Index im Steuerkanal,
    /// Titelleisten-Chips. `panes` bleibt die Entstehungsreihenfolge (Snapshot, Fokus-Nachfolger).
    private var displayPanes: [any Pane] {
        guard panes.count > 1, let root = effectiveLayout() else { return panes }
        var byID = Dictionary(panes.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = root.paneIDs.compactMap { byID.removeValue(forKey: $0) }
        return ordered + panes.filter { byID[$0.id.uuidString] != nil }
    }

    // MARK: Reiter

    /// Kacheln, die gerade als hintere Reiter verdeckt sind.
    private var hiddenTabIDs: Set<String> {
        guard panes.count > 1, let root = effectiveLayout() else { return [] }
        return Set(root.hiddenPaneIDs)
    }

    /// Alle Kacheln am Platz von `pane` (Reiter samt ihr; sonst nur sie).
    private func placeMembers(of pane: any Pane) -> [any Pane] {
        guard let root = effectiveLayout(), let path = LayoutEdit.path(of: pane.id.uuidString, in: root) else { return [pane] }
        let ids = LayoutEdit.node(at: path, in: root).members
        return ids.compactMap { id in panes.first { $0.id.uuidString == id } }
    }

    /// Die Kachel, die am Platz von `pane` gerade vorn liegt.
    private func frontOfPlace(of pane: any Pane) -> (any Pane)? {
        guard let root = effectiveLayout(), let path = LayoutEdit.path(of: pane.id.uuidString, in: root),
              let front = LayoutEdit.node(at: path, in: root).pane else { return nil }
        return panes.first { $0.id.uuidString == front }
    }

    private func markShown(_ pane: any Pane) {
        shownClock += 1
        shownAt[pane.id.uuidString] = shownClock
    }

    /// Verdeckten Reiter nach vorn holen (sofort, ohne Animation). Kein neuer Layout-Stand: was vorn liegt,
    /// ändert keine Aufteilung. true = war verdeckt.
    @discardableResult
    private func reveal(_ pane: any Pane) -> Bool {
        guard hiddenTabIDs.contains(pane.id.uuidString) else { return false }
        markShown(pane)
        relayout(animated: false)
        return true
    }

    /// Reiter angeklickt: nach vorn und fokussieren.
    private func selectTab(_ id: String) {
        guard let pane = panes.first(where: { $0.id.uuidString == id }) else { return }
        focusPane(pane)
    }

    /// Reiter-Leisten an die Plätze legen; Inhalte (Titel, Farbe, Fokus) zieht `updateTabBarContents` nach.
    private func placeTabBars(_ bars: [LayoutTabBar]) {
        currentTabBars = bars
        while tabBarViews.count > bars.count { tabBarViews.removeLast().removeFromSuperview() }
        while tabBarViews.count < bars.count {
            let view = PaneTabBarView(frame: .zero)
            view.onSelect = { [weak self] in self?.selectTab($0) }
            view.onClose = { [weak self] id in
                guard let self, let pane = self.panes.first(where: { $0.id.uuidString == id }) else { return }
                self.closePane(pane)
            }
            view.onDrag = { [weak self] id, event in self?.dragPane(id, with: event) }
            addSubview(view)
            tabBarViews.append(view)
        }
        // Im Zoom verdeckt die gezoomte Kachel alles.
        for view in tabBarViews { view.isHidden = zoomedPane != nil }
        updateTabBarContents()
    }

    private func updateTabBarContents() {
        guard !currentTabBars.isEmpty else { return }
        let ordered = displayPanes
        for (view, bar) in zip(tabBarViews, currentTabBars) {
            view.tabs = bar.tabs.compactMap { id in
                panes.first { $0.id.uuidString == id }.map { pane in
                    let index = ordered.firstIndex { $0 === pane }.map { $0 + 1 }
                    let badge = id == bar.front ? nil : tabBadge(for: pane)
                    return PaneTabBarView.Tab(id: id, number: index.flatMap { $0 <= 9 ? $0 : nil },
                                       title: pane.tabTitle, accent: pane.effectiveAccent,
                                       front: id == bar.front, focused: id == bar.front && isFocused(pane),
                                       badge: badge?.badge, badgeText: badge?.text)
                }
            }
        }
    }

    /// Abzeichen eines verdeckten Reiters (Scheibe C), wichtigstes zuerst: Agent wartet › arbeitet › ungesehenes
    /// Ergebnis › Inhalt neu. Alles aus dem Chip der Kachel (eine Wahrheit mit der Titelleiste) plus `newsPanes`.
    private func tabBadge(for pane: any Pane) -> (badge: PaneTabBarView.Badge, text: String)? {
        let chip = pane.statusChip
        // Texte ohne Uhr: der Chip tickt sekündlich, der Tooltip soll dabei nicht flackern.
        if chip.urgent { return (.attention(chip.tone), chip.long ?? chip.short ?? "braucht dich") }
        if chip.pulsing { return (.working(chip.tone), "arbeitet") }
        if chip.outcome { return (.outcome(chip.tone), chip.long ?? chip.short ?? "fertig") }
        if newsPanes.contains(pane.id) { return (.news(pane.effectiveAccent), "neu, seit sie verdeckt ist") }
        return nil
    }

    /// Wurzel-Kachel einer Kachel: der Begleiter eines Begleiters gehört zu dessen Kachel.
    private func rootAnchor(of id: UUID) -> UUID {
        var current = id
        var visited: Set<UUID> = [id]
        while let next = companionOf[current], panes.contains(where: { $0.id == next }) {
            guard visited.insert(next).inserted else { return id }
            current = next
        }
        return current
    }

    /// Kacheln, die zu `anchor` gehören (sie selbst und alle ihre Begleiter), ohne `excluding`.
    private func block(of anchor: UUID, excluding: UUID? = nil) -> Set<String> {
        Set(panes.filter { $0.id != excluding && rootAnchor(of: $0.id) == anchor }.map { $0.id.uuidString })
    }

    /// Angepasstes Layout: neue Kachel einsetzen, ohne den Rest umzuwerfen (Begleiter in die Nebenspalte
    /// ihrer Kachel, eigenständige neben den Block der fokussierten).
    private func insertIntoManualLayout(_ pane: any Pane, focused: (any Pane)?) {
        guard let root = manualLayout else { return }
        let anchor = companionOf[pane.id].map { rootAnchor(of: $0) }
        let anchorPane = anchor.flatMap { a in panes.first { $0.id == a } }
        let companions = anchor.map { block(of: $0, excluding: pane.id).subtracting([$0.uuidString]) } ?? []
        let focusBlock = focused.map { block(of: rootAnchor(of: $0.id), excluding: pane.id) } ?? []
        manualLayout = LayoutEdit.insert(pane.id.uuidString, companionOf: anchor?.uuidString,
                                         anchorCompanions: companions, focusBlock: focusBlock,
                                         preference: pane.layoutPreference,
                                         anchorPreference: anchorPane?.layoutPreference ?? .flexible,
                                         into: root, bounds: bounds, gap: Double(Self.gap))
    }

    private func relayout(animated: Bool = false) {
        guard !panes.isEmpty else { return }
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0, let root = effectiveLayout() else { return }
        if manualLayout != nil { manualLayout = root }   // bereinigte Fassung behalten
        let (slots, lines, bars) = LayoutGeometry.layout(root, in: bounds, gap: Self.gap, tabBarHeight: Self.tabBarHeight)
        let slotByID = Dictionary(slots.map { ($0.pane, $0) }, uniquingKeysWith: { a, _ in a })
        placeTabBars(bars)

        var frames: [NSRect] = []
        var cornerMasks: [CACornerMask] = []
        var cornerRadii: [CGFloat] = []
        for pane in panes {
            guard let slot = slotByID[pane.id.uuidString] else {
                // Kann nach `effectiveLayout` nicht vorkommen; dann lieber stehen lassen als springen.
                frames.append(pane.container.frame)
                cornerMasks.append(pane.container.layer?.maskedCorners ?? [])
                cornerRadii.append(pane.container.layer?.cornerRadius ?? 8)
                continue
            }
            frames.append(slot.frame)
            // Ecken-Regeln (AppKit flippt die Layer-Geometrie mit, isFlipped → minY = oben):
            // - Obere Außenecken ECKIG: die Kachel sitzt unterhalb der Titlebar, die Fenster-Rundung
            //   ist dort schon vorbei — ein eigener Radius ergäbe die alte „Doppelabrundung".
            // - Untere Außenecken RUNDEN, mit Fenster-Radius: die Kachel liegt IN der unteren
            //   Fenster-Rundung; eine eckige Akzent-Outline würde dort von der Fenster-Maske abgeschnitten.
            // - Innen-Steg-Ecken runden wie gehabt (8px).
            let topOuter = slot.outer.contains(.top), bottomOuter = slot.outer.contains(.bottom)
            let leftOuter = slot.outer.contains(.left), rightOuter = slot.outer.contains(.right)
            var mask = CACornerMask()
            if !(topOuter && leftOuter)     { mask.insert(.layerMinXMinYCorner) }
            if !(topOuter && rightOuter)    { mask.insert(.layerMaxXMinYCorner) }
            mask.insert(.layerMinXMaxYCorner)
            mask.insert(.layerMaxXMaxYCorner)
            cornerMasks.append(mask)
            cornerRadii.append(bottomOuter ? Self.windowCornerRadius : 8)
        }

        // Zoom-Sonderfall (#26): die gezoomte Kachel bekommt statt ihres Layout-Frames
        // die vollen Bounds und wird per Subview-Reorder über alle anderen gehoben;
        // deren Frames bleiben unverändert darunter liegen. Alle Ecken sind
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
        // viele Zwischengrößen die Animation produziert. Beim Ziehen einer Trennlinie nicht:
        // da halten die Hüllen ihren Inhalt fest (`holdsContent`), gesetzt wird beim Loslassen.
        if dragOrigin == nil {
            for (pane, frame) in zip(panes, frames) { pane.container.pinContent(forTargetSize: frame.size) }
        }

        // Hintere Reiter: gleicher Frame wie die vordere, aber verborgen; die gezoomte ist immer sichtbar.
        let hidden = panes.map { pane in slotByID[pane.id.uuidString]?.hidden == true && pane !== zoomedPane }
        if animated && !isFirstLayout && window != nil && dragOrigin == nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for (i, pane) in panes.enumerated() {
                    if hidden[i] { pane.container.frame = frames[i] } else { pane.container.animator().frame = frames[i] }
                }
                for (view, bar) in zip(tabBarViews, bars) { view.animator().frame = bar.rect }
            }
        } else {
            for (pane, frame) in zip(panes, frames) { pane.container.frame = frame }
            for (view, bar) in zip(tabBarViews, bars) { view.frame = bar.rect }
        }
        for (pane, isHidden) in zip(panes, hidden) where pane.container.isHidden != isHidden { pane.container.isHidden = isHidden }
        // Wieder vorn = gesehen: kein „neu“ mehr.
        let seen = zip(panes, hidden).filter { !$0.1 }.map { $0.0.id }
        if !newsPanes.isDisjoint(with: seen) {
            newsPanes.subtract(seen)
            updateTabBarContents()
        }
        isFirstLayout = false
        updateDividers(lines)
        keepFocusVisible()
    }

    /// Liegt der Tastaturfokus in einer Kachel, die gerade verdeckt wurde, wandert er zur vorderen ihres Platzes.
    private func keepFocusVisible() {
        guard let responder = window?.firstResponder as? NSView,
              let owner = panes.first(where: { responder.isDescendant(of: $0.container) }),
              owner.container.isHidden, let front = frontOfPlace(of: owner), front !== owner else { return }
        window?.makeFirstResponder(front.focusTarget)
    }

    // MARK: Trennlinien (Mats zieht)

    private func updateDividers(_ lines: [LayoutDivider]) {
        while dividerViews.count > lines.count { dividerViews.removeLast().removeFromSuperview() }
        for (i, line) in lines.enumerated() {
            if i < dividerViews.count {
                dividerViews[i].update(line)
            } else {
                let view = PaneDividerView(divider: line)
                view.onBegin = { [weak self] in self?.dividerBegan($0) }
                view.onMove = { [weak self] in self?.dividerMoved($0, to: $1) }
                view.onEnd = { [weak self] in self?.dividerEnded($0) }
                view.onDoubleClick = { [weak self] in self?.dividerDoubleClicked($0) }
                addSubview(view)
                dividerViews.append(view)
            }
            // Im Zoom verdeckt die gezoomte Kachel alles; eine einzelne Kachel hat keine Stege.
            dividerViews[i].isHidden = zoomedPane != nil
        }
    }

    private func dividerBegan(_ view: PaneDividerView) {
        guard zoomedPane == nil, let root = manualLayout ?? effectiveLayout(),
              LayoutEdit.exists(view.divider.path, in: root) else { return }
        dragOrigin = (root, view.divider)
        panes.forEach { $0.container.holdsContent = true }
    }

    private func dividerMoved(_ view: PaneDividerView, to position: Double) {
        guard let origin = dragOrigin else { return }
        // Kachel dazu oder weg während des Zugs: Linie gehört zu einem alten Stand → abbrechen.
        guard Set(origin.tree.paneIDs) == Set(panes.map { $0.id.uuidString }) else { cancelDividerDrag(); return }
        manualLayout = LayoutEdit.dragged(origin.tree, divider: origin.divider, to: position,
                                          minimum: Self.dragMinimum, actor: .mats)
        relayout(animated: false)
    }

    private func dividerEnded(_ view: PaneDividerView) {
        guard let origin = dragOrigin else { return }
        finishDividerDrag()
        if manualLayout != origin.tree { layoutChanged() }
    }

    private func dividerDoubleClicked(_ view: PaneDividerView) {
        guard zoomedPane == nil, dragOrigin == nil, let root = manualLayout ?? effectiveLayout() else { return }
        let equal = LayoutEdit.equalized(root, divider: view.divider, actor: .mats)
        guard equal != root else { return }
        manualLayout = equal
        relayout(animated: true)
        layoutChanged()
    }

    /// Zug beenden: Hüllen geben den Inhalt frei, ein Relayout setzt die Endgröße (ein Resize je Kachel).
    private func finishDividerDrag() {
        dragOrigin = nil
        panes.forEach { $0.container.holdsContent = false }
        relayout(animated: false)
    }

    /// Kachel kam dazu oder ging während eines Zugs: der Zug gilt bis hierhin.
    private func cancelDividerDrag() {
        guard dragOrigin != nil else { return }
        finishDividerDrag()
        layoutChanged()
    }

    // MARK: Kachel ziehen (Mats, Stufe 2 Scheibe B)

    /// Kachel am Reiter oder Titelleisten-Chip gezogen: bis zum Loslassen zeigt die Anzeige, wo sie landen
    /// würde; beim Loslassen wird genau das umgesetzt, Esc bricht ab. Der Zug läuft als eigene
    /// Ereignisschleife (`trackEvents`) und kehrt erst danach zurück — so hängt er nicht an der Quelle
    /// (Chips werden bei jeder Statusänderung neu aufgebaut, Reiterleisten beim Umordnen). Gerechnet wird bei
    /// jedem Schritt auf dem aktuellen Baum: ändert ein Agent oder die Automatik etwas, folgt die Anzeige;
    /// kommt eine Kachel dazu oder geht eine, endet der Zug ohne Wirkung. false = nichts zu ziehen.
    @discardableResult
    private func dragPane(_ id: String, with event: NSEvent) -> Bool {
        guard let window, paneDrag == nil, dragOrigin == nil, zoomedPane == nil, panes.count > 1,
              let pane = panes.first(where: { $0.id.uuidString == id }) else { return false }
        let overlay = PaneDropOverlayView(frame: bounds)
        overlay.title = pane.tabTitle
        overlay.accent = pane.effectiveAccent
        addSubview(overlay)
        paneDrag = (id, overlay)
        let members = Set(panes.map { $0.id.uuidString })
        NSCursor.closedHand.push()
        window.disableCursorRects()
        defer {
            window.enableCursorRects()
            NSCursor.pop()
        }

        // Position über den Bildschirm umrechnen: im Vollbild liegen die Chips in einem eigenen Titelleisten-Fenster,
        // dessen `locationInWindow` nichts mit diesem Fenster zu tun hat.
        func location(_ event: NSEvent) -> NSPoint {
            let screen = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation
            return window.convertPoint(fromScreen: screen)
        }
        var drop: LayoutNode?
        var dropRevision = 0
        updatePaneDrag(at: location(event))
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown, .appKitDefined],
                           timeout: NSEvent.foreverDuration, mode: .eventTracking) { [weak self] event, stop in
            // Kachel auf/zu (cancelPaneDrag) oder Zoom (Benachrichtigung, Steuerkanal) beendet den Zug ohne Wirkung.
            guard let self, let event, self.paneDrag?.pane == id, self.zoomedPane == nil,
                  Set(self.panes.map { $0.id.uuidString }) == members else { stop.pointee = true; return }
            switch event.type {
            case .leftMouseDragged:
                self.updatePaneDrag(at: location(event))
            case .leftMouseUp:
                drop = self.updatePaneDrag(at: location(event))
                dropRevision = self.layoutRevision
                stop.pointee = true
            case .keyDown where event.keyCode == 53:   // Esc
                stop.pointee = true
            case .rightMouseDown:
                stop.pointee = true
            case .appKitDefined where event.subtype == .applicationDeactivated:
                stop.pointee = true
            default:
                break
            }
        }
        let valid = paneDrag?.pane == id && zoomedPane == nil && Set(panes.map { $0.id.uuidString }) == members
        cancelPaneDrag()
        guard valid, let drop else { return true }
        // Nach dem Rücksprung aus dem Maus-Handler der Quelle umbauen: die Quelle (Chip, Reiterleiste) darf
        // dabei verschwinden, ohne dass ihr eigener Aufruf noch auf ihr läuft.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panes.contains(where: { $0 === pane }), self.zoomedPane == nil,
                  self.layoutRevision == dropRevision,
                  Set(self.panes.map { $0.id.uuidString }) == members else { return }
            self.applyPaneDrop(pane, result: drop)
        }
        return true
    }

    /// Ziel unter der Maus bestimmen und anzeigen; liefert das Ergebnis, das ein Loslassen hier hätte (nil = keins).
    @discardableResult
    private func updatePaneDrag(at locationInWindow: NSPoint) -> LayoutNode? {
        guard let drag = paneDrag, let tree = effectiveLayout() else { return nil }
        let overlay = drag.overlay
        if overlay.frame != bounds { overlay.frame = bounds }
        // Neue Reiterleisten/Stege (Agent ordnet während des Zugs um) kämen sonst darüber.
        if subviews.last !== overlay { addSubview(overlay, positioned: .above, relativeTo: nil) }
        let point = convert(locationInWindow, from: nil)
        overlay.cursor = point
        let current = LayoutGeometry.layout(tree, in: bounds, gap: Self.gap, tabBarHeight: Self.tabBarHeight)
        overlay.source = current.slots.first { $0.pane == drag.pane && !$0.hidden }?.frame
        overlay.caret = nil
        overlay.preview = nil
        overlay.note = nil

        guard let target = dropTarget(at: point, in: current) else { return nil }
        if case .tabBar(let front, let index) = target,
           let (view, _) = zip(tabBarViews, currentTabBars).first(where: { $0.1.front == front }),
           let caret = view.insertionCaret(for: index) {
            overlay.caret = convert(caret, from: view)
        }
        guard let result = LayoutEdit.moved(drag.pane, to: target, in: tree, actor: .mats) else {
            overlay.caret = nil
            return nil
        }
        let next = LayoutGeometry.layout(result, in: bounds, gap: Self.gap, tabBarHeight: Self.tabBarHeight)
        // Sieht danach alles gleich aus (z. B. A links neben B, wo A schon steht), ist es kein Wurf — sonst würde
        // die Anordnung ohne sichtbaren Grund angepasst, ✋ und neue Stand-Nummer.
        let byPane: ([LayoutSlot]) -> [LayoutSlot] = { $0.sorted { $0.pane < $1.pane } }
        if byPane(next.slots) == byPane(current.slots), next.tabBars == current.tabBars {
            overlay.caret = nil
            return nil
        }
        guard fitsAfterDrop(before: current.slots, after: next.slots, moved: drag.pane),
              let landing = next.slots.first(where: { $0.pane == drag.pane }) else {
            overlay.caret = nil
            overlay.note = "zu eng"
            return nil
        }
        // Landet sie als Reiter, gehört die Leiste zum Platz dazu.
        let bar = next.tabBars.first { $0.tabs.contains(drag.pane) }?.rect
        overlay.preview = bar.map { landing.frame.union($0) } ?? landing.frame
        return result
    }

    /// Ziel unter `point`: eine Reiterleiste (Einfügestelle), der Fensterrand, sonst eine Seite oder die Mitte
    /// des Platzes darunter (Anteil ohne Steg — auch der Spalt gehört so zu einem Nachbarn).
    private func dropTarget(at point: NSPoint, in current: (slots: [LayoutSlot], dividers: [LayoutDivider], tabBars: [LayoutTabBar]))
        -> LayoutDropTarget? {
        guard bounds.contains(point) else { return nil }
        for (view, bar) in zip(tabBarViews, currentTabBars) where !view.isHidden && bar.rect.contains(point) {
            return .tabBar(bar.front, index: view.insertionIndex(at: view.convert(point, from: self)))
        }
        if let edge = LayoutDrop.windowZone(at: point, in: bounds, band: Self.windowDropBand) { return .window(edge) }
        guard let slot = current.slots.first(where: { !$0.hidden && $0.rect.contains(point) }),
              let zone = LayoutDrop.zone(at: point, in: slot.rect) else { return nil }
        return .place(slot.pane, zone)
    }

    /// Kein Wurf darf eine Kachel unbrauchbar klein machen: die gezogene nicht und keine, die dabei schrumpft.
    /// (Was schon vorher so klein war und nicht kleiner wird, bleibt erlaubt.)
    private func fitsAfterDrop(before: [LayoutSlot], after: [LayoutSlot], moved: String) -> Bool {
        let old = Dictionary(before.map { ($0.pane, $0.frame.size) }, uniquingKeysWith: { a, _ in a })
        let min = Self.dropMinimum
        for slot in after where !slot.hidden || slot.pane == moved {
            let size = slot.frame.size
            let was = slot.pane == moved ? nil : old[slot.pane]
            if size.width < min.width, size.width < (was?.width ?? .infinity) - 0.5 { return false }
            if size.height < min.height, size.height < (was?.height ?? .infinity) - 0.5 { return false }
        }
        return true
    }

    /// Wurf umsetzen: Anordnung gilt als angepasst (die neue Teilung ✋), die Kachel liegt vorn und hat den Fokus.
    private func applyPaneDrop(_ pane: any Pane, result: LayoutNode) {
        guard let root = effectiveLayout(), Set(result.paneIDs) == Set(root.paneIDs) else { return }
        manualLayout = result
        markShown(pane)
        relayout(animated: true)
        layoutChanged()
        window?.makeFirstResponder(pane.focusTarget)
    }

    /// Anzeige weg; ein laufender Zug endet ohne Wirkung (Kachel auf/zu, Abbruch, Ende).
    private func cancelPaneDrag() {
        guard let drag = paneDrag else { return }
        paneDrag = nil
        drag.overlay.removeFromSuperview()
    }

    /// „Kachel 2 (preview)“ — Index in Lesereihenfolge.
    private func layoutName(_ pane: any Pane) -> String {
        let index = (displayPanes.firstIndex { $0 === pane } ?? 0) + 1
        return "Kachel \(index) (\(pane.kind))"
    }

    /// Neue Stand-Nummer: jedes Lagebild, das ein Agent vorher gelesen hat, ist damit veraltet. Die Chips in der
    /// Titelleiste folgen der Lesereihenfolge — nach jeder Änderung der Anordnung nachziehen.
    private func layoutChanged() {
        layoutRevision += 1
        updateTitlebarHUD()
    }

    /// Menü „Automatisch anordnen“ / Agent mit Auftrag: Anordnung zurück an die Automatik.
    fileprivate func rearrangeAutomatically() {
        guard manualLayout != nil else { return }
        cancelDividerDrag()
        manualLayout = nil
        relayout(animated: true)
        layoutChanged()
    }
}

// MARK: - Rückkanal der Kacheln

extension TerminalSplitView: PaneHost {
    /// ⌘T: die anfordernde Kachel ist die fokussierte → ihr CWD vererben (#8).
    func paneRequestsSplit(_ pane: any Pane) { addPane(startingIn: pane.currentDirectory) }
    func paneRequestsClose(_ pane: any Pane) { closePane(pane) }
    func paneDidClose(_ pane: any Pane) { removePane(pane) }
    func paneRequestsZoom(_ pane: any Pane) { toggleZoom(pane) }
    func paneRequestsJump(toPane index: Int) { jumpToPane(index) }

    func paneStyleChanged(_ pane: any Pane) {
        // Ungesehenes Ergebnis hinter einem Reiter: auch „neu“ merken — der Nachklang des Chips endet nach
        // 10 min, der Reiter soll sich bis zum Hinsehen erinnern.
        if pane.statusChip.outcome, hiddenTabIDs.contains(pane.id.uuidString) { newsPanes.insert(pane.id) }
        updateWindowTitle()
        updateTitlebarHUD()
        updateTabBarContents()
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

    /// Inhalt geladen, Wunschform steht fest (PDF hochkant …): einmal neu anordnen, danach nie wieder
    /// für diese Kachel — ein später geladenes PDF anderer Form verschiebt nichts. Angepasste Layouts
    /// und laufende Züge bleiben unberührt.
    /// Neuigkeit nur für verdeckte Reiter merken — was vorn liegt, sieht Mats ja.
    func paneHasNews(_ pane: any Pane) {
        guard hiddenTabIDs.contains(pane.id.uuidString), newsPanes.insert(pane.id).inserted else { return }
        updateTabBarContents()
    }

    func paneLayoutPreferenceChanged(_ pane: any Pane) {
        guard settledPreferences.insert(pane.id).inserted, manualLayout == nil, dragOrigin == nil else { return }
        relayout(animated: true)
        layoutChanged()
    }

    func paneRequestsFreshTerminal(focus: Bool) -> TerminalPane {
        let fresh = addPane(home: true)
        if focus { focusPane(fresh) }
        return fresh
    }

    func agentPanes() -> [PaneInfo] {
        ControlServer.shared.router.panes.filter { $0.runningAgent != nil }
    }

    /// Über den Router, damit es auch in Kacheln anderer Fenster geht: einfügen (ohne Enter), dann Fokus.
    func paneRequestsPaste(_ text: String, intoPaneID: String) -> Bool {
        var send = ControlRequest(cmd: "send", pane: intoPaneID)
        send.text = text
        send.enter = false
        send.paste = true
        guard ControlServer.shared.router.route(send).ok else { return false }
        _ = ControlServer.shared.router.route(ControlRequest(cmd: "focus", pane: intoPaneID))
        return true
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
    var controlPanes: [PaneInfo] { window == nil || windowClosed ? [] : displayPanes.map { info(for: $0) } }

    func layoutReport() -> LayoutReport? {
        guard window != nil, !windowClosed else { return nil }
        return LayoutReport(revision: layoutRevision, automatic: manualLayout == nil, root: effectiveLayout(),
                            width: Double(bounds.width), height: Double(bounds.height))
    }


    func handleControl(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case "list-panes":
            return ControlResponse(ok: true, panes: displayPanes.map { info(for: $0) })

        case "pane-kinds":
            return ControlResponse(ok: true, kinds: PaneKindRegistry.kinds, kindInfos: PaneKindRegistry.infos)

        case "new-pane":
            // Wer öffnet: die Kachel des Aufrufers (CLI/MCP schicken ihre LATEXTERM_PANE_ID mit).
            let openerID = request.paneID.flatMap(UUID.init(uuidString:))
            let opener = openerID?.uuidString
            let kind = request.kind ?? "terminal"
            let args = request.args ?? [:]
            if kind != "terminal", request.cwd != nil || request.exec != nil {
                return .failure("--cwd und --exec gibt es nur für terminal")
            }
            // Kachel-Layout: neben die aufrufende Kachel (Default), eigenständig auf Wunsch ("own",
            // neue Agenten-Session). Ohne Aufrufer im Fenster: App-Kacheln neben die fokussierte.
            let placement: PanePlacement
            switch request.placement {
            case "own": placement = .own
            case nil, "beside":
                if let openerID, panes.contains(where: { $0.id == openerID }) { placement = .beside(openerID) }
                else { placement = kind == "terminal" || kind == "home" ? .own : .besideFocused }
            default: return .failure("placement „\(request.placement ?? "")“ unbekannt (beside | own)")
            }
            let layout = { self.layoutReport() }
            switch kind {
            case "terminal", "home":
                guard args.isEmpty else { return .failure("\(kind) kennt kein --arg") }
                let pane = addPane(startingIn: request.cwd, home: kind == "home", focus: request.focus ?? true,
                                   placement: placement)
                pane.openedBy = opener
                if let exec = request.exec, !exec.isEmpty {
                    // Sofort in die PTY — der Kernel puffert, die Shell liest das
                    // Kommando, sobald sie bereit ist (kein Delay/Poll nötig).
                    pane.view.send(txt: exec + "\r")
                }
                return ControlResponse(ok: true, pane: info(for: pane), layout: layout())
            default:
                do {
                    let pane = try addAppPane(kind: kind, args: args, focus: request.focus ?? true, placement: placement)
                    pane.openedBy = opener
                    return ControlResponse(ok: true, pane: info(for: pane), layout: layout())
                }
                catch { return .failure(String(describing: error)) }
            }

        case "layout":
            return handleLayout(request)

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

        case "call":
            guard let pane = resolvePane(request.pane ?? request.paneID) else {
                return .failure("Kachel nicht gefunden: „\(request.pane ?? request.paneID ?? "kein Ziel angegeben")“ — `latexterm list-panes` zeigt Index und ID")
            }
            guard let text = request.text, !text.isEmpty else { return .failure("call braucht einen Text") }
            do {
                let reply = try pane.call(text)
                return ControlResponse(ok: true, pane: info(for: pane), reply: reply)
            } catch {
                return .failure(String(describing: error))
            }

        case "send", "zoom", "focus", "activate":
            guard let pane = resolvePane(request.pane ?? request.paneID) else {
                return .failure("Kachel nicht gefunden: „\(request.pane ?? request.paneID ?? "kein Ziel angegeben")“ — `latexterm list-panes` zeigt Index und ID")
            }
            switch request.cmd {
            case "send":
                guard let text = request.text, !text.isEmpty else {
                    return .failure("send braucht einen Text")
                }
                guard pane.receive(text, enter: request.enter ?? true, paste: request.paste ?? false) else {
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
                        index: (displayPanes.firstIndex(where: { $0 === pane }) ?? 0) + 1,
                        cwd: pane.currentDirectory,
                        focused: isActiveControlWindow && isFocused(pane),
                        zoomed: pane === zoomedPane,
                        state: state, agent: identity?.agent,
                        sessionID: identity?.sessionID,
                        windowID: window.map { String($0.windowNumber) },
                        tab: WindowTabs.position(of: window),
                        kind: pane.kind,
                        title: String(pane.title.prefix(120)),
                        args: terminal == nil ? pane.snapshot()?.args : nil,
                        foreground: terminal?.foregroundProcessName,
                        openedBy: pane.openedBy,
                        companionOf: companionOf[pane.id]?.uuidString,
                        hidden: hiddenTabIDs.contains(pane.id.uuidString) ? true : nil)
    }

    /// Steuerkanal `layout` (Kachel-Layout): Stand zeigen oder eine Absicht anwenden. Ein Agent ordnet
    /// nur auf dem aktuellen Stand um: er schickt die Stand-Nummer mit, die er zuletzt gelesen hat —
    /// passt sie nicht, lehnt die App ab (er liest neu und entscheidet dann). Rechte: eigene Kacheln
    /// (die aufrufende und alles, was sie geöffnet hat) frei, fremde nur mit `onBehalf`; Teilungen, die
    /// Mats von Hand gesetzt hat, ebenfalls nur mit `onBehalf` (Prüfung in `LayoutEdit`). Ohne Aufrufer
    /// (CLI von Hand außerhalb einer Kachel) handelt Mats selbst.
    private func handleLayout(_ request: ControlRequest) -> ControlResponse {
        let caller = request.paneID?.uppercased()
        let report = { self.layoutReport() }
        let op = request.layoutOp ?? "show"
        let onBehalf = request.onBehalf ?? false
        let actor: LayoutActor = caller == nil ? .mats : .agent
        func own(_ pane: any Pane) -> Bool {
            guard let caller else { return true }
            return pane.id.uuidString == caller || pane.openedBy?.uppercased() == caller
        }
        if op == "show" { return ControlResponse(ok: true, layout: report()) }
        if actor == .agent, request.layoutRevision != layoutRevision {
            var stale = ControlResponse.failure(request.layoutRevision == nil
                ? "Erst den aktuellen Stand lesen (layout zeigen) und dessen Stand-Nummer mitschicken."
                : "Die Anordnung hat sich geändert, seit du sie gelesen hast (Stand \(request.layoutRevision!) → \(layoutRevision)). Aktueller Stand anbei — prüfen, dann erneut.")
            stale.layout = report()
            return stale
        }
        if op == "auto" {
            if let manual = manualLayout, manual.containsMatsLock, !onBehalf, actor == .agent {
                return .failure("Mats hat die Anordnung von Hand angepasst — zurück zur Automatik nur auf seinen Wunsch (auf_auftrag: true).")
            }
            rearrangeAutomatically()
            return ControlResponse(ok: true, layout: report())
        }
        guard let first = resolvePane(request.pane) else {
            return .failure("Kachel nicht gefunden: „\(request.pane ?? "keine angegeben")“")
        }
        var targets = [first]
        if let selector = request.otherPane {
            guard let second = resolvePane(selector) else {
                return .failure("Zweite Kachel „\(selector)“ steht nicht in diesem Fenster — umordnen geht nur innerhalb eines Fensters.")
            }
            targets.append(second)
        }
        if !onBehalf, let foreign = targets.first(where: { !own($0) }) {
            return .failure("\(layoutName(foreign)) hast nicht du geöffnet — fremde Kacheln ordnest du nur auf ausdrücklichen Auftrag um (auf_auftrag: true).")
        }
        // Reiter nach vorn holen: ändert keine Aufteilung, also auch keinen Stand.
        if op == "front" {
            reveal(first)
            return ControlResponse(ok: true, pane: info(for: first), layout: report())
        }
        let a = first.id.uuidString, b = targets.count > 1 ? targets[1].id.uuidString : nil
        let intent: LayoutOp
        switch (op, b) {
        case ("big", _): intent = .big(a)
        case ("grow", _): intent = .grow(a)
        case ("shrink", _): intent = .shrink(a)
        case ("beside", let b?): intent = .beside(a, b)
        case ("below", let b?): intent = .below(a, b)
        case ("swap", let b?): intent = .swap(a, b)
        case ("tab", let b?): intent = .tab(a, into: b)
        case ("beside", nil), ("below", nil), ("swap", nil), ("tab", nil): return .failure("\(op) braucht eine zweite Kachel (otherPane)")
        default: return .failure("Unbekannte Absicht „\(op)“ (show, big, grow, shrink, beside, below, swap, tab, front, auto)")
        }
        guard zoomedPane == nil else { return .failure("Gerade ist eine Kachel gezoomt (⌘⏎) — erst danach umordnen.") }
        guard let root = manualLayout ?? effectiveLayout() else { return .failure("Kein Layout") }
        let changed: LayoutNode
        do { changed = try LayoutEdit.apply(intent, to: root, actor: actor, overrideMats: onBehalf || actor == .mats) }
        catch { return .failure(String(describing: error)) }
        switch intent {
        case .big, .grow, .shrink:
            // Wer eine Kachel groß haben will, will sie sehen.
            markShown(first)
        case .tab:
            // Als Reiter anlegen = dahinter: die bisher vordere am Zielplatz bleibt vorn.
            if let front = frontOfPlace(of: targets[1]) { markShown(front) }
        default: break
        }
        if changed != root {
            cancelDividerDrag()
            manualLayout = changed
            relayout(animated: true)
            layoutChanged()
        } else {
            relayout(animated: false)
        }
        return ControlResponse(ok: true, pane: info(for: first), layout: report())
    }

    /// Löst den Ziel-Selektor des CLI auf eine Kachel auf. Semantik: reine Ziffern
    /// sind IMMER der 1-basierte Index aus `list-panes` (nie UUID-Präfix — vorhersagbar
    /// schlägt bequem); alles andere matcht case-insensitiv als UUID-Präfix, aber nur
    /// bei GENAU einem Treffer. Mehrdeutig = nil: `send` in die falsche Shell wäre
    /// Command-Execution, da ist ein Fehler die sichere Antwort.
    private func resolvePane(_ selector: String?) -> (any Pane)? {
        guard let selector, !selector.isEmpty else { return nil }
        if let index = Int(selector) {
            let ordered = displayPanes
            guard (1...ordered.count).contains(index) else { return nil }
            return ordered[index - 1]
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
/// tickt so ohne Neuaufbau. Ziehen verschiebt die Kachel (Kachel-Layout Scheibe B): ab ein paar Punkten Weg
/// übernimmt die Split-View; der Klick zählt deshalb erst beim Loslassen.
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
    /// Zug beginnt: true = die Split-View hat ihn geführt (kehrt erst nach dem Loslassen zurück),
    /// false = hier gibt es nichts zu ziehen (Zoom, eine Kachel) — dann bleibt es ein Klick.
    var onDrag: ((NSEvent) -> Bool)?
    /// Wo gedrückt wurde (Fensterkoordinaten); nil = kein Klick offen.
    private var pressedAt: NSPoint?
    private var dragRefused = false
    private static let dragThreshold: CGFloat = 4
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

    override func mouseDown(with event: NSEvent) {
        pressedAt = event.locationInWindow
        dragRefused = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressedAt, !dragRefused else { return }
        let point = event.locationInWindow
        guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
        // Chips werden bei Statuswechseln neu aufgebaut — während des Zugs am Leben halten.
        let led = withExtendedLifetime(self) { onDrag?(event) == true }
        if led { pressedAt = nil } else { dragRefused = true }
    }

    /// Klick = Loslassen über dem Chip ohne geführten Zug. Wurde die Leiste zwischendurch neu gebaut (Status-
    /// wechsel), hängt der Chip an keinem Fenster mehr — der Klick zählt trotzdem.
    override func mouseUp(with event: NSEvent) {
        defer { pressedAt = nil; dragRefused = false }
        guard pressedAt != nil, window == nil || bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    /// Der ganze Chip ist Ziel — auch über dem Text. Sonst nähme die Titelleiste einen Zug, der auf dem Label
    /// beginnt, als Fenster-Verschieben.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

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
