import AppKit

/// Menü-Aktionen auf die Bretter des Key-Fensters (`Notification.Name.latexTermBoardCommand`).
enum BoardCommand {
    case new, close, next, previous, rename
    case select(Int)
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
    /// Autosave (24.09.2026): verschwindet die App ohne `applicationWillTerminate`, stellt der nächste Start diesen Stand
    /// wieder her (`SessionStore` Lauf-Marke). Beginnt erst nach der Startphase, damit ein halb aufgebauter Restore nie
    /// den guten Stand überschreibt — und damit ein Absturz beim Wiederherstellen nicht in Schleife wiederherstellt.
    private static var autosaveTimer: Timer?
    private static let autosaveDelay: TimeInterval = 10
    private static let autosaveInterval: TimeInterval = 5

    private static func startAutosave() {
        guard autosaveTimer == nil else { return }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: autosaveInterval, repeats: true) { _ in
            guard !AppLifecycle.isTerminating else { return }
            SessionStore.autosave(sessionSnapshot(restoreOnce: false))
        }
        autosaveTimer?.fireDate = Date().addingTimeInterval(autosaveDelay)
    }

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
    /// Titelleiste: Platz der Ampel links, Luft zwischen Brett-Leiste und Chips.
    private static let trafficLights: CGFloat = 92
    private static let chipGap: CGFloat = 40
    /// KI-Namen (26.09.): je Brett, seit wann seine Uhr läuft und seit wann es fragt. Ein Takt je Sekunde prüft alle
    /// Bretter — auch verlassene (Mats 26.09.: Prompt tippen, nach 3 s weg, der Name kommt trotzdem).
    private var namingTimer: Timer?
    private var dwelling: [ObjectIdentifier: Date] = [:]
    private var asking: [ObjectIdentifier: Date] = [:]

    /// Bretter in Leisten-Reihenfolge.
    var ordered: [TerminalSplitView] {
        list.order.compactMap { id in boards.first { ObjectIdentifier($0) == id } }
    }
    var activeBoard: TerminalSplitView? { boards.first { ObjectIdentifier($0) == list.active } }
    /// Platz, den die Leiste in der Titelleiste belegt — die Chips rechts rechnen ihn ab.
    var stripWidth: CGFloat { stripAccessory?.view.frame.width ?? 0 }

    init() {
        super.init(frame: .zero)
        let group = Self.restoreQueue.claimGroup()
        Self.startAutosave()
        if group.isEmpty {
            addBoard(plan: nil, activate: true)
        } else {
            for plan in group { addBoard(plan: plan, activate: false, atEnd: true) }
            let selected = group.firstIndex { $0.selected == true } ?? 0
            activate(ordered[min(selected, ordered.count - 1)])
            // Nur das erste Fenster öffnet die übrigen; Nachzügler finden die Schlange leer.
            if !Self.restoreStarted {
                Self.restoreStarted = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.restoreLeftovers() }
            }
        }

        strip.onSelect = { [weak self] id in
            guard let self, let board = self.boards.first(where: { ObjectIdentifier($0) == id }) else { return }
            self.activate(board)
        }
        strip.onClose = { [weak self] id in
            guard let self, let board = self.boards.first(where: { ObjectIdentifier($0) == id }) else { return }
            self.close(board)
        }
        strip.onAdd = { [weak self] in self?.addBoard(plan: nil, activate: true) }
        strip.onRename = { [weak self] id, name in
            guard let self, let board = self.boards.first(where: { ObjectIdentifier($0) == id }) else { return }
            board.customName = name.isEmpty ? nil : name
            self.refreshStrip()
        }
        strip.onMove = { [weak self] id, gap in
            guard let self, let index = self.list.moveIndex(for: id, gap: gap) else { return }
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
        namingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.namingTick() }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let commandObserver { NotificationCenter.default.removeObserver(commandObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        namingTimer?.invalidate()
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
        refreshStrip()
        return board
    }

    func activate(_ board: TerminalSplitView) {
        guard boards.contains(where: { $0 === board }) else { return }
        let old = activeBoard
        list.activate(ObjectIdentifier(board))
        if old !== board { old?.boardDidResignActive() }
        if old !== board || board.isHidden { board.boardDidBecomeActive() }
        refreshStrip()
    }

    /// 1-basierte Position in der Leiste; nil, solange es nur ein Brett gibt (Steuerkanal: `tab`).
    func position(of board: TerminalSplitView) -> Int? {
        guard boards.count > 1 else { return nil }
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
        refreshStrip()
        return target
    }

    /// Letzte Kachel eines Bretts zu (⌘W): das Brett geht mit, das letzte Brett nimmt das Fenster mit.
    func boardBecameEmpty(_ board: TerminalSplitView) {
        close(board)
    }

    /// × oder ⇧⌘W: sofort, ohne Rückfrage — was dort läuft, prüft Mats selbst (Entscheidung 23.09.).
    private func close(_ board: TerminalSplitView) {
        guard boards.contains(where: { $0 === board }) else { return }
        let wasActive = board === activeBoard
        if wasActive { board.boardDidResignActive() }
        list.remove(ObjectIdentifier(board))
        boards.removeAll { $0 === board }
        board.closeBoard()
        guard let next = activeBoard else { window?.close(); return }
        if wasActive { next.boardDidBecomeActive() }
        refreshStrip()
    }

    private func perform(_ command: BoardCommand) {
        switch command {
        case .new: addBoard(plan: nil, activate: true)
        case .close: if let board = activeBoard { close(board) }
        case .next, .previous:
            guard let id = list.neighbor(command.isNext ? 1 : -1),
                  let board = boards.first(where: { ObjectIdentifier($0) == id }) else { NSSound.beep(); return }
            activate(board)
        case .select(let n):
            let all = ordered
            guard all.indices.contains(n - 1) else { NSSound.beep(); return }
            activate(all[n - 1])
        case .rename: if let board = activeBoard { strip.beginRename(ObjectIdentifier(board)) }
        case .newWindow: Self.openWindow?()
        }
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
        strip.items = ordered.map { board in
            BoardStripView.Item(id: ObjectIdentifier(board), name: board.displayName, active: board === active,
                                badge: board === active ? nil : board.boardBadge, naming: namingPhase(of: board))
        }
        // Alles bis auf Ampel, die kurze Form der Chips des vorderen Bretts und Luft (26.09., vorher fest 45 %). Die
        // Chips nutzen darüber hinaus Freies für ihre lange Form. In 10-pt-Stufen, damit Ziehen am Fensterrand und
        // kleine Chip-Änderungen das Accessory nicht bei jedem Punkt neu einhängen.
        if let window {
            let free = window.frame.width - Self.trafficLights - (active?.chipReserve ?? 0) - Self.chipGap
            strip.maxWidth = max(160, (free / 10).rounded(.down) * 10)
        }
        // Breite geändert: Accessory neu einhängen, sonst vergibt die Titelleiste den Platz nicht neu (wie bei den Chips).
        let width = strip.fittingWidth
        guard let window, let vc = stripAccessory, abs(strip.frame.width - width) > 0.5 else { return }
        strip.setFrameSize(NSSize(width: width, height: BoardStripView.height))
        vc.removeFromParent()
        window.addTitlebarAccessoryViewController(vc)
        // Chips rechts rechnen mit der neuen Breite.
        active?.titlebarSpaceChanged()
    }

    // MARK: KI-Namen (26.09.)

    private func namingPhase(of board: TerminalSplitView) -> BoardStripView.Naming? {
        let id = ObjectIdentifier(board)
        if let since = asking[id] { return .asking(since: since) }
        if let since = dwelling[id] { return .waiting(since: since, duration: BoardNaming.dwell) }
        return nil
    }

    /// Jedes Brett ohne eigenen Namen, das dran ist (`BoardNaming.isDue`): Uhr läuft `dwell` Sekunden (Entprellung,
    /// Punkt wandert durch den Strich), dann wird gefragt. Brettwechsel hält die Uhr nicht an und bricht keinen Aufruf
    /// ab (Mats 26.09.) — die Uhr fällt nur, wenn das Brett nicht mehr dran ist oder einen eigenen Namen bekommt.
    private func namingTick() {
        let before = (dwelling, asking)
        defer { if before.0 != dwelling || before.1 != asking { refreshStrip() } }
        guard BoardNameRequest.enabled, !windowClosed else { dwelling = [:]; return }
        let now = Date()
        let live = Set(boards.map(ObjectIdentifier.init))
        dwelling = dwelling.filter { live.contains($0.key) }
        for board in boards {
            let id = ObjectIdentifier(board)
            guard asking[id] == nil else { continue }
            let state = board.namingState
            guard board.customName?.isEmpty ?? true,
                  board.naming.isDue(turns: state.turns, panes: state.panes, hasSession: state.hasSession) else {
                dwelling[id] = nil; continue
            }
            guard let since = dwelling[id] else { dwelling[id] = now; continue }
            guard now.timeIntervalSince(since) >= BoardNaming.dwell else { continue }
            dwelling[id] = nil
            asking[id] = now
            BoardNameRequest.run(board.namingInput) { [weak self, weak board] name in
                guard let self else { return }
                self.asking[id] = nil
                board?.naming.checked(turns: state.turns, panes: state.panes, now: now, newName: name)
                self.refreshStrip()
            }
        }
    }

    // MARK: Snapshot und Wiederherstellen

    /// Stand aller Fenster: je Brett ein Eintrag, `tabGroup` = Fenster, `selected` = vorn, `name` = gesetzter Name.
    static func sessionSnapshot(restoreOnce: Bool) -> SessionSnapshot {
        live.removeAll { $0.view == nil }
        let hosts = live.compactMap(\.view).filter { $0.window != nil && !$0.windowClosed }
        var windows: [SessionSnapshot.Window] = []
        for (group, host) in hosts.enumerated() {
            let active = host.activeBoard
            for board in host.ordered {
                var snapshot = board.windowSnapshot()
                guard !snapshot.panes.isEmpty else { continue }
                snapshot.tabGroup = group
                snapshot.selected = board === active
                snapshot.name = board.customName
                snapshot.aiName = board.naming.name
                windows.append(snapshot)
            }
        }
        return SessionSnapshot(windows: windows, restoreOnce: restoreOnce)
    }

    /// Offene Kacheln aller Fenster — was ein Wiederherstellen nicht doppelt öffnen darf.
    static func openPanes() -> OpenPanes {
        var open = OpenPanes()
        for host in live.compactMap(\.view) where host.window != nil && !host.windowClosed {
            for board in host.boards {
                for entry in board.windowSnapshot().panes {
                    if let id = entry.id { open.ids.insert(id.uppercased()) }
                    if case .resume(_, let session, _, _) = RestoreStep(entry) { open.sessions.insert(session.lowercased()) }
                    if case .app(let kind, let args) = RestoreStep(entry),
                       let key = OpenPanes.contentKey(kind: kind, args: args) { open.contents.insert(key) }
                }
            }
        }
        // Agenten, deren Session erst nach dem Snapshot gebunden wurde, meldet der Router.
        for pane in ControlServer.shared.router.panes {
            open.ids.insert(pane.id.uppercased())
            if let session = pane.sessionID { open.sessions.insert(session.lowercased()) }
        }
        return open
    }

    /// Bretter in die laufende App (Steuerkanal `restore`): ans Ende des vorderen Fensters, ohne es zu wechseln.
    /// Ohne Fenster: nichts (die App öffnet beim nächsten Fenster ohnehin Home).
    /// `activate` (Brett-Datei öffnen, 25.09.): das erste neue Brett nach vorn holen.
    static func addRestoredBoards(_ plans: [SessionSnapshot.Window], activate: Bool = false) -> Bool {
        live.removeAll { $0.view == nil }
        let hosts = live.compactMap(\.view).filter { $0.window != nil && !$0.windowClosed }
        guard let host = hosts.first(where: { $0.window?.isKeyWindow == true }) ?? hosts.first else { return false }
        for (index, plan) in plans.enumerated() { host.addBoard(plan: plan, activate: activate && index == 0, atEnd: true) }
        return true
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
