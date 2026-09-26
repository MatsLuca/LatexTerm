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
    /// Selbstbeschreibung für Agenten (`pane-kinds` → `latexterm mcp` → Werkzeug `open_<art>`).
    /// Bewusst ohne Default: jede Art sagt, was sie zeigt, welche Args sie will und welche
    /// `send`-Texte sie versteht — sonst sieht das Modell sie nicht richtig.
    static var manual: PaneKindManual { get }
    /// Aus Steuerkanal (`--arg k=v`), Menü (`menuArgs`) oder Snapshot. Unsinn → `PaneArgsError` mit Grund.
    init(args: [String: String]) throws
    /// Args für einen Start aus dem Menü — z. B. per Dateidialog; nil = abgebrochen (Default: keine).
    static func menuArgs() -> [String: String]?
    /// Wie `menuArgs()`, mit dem Ordner der Kachel, aus der bestellt wurde (Dateidialog startet dort; Default: ignoriert).
    static func menuArgs(in directory: String?) -> [String: String]?

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
    /// Wunschform für das Kachel-Layout (Default `.flexible`: egal, klein geht). Hängt sie vom
    /// Inhalt ab, nach dem Laden `delegate?.contentLayoutPreferenceChanged()` rufen.
    var layoutPreference: LayoutPreference { get }
    /// Rückkanal zum Wirt — im Inhalt als `weak var` deklarieren.
    var delegate: PaneContentDelegate? { get set }

    /// Theme-Wechsel (auch einmal direkt nach dem Anlegen).
    func applyTheme(_ theme: TerminalTheme)
    /// Steuerkanal `send`; false = nimmt diesen Text nicht an.
    func receive(_ text: String) -> Bool
    /// Steuerkanal `call`: Anfrage mit Antwort; wirft `PaneArgsError` mit Grund (Default: versteht keine).
    func call(_ text: String) throws -> String
    /// Menü-Aktion (⌘F …); false = nicht zuständig.
    func handle(_ command: PaneCommand) -> Bool
    /// Kachel geht zu: Timer, Observer, Ladevorgänge beenden.
    func willClose()
    /// Args für den Session-Snapshot; nil = flüchtig, kommt nach ⌥⌘R nicht wieder.
    func snapshotArgs() -> [String: String]?
    /// Fokus-Dimmung selbst zeichnen (z. B. nur den Grund, nicht die Tinte)? true = die Hülle blendet dann nicht
    /// den ganzen Inhalt ab (Default false).
    func setDimmed(_ dimmed: Bool) -> Bool
}

extension PaneContent {
    static func menuArgs() -> [String: String]? { [:] }
    static func menuArgs(in directory: String?) -> [String: String]? { menuArgs() }
    var keyView: NSView { view }
    var chip: StatusChip? { nil }
    var accent: NSColor? { nil }
    var directory: String? { nil }
    var closeGuard: CloseGuard { .free }
    var layoutPreference: LayoutPreference { .flexible }
    func applyTheme(_ theme: TerminalTheme) {}
    func receive(_ text: String) -> Bool { false }
    func call(_ text: String) throws -> String {
        throw PaneArgsError("\(Self.kind) beantwortet keine Abfragen (call)")
    }
    func handle(_ command: PaneCommand) -> Bool { false }
    func willClose() {}
    func snapshotArgs() -> [String: String]? { nil }
    func setDimmed(_ dimmed: Bool) -> Bool { false }
}

/// Was ein Inhalt vom Wirt will.
protocol PaneContentDelegate: AnyObject {
    /// Titel, Chip oder Farbe haben sich geändert.
    func contentStyleChanged()
    /// Der Inhalt will selbst zugehen (wie ⌘W).
    func contentRequestsClose()
    /// Notification, wenn niemand hinsieht.
    func contentRequestsAttention(_ note: AttentionNote)
    /// Die Wunschform hat sich geändert (`layoutPreference`); das Layout ordnet höchstens einmal neu.
    func contentLayoutPreferenceChanged()
    /// Etwas Neues ist zu sehen, ohne dass der Nutzer es ausgelöst hat (Datei neu geladen, Agent hat
    /// gezeichnet). Nicht für Titel-/Chip-Wechsel — die gehen über `contentStyleChanged`.
    func contentHasNews()
    /// Wer die Kachel geöffnet hat (`Pane.openedBy`): Kachel-UUID eines Agenten, "user" oder nil.
    var contentOpener: String? { get }
    /// Eigene Kachel-UUID — als Aufrufer für Steuerbefehle (Myzel: Agent-Kachel „neben mir“ öffnen).
    var contentPaneID: UUID { get }
    /// Kacheln mit laufender Claude-/Codex-Session (alle Fenster).
    func contentAgentPanes() -> [PaneInfo]
    /// Text in eine andere Kachel einfügen (bracketed paste) und sie fokussieren.
    func contentPaste(_ text: String, intoPaneID: String) -> Bool
    /// Diese Kachel an Ort und Stelle durch eine andere ersetzen (gleiche ID, gleicher Platz) — die ⌘T-Auswahl.
    func contentRequestsReplace(with replacement: PaneReplacement)
}

/// Was an die Stelle einer Kachel tritt (⌘T-Auswahl `KachelWahlContent`).
enum PaneReplacement: Equatable {
    /// Terminal in `directory`; mit `command` startet darin eine Session hinter dem Start-Vorhang wie aus Home
    /// (`integration` "terminal" = eigene Start-UI, z. B. Codex).
    case shell(directory: String?, command: String?, label: String?, integration: String?)
    /// Home-Kachel (Projekt-Launcher).
    case home
    /// App-Kachel aus der Registry.
    case app(kind: String, args: [String: String])
}

/// Was eine App-Kachelart Agenten über sich sagt; Art und Anzeigename ergänzt die Registry.
struct PaneKindManual {
    /// Ein bis zwei Sätze: was die Kachel zeigt und wann sie hilft (liest das Modell).
    var summary: String
    var args: [PaneKindArg] = []
    var actions: [PaneKindAction] = []
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
    static let contents: [any PaneContent.Type] = [ScratchpadContent.self, WebContent.self, PreviewContent.self, DiffContent.self, MyzelContent.self]

    /// Alle Arten, die `new-pane --kind` kennt.
    static var kinds: [String] { ["terminal", "home"] + contents.map { $0.kind } }

    /// Selbstbeschreibung aller Arten für `pane-kinds` (terminal/home fest, Rest aus den Handbüchern).
    static var infos: [PaneKindInfo] {
        [PaneKindInfo(kind: "terminal", displayName: "Neues Terminal",
                      summary: "Login-Shell in einer neuen Kachel, optional in einem Ordner und mit Startbefehl."),
         PaneKindInfo(kind: "home", displayName: "Neue Home-Kachel",
                      summary: "Projekt-Launcher: Ordner wählen und dort eine Session starten oder fortsetzen.")]
        + contents.map { type in
            PaneKindInfo(kind: type.kind, displayName: type.displayName, summary: type.manual.summary,
                         args: type.manual.args, actions: type.manual.actions)
        }
    }

    /// Menüeinträge für App-Kacheln (Terminal und Home haben eigene Menüpunkte mit Kürzel).
    static var menuEntries: [(kind: String, displayName: String)] {
        contents.filter { !fileKinds.contains($0.kind) }.map { ($0.kind, $0.displayName) }
    }

    /// Kachelarten, die eine Datei zeigen: im Menü ein gemeinsamer Eintrag „Datei öffnen …“ (26.09.).
    static let fileKinds: Set<String> = ["web", "preview"]
    /// Pseudo-Art für `.latexTermNewAppPane`: erst Datei wählen, dann nach Endung web oder preview.
    static let openFileKind = "datei"

    /// „Datei öffnen …“: HTML → web, alles andere (PDF, Bild, Markdown, Office, Ordner) → preview. Abbrechen = nil.
    static func openFile(in directory: String? = nil) -> (kind: String, args: [String: String])? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory, isDirectory: true) }
        panel.allowsMultipleSelection = false
        panel.message = "HTML-Seite, PDF, Bild, Markdown, Dokument — oder ein Ordner mit Plots"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (fileKind(for: url.path), ["url": url.path])
    }

    /// Welche Kachel eine Datei zeigt: HTML → web, alles andere → preview.
    static func fileKind(for path: String) -> String {
        ["html", "htm", "xhtml"].contains((path as NSString).pathExtension.lowercased()) ? "web" : "preview"
    }

    /// Args für einen Menü-Start dieser Art (Dateidialog …); nil = abgebrochen oder unbekannt.
    static func menuArgs(for kind: String, in directory: String? = nil) -> [String: String]? {
        contents.first(where: { $0.kind == kind })?.menuArgs(in: directory)
    }

    /// App-Kachel dieser Art anlegen; Fehler mit Grund (unbekannte Art, falsche Args).
    static func makeAppPane(kind: String, args: [String: String], id: UUID = UUID()) throws -> AppPane {
        guard let type = contents.first(where: { $0.kind == kind }) else {
            throw PaneArgsError("Unbekannte Kachelart „\(kind)“ — bekannt: \(kinds.joined(separator: ", "))")
        }
        return AppPane(content: try type.init(args: args), id: id)
    }
}

extension Notification.Name {
    /// Menü „Kachel → Neues …“: das Key-Fenster hängt eine App-Kachel an (`userInfo["kind"]`).
    static let latexTermNewAppPane = Notification.Name("LatexTerm.newAppPane")
}
