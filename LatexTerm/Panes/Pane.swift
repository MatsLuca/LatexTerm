import AppKit

/// Was die Split-View von jeder Kachel braucht (Kachel-Protokoll, 22.09.2026). Eine Kachel kann
/// irgendetwas sein — Terminal, Home, später Zeichenbrett oder HTML-Ansicht —; Raster, Hülle,
/// Fokus, Zoom, ⌘W, Chips und Steuerkanal gibt es genau einmal, in der Split-View.
/// Regel: die Split-View spricht nur dieses Protokoll. Terminal-Sonderwissen (Hook-Status,
/// Session-Identität, Home-Start) holt sie sich per `as? TerminalPane` an wenigen, kommentierten
/// Stellen (Zahl in der CLAUDE.md).
protocol Pane: AnyObject {
    /// Stabile Identität über UI-Umbauten hinweg (Notifications, Steuerkanal, HUD).
    var id: UUID { get }
    /// Art der Kachel für `list-panes` und Registry: "terminal" | "home" | …
    var kind: String { get }
    /// Hülle; die Split-View layoutet nur diese.
    var container: PaneContainerView { get }
    /// Wer die Tastatur bekommt, wenn die Kachel fokussiert wird.
    var focusTarget: NSView { get }
    /// Fenstertitel, solange die Kachel fokussiert ist.
    var title: String { get }
    /// Chip in der Titelleiste.
    var statusChip: StatusChip { get }
    /// Farbe für Rahmen, Chip-Punkt und Zoom-Pille.
    var effectiveAccent: NSColor { get }
    /// Claude-Code-Farbname (Kollisionsschutz der Projektfarben); nil bei Kacheln ohne Session.
    var accentName: String? { get }
    /// Verzeichnis der Kachel (⌘T-Erbe, Steuerkanal); nil, wenn sie keins hat.
    var currentDirectory: String? { get }
    /// Darf der Steuerkanal die Kachel ohne `--force` schließen?
    var closeGuard: CloseGuard { get }
    /// Rückkanal zur Split-View; die Kachel hält ihn schwach.
    var host: PaneHost? { get set }
    /// Wer die Kachel geöffnet hat — `PaneOpener.user` (Menü, Tastatur, Home) oder die UUID der Kachel,
    /// aus der ein Agent sie per Steuerkanal/MCP geöffnet hat; nil = unbekannt (alter Snapshot).
    /// Bleibt über ⌥⌘R erhalten, damit ein Agent „seine“ und Mats' Kacheln wiedererkennt.
    var openedBy: String? { get set }

    /// Menü-Aktion, die die Kachel selbst ausführt (⌘F-Suche); false = nicht zuständig.
    func handle(_ command: PaneCommand) -> Bool
    /// Steuerkanal `send`: Terminal tippt, andere Arten deuten den Text selbst; false = nimmt
    /// keinen Text an. `enter` ist das abschließende ⏎, `paste` = als Einfügen (bracketed paste) —
    /// beides nur für Kacheln mit Eingabezeile.
    func receive(_ text: String, enter: Bool, paste: Bool) -> Bool
    /// Steuerkanal `call`: Anfrage mit Antwort (Scratchpad: ansehen, zeichnen). Wirft mit Grund, wenn
    /// die Kachel sie nicht versteht.
    func call(_ text: String) throws -> String
    /// Kachel wird geschlossen: Prozess beenden, Timer stoppen, Observer lösen — hier, nicht in
    /// `deinit`.
    func willClose()
    /// Eintrag für den Session-Snapshot (#11, `PaneSnapshot` in SessionStore.swift); nil = lässt
    /// sich nicht wiederherstellen, der Platz fällt beim Neustart weg.
    func snapshot() -> PaneSnapshot?
}

// Bewusst KEINE Defaults per Protokoll-Erweiterung: eine Kachel, deren Signatur sich um ein
// Zeichen vertippt, bekäme still den Default (⌘F täte nichts, `send` schluckte Text). Es gibt
// nur wenige Konformer (`TerminalPane`, künftig der Wirt für App-Kacheln); Defaults für
// Inhalte gehören auf deren eigenes Protokoll.

/// Werte für `Pane.openedBy` neben einer Kachel-UUID.
enum PaneOpener {
    /// Von Hand geöffnet (Menü, ⌘T/⌘N/⌘1–9, Home, Quickstart).
    static let user = "user"
}

/// Was die Titelleiste über eine Kachel zeigt (Chip = Punkt in Kachelfarbe + Text, 15.09.2026).
/// Drei Textlängen — die HUD wählt je nach Fokus und Kachelzahl; alle nil = nur der Punkt.
/// Tonfarben: arbeitet = Kachel-Akzent, braucht dich = Gelb, fertig = Grün, Fehler = Rot,
/// abgebrochen = gedimmt — alles aus dem Theme, keine festen Farben.
struct StatusChip: Equatable {
    var long: String?
    var short: String?
    var glyph: String?
    var tone: NSColor
    var pulsing = false
    var urgent = false
    var tooltip: String?
}

/// Schließschutz für `latexterm close-pane` ohne `--force`.
enum CloseGuard: Equatable {
    case free
    /// Grund als Satzrest hinter „Kachel N …“, z. B. „hat einen laufenden Prozess (vim)“.
    case busy(String)
}

/// Rückkanal einer Kachel zur Split-View. Ein Protokoll statt einzelner optionaler Closures:
/// eine vergessene Verdrahtung ist ein Compile-Fehler, kein stiller No-op (Kachel reagiert nicht
/// auf ⌘W, niemand merkt es beim Bauen).
protocol PaneHost: AnyObject {
    /// ⌘T in dieser Kachel → neue Terminal-Kachel (erbt deren Verzeichnis, #8).
    func paneRequestsSplit(_ pane: any Pane)
    /// ⌘W / Menü / Home: Kachel schließen (der Host ruft `willClose` und entfernt sie).
    func paneRequestsClose(_ pane: any Pane)
    /// Prozess der Kachel ist von selbst geendet (`exit`) → nur noch entfernen.
    func paneDidClose(_ pane: any Pane)
    /// ⌘⏎: Zoom-Toggle (#26).
    func paneRequestsZoom(_ pane: any Pane)
    /// ⌘1…9: auf so viele Kacheln auffüllen (nur erweitern, nie schließen).
    func paneRequestsPaneCount(_ count: Int)
    /// Akzent, Chip oder Titel haben sich geändert → Fenstertitel und Titelleiste nachziehen.
    func paneStyleChanged(_ pane: any Pane)
    /// Die Kachel will Aufmerksamkeit (Titel und Text formuliert sie selbst); gemeldet wird nur,
    /// wenn niemand hinsieht.
    func paneRequestsAttention(_ pane: any Pane, title: String, body: String?)
    /// Sieht gerade jemand diese Kachel an (App aktiv, Fenster vorn, Kachel fokussiert)?
    func paneIsObserved(_ pane: any Pane) -> Bool

    // Terminal/Home: die Split-View legt die neue Kachel an, die anfragende startet darin.

    /// Frische Home-Kachel für einen Start, den die anfragende nicht (mehr) tragen kann.
    func paneRequestsFreshTerminal(focus: Bool) -> TerminalPane
    /// Kollisionsschutz für Projektfarben: erster freier Name unter den übrigen Kacheln.
    func distinctAccentName(_ wanted: String, alternatives: [String], palette: [String],
                            excluding pane: any Pane) -> String
    /// Für Home: die anderen Kacheln aller Fenster mit Session-Identität.
    func homePaneSummary(excluding pane: any Pane) -> [HomePaneInfo]
    /// Home: Sprung zu einer laufenden Kachel (Pane-ID, fensterübergreifend).
    func paneRequestsFocus(paneID: String)

    // App-Kacheln, die etwas an eine Agenten-Session übergeben (Scratchpad → „An Agent schicken“).

    /// Alle Kacheln aller Fenster, in denen eine Claude- oder Codex-Session läuft.
    func agentPanes() -> [PaneInfo]
    /// Text als Einfügen in eine Kachel (fensterübergreifend) und diese fokussieren; false = ging nicht.
    func paneRequestsPaste(_ text: String, intoPaneID: String) -> Bool
}
