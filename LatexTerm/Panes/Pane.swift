import AppKit

/// Rückkanal einer Kachel zur Split-View (Kachel-Protokoll, 22.09.2026). Ein Protokoll statt
/// einzelner optionaler Closures: eine vergessene Verdrahtung ist ein Compile-Fehler, kein
/// stiller No-op (Kachel reagiert nicht auf ⌘W, niemand merkt es beim Bauen).
protocol PaneHost: AnyObject {
    /// ⌘T in dieser Kachel → neue Terminal-Kachel (erbt deren Verzeichnis, #8).
    func paneRequestsSplit(_ pane: TerminalPane)
    /// ⌘W / Menü / Home: Kachel schließen (die Kachel beendet ihren Prozess vorher nicht selbst).
    func paneRequestsClose(_ pane: TerminalPane)
    /// Prozess der Kachel ist von selbst geendet (`exit`) → nur noch entfernen.
    func paneDidClose(_ pane: TerminalPane)
    /// ⌘⏎: Zoom-Toggle (#26).
    func paneRequestsZoom(_ pane: TerminalPane)
    /// ⌘1…9: auf so viele Kacheln auffüllen (nur erweitern, nie schließen).
    func paneRequestsPaneCount(_ count: Int)
    /// Akzent, Chip oder Titel haben sich geändert → Fenstertitel und Titelleiste nachziehen.
    func paneStyleChanged(_ pane: TerminalPane)
    /// Die Kachel will Aufmerksamkeit (Titel und Text formuliert sie selbst); gemeldet wird nur,
    /// wenn niemand hinsieht.
    func paneRequestsAttention(_ pane: TerminalPane, title: String, body: String?)
    /// Sieht gerade jemand diese Kachel an (App aktiv, Fenster vorn, Kachel fokussiert)?
    func paneIsObserved(_ pane: TerminalPane) -> Bool

    // Terminal/Home: die Split-View legt die neue Kachel an, die anfragende startet darin.

    /// Frische Home-Kachel für einen Start, den die anfragende nicht (mehr) tragen kann.
    func paneRequestsFreshTerminal(focus: Bool) -> TerminalPane
    /// Kollisionsschutz für Projektfarben: erster freier Name unter den übrigen Kacheln.
    func distinctAccentName(_ wanted: String, alternatives: [String], palette: [String],
                            excluding pane: TerminalPane) -> String
    /// Für Home: die anderen Kacheln aller Fenster mit Session-Identität.
    func homePaneSummary(excluding pane: TerminalPane) -> [HomePaneInfo]
    /// Home: Sprung zu einer laufenden Kachel (Pane-ID, fensterübergreifend).
    func paneRequestsFocus(paneID: String)
}
