import AppKit

/// Inhalt einer App-Kachel (alles, was kein Terminal ist): weiß nichts von Kacheln, Raster,
/// Rahmen oder Kürzeln — er liefert eine View und reagiert auf das, was der Wirt `AppPane` ihm
/// weiterreicht. Neuer Inhalt = eine Datei in `Panes/Contents/` + eine Zeile in
/// `PaneKindRegistry.contents`, sonst nichts.
///
/// Regeln für Inhalte (Bauplan Kachel-Protokoll §6): kein `becomeFirstResponder`- und kein
/// `performKeyEquivalent`-Override für Kachel-Kürzel (die verteilt die Hülle); zur `init`-Zeit
/// fensterlos (kein `window`, keine Größe — die Hülle setzt den Frame); Aufräumen in `willClose`;
/// Args sind Strings und werden hier validiert; Einstellungen kommen über `applyTheme`, nie
/// direkt aus UserDefaults. Eine nicht-opake View muss `mouseDownCanMoveWindow = false` setzen,
/// sonst zieht ein Klick das Fenster (`isMovableByWindowBackground`).
protocol PaneContent: AnyObject {
    /// Art für Registry, Steuerkanal und Snapshot, z. B. "scratchpad".
    static var kind: String { get }
    /// Eintrag im Menü „Kachel“ (ganze Zeile, z. B. „Neues Scratchpad“).
    static var displayName: String { get }
    /// Aus Steuerkanal (`--arg k=v`), Menü (`menuArgs`) oder Snapshot. Unsinn → `PaneArgsError` mit Grund.
    init(args: [String: String]) throws
    /// Args für einen Start aus dem Menü — z. B. per Dateidialog; nil = abgebrochen (Default: keine).
    static func menuArgs() -> [String: String]?

    var view: NSView { get }
    /// Wer die Tastatur bekommt (Default: `view`).
    var keyView: NSView { get }
    /// Fenstertitel, solange die Kachel fokussiert ist.
    var title: String { get }
    /// Chip-Text in der Titelleiste (Default nil → nur der Punkt in Kachelfarbe).
    var chip: StatusChip? { get }
    /// Eigene Kachelfarbe (Default nil → globale Akzentfarbe).
    var accent: NSColor? { get }
    /// Verzeichnis für ⌘T aus dieser Kachel (Default nil → Home-Verzeichnis).
    var directory: String? { get }
    /// Schließschutz für `close-pane` ohne `--force` (Default `.free`).
    var closeGuard: CloseGuard { get }
    /// Rückkanal zum Wirt — im Inhalt als `weak var` deklarieren.
    var delegate: PaneContentDelegate? { get set }

    /// Theme-Wechsel (auch einmal direkt nach dem Anlegen).
    func applyTheme(_ theme: TerminalTheme)
    /// Steuerkanal `send`; false = nimmt diesen Text nicht an.
    func receive(_ text: String) -> Bool
    /// Menü-Aktion (⌘F …); false = nicht zuständig.
    func handle(_ command: PaneCommand) -> Bool
    /// Kachel geht zu: Timer, Observer, Ladevorgänge beenden.
    func willClose()
    /// Args für den Session-Snapshot; nil = flüchtig, kommt nach ⌥⌘R nicht wieder.
    func snapshotArgs() -> [String: String]?
}

extension PaneContent {
    static func menuArgs() -> [String: String]? { [:] }
    var keyView: NSView { view }
    var chip: StatusChip? { nil }
    var accent: NSColor? { nil }
    var directory: String? { nil }
    var closeGuard: CloseGuard { .free }
    func applyTheme(_ theme: TerminalTheme) {}
    func receive(_ text: String) -> Bool { false }
    func handle(_ command: PaneCommand) -> Bool { false }
    func willClose() {}
    func snapshotArgs() -> [String: String]? { nil }
}

/// Was ein Inhalt vom Wirt will.
protocol PaneContentDelegate: AnyObject {
    /// Titel, Chip oder Farbe haben sich geändert.
    func contentStyleChanged()
    /// Der Inhalt will selbst zugehen (wie ⌘W).
    func contentRequestsClose()
    /// Notification, wenn niemand hinsieht.
    func contentRequestsAttention(title: String, body: String?)
}

/// Grund, warum ein Inhalt mit diesen Args nicht entstehen kann — landet wörtlich beim CLI.
struct PaneArgsError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }

    /// Für Inhalte ohne Argumente oder mit fester Liste: unbekannte Schlüssel ablehnen.
    static func rejectUnknown(_ args: [String: String], allowed: Set<String> = [], kind: String) throws {
        let unknown = Set(args.keys).subtracting(allowed).sorted()
        guard unknown.isEmpty else {
            let known = allowed.isEmpty ? "keine" : allowed.sorted().joined(separator: ", ")
            throw PaneArgsError("\(kind) kennt die Argumente \(unknown.joined(separator: ", ")) nicht (bekannt: \(known))")
        }
    }
}

/// Eine Wahrheit über die Kachelarten für Steuerkanal (`new-pane --kind`), Menü „Kachel“
/// und Session-Restore. "terminal" und "home" sind fest verdrahtet (`TerminalPane`), alles
/// andere kommt aus `contents`.
enum PaneKindRegistry {
    static let contents: [any PaneContent.Type] = [ScratchpadContent.self, WebContent.self]

    /// Alle Arten, die `new-pane --kind` kennt.
    static var kinds: [String] { ["terminal", "home"] + contents.map { $0.kind } }

    /// Menüeinträge für App-Kacheln (Terminal und Home haben eigene Menüpunkte mit Kürzel).
    static var menuEntries: [(kind: String, displayName: String)] {
        contents.map { ($0.kind, $0.displayName) }
    }

    /// Args für einen Menü-Start dieser Art (Dateidialog …); nil = abgebrochen oder unbekannt.
    static func menuArgs(for kind: String) -> [String: String]? {
        contents.first(where: { $0.kind == kind })?.menuArgs()
    }

    /// App-Kachel dieser Art anlegen; Fehler mit Grund (unbekannte Art, falsche Args).
    static func makeAppPane(kind: String, args: [String: String]) throws -> AppPane {
        guard let type = contents.first(where: { $0.kind == kind }) else {
            throw PaneArgsError("Unbekannte Kachelart „\(kind)“ — bekannt: \(kinds.joined(separator: ", "))")
        }
        return AppPane(content: try type.init(args: args))
    }
}

extension Notification.Name {
    /// Menü „Kachel → Neues …“: das Key-Fenster hängt eine App-Kachel an (`userInfo["kind"]`).
    static let latexTermNewAppPane = Notification.Name("LatexTerm.newAppPane")
}
