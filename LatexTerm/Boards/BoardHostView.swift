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
        if group.isEmpty {
            addBoard(plan: nil, activate: true)
        } else {
            for plan in group { addBoard(plan: plan, activate: false) }
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
    }

    // MARK: Bretter

    @discardableResult
    private func addBoard(plan: SessionSnapshot.Window?, activate: Bool) -> TerminalSplitView {
        let board = TerminalSplitView(plan: plan)
        board.boardHost = self
        board.frame = bounds
        board.isHidden = true
        addSubview(board)
        boards.append(board)
        list.add(ObjectIdentifier(board), activate: false)
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
        case .rename: break   // Scheibe 2
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
                                badge: board === active ? nil : board.boardBadge)
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
