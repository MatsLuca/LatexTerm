import AppKit

/// Was die Übersicht vom Fenster braucht — `BoardHostView` liefert es (die Übersicht sucht ihn über die View-Kette;
/// als Kachel kennt sie sonst nur ihren Wirt).
protocol OverviewHost: AnyObject {
    /// Alle Bretter dieses Fensters außer dem Home-Brett, in Leisten-Reihenfolge.
    func overviewBoards() -> [OverviewBoard]
    /// Brett nach vorn holen.
    func overviewShowBoard(_ id: ObjectIdentifier)
    /// Kachel auf ihrem Brett zeigen und fokussieren.
    func overviewShowPane(_ paneID: String, board: ObjectIdentifier)
    /// Chef-Claude im Home-Brett: nil = noch keiner gestartet.
    var overviewChef: OverviewChef? { get }
    /// Nachricht an den Chef (startet ihn beim ersten Mal); Rückgabe = kurzer Satz fürs Band.
    func overviewAskChef(_ text: String, done: @escaping (String, Bool) -> Void)
    /// Chef-Kachel nach vorn holen (Verlauf lesen).
    func overviewShowChef()
}

struct OverviewChef: Equatable {
    var state: OverviewState
    /// Letzter Satz (Antwort-Anfang) bzw. woran er arbeitet.
    var say: String?
    var starting: Bool
}

/// Übersicht im Home-Brett (24.09.2026, Scheibe ① — Plan claude-werkstatt `plans/home-brett_2026-09-24.md`):
/// eine Karte je Brett, Schwerkraft fließend (wer wartet, steht groß oben), innen die Miniatur der echten Anordnung
/// und der letzte Satz; wer wartet, hat sein Antwortfeld in der Karte. Unten die Tippzeile: `@brett text` an ein
/// Brett, ohne @ an Chef-Claude — dessen letzter Satz steht im Band darüber. Legt die App selbst an
/// (`PaneKindRegistry.internalContents`), nicht im Menü und nicht für Agenten.
final class OverviewContent: PaneContent {
    static let kind = "overview"
    static let displayName = "Übersicht"
    static let manual = PaneKindManual(
        summary: "Übersicht über alle Bretter des Fensters (Home-Brett): Karten nach Dringlichkeit, Antworten an Agenten, Tippzeile an den Chef.")

    weak var delegate: PaneContentDelegate?
    private let root = OverviewView()

    init(args: [String: String]) throws {
        try PaneArgsError.rejectUnknown(args, kind: Self.kind)
        root.hostProvider = { [weak root] in
            var view = root?.superview
            while let current = view {
                if let host = current as? OverviewHost { return host }
                view = current.superview
            }
            return nil
        }
    }

    var view: NSView { root }
    var keyView: NSView { root.commandField }
    var title: String { "Übersicht" }

    func applyTheme(_ theme: TerminalTheme) { root.applyTheme(theme) }
    func willClose() { root.stop() }
    func snapshotArgs() -> [String: String]? { [:] }

    func receive(_ text: String) -> Bool {
        guard text == "reload" else { return false }
        root.refresh(force: true)
        return true
    }
}
