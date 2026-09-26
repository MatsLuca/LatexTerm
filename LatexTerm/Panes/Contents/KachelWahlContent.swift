import AppKit

/// ⌘T (26.09.2026): „Neue Kachel“ — große Knöpfe, die die ganze Kachel füllen, je einer für eine Kachelart, die
/// Mats von Hand öffnet. Ein Klick (oder 1–9, Pfeile + ⏎) verwandelt diese Kachel an Ort und Stelle in die gewählte
/// (`PaneReplacement`, gleiche Kachel-ID, gleicher Platz); Esc schließt sie. ⌘T in der Auswahl = Terminal (Split-View).
///
/// Bewusst **nicht** in `PaneKindRegistry.contents`: die Auswahl ist ein Übergang, kein Inhalt — kein Menüeintrag,
/// kein `open_<art>` für Agenten, kein Snapshot. Welche Knöpfe es gibt, steht allein in `tiles` (Mats, 26.09.: nur
/// Relevantes, nicht automatisch jede Art) — ein neuer Knopf = eine Zeile dort.
final class KachelWahlContent: PaneContent {
    static let kind = "neu"
    static let displayName = "Neue Kachel …"
    static let manual = PaneKindManual(
        summary: "Auswahl für Mats (⌘T): verwandelt sich per Klick in Home, Scratchpad, Myzel-Chat oder eine Claude-Session in Documents. "
            + "Nicht für Agenten — die öffnen Kacheln direkt.")

    /// Die Knöpfe, in dieser Reihenfolge (Nummer 1–9 = Position). Symbol = SF-Symbol-Name.
    static let tiles: [KachelWahlView.Tile] = [
        .init(title: "Home", subtitle: "Projekt wählen, Session starten", symbol: "house.fill", tone: .area, action: .home),
        .init(title: "Scratchpad", subtitle: "Skizzen und Karten", symbol: "scribble.variable", tone: .start, action: .app("scratchpad")),
        .init(title: "Myzel-Chat", subtitle: "Chat zu zweit, mit Agenten", symbol: "bubble.left.and.bubble.right.fill", tone: .running,
              action: .app("myzel")),
        // Vorerst (26.09.): allgemeiner Agent an der Wurzel des Ablagesystems.
        .init(title: "Claude", subtitle: "neue Session in Documents", symbol: "sparkle", tone: .claude,
              action: .claude("~/Documents")),
    ]

    weak var delegate: PaneContentDelegate?
    private let directory_: String
    private let root: KachelWahlView

    init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, allowed: ["dir"], kind: Self.kind)
        let dir = args["dir"].map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
        var isDir: ObjCBool = false
        directory_ = FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue ? dir : NSHomeDirectory()
        root = KachelWahlView(tiles: Self.tiles)
        root.onPick = { [weak self] tile in self?.pick(tile) }
        root.onCancel = { [weak self] in self?.delegate?.contentRequestsClose() }
    }

    var view: NSView { root }
    var title: String { "Neue Kachel" }
    var directory: String? { directory_ }

    func applyTheme(_ theme: TerminalTheme) { root.applyTheme(theme) }

    private func pick(_ tile: KachelWahlView.Tile) {
        let replacement: PaneReplacement
        switch tile.action {
        case .home:
            replacement = .home
        case .terminal:
            replacement = .shell(directory: directory_, command: nil, label: nil, integration: nil)
        case .claude(let path):
            let dir = (path as NSString).expandingTildeInPath
            replacement = .shell(directory: dir, command: "claude", label: "Claude · \((dir as NSString).lastPathComponent)",
                                 integration: nil)
        case .app(let kind):
            guard let args = PaneKindRegistry.menuArgs(for: kind, in: directory_) else { return }   // Dialog abgebrochen: Auswahl bleibt
            replacement = .app(kind: kind, args: args)
        }
        delegate?.contentRequestsReplace(with: replacement)
    }
}
