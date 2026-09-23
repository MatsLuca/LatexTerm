import AppKit

/// Der einzige Wirt für App-Kacheln: legt die Hülle an, setzt die View des Inhalts hinein,
/// leitet Theme, Befehle und Text weiter und übersetzt Wünsche des Inhalts in Host-Aufrufe.
/// Alles Kachel-Typische (Rahmen, Fokus, Zoom, ⌘W, Chips) kommt aus Hülle und Split-View —
/// ein Inhalt schreibt nur, was er wirklich hat.
final class AppPane: Pane, PaneContentDelegate {
    let id: UUID
    var openedBy: String?
    let content: any PaneContent
    let container = PaneContainerView()
    weak var host: PaneHost?
    private var themeObserver: NSObjectProtocol?

    init(content: any PaneContent, id: UUID = UUID()) {
        self.id = id
        self.content = content
        let view = content.view
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        container.pane = self
        container.ownAccent = content.accent
        content.delegate = self
        content.applyTheme(ThemeStore.shared.theme)
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let change = note.userInfo?[ThemeStore.changeKey] as? ThemeStore.Change else { return }
            switch change {
            case .theme, .appearance: self.content.applyTheme(ThemeStore.shared.theme)
            case .accent: self.host?.paneStyleChanged(self)   // Chip-Punkt folgt der globalen Farbe
            default: break
            }
        }
    }

    deinit {
#if DEBUG
        TerminalPane.statusLog("PANE \(kind) freed \(id.uuidString.prefix(8))")
#endif
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    // MARK: Pane

    var kind: String { type(of: content).kind }
    var focusTarget: NSView { content.keyView }
    var title: String { content.title }
    var statusChip: StatusChip { content.chip ?? StatusChip(tone: effectiveAccent, tooltip: content.title) }
    var effectiveAccent: NSColor { container.effectiveAccent }
    var accentName: String? { nil }
    var currentDirectory: String? { content.directory }
    var closeGuard: CloseGuard { content.closeGuard }
    var layoutPreference: LayoutPreference { content.layoutPreference }

    func handle(_ command: PaneCommand) -> Bool { content.handle(command) }
    /// `enter`/`paste` gelten nur für Kacheln mit Eingabezeile — ein Inhalt bekommt den Text, wie er ist.
    func receive(_ text: String, enter: Bool, paste: Bool) -> Bool { content.receive(text) }
    func call(_ text: String) throws -> String { try content.call(text) }

    func willClose() {
        content.willClose()
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        themeObserver = nil
    }

    func snapshot() -> PaneSnapshot? {
        content.snapshotArgs().map { PaneSnapshot(kind: kind, args: $0) }
    }

    // MARK: PaneContentDelegate

    func contentStyleChanged() {
        container.ownAccent = content.accent
        host?.paneStyleChanged(self)
    }

    func contentRequestsClose() { host?.paneRequestsClose(self) }

    func contentRequestsAttention(title: String, body: String?) {
        host?.paneRequestsAttention(self, title: title, body: body)
    }

    func contentLayoutPreferenceChanged() { host?.paneLayoutPreferenceChanged(self) }

    var contentOpener: String? { openedBy }

    func contentAgentPanes() -> [PaneInfo] { host?.agentPanes() ?? [] }

    func contentPaste(_ text: String, intoPaneID: String) -> Bool {
        host?.paneRequestsPaste(text, intoPaneID: intoPaneID) ?? false
    }
}
