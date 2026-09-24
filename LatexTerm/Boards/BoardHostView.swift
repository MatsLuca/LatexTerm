import AppKit

/// Menü-Aktionen auf die Bretter des Key-Fensters (`Notification.Name.latexTermBoardCommand`).
enum BoardCommand {
    case new, close, next, previous, rename
    case select(Int)
    /// ⌃0: Home-Brett (Übersicht) — legt es an, wenn es fehlt.
    case home
    case newWindow
}

extension Notification.Name {
    static let latexTermBoardCommand = Notification.Name("LatexTerm.boardCommand")
}

/// Bretter (23.09.2026, Plan `bretter_2026-09-23.md` in der Werkstatt): Inhalt eines Fensters. Hält mehrere Bretter
/// (je ein `TerminalSplitView` mit eigenen Kacheln) übereinander, zeigt eins, und die Brett-Leiste oben links in der
/// Titelleiste. Ersetzt die native macOS-Tab-Leiste — die ließ sich ab zwei Tabs nicht ausblenden (Spike 23.09.).
/// Verdeckte Bretter bleiben mit gleichem Rahmen eingehängt (nur `isHidden`): Prozesse laufen weiter, kein Resize.
final class BoardHostView: NSView {
    /// Öffnet ein neues Fenster der WindowGroup (gesetzt von `TerminalContainer` aus der SwiftUI-Umgebung).
    static var openWindow: (() -> Void)?

    private struct Weak { weak var view: BoardHostView?; init(_ v: BoardHostView) { view = v } }
    /// Alle Fenster in Entstehungsreihenfolge — der Snapshot beim Beenden ist EINE Datei für alle.
    private static var live: [Weak] = []
    /// Beim ersten Zugriff einmal von der Platte geholt; jedes Fenster holt sich eine Gruppe (seine Bretter).
    private static var restoreQueue = RestoreQueue(SessionStore.takeRestore() ?? [])
    private static var restoreStarted = false

    private var boards: [TerminalSplitView] = []
    private var list = BoardList<ObjectIdentifier>()
    private let strip = BoardStripView(frame: .zero)
    private var stripAccessory: NSTitlebarAccessoryViewController?
    private var commandObserver: NSObjectProtocol?
    /// ⌃⇥ / ⌃⇧⇥ = nächstes/voriges Brett. Als Monitor vor allem anderen: die Kachel-Hülle sah die Taste nie, AppKit gibt
    /// ⌃⇥ direkt ans Terminal (Live-Befund 23.09.).
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var windowClosed = false
    private var stripRefreshQueued = false

    // Home-Brett (24.09.2026, Plan claude-werkstatt `plans/home-brett_2026-09-24.md`): Übersicht über alle Bretter +
    // Chef-Claude als verdeckter Reiter. Steht links vor den Brettern, zählt nicht mit (⌃1–9, Brett-Nummern, `tab`),
    // hat ⌃0. Erscheint von selbst ab zwei Brettern und geht bei einem wieder.
    private(set) var homeBoard: TerminalSplitView?
    private var homeActive = false
    /// Mats hat es geschlossen: kommt erst mit ⌃0 wieder oder nachdem die Bretter unter zwei gefallen sind.
    private var homeDismissed = false
    /// Beim Wiederherstellen kein automatisches Home-Brett — es kommt ggf. aus dem Snapshot.
    private var restoring = false

    /// Bretter in Leisten-Reihenfolge.
    var ordered: [TerminalSplitView] {
        list.order.compactMap { id in boards.first { ObjectIdentifier($0) == id } }
    }
    var activeBoard: TerminalSplitView? {
        homeActive ? homeBoard : boards.first { ObjectIdentifier($0) == list.active }
    }
    /// Platz, den die Leiste in der Titelleiste belegt — die Chips rechts rechnen ihn ab.
    var stripWidth: CGFloat { stripAccessory?.view.frame.width ?? 0 }

    init() {
        super.init(frame: .zero)
        let group = Self.restoreQueue.claimGroup()
        if group.isEmpty {
            addBoard(plan: nil, activate: true)
        } else {
            restoring = true
            // Das Home-Brett kommt als eigenes, die übrigen in Snapshot-Reihenfolge.
            let regular = group.filter { $0.home != true }
            if let home = group.first(where: { $0.home == true }) { makeHome(plan: home) }
            for plan in regular { addBoard(plan: plan, activate: false, atEnd: true) }
            if regular.isEmpty { addBoard(plan: nil, activate: true) }
            restoring = false
            if group.first(where: { $0.selected == true })?.home == true, let home = homeBoard {
                activate(home)
            } else {
                let selected = regular.firstIndex { $0.selected == true } ?? 0
                activate(ordered[min(selected, ordered.count - 1)])
            }
            // Nur das erste Fenster öffnet die übrigen; Nachzügler finden die Schlange leer.
            if !Self.restoreStarted {
                Self.restoreStarted = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restoreLeftovers() }
            }
        }

        strip.onSelect = { [weak self] id in
            guard let self, let board = self.board(for: id) else { return }
            self.activate(board)
        }
        strip.onClose = { [weak self] id in
            guard let self, let board = self.board(for: id) else { return }
            self.close(board)
        }
        strip.onAdd = { [weak self] in self?.addBoard(plan: nil, activate: true) }
        strip.onRename = { [weak self] id, name in
            guard let self, let board = self.boards.first(where: { ObjectIdentifier($0) == id }) else { return }
            board.customName = name.isEmpty ? nil : name
            self.refreshStrip()
        }
        strip.onMove = { [weak self] id, gap in
            // Die Leiste zählt das Home-Brett mit, die Liste nicht.
            let gap = gap - (self?.homeBoard == nil ? 0 : 1)
            guard let self, gap >= 0, let index = self.list.moveIndex(for: id, gap: gap) else { return }
            self.list.move(id, to: index)
            self.refreshStrip()
        }
        // Nach dem Umbenennen bekommt die Kachel die Tastatur zurück.
        strip.onEditingEnded = { [weak self] in self?.activeBoard?.restoreFocus() }

        commandObserver = NotificationCenter.default.addObserver(
            forName: .latexTermBoardCommand, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.window?.isKeyWindow == true, let command = note.object as? BoardCommand else { return }
            self.perform(command)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 48, let window = self.window, event.window === window, window.isKeyWindow,
                  event.modifierFlags.intersection([.command, .option, .control]) == .control else { return event }
            self.perform(event.modifierFlags.contains(.shift) ? .previous : .next)
            return nil
        }
        Self.live.append(Weak(self))
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let commandObserver { NotificationCenter.default.removeObserver(commandObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Keine nativen Tabs mehr: Bretter ersetzen sie (die Leiste ließ sich nicht ausblenden).
        window.tabbingMode = .disallowed
        installStrip()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in self?.windowClosed = true }
        // Beim Einhängen gab es noch kein Fenster für Fokus und Chips.
        DispatchQueue.main.async { [weak self] in self?.activeBoard?.boardDidBecomeActive() }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for board in boards { board.frame = bounds }
        homeBoard?.frame = bounds
        if abs(bounds.width - oldSize.width) > 0.5 { refreshStrip() }
    }

    // MARK: Bretter

    @discardableResult
    private func addBoard(plan: SessionSnapshot.Window?, activate: Bool, atEnd: Bool = false) -> TerminalSplitView {
        let board = TerminalSplitView(plan: plan)
        board.boardHost = self
        board.frame = bounds
        board.isHidden = true
        addSubview(board)
        boards.append(board)
        list.add(ObjectIdentifier(board), activate: false, atEnd: atEnd)
        if activate || boards.count == 1 { self.activate(board) }
        updateHomePresence()
        refreshStrip()
        return board
    }

    private func board(for id: ObjectIdentifier) -> TerminalSplitView? {
        if let homeBoard, ObjectIdentifier(homeBoard) == id { return homeBoard }
        return boards.first { ObjectIdentifier($0) == id }
    }

    func activate(_ board: TerminalSplitView) {
        let isHome = board === homeBoard
        guard isHome || boards.contains(where: { $0 === board }) else { return }
        let old = activeBoard
        homeActive = isHome
        if !isHome { list.activate(ObjectIdentifier(board)) }
        if old !== board { old?.boardDidResignActive() }
        if old !== board || board.isHidden { board.boardDidBecomeActive() }
        refreshStrip()
    }

    /// 1-basierte Position in der Leiste; nil, solange es nur ein Brett gibt (Steuerkanal: `tab`).
    func position(of board: TerminalSplitView) -> Int? {
        guard boards.count > 1, board !== homeBoard else { return nil }
        return list.position(of: ObjectIdentifier(board))
    }

    /// Kachel samt Begleitern auf ein anderes Brett dieses Fensters (Steuerkanal `layout` Absicht `board`).
    /// `to` = "new" oder Brett-Nummer. Das Ziel entsteht bzw. steht fest, bevor das alte Brett leer werden kann —
    /// sonst nähme das letzte Brett das Fenster mit. `activate` false: Mats bleibt auf seinem Brett.
    func move(_ pane: any Pane, from source: TerminalSplitView, to: String, activate: Bool) throws -> TerminalSplitView {
        let target: TerminalSplitView
        if to.lowercased() == "new" || to.lowercased() == "neu" {
            target = TerminalSplitView(plan: nil, empty: true)
            target.boardHost = self
            target.frame = bounds
            target.isHidden = true
            addSubview(target)
            boards.append(target)
            list.add(ObjectIdentifier(target), activate: false)
        } else {
            guard let n = Int(to), ordered.indices.contains(n - 1) else {
                throw BoardMoveError("Brett „\(to)“ gibt es nicht (\"new\" oder 1–\(ordered.count))")
            }
            target = ordered[n - 1]
            guard target !== source else { throw BoardMoveError("Die Kachel steht schon auf Brett \(n)") }
        }
        let moving = source.detachForMove(pane)
        target.adopt(moving, focus: activate)
        if activate { self.activate(target) }
        updateHomePresence()
        refreshStrip()
        return target
    }

    /// Letzte Kachel eines Bretts zu (⌘W): das Brett geht mit, das letzte Brett nimmt das Fenster mit.
    func boardBecameEmpty(_ board: TerminalSplitView) {
        close(board)
    }

    /// × oder ⇧⌘W: sofort, ohne Rückfrage — was dort läuft, prüft Mats selbst (Entscheidung 23.09.).
    private func close(_ board: TerminalSplitView) {
        if board === homeBoard { closeHome(dismiss: true); return }
        guard boards.contains(where: { $0 === board }) else { return }
        let wasActive = board === activeBoard
        if wasActive { board.boardDidResignActive() }
        list.remove(ObjectIdentifier(board))
        boards.removeAll { $0 === board }
        board.closeBoard()
        updateHomePresence()
        guard let next = activeBoard else { window?.close(); return }
        if wasActive { next.boardDidBecomeActive() }
        refreshStrip()
    }

    private func perform(_ command: BoardCommand) {
        switch command {
        case .new: addBoard(plan: nil, activate: true)
        case .close: if let board = activeBoard { close(board) }
        case .next, .previous:
            // Vom Home-Brett aus: das erste bzw. letzte Brett.
            if homeActive, let board = command.isNext ? ordered.first : ordered.last { activate(board); return }
            guard let id = list.neighbor(command.isNext ? 1 : -1),
                  let board = boards.first(where: { ObjectIdentifier($0) == id }) else { NSSound.beep(); return }
            activate(board)
        case .select(let n):
            let all = ordered
            guard all.indices.contains(n - 1) else { NSSound.beep(); return }
            activate(all[n - 1])
        case .rename:
            if let board = activeBoard, board !== homeBoard { strip.beginRename(ObjectIdentifier(board)) }
        case .newWindow: Self.openWindow?()
        case .home:
            if homeBoard == nil { homeDismissed = false; makeHome(plan: nil) }
            if let homeBoard { activate(homeBoard) }
        }
    }

    // MARK: Home-Brett

    /// Ab zwei Brettern da (außer Mats hat es geschlossen), bei weniger weg.
    private func updateHomePresence() {
        guard !restoring else { return }
        if ordered.count < 2 {
            homeDismissed = false
            if homeBoard != nil { closeHome(dismiss: false) }
            return
        }
        if homeBoard == nil, !homeDismissed { makeHome(plan: nil) }
    }

    @discardableResult
    private func makeHome(plan: SessionSnapshot.Window?) -> TerminalSplitView {
        if let homeBoard { return homeBoard }
        let home = TerminalSplitView(plan: plan, empty: plan == nil)
        home.boardHost = self
        home.isHomeBoard = true
        home.frame = bounds
        home.isHidden = true
        addSubview(home, positioned: .below, relativeTo: nil)
        homeBoard = home
        if !home.allPanes.contains(where: { $0.kind == OverviewContent.kind }) {
            _ = try? home.addAppPane(kind: OverviewContent.kind, focus: false, placement: .own)
        }
        refreshStrip()
        return home
    }

    private func closeHome(dismiss: Bool) {
        guard let home = homeBoard else { return }
        let wasActive = homeActive
        if wasActive { home.boardDidResignActive() }
        homeActive = false
        homeBoard = nil
        if dismiss { homeDismissed = true }
        home.closeBoard()
        if wasActive { activeBoard?.boardDidBecomeActive() }
        refreshStrip()
    }

    // MARK: Leiste

    private func installStrip() {
        guard let window, stripAccessory == nil else { return }
        let vc = NSTitlebarAccessoryViewController()
        vc.view = strip
        vc.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(vc)
        stripAccessory = vc
        refreshStrip()
    }

    /// Ein Brett hat sich geändert (Kacheln, Status, Titel): Leiste im nächsten Durchlauf neu füllen.
    func boardDidChange(_ board: TerminalSplitView) {
        guard !stripRefreshQueued else { return }
        stripRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.stripRefreshQueued = false
            self?.refreshStrip()
        }
    }

    private func refreshStrip() {
        let active = activeBoard
        let home = homeBoard.map { board in
            BoardStripView.Item(id: ObjectIdentifier(board), name: "Home", active: board === active,
                                badge: board === active ? nil : board.boardBadge, isHome: true)
        }
        strip.items = (home.map { [$0] } ?? []) + ordered.map { board in
            BoardStripView.Item(id: ObjectIdentifier(board), name: board.displayName, active: board === active,
                                badge: board === active ? nil : board.boardBadge)
        }
        // Höchstens knapp die halbe Titelleiste — rechts brauchen die Chips Platz. In 10-pt-Stufen, damit Ziehen am
        // Fensterrand das Accessory nicht bei jedem Punkt neu einhängt.
        if let window { strip.maxWidth = max(160, (window.frame.width * 0.45 / 10).rounded(.down) * 10) }
        // Breite geändert: Accessory neu einhängen, sonst vergibt die Titelleiste den Platz nicht neu (wie bei den Chips).
        let width = strip.fittingWidth
        guard let window, let vc = stripAccessory, abs(strip.frame.width - width) > 0.5 else { return }
        strip.setFrameSize(NSSize(width: width, height: BoardStripView.height))
        vc.removeFromParent()
        window.addTitlebarAccessoryViewController(vc)
        // Chips rechts rechnen mit der neuen Breite.
        active?.titlebarSpaceChanged()
    }

    // MARK: Snapshot und Wiederherstellen

    /// Stand aller Fenster: je Brett ein Eintrag, `tabGroup` = Fenster, `selected` = vorn, `name` = gesetzter Name.
    static func sessionSnapshot(restoreOnce: Bool) -> SessionSnapshot {
        live.removeAll { $0.view == nil }
        let hosts = live.compactMap(\.view).filter { $0.window != nil && !$0.windowClosed }
        var windows: [SessionSnapshot.Window] = []
        for (group, host) in hosts.enumerated() {
            let active = host.activeBoard
            if let home = host.homeBoard {
                var snapshot = home.windowSnapshot()
                snapshot.tabGroup = group
                snapshot.selected = home === active
                snapshot.home = true
                if !snapshot.panes.isEmpty { windows.append(snapshot) }
            }
            for board in host.ordered {
                var snapshot = board.windowSnapshot()
                guard !snapshot.panes.isEmpty else { continue }
                snapshot.tabGroup = group
                snapshot.selected = board === active
                snapshot.name = board.customName
                windows.append(snapshot)
            }
        }
        return SessionSnapshot(windows: windows, restoreOnce: restoreOnce)
    }

    /// Übrige Gruppen des Snapshots als eigene Fenster öffnen (jedes holt sich im `init` seine Bretter). Was danach
    /// niemand geholt hat, kommt als Kacheln ins vordere Brett hier.
    private func restoreLeftovers() {
        let groups = Self.restoreQueue.groupCount
        if groups > 0, let open = Self.openWindow { for _ in 0..<groups { open() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + (groups > 0 ? 1.0 : 0)) { [weak self] in
            guard let self else { return }
            self.activeBoard?.mergeLeftovers(Self.restoreQueue.drain())
            self.window?.makeKeyAndOrderFront(nil)
        }
    }
}

private extension BoardCommand {
    var isNext: Bool { if case .next = self { return true } else { return false } }
}

struct BoardMoveError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Übersicht (Home-Brett, 24.09.2026)

extension BoardHostView: OverviewHost {
    func overviewBoards() -> [OverviewBoard] {
        ordered.enumerated().map { index, board in board.overviewBoard(number: index + 1) }
    }

    func overviewShowBoard(_ id: ObjectIdentifier) {
        guard let board = boards.first(where: { ObjectIdentifier($0) == id }) else { return }
        activate(board)
        board.restoreFocus()
    }

    func overviewShowPane(_ paneID: String, board id: ObjectIdentifier) {
        guard let board = boards.first(where: { ObjectIdentifier($0) == id }), let pane = board.pane(withID: paneID) else { return }
        board.showPane(pane)
    }

    /// Chef = die Terminal-Kachel im Home-Brett (verdeckter Reiter hinter der Übersicht).
    private var chefPane: TerminalPane? {
        homeBoard?.allPanes.lazy.compactMap { $0 as? TerminalPane }.first
    }

    var overviewChef: OverviewChef? {
        guard let chef = chefPane else { return nil }
        let working = chef.sessionState == .working
        let state: OverviewState = chef.sessionState == .awaitingInput ? .waiting : working ? .working : .idle
        let say = working ? chef.currentPrompt.map { "„\($0)“" } : chef.lastSay
        let starting = !chef.isStarted || chef.agentSession.identity == nil && chef.sessionState == .none && chef.lastSay == nil
        return OverviewChef(state: state, say: say, starting: starting && !working)
    }

    func overviewShowChef() {
        guard let home = homeBoard, let chef = chefPane else { return }
        home.showPane(chef)
    }

    /// Erste Nachricht startet Chef-Claude verdeckt hinter der Übersicht, mit seiner Rolle im ersten Prompt (bleibt so
    /// auch nach ⌥⌘R im Verlauf); danach geht alles über den Briefkasten wie an jeden Agenten.
    func overviewAskChef(_ text: String, done: @escaping (String, Bool) -> Void) {
        guard let home = homeBoard,
              let overview = home.allPanes.first(where: { $0.kind == OverviewContent.kind }) else {
            done("kein Home-Brett", false); return
        }
        if let chef = chefPane {
            if chef.agentSession.identity != nil || chef.sessionState != .none {
                AgentDelivery.deliver(text, toPane: chef.id.uuidString, agent: "claude", done: done)
            } else if chef.isStarted {
                // Session beendet, Shell steht noch: neu starten, diesmal wieder mit Rolle.
                _ = chef.receive("claude " + Self.shellQuote(Self.chefBriefing(text)), enter: true, paste: false)
                done("startet neu", true)
            } else {
                done("startet noch — gleich nochmal", false)
            }
            return
        }
        let chef = home.addBackgroundTerminal(behind: overview)
        chef.launchQuietly(in: NSHomeDirectory() + "/Documents",
                           command: "claude " + Self.shellQuote(Self.chefBriefing(text)), label: "Chef")
        done("startet", true)
    }

    /// Rolle des Chefs — kurz; das Lagebild holt er sich selbst über den LatexTerm-MCP.
    private static func chefBriefing(_ text: String) -> String {
        "[Home-Brett] Du bist Chef-Claude im Home-Brett von LatexTerm: Mats führt von hier aus die Agenten in den "
            + "anderen Brettern (Feld tab in `panes`). Lagebild per MCP latexterm `panes`, Fragen an eine Session per "
            + "`ask_session`, Warten per `wait_session`. Regeln: antworte knapp — dein erster Satz erscheint als Band in "
            + "der Übersicht, also das Wichtigste zuerst; je Brett höchstens ein Satz. Delegiere nur, was Mats dir "
            + "aufträgt; schließe keine fremden Kacheln, öffne keine neuen ohne Auftrag. Mats: " + text
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
