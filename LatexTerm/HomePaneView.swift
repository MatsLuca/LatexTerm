import AppKit

// MARK: - Datenmodell (Vertrag: `projekte --json`, claude-werkstatt/plans/projekt-launcher_2026-08-24.md)

struct ProjekteData: Decodable {
    struct Git: Decodable {
        var branch: String?
        var dirty: Int?
        var ahead: Int?
        var behind: Int?
    }
    struct Context: Decodable {
        var tokens: Int
        var percent: Int?
        var model: String?
        var advice: String   // ok | compact | critical
        var window: Int?
        var exact: Bool?     // false = Fenster geraten (altes Transkript ohne `modelUsage`) → „≈"
    }
    struct Session: Decodable {
        var id: String
        var lastAt: String?
        var turns: Int
        var title: String?
        var titleSource: String?   // manual | ai | first-prompt | none
        var lastPrompt: String?    // letzte Eingabe — „wo war ich" beim Weitermachen
        var pinned: Bool?
        var context: Context?
    }
    /// Angepinnte Session mit Projekt (Top-Level-Liste `pinned`).
    struct Pinned: Decodable {
        var id: String
        var lastAt: String?
        var turns: Int
        var title: String?
        var context: Context?
        var project: String
        var path: String
        var session: Session { Session(id: id, lastAt: lastAt, turns: turns, title: title, pinned: true, context: context) }
    }
    /// Angepinntes Projekt / Ordner (Top-Level-Liste `pinnedProjects`).
    struct PinnedProject: Decodable {
        var id: String
        var name: String
        var path: String
        var level: String
        var aliases: [String]
        var lastActivity: String?
        var lastSession: Session?
    }
    struct Project: Decodable {
        var id: String
        var path: String
        var name: String
        var aliases: [String]
        var group: String
        var level: String
        var lastActivity: String?
        var git: Git?
        var sessions: [Session]
        var pinned: Bool?
        var claudeMd: ClaudeMd?
        /// Kopfzeile der CLAUDE.md ohne „# " — als Untertitel in der Struktur-Ansicht.
        var claudeMdHeader: String? {
            guard let h = claudeMd?.header, !h.isEmpty else { return nil }
            return h.hasPrefix("# ") ? String(h.dropFirst(2)) : h
        }
    }
    struct ClaudeMd: Decodable { var exists: Bool; var header: String? }
    struct Area: Decodable { var id: String }
    /// Einstieg je Höhe — kommt aus `projekte` (Verfassungs-Logik lebt dort, nicht in der App).
    struct ActionTemplate: Decodable {
        var glyph: String
        var label: String
        var hint: String?
        var command: String?      // nil = nur Shell
        var aliasCommand: String? // nur newProject: "hier {alias}"
        var placeCommand: String? // nur newProject: Ort offen → Start in der Wurzel mit --einordnen
        var followUp: String?     // nach dem Start tippen (compact: "/compact")
    }
    struct Actions: Decodable {
        var resume: ActionTemplate
        var newProject: ActionTemplate
        var compact: ActionTemplate?
        var pin: ActionTemplate?
        var unpin: ActionTemplate?
        var pinProject: ActionTemplate?
        var unpinProject: ActionTemplate?
        var rename: ActionTemplate?
        var byLevel: [String: [ActionTemplate]]
    }
    struct Wiedervorlage: Decodable {
        var file: String; var slug: String; var due: String; var daysLeft: Int; var title: String
        var overdue: Bool; var dueToday: Bool
    }
    /// Quickstart (Dock-Menü): fertiger Ordner + Befehl aus `config.toml` der Datenschicht.
    struct Quickstart: Decodable {
        var key: String; var label: String; var glyph: String; var hint: String?
        var path: String; var exists: Bool; var prompt: String?; var command: String?
    }
    var quickstarts: [Quickstart]?
    var wiedervorlagen: [Wiedervorlage]?
    /// Hintergrund-Sync von mats-tools + Klonen (Datenschicht `sync_status()`): nur zeigen, was hakt oder neu ist.
    struct Sync: Decodable {
        struct Behind: Decodable { var name: String; var path: String; var count: Int }
        var age: Int?; var lastResult: String?; var pluginNew: String?; var stale: Bool; var behind: [Behind]
    }
    var sync: Sync?
    var root: String
    var projects: [Project]
    var areas: [Area]
    var actions: Actions?
    var pinned: [Pinned]?
    var pinnedProjects: [PinnedProject]?
}

/// Was die Kachel beim Ausführen einer Aktion an TerminalPane übergibt.
struct LaunchRequest {
    var path: String
    var command: String?     // nil = nur Shell
    var label: String        // fürs Start-Overlay
    var followUp: String?    // wird getippt, sobald die Session steht (z. B. "/compact")
}

/// Lädt die Projektliste über das externe CLI `projekte` (Werkstatt-Datenschicht).
/// Die App kennt keine Pfade: Login-Shell (`zsh -lc`) liefert PATH/.local/bin; der
/// Befehl ist per UserDefaults `LatexTerm.projekteCommand` übersteuerbar.
enum ProjekteLoader {
    static var command: String {
        UserDefaults.standard.string(forKey: "LatexTerm.projekteCommand") ?? "projekte --json"
    }

    static func load(completion: @escaping (Result<ProjekteData, LoaderError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", command]
            let out = Pipe(), err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            do { try proc.run() } catch {
                DispatchQueue.main.async { completion(.failure(LoaderError(message: "zsh nicht startbar: \(error.localizedDescription)"))) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0, !data.isEmpty else {
                let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    completion(.failure(LoaderError(message: msg.isEmpty
                        ? "`\(command)` lieferte nichts (Exit \(proc.terminationStatus)). Werkstatt eingehängt? (claude-werkstatt/einhaengen.sh)"
                        : msg)))
                }
                return
            }
            do {
                let parsed = try JSONDecoder().decode(ProjekteData.self, from: data)
                DispatchQueue.main.async {
                    QuickstartStore.shared.items = parsed.quickstarts ?? []
                    completion(.success(parsed))
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(LoaderError(message: "JSON von `\(command)` unlesbar: \(error)"))) }
            }
        }
    }
}

/// Kontingente des Claude-Abos (5h / 7d / Modell-Woche), wie `projekte limits --json` sie liefert.
/// Reine Anzeige: Label, Prozent, Farbname und Reset-Zeitpunkt kommen fertig aus der Datenschicht.
struct LimitsData: Decodable {
    struct Limit: Decodable {
        var key: String?
        var label: String
        var percent: Int
        var resetsAt: String?
        var severity: String?
        var color: String?
    }
    var stale: Bool?
    var limits: [Limit]
}

enum LimitsLoader {
    static var command: String {
        UserDefaults.standard.string(forKey: "LatexTerm.limitsCommand") ?? "projekte limits --json"
    }

    /// Still: schlägt der Befehl fehl (kein Token, kein Netz, Befehl gar nicht da), liefert er nil
    /// und die Zeile bleibt einfach leer — Kontingente sind Beiwerk, kein Grund für eine Fehlermeldung.
    static func load(completion: @escaping (LimitsData?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", command]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            do { try proc.run() } catch {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let parsed = try? JSONDecoder().decode(LimitsData.self, from: data)
            DispatchQueue.main.async { completion(parsed) }
        }
    }
}

struct LoaderError: Error { let message: String }

extension Notification.Name {
    /// ⌘N (Menü): das Key-Fenster hängt eine Home-Kachel an.
    static let latexTermNewHomePane = Notification.Name("LatexTerm.newHomePane")
    /// Dock-Menü → Quickstart starten; userInfo["quickstart"] = ProjekteData.Quickstart.
    static let latexTermQuickstart = Notification.Name("LatexTerm.quickstart")
    /// Menü „Home" → „Nur Projekte": alle Home-Kacheln stellen ihren Baum um.
    static let latexTermHomeTreeChanged = Notification.Name("LatexTerm.homeTreeChanged")
}

/// Welche Home-Kachel gerade den Tastaturfokus hat. Die Menüpunkte im „Home"-Menü sind
/// SwiftUI-Buttons und können den Responder-Chain nicht selbst validieren — also merkt sich die
/// Kachel hier selbst, wer dran ist (Setzen nur durch den Gewinner, Löschen nur durch sich selbst,
/// damit die Reihenfolge zweier Fokuswechsel egal ist).
final class HomeFocus: ObservableObject {
    static let shared = HomeFocus()
    @Published private(set) var active: HomePaneView?
    fileprivate func set(_ pane: HomePaneView, focused: Bool) {
        if focused { if active !== pane { active = pane } }
        else if active === pane { active = nil }
    }
}

// MARK: - Home-Kachel

/// Startbildschirm einer Kachel (⌘N / erste Kachel): links der Ordnerbaum unter `root`
/// (Finder-Logik, lazy aus dem Dateisystem, Projekte/Sessions aus `projekte` angeheftet, ● wo
/// gerade eine Claude-Kachel läuft), rechts die Aktionen des gewählten Ordners:
/// „＋ Neue Session" (Standard, ⏎), „↻ Weiter" (letzte Session), „› Nur Shell", darunter „Zuletzt hier"
/// (eigene Sessions + letzte Session jedes Unterprojekts, EINE Zeitliste).
/// Tasten: ↑↓ · → in den Ordner / zu den Aktionen · ← zu / zurück · ⏎ ausführen · Tippen filtert
/// den Baum · Esc leert · ⌘⇧N neues Projekt im gewählten Ordner · ⌘R neu laden.
final class HomePaneView: NSView {

    /// (Pfad, Befehl-oder-nil, Label fürs Start-Overlay) → Kachel wird Terminal in `Pfad`.
    var onLaunch: ((LaunchRequest) -> Void)?
    var onClose: (() -> Void)?
    /// ⌘⏎ — Zoom wie bei Terminal-Kacheln (#26).
    var onZoom: (() -> Void)?
    /// First-Responder-Wechsel (Baum oder Aktionen) → Kachel-Dimmung.
    var onFocusChanged: ((Bool) -> Void)?
    /// (CWD, Claude-Status) der anderen gestarteten Kacheln → ● im Baum.
    var otherPanes: (() -> [(String, String)])?
    /// Sprung zu einer laufenden Kachel (CWD) — Fokus + ggf. Zoom wandert dorthin.
    var onFocusPane: ((String) -> Void)?

    // MARK: Modell

    /// Ein Ordner im Baum; Kinder werden beim ersten Aufklappen gelesen.
    final class Node {
        let path: String
        let name: String
        weak var parent: Node?
        private var loaded: [Node]?
        init(path: String, parent: Node?) {
            self.path = path; self.parent = parent
            self.name = (path as NSString).lastPathComponent
        }
        func children(_ excludes: Set<String>) -> [Node] {
            if let loaded { return loaded }
            let kids = HomePaneView.subfolders(of: path, excludes).map { Node(path: (path as NSString).appendingPathComponent($0), parent: self) }
            loaded = kids
            return kids
        }
        var hasChildren: Bool { !children(HomePaneView.treeExcludes).isEmpty }
    }

    private enum Action {
        case resume(ProjekteData.Session, path: String, title: String, age: String, project: String?)
        case run(ProjekteData.ActionTemplate, path: String)   // Zeile aus den Höhen-Templates
        case compact(ProjekteData.Session, path: String)      // Weiter + /compact
        case togglePin(ProjekteData.Session, pinned: Bool)
        case rename(ProjekteData.Session)                     // eigener Titel (⌘E)
        case togglePinProject(path: String, name: String, pinned: Bool)
        case more(count: Int, expanded: Bool)                 // „▸ Sessions (n)" — klappt den Rest auf
        case jump(cwd: String, state: String, name: String)   // → zur laufenden Kachel
        case wiedervorlage(ProjekteData.Wiedervorlage, path: String)
        case header(String)
        var isHeader: Bool { if case .header = self { return true }; return false }
        /// Ab hier beginnt die Liste (Mehr, Kopfzeilen, Pin-Zeilen) — davor sind Knöpfe.
        var endsPrimary: Bool {
            switch self {
            case .more, .header, .togglePin, .togglePinProject, .rename: return true
            case .run(let t, _): return t.command == nil     // „Nur Shell" ist der letzte Knopf
            default: return false
            }
        }
    }

    /// Fallback, falls `projekte` (noch) keine Templates liefert: nur Neu + Shell.
    /// Pin-Screen: rechts die Aktionen des gewählten Pins (Projekt: Neu/Weiter/Shell — Session: Weiter …).
    private func renderPinActions() {
        lastLine.stringValue = ""
        let item = tree.item(atRow: tree.selectedRow)
        if let pp = (item as? PinProjectItem)?.p {
            title.stringValue = pp.name
            var sub: [String] = []
            if !pp.aliases.isEmpty { sub.append(pp.aliases.joined(separator: ", ")) }
            sub.append(Self.rootRelative(pp.path))
            subtitle.stringValue = sub.joined(separator: "   ·   ")
            var out: [Action] = []
            let byLevel = templates.byLevel[pp.level] ?? templates.byLevel["ordner"] ?? []
            for t in byLevel where t.command != nil { out.append(.run(t, path: pp.path)) }
            if let s = pp.lastSession {
                out.append(.resume(s, path: pp.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt), project: nil))
            }
            for t in byLevel where t.command == nil { out.append(.run(t, path: pp.path)) }
            if templates.unpinProject != nil { out.append(.togglePinProject(path: pp.path, name: pp.name, pinned: true)) }
            actions = out
        } else if let pi = (item as? PinItem)?.p {
            let s = pi.session
            title.stringValue = pi.project
            subtitle.stringValue = (s.title ?? "(ohne Titel)") + (s.context.map { "   ·   " + Self.contextLine($0) } ?? "")
            var out: [Action] = [.resume(s, path: pi.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt), project: nil)]
            if templates.compact != nil { out.append(.compact(s, path: pi.path)) }
            if templates.unpin != nil { out.append(.togglePin(s, pinned: true)) }
            if templates.rename != nil { out.append(.rename(s)) }
            actions = out
        } else {
            title.stringValue = "Angepinnt"
            subtitle.stringValue = pinGroups.isEmpty ? "Noch nichts angepinnt — ⌘P pinnt eine Session, ⌘⇧P ein Projekt." : ""
            actions = []; list.reloadData(); return
        }
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private static func rootRelative(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func togglePinMode() {
        pinMode.toggle()
        filter = ""
        pinItems = (data?.pinned ?? []).map(PinItem.init)
        let pinProjects = (data?.pinnedProjects ?? []).map(PinProjectItem.init)
        pinGroups = []
        if !pinProjects.isEmpty { pinGroups.append(PinGroup("Projekte", pinProjects)) }
        if !pinItems.isEmpty { pinGroups.append(PinGroup("Sessions", pinItems)) }
        suppressExpansionSave = true
        tree.reloadData()
        if let root, !pinMode { tree.expandItem(root) }
        if pinMode { for g in pinGroups { tree.expandItem(g) } }
        suppressExpansionSave = false
        if pinMode {
            if !pinGroups.isEmpty { tree.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
        } else {
            restoreExpansion()
            if let first = data?.projects.first, let n = node(for: first.path) { reveal(n) }
        }
        window?.makeFirstResponder(tree)
        renderActions()
    }

    /// „⎇ main ↑2 ↓1 · 3 geändert" — nur was abweicht; ein sauberes main ohne Abweichung bleibt kurz.
    static func gitLine(_ g: ProjekteData.Git?) -> String? {
        guard let g, let b = g.branch else { return nil }
        var out = "⎇ " + b
        if let a = g.ahead, a > 0 { out += " ↑\(a)" }
        if let bh = g.behind, bh > 0 { out += " ↓\(bh)" }
        if let d = g.dirty, d > 0 { out += " · \(d) geändert" }
        return out
    }

    static func contextLine(_ c: ProjekteData.Context) -> String {
        let k = c.tokens >= 1000 ? "\(c.tokens / 1000)k" : "\(c.tokens)"
        var out = c.percent.map { "Kontext \(c.exact == false ? "≈" : "")\($0) %" } ?? "Kontext"
        out += " · \(k) Tokens"
        switch c.advice {
        case "compact": out += " · kompakten empfohlen"
        case "critical": out += " · kompakten!"
        default: break
        }
        return out
    }

    /// Kurzform für die rechte Spalte: „55%" (Farbe nach Empfehlung).
    static func contextBadge(_ c: ProjekteData.Context?) -> (String, NSColor)? {
        guard let c, let pct = c.percent else { return nil }
        let color: NSColor = c.advice == "critical" ? red : (c.advice == "compact" ? fg.withAlphaComponent(0.8) : faint)
        return ("\(c.exact == false ? "≈" : "")\(pct)%", color)
    }

    private static let fallbackActions = ProjekteData.Actions(
        resume: .init(glyph: "↻", label: "Weiter", hint: nil, command: "claude --resume {session}", aliasCommand: nil, followUp: nil),
        newProject: .init(glyph: "✚", label: "Neues Projekt", hint: nil, command: "claude", aliasCommand: nil, followUp: nil),
        compact: nil, pin: nil, unpin: nil, pinProject: nil, unpinProject: nil, rename: nil,
        byLevel: ["ordner": [.init(glyph: "+", label: "Neue Session", hint: nil, command: "claude", aliasCommand: nil, followUp: nil),
                             .init(glyph: "$", label: "Nur Shell", hint: nil, command: nil, aliasCommand: nil, followUp: nil)]])
    private var templates: ProjekteData.Actions { data?.actions ?? Self.fallbackActions }
    private var pinnedProjectPaths: Set<String> { Set((data?.pinnedProjects ?? []).map(\.path)) }

    private var data: ProjekteData?
    private var byPath: [String: ProjekteData.Project] = [:]
    /// ⇧⇥: Pin-Screen — links die angepinnten Sessions statt des Baums.
    private var pinMode = false
    final class PinItem { let p: ProjekteData.Pinned; init(_ p: ProjekteData.Pinned) { self.p = p } }
    final class PinProjectItem { let p: ProjekteData.PinnedProject; init(_ p: ProjekteData.PinnedProject) { self.p = p } }
    /// Block im Pin-Screen („Projekte" / „Sessions") — nicht wählbar, immer aufgeklappt.
    final class PinGroup { let title: String; let items: [AnyObject]; init(_ t: String, _ i: [AnyObject]) { title = t; items = i } }
    private var pinItems: [PinItem] = []
    private var pinGroups: [PinGroup] = []
    private var root: Node?
    private var filter = "" { didSet { applyFilter() } }
    private var filtered: [Node] = []
    /// Reduzierter Baum: nur Projekte/Bereiche (CLAUDE.md oder Sessions) und die Ordner, die zu
    /// ihnen führen. Alles andere ist grau und im Weg — `relevant` hält Projektpfade + Elternpfade.
    private var relevant: Set<String> = []
    private var onlyProjects = UserDefaults.standard.bool(forKey: "LatexTerm.homeOnlyProjects")
    private var allFolders: [Node] = []          // flacher Index für die Suche (bis Tiefe 4)
    private var actions: [Action] = [] { didSet { primaryCount = Self.primaryCount(actions) } }
    /// Zeilen vor der ersten Listenzeile sind Knöpfe (höher, mit Fläche).
    private var primaryCount = 0
    private static func primaryCount(_ a: [Action]) -> Int {
        guard let i = a.firstIndex(where: { $0.endsPrimary }) else { return a.count }
        if case .run(let t, _) = a[i], t.command == nil { return i + 1 }   // Shell-Knopf zählt noch mit
        return i
    }
    private func isPrimary(_ row: Int) -> Bool { row < primaryCount && !actions[row].isHeader }
    private var running: [String: String] = [:]  // cwd → state
    private var refreshTimer: Timer?
    private var limitsTimer: Timer?
    private var limitsTick = 0
    private var limitsData: LimitsData?
    private var treeModeObserver: NSObjectProtocol?

    // MARK: Views

    private let tree = HomeOutline()
    private let treeScroll = NSScrollView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let lastLine = NSTextField(labelWithString: "")   // „zuletzt: …" der Weiter-Session
    private let list = HomeTable()
    private let listScroll = NSScrollView()
    private let limitsLabel = NSTextField(labelWithString: "")
    private let keyHelp = NSView()
    private let notices = NSStackView()          // über dem Baum: wartet auf dich · fällige Wiedervorlagen
    private let divider = NSView()

    // Aus einem Guss mit Terminal und Statusline: dieselbe Monospace-Schrift in derselben Größe,
    // dieselbe xterm-256-Palette wie `statusline-command.sh` (51 cyan, 77 grün, 111 blau,
    // 171 violett, 214 orange, 220 gelb, 203 rot).
    static let fg = NSColor(red: 230/255.0, green: 225/255.0, blue: 225/255.0, alpha: 1)
    static let dim = fg.withAlphaComponent(0.45)
    static let faint = fg.withAlphaComponent(0.22)
    static let cyan   = NSColor(red: 0x5f/255.0, green: 0xd7/255.0, blue: 0xff/255.0, alpha: 1)
    static let green  = NSColor(red: 0x87/255.0, green: 0xd7/255.0, blue: 0x87/255.0, alpha: 1)   // 114, gedämpfter als 77
    static let blue   = NSColor(red: 0x87/255.0, green: 0xaf/255.0, blue: 0xff/255.0, alpha: 1)
    static let violet = NSColor(red: 0xd7/255.0, green: 0x5f/255.0, blue: 0xff/255.0, alpha: 1)
    static let orange = NSColor(red: 0xff/255.0, green: 0xaf/255.0, blue: 0x00/255.0, alpha: 1)
    static let yellow = NSColor(red: 0xff/255.0, green: 0xd7/255.0, blue: 0x00/255.0, alpha: 1)
    static let pink   = NSColor(red: 0xff/255.0, green: 0x5f/255.0, blue: 0xaf/255.0, alpha: 1)
    static let red    = NSColor(red: 0xff/255.0, green: 0x5f/255.0, blue: 0x5f/255.0, alpha: 1)
    static var base: CGFloat { LatexTerminalView.storedFontSize() }
    static func mono(_ delta: CGFloat = 0, _ w: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: base + delta, weight: w)
    }
    static let treeExcludes: Set<String> = ["node_modules", ".build", "venv", "DerivedData", "7_AppData", "__pycache__", "Library"]
    private var accent: NSColor { FormulaSettings.shared.accentColor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 23/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1).cgColor
        buildUI()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Fokusziel der Kachel (direkt, nie über becomeFirstResponder umleiten — siehe HISTORIE 24.08.).
    var keyView: NSView { tree }
    override var acceptsFirstResponder: Bool { false }
    override func mouseDown(with event: NSEvent) {
        // Klick ins Leere: die Spalte unter der Maus bekommt den Fokus (rechts nur, wenn es Aktionen gibt).
        closeKeyHelpIfOpen()
        let p = convert(event.locationInWindow, from: nil)
        if listScroll.frame.contains(p), !actions.isEmpty { focusList() } else { window?.makeFirstResponder(tree) }
        super.mouseDown(with: event)
    }

    /// Eine Wahrheit für „wo ist der Fokus": der First Responder des Fensters, per KVO beobachtet.
    /// So stimmen Dimmung und Akzentbalken bei ⇥, Klick, → / ←, Overlay und Kachelwechsel gleichermaßen.
    private var firstResponderObservation: NSKeyValueObservation?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer?.invalidate()
        limitsTimer?.invalidate()
        treeModeObserver.map(NotificationCenter.default.removeObserver)
        treeModeObserver = nil
        firstResponderObservation = nil
        guard let window else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshRunning() }
        treeModeObserver = NotificationCenter.default.addObserver(forName: .latexTermHomeTreeChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyTreeMode()
        }
        limitsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.limitsTock() }
        limitsTick = 0
        limitsTock()
        firstResponderObservation = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            self?.focusDidChange()
        }
    }
    deinit {
        refreshTimer?.invalidate(); limitsTimer?.invalidate()
        treeModeObserver.map(NotificationCenter.default.removeObserver)
    }

    // MARK: Start-Overlay (Spinner bis Claude steht)

    private var launchOverlay: NSView?
    private var spinnerTimer: Timer?
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    func beginLaunch(_ label: String) {
        let overlay = NSView(frame: bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(red: 23/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1).cgColor
        let spin = NSTextField(labelWithString: Self.spinnerFrames[0])
        spin.font = Self.mono(10)
        spin.textColor = accent
        let text = NSTextField(labelWithString: label)
        text.font = Self.mono(1)
        text.textColor = Self.fg
        text.lineBreakMode = .byTruncatingMiddle
        let sub = NSTextField(labelWithString: "Session startet …")
        sub.font = Self.mono(-1)
        sub.textColor = Self.dim
        let stack = NSStackView(views: [spin, text, sub])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -10),
            text.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.8),
        ])
        overlay.alphaValue = 0
        addSubview(overlay)
        launchOverlay = overlay
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; overlay.animator().alphaValue = 1 }
        var i = 0
        spinnerTimer?.invalidate()
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            i = (i + 1) % Self.spinnerFrames.count
            spin.stringValue = Self.spinnerFrames[i]
        }
        // Tastatur während des Starts still: Fokus auf das Overlay, nicht mehr auf den Baum.
        window?.makeFirstResponder(nil)
    }

    override func removeFromSuperview() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        super.removeFromSuperview()
    }

    // MARK: Aufbau

    private func buildUI() {
        title.font = Self.mono(2, .bold)
        title.textColor = Self.cyan
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Self.mono(-1)
        subtitle.textColor = Self.dim
        subtitle.lineBreakMode = .byTruncatingTail
        lastLine.font = Self.mono(-1)
        lastLine.textColor = Self.fg.withAlphaComponent(0.5)
        lastLine.lineBreakMode = .byTruncatingTail
        lastLine.maximumNumberOfLines = 1
        limitsLabel.font = Self.mono(-1)
        limitsLabel.alignment = .right
        limitsLabel.lineBreakMode = .byClipping
        limitsLabel.toolTip = "Kontingente des Abos — 5-Stunden-Fenster, Woche, Modell-Woche; ↻ = Reset"
        limitsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        limitsLabel.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buildKeyHelp()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Self.fg.withAlphaComponent(0.08).cgColor

        // Baum
        tree.headerView = nil
        tree.rowHeight = Self.base + 11
        tree.indentationPerLevel = 14
        tree.intercellSpacing = NSSize(width: 0, height: 0)
        tree.backgroundColor = .clear
        tree.style = .plain
        tree.selectionHighlightStyle = .regular
        tree.allowsEmptySelection = false
        tree.autoresizesOutlineColumn = true
        let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tree"))
        tc.resizingMask = .autoresizingMask
        tree.addTableColumn(tc)
        tree.outlineTableColumn = tc
        tree.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tree.dataSource = self
        tree.delegate = self
        tree.target = self
        tree.doubleAction = #selector(treeDoubleClick)
        tree.onKey = { [weak self] ev in self?.treeKey(ev) ?? false }
        tree.onFocus = { [weak self] in self?.focusDidChange() }
        treeScroll.documentView = tree
        treeScroll.hasVerticalScroller = true
        treeScroll.autohidesScrollers = true
        treeScroll.drawsBackground = false
        treeScroll.borderType = .noBorder

        // Aktionen
        list.headerView = nil
        list.rowHeight = Self.base + 15
        list.intercellSpacing = NSSize(width: 0, height: 2)
        list.backgroundColor = .clear
        list.style = .plain
        list.selectionHighlightStyle = .regular
        list.allowsEmptySelection = false
        let lc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        lc.resizingMask = .autoresizingMask
        list.addTableColumn(lc)
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        list.dataSource = self
        list.delegate = self
        list.target = self
        list.doubleAction = #selector(runSelectedAction)
        list.onKey = { [weak self] ev in self?.listKey(ev) ?? false }
        list.onFocus = { [weak self] in self?.focusDidChange() }
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder

        notices.orientation = .vertical
        notices.alignment = .leading
        notices.spacing = 4
        for v in [notices, treeScroll, divider, title, subtitle, lastLine, limitsLabel, listScroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let m: CGFloat = 18
        NSLayoutConstraint.activate([
            notices.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            notices.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            notices.trailingAnchor.constraint(lessThanOrEqualTo: divider.leadingAnchor, constant: -8),
            { let c = treeScroll.topAnchor.constraint(equalTo: notices.bottomAnchor, constant: 0); noticesGap = c; return c }(),
            treeScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            treeScroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.36),
            treeScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            divider.leadingAnchor.constraint(equalTo: treeScroll.trailingAnchor, constant: 8),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: treeScroll.topAnchor),
            divider.bottomAnchor.constraint(equalTo: treeScroll.bottomAnchor),

            title.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: m),
            title.trailingAnchor.constraint(lessThanOrEqualTo: limitsLabel.leadingAnchor, constant: -14),

            // Kontingente oben rechts, auf der Grundlinie des Titels: immer im Blick, ohne die
            // Aktionsspalte zu belegen — der Countdown tickt sekündlich weiter.
            limitsLabel.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            limitsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            limitsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: divider.trailingAnchor, constant: m),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m),

            lastLine.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 2),
            lastLine.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            lastLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m),
            listScroll.topAnchor.constraint(equalTo: lastLine.bottomAnchor, constant: 12),
            listScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: m - 8),
            listScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(m - 8)),
            listScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

        ])
    }

    private var focusInside = false
    /// Wird vom KVO auf `window.firstResponder` und von den Tabellen selbst gerufen — idempotent.
    private func focusDidChange() {
        let fr = window?.firstResponder as? NSView
        let inTree = fr.map { $0 === tree || $0.isDescendant(of: tree) } ?? false
        let inList = fr.map { $0 === list || $0.isDescendant(of: list) } ?? false
        let inside = fr.map { $0 === self || $0.isDescendant(of: self) } ?? false
        // Die Spalte mit Tastaturfokus ist voll sichtbar, die andere leicht abgedimmt — so ist
        // immer klar, wo ↑↓⏎ gerade wirken. Nur die fokussierte Spalte zeichnet den Akzentbalken.
        treeScroll.animator().alphaValue = inList ? 0.55 : 1
        listScroll.animator().alphaValue = inTree ? 0.55 : 1
        title.animator().alphaValue = inTree ? 0.55 : 1
        subtitle.animator().alphaValue = inTree ? 0.55 : 1
        lastLine.animator().alphaValue = inTree ? 0.55 : 1
        tree.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
        list.enumerateAvailableRowViews { rv, _ in rv.needsDisplay = true }
        HomeFocus.shared.set(self, focused: inside)
        if inside != focusInside { focusInside = inside; onFocusChanged?(inside) }
    }

    // MARK: Kontingente

    /// Sekundentakt: der Countdown wird jedes Mal neu gerechnet, die Zahlen selbst nur alle 30 s
    /// nachgeladen (die Datenschicht cacht ohnehin — der Endpoint drosselt).
    private func limitsTock() {
        if limitsTick % 30 == 0 {
            LimitsLoader.load { [weak self] d in
                guard let self else { return }
                if let d { self.limitsData = d }
                self.renderLimits()
            }
        }
        limitsTick += 1
        renderLimits()
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISO(_ s: String) -> Date? {
        isoParser.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Restzeit kurz: 1h38m · 25m · 9:41 (unter 10 Minuten sekundengenau — dann zählt jede Minute).
    private static func until(_ iso: String?) -> String? {
        guard let iso, let target = parseISO(iso) else { return nil }
        let secs = Int(target.timeIntervalSinceNow.rounded())
        if secs <= 0 { return "jetzt" }
        if secs >= 86400 { return String(format: "%dd%dh", secs / 86400, secs % 86400 / 3600) }   // 6d23h statt 167h38m
        if secs >= 3600 { return String(format: "%dh%02dm", secs / 3600, secs % 3600 / 60) }
        if secs >= 600 { return "\(secs / 60)m" }
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    /// Farbdisziplin: cyan/violett/orange/gelb gehören dem Baum (Projekt/Bereich/wartet/◇). Die
    /// Kontingente bleiben neutral — Aufmerksamkeit erst, wenn es eng wird (≥ 85 % rot).
    private static func limitColor(_ l: LimitsData.Limit) -> NSColor {
        if l.percent >= 85 || l.severity == "critical" { return red }
        return fg.withAlphaComponent(0.85)
    }
    /// Mini-Balken wie in der Statusline (█░), 6 Zellen.
    private static func limitBar(_ pct: Int) -> String {
        let full = max(0, min(6, Int((Double(pct) / 100 * 6).rounded())))
        return String(repeating: "█", count: full) + String(repeating: "░", count: 6 - full)
    }

    private func renderLimits() {
        guard let d = limitsData, !d.limits.isEmpty else {
            limitsLabel.stringValue = ""
            return
        }
        let out = NSMutableAttributedString()
        let dimA: [NSAttributedString.Key: Any] = [.font: Self.mono(-1), .foregroundColor: Self.dim]
        for l in d.limits {
            if out.length > 0 { out.append(NSAttributedString(string: "   ", attributes: dimA)) }
            out.append(NSAttributedString(string: l.label + " ", attributes: dimA))
            let c = Self.limitColor(l)
            out.append(NSAttributedString(string: Self.limitBar(l.percent) + " ", attributes: [
                .font: Self.mono(-2), .foregroundColor: c.withAlphaComponent(c == Self.red ? 1 : 0.7)]))
            out.append(NSAttributedString(string: "\(l.percent)%", attributes: [
                .font: Self.mono(-1, .bold), .foregroundColor: c]))
            if let rest = Self.until(l.resetsAt) {
                out.append(NSAttributedString(string: " ↻" + rest, attributes: [
                    .font: Self.mono(-2), .foregroundColor: Self.faint]))
            }
        }
        limitsLabel.attributedStringValue = out
        limitsLabel.alphaValue = (d.stale == true) ? 0.5 : 1
    }

    // MARK: Daten

    @objc func reload() {
        subtitle.stringValue = "lädt …"
        ProjekteLoader.load { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let d):
                self.data = d
                self.byPath = Dictionary(d.projects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                let root = Node(path: d.root, parent: nil)
                self.root = root
                self.allFolders = []
                self.relevant = Self.relevantPaths(d)
                self.index(root, depth: 0)
                self.loadExpansion()
                self.suppressExpansionSave = true
                self.tree.reloadData()
                self.tree.expandItem(root)
                self.suppressExpansionSave = false
                self.restoreExpansion()
                self.refreshRunning()
                self.renderNotices()
                self.selectInitial()
            case .failure(let err):
                self.data = nil
                self.title.stringValue = "projekte nicht erreichbar"
                self.subtitle.stringValue = err.message
                self.actions = []
                self.list.reloadData()
            }
        }
    }

    // Aufklapp-Zustand über Sessions/Kacheln hinweg: EIGENE Menge relativer Pfade (Wahrheit),
    // nicht der Outline-Zustand — `reloadData()` (Statuswechsel, Filter) feuert Collapse-Events,
    // die sonst den gespeicherten Zustand überschreiben. Programmatische Umbauten laufen mit
    // `suppressExpansionSave`, nur Nutzer-Klicks/Tasten ändern die Menge.
    private static let expandedKey = "LatexTerm.homeExpanded"
    private var expandedPaths: Set<String> = []
    private var suppressExpansionSave = false

    private func relPath(_ n: Node) -> String {
        guard let root else { return n.path }
        return n.path == root.path ? "" : String(n.path.dropFirst(root.path.count + 1))
    }
    private func loadExpansion() {
        expandedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [""])
        expandedPaths.insert("")
    }
    private func restoreExpansion() {
        guard let root else { return }
        suppressExpansionSave = true
        for rel in expandedPaths.sorted(by: { $0.count < $1.count }) {
            let path = rel.isEmpty ? root.path : (root.path as NSString).appendingPathComponent(rel)
            if let n = node(for: path) { tree.expandItem(n) }
        }
        suppressExpansionSave = false
    }
    private func persistExpansion() {
        UserDefaults.standard.set(Array(expandedPaths).sorted(), forKey: Self.expandedKey)
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !suppressExpansionSave, filter.isEmpty, !pinMode, let n = notification.userInfo?["NSObject"] as? Node else { return }
        expandedPaths.insert(relPath(n)); persistExpansion()
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !suppressExpansionSave, filter.isEmpty, !pinMode, let n = notification.userInfo?["NSObject"] as? Node else { return }
        let r = relPath(n)
        expandedPaths = expandedPaths.filter { $0 != r && !$0.hasPrefix(r + "/") }
        persistExpansion()
    }

    /// Kinder, wie der Baum sie zeigt — im reduzierten Modus ohne die grauen Ordner.
    private func kids(_ n: Node) -> [Node] {
        let all = n.children(Self.treeExcludes)
        guard onlyProjects, !relevant.isEmpty else { return all }
        return all.filter { relevant.contains($0.path) }
    }

    private func index(_ node: Node, depth: Int) {
        allFolders.append(node)
        guard depth < 4 else { return }
        for c in node.children(Self.treeExcludes) { index(c, depth: depth + 1) }
    }

    /// Projektpfade plus alle Ordner darüber — nur die überleben den reduzierten Baum.
    private static func relevantPaths(_ d: ProjekteData) -> Set<String> {
        var out: Set<String> = [d.root]
        for p in d.projects {
            var path = p.path
            while path.hasPrefix(d.root), path.count > d.root.count {
                out.insert(path)
                path = (path as NSString).deletingLastPathComponent
            }
        }
        return out
    }

    /// Startauswahl: das zuletzt aktive Projekt, aufgeklappt bis dorthin.
    private func selectInitial() {
        guard let root, let d = data else { return }
        if let first = d.projects.first, let node = node(for: first.path) {
            reveal(node)
        } else {
            tree.selectRowIndexes(IndexSet(integer: tree.row(forItem: root)), byExtendingSelection: false)
        }
        window?.makeFirstResponder(tree)
    }

    private func node(for path: String) -> Node? {
        guard let root else { return nil }
        if path == root.path { return root }
        guard path.hasPrefix(root.path + "/") else { return nil }
        var n = root
        for part in path.dropFirst(root.path.count + 1).split(separator: "/") {
            guard let c = n.children(Self.treeExcludes).first(where: { $0.name == part }) else { return nil }
            n = c
        }
        return n
    }

    private func reveal(_ node: Node) {
        var chain: [Node] = []
        var p = node.parent
        while let q = p { chain.insert(q, at: 0); p = q.parent }
        for a in chain { tree.expandItem(a) }
        let r = tree.row(forItem: node)
        guard r >= 0 else { return }
        tree.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        tree.scrollRowToVisible(r)
    }

    private func refreshRunning() {
        var m: [String: String] = [:]
        for (cwd, st) in otherPanes?() ?? [] { m[cwd] = st }
        if m != running {
            running = m
            tree.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tree.numberOfRows), columnIndexes: IndexSet(integer: 0))
            renderNotices()
            if !pinMode, filter.isEmpty { renderActions(keepSelection: true) }
        }
    }

    // MARK: Hinweise (über dem Baum)

    /// Die eine Information, für die man das Home aufmacht, wenn mehrere Sessions laufen: wer wartet.
    /// Dazu fällige Wiedervorlagen — die kämen sonst erst beim nächsten Session-Start ins Bild.
    private func renderNotices() {
        notices.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let waiting = running.filter { $0.value == "awaitingInput" }.keys.sorted()
        for cwd in waiting {
            let name = (cwd as NSString).lastPathComponent
            notices.addArrangedSubview(noticeButton(glyph: "●", color: Self.orange, text: "\(name) wartet auf dich", hint: "→ zur Kachel") { [weak self] in
                self?.onFocusPane?(cwd)
            })
        }
        let due = (data?.wiedervorlagen ?? []).filter { $0.daysLeft <= 0 }
        for w in due {
            let when = w.overdue ? "seit \(-w.daysLeft) d fällig" : "heute fällig"
            notices.addArrangedSubview(noticeButton(glyph: "⏰", color: Self.yellow, text: w.title, hint: when) { [weak self] in
                self?.startWiedervorlage(w)
            })
        }
        // Sync-Zustand: schweigt im Normalfall. Hängender Klon → Shell dort öffnen; Rest nur Info.
        if let sy = data?.sync {
            for b in sy.behind {
                notices.addArrangedSubview(noticeButton(glyph: "⬇", color: Self.yellow, text: "\(b.name) hängt \(b.count) Commit\(b.count == 1 ? "" : "s") zurück",
                                                        hint: "lokale Änderungen offen — selbst pullen · → Shell") { [weak self] in
                    self?.onLaunch?(LaunchRequest(path: b.path, command: nil, label: "Shell · \(b.name)", followUp: nil))
                })
            }
            if let v = sy.pluginNew {
                notices.addArrangedSubview(noticeButton(glyph: "🆕", color: Self.blue, text: "mats-tools aktualisiert (\(v.prefix(7)))", hint: "nächste Session hat es") {})
            }
            if sy.stale {
                let d = sy.age.map { $0 / 86400 }
                let text = d.map { "Sync seit \($0) Tag\($0 == 1 ? "" : "en") nicht durchgekommen" } ?? "Sync noch nie gelaufen"
                notices.addArrangedSubview(noticeButton(glyph: "⚠", color: Self.orange, text: text, hint: sy.lastResult ?? "offline?") {})
            }
        }
        notices.isHidden = notices.arrangedSubviews.isEmpty
        // Abstand zum Baum nur, wenn etwas drinsteht
        noticesGap?.constant = notices.isHidden ? 0 : 10
    }
    private var noticesGap: NSLayoutConstraint?

    private func noticeButton(glyph: String, color: NSColor, text: String, hint: String, action: @escaping () -> Void) -> NSView {
        let b = NoticeButton()
        let a = NSMutableAttributedString()
        a.append(NSAttributedString(string: glyph + " ", attributes: [.font: Self.mono(-2), .foregroundColor: color]))
        a.append(NSAttributedString(string: text, attributes: [.font: Self.mono(-1, .semibold), .foregroundColor: Self.fg]))
        a.append(NSAttributedString(string: "  " + hint, attributes: [.font: Self.mono(-2), .foregroundColor: Self.faint]))
        b.attributedTitle = a
        b.onClick = action
        return b
    }

    /// Wiedervorlage: Session in der Wurzel, der Text der Datei geht als erster Prompt mit —
    /// der SessionStart-Hook spielt die fällige Datei ohnehin ein, der Prompt sagt nur „die hier, jetzt".
    private func startWiedervorlage(_ w: ProjekteData.Wiedervorlage) {
        guard let rootPath = data?.root else { return }
        let new = (templates.byLevel["router"] ?? templates.byLevel["ordner"] ?? []).first { $0.command != nil }
        guard let cmd = new?.command else { return }
        onLaunch?(LaunchRequest(path: rootPath, command: cmd, label: "Wiedervorlage · \(w.title)",
                                followUp: "Wiedervorlage \(w.slug) (\(w.due)) abarbeiten: \(w.title). Datei: \(w.file) — erledigt = Datei löschen."))
    }

    // MARK: Filter

    private var lastTypedAt: Date = .distantPast
    /// Tippen sucht: nach > 1 s Pause beginnt das nächste Zeichen eine NEUE Suche (kein Backspace nötig).
    private func typeToSearch(_ chars: String) {
        let now = Date()
        if now.timeIntervalSince(lastTypedAt) > 1.0 { filter = chars } else { filter += chars }
        lastTypedAt = now
    }
    /// Suche beenden, aber die aktuelle Auswahl behalten (wird im Baum aufgedeckt).
    private func endSearchKeepingSelection() {
        guard !filter.isEmpty else { return }
        let keep = selectedNode
        selectedNodeBeforeFilter = keep
        filter = ""
    }

    private func applyFilter() {
        let q = filter.lowercased()
        if q.isEmpty {
            filtered = []
            suppressExpansionSave = true
            tree.reloadData()
            if let root { tree.expandItem(root) }
            suppressExpansionSave = false
            restoreExpansion()
            if let sel = selectedNodeBeforeFilter, let n = node(for: sel.path) { reveal(n) }
            selectedNodeBeforeFilter = nil
        } else {
            if selectedNodeBeforeFilter == nil { selectedNodeBeforeFilter = selectedNode }
            suppressExpansionSave = true
            defer { suppressExpansionSave = false }
            filtered = allFolders.filter { n in
                n.name.lowercased().contains(q)
                    || (byPath[n.path]?.aliases.contains { $0.lowercased().contains(q) } ?? false)
                    // … und über Session-Titel: „Japan" findet das Projekt, auch wenn der Ordner 030_Reise heißt
                    || (byPath[n.path]?.sessions.contains { ($0.title ?? "").lowercased().contains(q) } ?? false)
            }.sorted { a, b in
                let la = byPath[a.path]?.lastActivity ?? "", lb = byPath[b.path]?.lastActivity ?? ""
                return la != lb ? la > lb : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            tree.reloadData()
            if !filtered.isEmpty { tree.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
        renderActions()
    }
    private var selectedNodeBeforeFilter: Node?

    // MARK: Aktionen (rechte Seite)

    private var selectedNode: Node? { tree.item(atRow: tree.selectedRow) as? Node }

    private func renderActions(keepSelection: Bool = false) {
        if pinMode { renderPinActions(); return }
        guard let node = selectedNode, let d = data else { actions = []; list.reloadData(); return }
        let keepRow = keepSelection ? list.selectedRow : 0
        let p = byPath[node.path]
        let isRoot = node.path == d.root
        title.stringValue = isRoot ? (node.name) : node.name
        var sub: [String] = []
        if let a = p?.aliases, !a.isEmpty { sub.append(a.joined(separator: ", ")) }
        if let h = p?.claudeMdHeader { sub.append(h) } else if !isRoot { sub.append("keine CLAUDE.md") }
        if let g = Self.gitLine(p?.git) { sub.append(g) }
        if let la = p?.lastActivity, !isRoot { sub.append("aktiv " + Self.age(la)) }
        subtitle.stringValue = sub.joined(separator: "   ·   ")

        var out: [Action] = []
        // „Weiter" = die neueste Session im GESAMTEN Teilbaum (eigene + alle Unterordner) —
        // ein Bereich zeigt so das zuletzt bearbeitete Projekt darunter, nicht seine eigene alte Session.
        // Kandidaten: ALLE eigenen Sessions des Ordners + die jeweils letzte Session jedes Projekts
        // darunter, gemeinsam nach Zeit. „Weiter" = die neueste; der Rest wird EINE Liste —
        // eigene Sessions tragen den Ordnernamen, damit sie neben den Unterprojekten erkennbar sind.
        var candidates: [(ProjekteData.Project, ProjekteData.Session)] = []
        if let p { for s in p.sessions { candidates.append((p, s)) } }
        let below = d.projects.filter { $0.path != node.path && $0.path.hasPrefix(node.path + "/") && !$0.sessions.isEmpty }
        for q in below { if let s = q.sessions.first { candidates.append((q, s)) } }
        candidates.sort { ($0.1.lastAt ?? "") > ($1.1.lastAt ?? "") }
        // Reihenfolge: erst die Start-Templates der Höhe (＋ Neue Session zuerst — das ist der
        // häufigste Griff: Alias tippen, ⏎), dann ↻ Weiter, dann Shell & Co. (Templates ohne Befehl).
        let level = p?.level ?? "ordner"
        let byLevel = templates.byLevel[level] ?? templates.byLevel["ordner"] ?? []
        // Läuft hier (oder darunter) schon eine Kachel, ist der Sprung dorthin die erste Zeile —
        // sonst öffnet ⏎ aus Gewohnheit eine zweite Session neben der laufenden. Wartende zuerst.
        let here = running.filter { $0.key == node.path || $0.key.hasPrefix(node.path + "/") }
            .sorted { ($0.value == "awaitingInput" ? 0 : 1, $0.key) < ($1.value == "awaitingInput" ? 0 : 1, $1.key) }
        for (cwd, st) in here.prefix(3) {
            out.append(.jump(cwd: cwd, state: st, name: (cwd as NSString).lastPathComponent))
        }
        for t in byLevel where t.command != nil { out.append(.run(t, path: node.path)) }
        if let (q, s) = candidates.first {
            out.append(.resume(s, path: q.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt),
                               project: q.path == node.path ? nil : q.name))
        }
        lastLine.stringValue = candidates.first.flatMap { $0.1.lastPrompt }.map { "» \($0)" } ?? ""
        for t in byLevel where t.command == nil { out.append(.run(t, path: node.path)) }
        // Kompakt-Rat bleibt sichtbar (Warnung), alles Weitere — Pin, Umbenennen, ältere Sessions —
        // liegt hinter „▸ Sessions": erreichbar mit einem →, aber nicht dauernd im Bild.
        if let (q, s) = candidates.first, let ctx = s.context, ctx.advice != "ok", templates.compact != nil {
            out.append(.compact(s, path: q.path))
        }
        let rest = candidates.dropFirst()
        if candidates.isEmpty, templates.pinProject != nil, !isRoot {
            out.append(.togglePinProject(path: node.path, name: node.name, pinned: p?.pinned ?? pinnedProjectPaths.contains(node.path)))
        }
        if let (_, s) = candidates.first {
            out.append(.more(count: rest.count, expanded: showMore))
            if showMore {
                if templates.pinProject != nil, !isRoot {
                    out.append(.togglePinProject(path: node.path, name: node.name, pinned: p?.pinned ?? pinnedProjectPaths.contains(node.path)))
                }
                if templates.pin != nil { out.append(.togglePin(s, pinned: s.pinned ?? false)) }
                if templates.rename != nil { out.append(.rename(s)) }
                if !rest.isEmpty {
                    out.append(.header(isRoot ? "Zuletzt überall" : "Zuletzt hier"))
                    for (q, s) in rest.prefix(20) {
                        out.append(.resume(s, path: q.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt), project: q.name))
                    }
                }
            }
        }
        // Fällige Wiedervorlagen an der Wurzel auch als Zeilen — die Hinweisleiste ist Maus, das hier ⏎.
        if isRoot, let wv = d.wiedervorlagen?.filter({ $0.daysLeft <= 0 }), !wv.isEmpty {
            out.append(.header("Fällig"))
            for w in wv { out.append(.wiedervorlage(w, path: d.root)) }
        }
        actions = out
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: min(max(keepRow, 0), max(out.count - 1, 0))), byExtendingSelection: false)
    }

    private func run(_ a: Action) {
        switch a {
        case .resume(let s, let path, let title, _, let project):
            let cmd = (templates.resume.command ?? "").replacingOccurrences(of: "{session}", with: s.id)
            onLaunch?(LaunchRequest(path: path, command: cmd, label: "\(project ?? (path as NSString).lastPathComponent) · \(title)", followUp: nil))
        case .compact(let s, let path):
            guard let t = templates.compact else { return }
            let cmd = (t.command ?? "").replacingOccurrences(of: "{session}", with: s.id)
            onLaunch?(LaunchRequest(path: path, command: cmd, label: "\((path as NSString).lastPathComponent) · \(t.label)", followUp: t.followUp))
        case .run(let t, let path):
            onLaunch?(LaunchRequest(path: path, command: t.command, label: "\((path as NSString).lastPathComponent) · \(t.label)", followUp: t.followUp))
        case .togglePin(let s, let pinned):
            setPin(s.id, pinned: !pinned)
        case .rename(let s):
            renameSession(s)
        case .togglePinProject(let path, _, let pinned):
            runProjekte([pinned ? "unpin-projekt" : "pin-projekt", path])
        case .more(_, let expanded):
            setMore(!expanded)
        case .jump(let cwd, _, _):
            onFocusPane?(cwd)
        case .wiedervorlage(let w, _):
            startWiedervorlage(w)
        case .header: break
        }
    }

    /// „▸ Sessions" auf-/zuklappen; Auswahl bleibt auf der Zeile. Zustand wird gemerkt.
    private static let moreKey = "LatexTerm.homeShowSessions"
    private var showMore = UserDefaults.standard.bool(forKey: HomePaneView.moreKey)
    private func setMore(_ on: Bool) {
        guard on != showMore else { return }
        showMore = on
        UserDefaults.standard.set(on, forKey: Self.moreKey)
        renderActions()
        if let r = actions.firstIndex(where: { if case .more = $0 { return true }; return false }) {
            list.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
            list.scrollRowToVisible(r)
        }
        window?.makeFirstResponder(list)
    }
    /// Ist „▸ Sessions" markiert? → aufgeklappt ja/nein, sonst nil.
    private var selectedMore: Bool? {
        let r = list.selectedRow
        guard r >= 0, r < actions.count, case .more(_, let e) = actions[r] else { return nil }
        return e
    }

    /// Pin über die Datenschicht setzen (`projekte pin|unpin <id>`), dann neu laden.
    private func setPin(_ id: String, pinned: Bool) {
        runProjekte([pinned ? "pin" : "unpin", id])
    }

    /// Eigener Session-Titel (`projekte rename <id> [Titel]`); leer = zurück zum automatischen Titel.
    private func renameSession(_ s: ProjekteData.Session) {
        let alert = NSAlert()
        alert.messageText = "Session umbenennen"
        alert.informativeText = "Leer lassen = wieder der automatische Titel."
        alert.addButton(withTitle: "Umbenennen")
        alert.addButton(withTitle: "Abbrechen")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 22))
        field.stringValue = s.title ?? ""
        field.placeholderString = "Titel"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runProjekte(["rename", s.id, field.stringValue.trimmingCharacters(in: .whitespaces)])
    }

    /// `projekte <args…>` über die Login-Shell (PATH), Argumente unverändert durchgereicht; danach neu laden.
    private func runProjekte(_ args: [String]) {
        let keepPin = pinMode
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            proc.arguments = ["-lc", "projekte \"$@\"", "projekte"] + args
            try? proc.run(); proc.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                self?.pinMode = keepPin
                self?.reload()
            }
        }
    }

    /// Farblegende des Baums, einmal in der Fußzeile.
    // MARK: Griffe fürs Home-Menü

    func menuNewProject()  { newProject() }
    func menuReload()      { reload() }
    func menuPinSession()  { _ = pinSelectedFromList() }
    func menuPinProject()  { _ = pinSelectedProject() }
    func menuRename()      { _ = renameSelectedFromList() }
    func menuShowPins()    { togglePinMode() }

    /// „Alles ausklappen": nur entlang der relevanten Pfade — im vollen Baum würde alles andere
    /// das halbe Dateisystem aufziehen.
    func menuExpandAll() {
        guard let root else { return }
        func walk(_ n: Node, _ depth: Int) {
            guard depth < 6 else { return }
            tree.expandItem(n)
            for c in kids(n) where relevant.contains(c.path) { walk(c, depth + 1) }
        }
        walk(root, 0)
        if let n = selectedNode { reveal(n) }
    }

    /// „Alles einklappen": Gegenstück zu ⌘⇧A. Die Wurzel bleibt offen (sie *ist* der Baum);
    /// die Auswahl wandert dabei von selbst auf den nächsten sichtbaren Elternordner.
    func menuCollapseAll() {
        guard let root else { return }
        tree.collapseItem(root, collapseChildren: true)
        tree.expandItem(root)
    }

    /// Umschalten kommt als Notification (die Einstellung gilt für alle Home-Kacheln).
    private func applyTreeMode() {
        let want = UserDefaults.standard.bool(forKey: "LatexTerm.homeOnlyProjects")
        guard want != onlyProjects else { return }
        onlyProjects = want
        let keep = selectedNode?.path
        suppressExpansionSave = true
        tree.reloadData()
        if let root { tree.expandItem(root) }
        suppressExpansionSave = false
        restoreExpansion()
        if let keep, let n = node(for: keep), tree.row(forItem: n) >= 0 { reveal(n) } else { selectInitial() }
    }

    // MARK: Tastenhilfe

    /// Alles, was kein Menübefehl sein kann (Pfeile, ⇥, ⏎, Tippen) und die Zeichenlegende —
    /// früher eine Dauer-Fußzeile, jetzt auf Abruf mit ⌘/ (Menü „Home"). Die Kachel bleibt leer.
    private static let keyHelpRows: [(String, String)] = [
        ("↑ ↓", "auswählen"),
        ("→ ←", "Ordner auf/zu · zwischen Baum und Aktionen"),
        ("⇥ / ⇧⇥", "Spalte wechseln / Angepinntes zeigen"),
        ("⏎", "ausführen"),
        ("A–Z", "sucht im Baum, Esc leert"),
        ("⌘⇧N / ⌘R", "neues Projekt · neu laden"),
        ("⌘P / ⌘⇧P", "Session / Projekt anpinnen"),
        ("⌘E", "Session umbenennen"),
        ("⌘⇧B", "nur Projekte zeigen"),
        ("⌘⇧A / ⌘⇧E", "alles aus- / einklappen"),
    ]

    private func buildKeyHelp() {
        keyHelp.wantsLayer = true
        keyHelp.layer?.backgroundColor = NSColor(red: 31/255.0, green: 27/255.0, blue: 27/255.0, alpha: 0.97).cgColor
        keyHelp.layer?.cornerRadius = 10
        keyHelp.layer?.borderWidth = 1
        keyHelp.layer?.borderColor = Self.fg.withAlphaComponent(0.10).cgColor
        keyHelp.isHidden = true
        let text = NSTextField(labelWithAttributedString: Self.keyHelpText())
        text.translatesAutoresizingMaskIntoConstraints = false
        keyHelp.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: keyHelp.topAnchor, constant: 14),
            text.bottomAnchor.constraint(equalTo: keyHelp.bottomAnchor, constant: -14),
            text.leadingAnchor.constraint(equalTo: keyHelp.leadingAnchor, constant: 18),
            text.trailingAnchor.constraint(equalTo: keyHelp.trailingAnchor, constant: -18),
        ])
    }

    private static func keyHelpText() -> NSAttributedString {
        let a = NSMutableAttributedString()
        let width = keyHelpRows.map(\.0.count).max() ?? 8
        for (key, what) in keyHelpRows {
            a.append(NSAttributedString(string: key.padding(toLength: width, withPad: " ", startingAt: 0) + "  ",
                                        attributes: [.font: mono(-1), .foregroundColor: cyan]))
            a.append(NSAttributedString(string: what + "\n", attributes: [.font: mono(-1), .foregroundColor: dim]))
        }
        a.append(NSAttributedString(string: "\n", attributes: [.font: mono(-2)]))
        a.append(legend())
        return a
    }

    /// ⌘/ — Menüpunkt „Tastenhilfe" im Home-Menü.
    func toggleKeyHelp() {
        if keyHelp.superview == nil {
            keyHelp.translatesAutoresizingMaskIntoConstraints = false
            addSubview(keyHelp)
            NSLayoutConstraint.activate([
                keyHelp.centerXAnchor.constraint(equalTo: centerXAnchor),
                keyHelp.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            ])
        }
        keyHelp.isHidden.toggle()
    }

    /// Esc/Klick schließen die Hilfe, wenn sie offen ist — true heißt „Taste verbraucht".
    @discardableResult
    private func closeKeyHelpIfOpen() -> Bool {
        guard keyHelp.superview != nil, !keyHelp.isHidden else { return false }
        keyHelp.isHidden = true
        return true
    }

    private static func legend() -> NSAttributedString {
        let a = NSMutableAttributedString()
        func add(_ g: String, _ c: NSColor, _ t: String) {
            a.append(NSAttributedString(string: g, attributes: [.font: mono(-2), .foregroundColor: c]))
            a.append(NSAttributedString(string: " \(t)   ", attributes: [.font: mono(-2), .foregroundColor: faint]))
        }
        add("▣", cyan, "Projekt"); add("▤", violet, "Bereich"); add("◇", yellow, "ohne CLAUDE.md")
        add("●", green, "läuft"); add("●", orange, "wartet")
        return a
    }

    /// Session hinter einer Aktionszeile (nil für Neu/Shell/Header/Sessions-Klapper).
    private static func session(of a: Action) -> ProjekteData.Session? {
        switch a {
        case .resume(let s, _, _, _, _), .compact(let s, _), .togglePin(let s, _), .rename(let s): return s
        default: return nil
        }
    }
    /// Markierte Session-Zeile, sonst die „Weiter"-Session (erste Zeile mit Session).
    private var sessionInFocus: ProjekteData.Session? {
        let r = list.selectedRow
        if r >= 0, r < actions.count, let s = Self.session(of: actions[r]) { return s }
        return actions.lazy.compactMap(Self.session(of:)).first
    }

    /// ⌘P: Pin der markierten Session-Zeile (oder der „Weiter"-Session) umschalten.
    private func pinSelectedFromList() -> Bool {
        if let s = sessionInFocus { setPin(s.id, pinned: !(s.pinned ?? false)) }
        return true
    }

    /// ⌘⇧P: gewählten Ordner/Projekt anpinnen bzw. loslösen (im Pin-Screen: das markierte Projekt).
    private func pinSelectedProject() -> Bool {
        if pinMode {
            if let pp = (tree.item(atRow: tree.selectedRow) as? PinProjectItem)?.p { runProjekte(["unpin-projekt", pp.path]) }
            return true
        }
        guard let n = selectedNode, n.path != data?.root else { return true }
        let pinned = byPath[n.path]?.pinned ?? pinnedProjectPaths.contains(n.path)
        runProjekte([pinned ? "unpin-projekt" : "pin-projekt", n.path])
        return true
    }

    /// ⌘E: markierte Session-Zeile (oder die „Weiter"-Session) umbenennen.
    private func renameSelectedFromList() -> Bool {
        if let s = sessionInFocus { renameSession(s) }
        return true
    }

    @objc private func runSelectedAction() {
        let r = list.selectedRow
        guard r >= 0, r < actions.count else { return }
        run(actions[r])
    }

    @objc private func treeDoubleClick() {
        guard let a = actions.first else { return }
        run(a)
    }

    private func focusList() {
        guard !actions.isEmpty else { return }
        window?.makeFirstResponder(list)
        if list.selectedRow < 0 { list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    // MARK: Neues Projekt

    /// Neues Projekt (⌘⇧N / Menü Home). Zwei Wege: Ort bekannt (Baumauswahl oder Finder-Picker) →
    /// Ordner anlegen, `/neues-projekt <Zweck>`; Ort noch offen → keine Anlage, Start in der Wurzel
    /// mit `--einordnen`, Claude klärt die Einordnung und legt den Ordner selbst an. Alle Befehle
    /// kommen aus dem Werkstatt-Template (`newProject.command` / `.placeCommand`).
    @objc private func newProject() {
        guard let selected = selectedNode, let rootPath = data?.root ?? root?.path else { return }
        let alert = NSAlert()
        alert.messageText = "Neues Projekt"
        alert.informativeText = "Claude übernimmt mit /neues-projekt: Interview, CLAUDE.md, Git."
        alert.addButton(withTitle: "Anlegen")
        alert.addButton(withTitle: "Abbrechen")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        func label(_ t: String, y: CGFloat) {
            let l = NSTextField(labelWithString: t); l.frame = NSRect(x: 0, y: y + 3, width: 60, height: 18); l.alignment = .right
            box.addSubview(l)
        }
        let nameField = NSTextField(frame: NSRect(x: 68, y: 124, width: 344, height: 22))
        nameField.placeholderString = "Ordnername"
        let aliasField = NSTextField(frame: NSRect(x: 68, y: 96, width: 120, height: 22))
        aliasField.placeholderString = "optional"
        let purposeField = NSTextField(frame: NSRect(x: 68, y: 68, width: 344, height: 22))
        purposeField.placeholderString = "ein Satz, optional — spart die erste Interviewfrage"
        label("Name", y: 124); label("Alias", y: 96); label("Zweck", y: 68); label("Ort", y: 36)

        var place = selected.path
        let known = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
        known.frame = NSRect(x: 68, y: 36, width: 18, height: 20)
        let placeLabel = NSTextField(labelWithString: "")
        placeLabel.frame = NSRect(x: 88, y: 39, width: 240, height: 18)
        placeLabel.lineBreakMode = .byTruncatingHead
        placeLabel.textColor = .secondaryLabelColor
        func showPlace() { placeLabel.stringValue = place == rootPath ? "Documents (Wurzel)" : Self.rootRelative(place) }
        showPlace()
        let change = NSButton(title: "Ändern…", target: nil, action: nil)
        change.frame = NSRect(x: 330, y: 33, width: 82, height: 26)
        change.bezelStyle = .rounded
        change.controlSize = .small
        let open = NSButton(radioButtonWithTitle: "noch offen — mit Claude klären, wo es hingehört", target: nil, action: nil)
        open.frame = NSRect(x: 68, y: 8, width: 344, height: 20)
        known.state = .on

        // Radios ohne Target/Action gruppieren sich nicht von selbst — Handler über einen Helfer.
        let sink = RadioSink(); sink.onKnown = { known.state = .on; open.state = .off }
        sink.onOpen = { open.state = .on; known.state = .off }
        sink.onChange = {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.directoryURL = URL(fileURLWithPath: place)
            panel.prompt = "Hier anlegen"
            panel.message = "Ordner, unter dem das neue Projekt liegen soll"
            if panel.runModal() == .OK, let u = panel.url { place = u.path; showPlace(); sink.onKnown?() }
        }
        known.target = sink; known.action = #selector(RadioSink.known)
        open.target = sink; open.action = #selector(RadioSink.open)
        change.target = sink; change.action = #selector(RadioSink.change)
        for v in [nameField, aliasField, purposeField, known, placeLabel, change, open] { box.addSubview(v) }
        alert.accessoryView = box
        alert.window.initialFirstResponder = nameField
        nameField.nextKeyView = aliasField; aliasField.nextKeyView = purposeField; purposeField.nextKeyView = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        withExtendedLifetime(sink) {}

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard !name.isEmpty, !name.contains("/") else { return }
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespaces)
        let purpose = purposeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = templates.newProject
        func fill(_ s: String) -> String {
            s.replacingOccurrences(of: "{purpose}", with: Self.plain(purpose))
             .replacingOccurrences(of: "{name}", with: Self.plain(name))
             .replacingOccurrences(of: "{alias}", with: alias)
        }

        if open.state == .on {
            // Ort offen: nichts anlegen, Claude erörtert es in der Wurzel.
            guard let pc = t.placeCommand else { return }
            let cmd = "cd \(Self.q(rootPath)) && " + fill(pc)
            onLaunch?(LaunchRequest(path: rootPath, command: cmd, label: "\(name) · einordnen", followUp: nil))
            return
        }
        let dir = (place as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dir) {
            let a = NSAlert(); a.messageText = "Gibt es schon"; a.informativeText = dir; a.runModal(); return
        }
        var cmd = "mkdir -p \(Self.q(dir)) && cd \(Self.q(dir))"
        if !alias.isEmpty, alias.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
           let ac = t.aliasCommand {
            cmd += " && " + fill(ac)
        }
        if let c = t.command { cmd += " && " + fill(c) }
        onLaunch?(LaunchRequest(path: place, command: cmd, label: "\(name) · \(t.label)", followUp: nil))
    }

    /// Text, der in einem einfach-quotierten Shell-Argument landet (der Zweck-Satz): Apostrophe
    /// und Zeilenumbrüche raus, sonst bricht das Quoting des Templates.
    private static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "’").replacingOccurrences(of: "\n", with: " ")
    }

    private final class RadioSink: NSObject {
        var onKnown: (() -> Void)?; var onOpen: (() -> Void)?; var onChange: (() -> Void)?
        @objc func known() { onKnown?() }
        @objc func open() { onOpen?() }
        @objc func change() { onChange?() }
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Tastatur

    private func treeKey(_ ev: NSEvent) -> Bool {
        if ev.keyCode == 53, closeKeyHelpIfOpen() { return true }
        let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.contains(.command), !mods.contains(.control) else { return false }
        switch ev.keyCode {
        case 36, 76:
            if let a = actions.first { run(a) }
            return true
        case 48: // ⇥ : zu den Aktionen · ⇧⇥ : Pin-Screen an/aus
            if mods.contains(.shift) { togglePinMode(); return true }
            endSearchKeepingSelection(); focusList(); return true
        case 124: // → : Suche beenden / aufklappen / sonst zu den Aktionen
            if pinMode { focusList(); return true }
            if !filter.isEmpty { endSearchKeepingSelection(); return true }
            if let n = selectedNode, n.hasChildren, !tree.isItemExpanded(n) { tree.expandItem(n); return true }
            focusList(); return true
        case 123: // ← : zuklappen, sonst zum Eltern-Ordner
            if pinMode { return true }
            if !filter.isEmpty { endSearchKeepingSelection(); return true }
            guard let n = selectedNode else { return true }
            if tree.isItemExpanded(n) { tree.collapseItem(n); return true }
            if let p = n.parent { reveal(p) }
            return true
        case 53: if !filter.isEmpty { filter = "" }; return true
        case 51: if !filter.isEmpty { filter.removeLast(); lastTypedAt = Date() }; return true
        case 125, 126: return false
        default:
            if pinMode { return true }
            if let chars = ev.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                typeToSearch(chars); return true
            }
            return false
        }
    }

    private func listKey(_ ev: NSEvent) -> Bool {
        if ev.keyCode == 53, closeKeyHelpIfOpen() { return true }
        let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.contains(.command), !mods.contains(.control) else { return false }
        switch ev.keyCode {
        case 36, 76: runSelectedAction(); return true
        case 48 where mods.contains(.shift): togglePinMode(); return true
        case 124:   // → auf „▸ Sessions" klappt auf
            if selectedMore == false { setMore(true) }
            return true
        case 123 where selectedMore == true: setMore(false); return true   // ← klappt zu
        case 123, 53, 48: window?.makeFirstResponder(tree); return true   // ← / Esc / ⇥ zurück zum Baum
        case 125, 126: return false
        default:
            // Tippen in der Aktionsspalte = Suche im Baum (schnell woanders hin), Fokus wandert nach links.
            if !pinMode, let chars = ev.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                window?.makeFirstResponder(tree)
                typeToSearch(chars)
                return true
            }
            return true
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let a = event.charactersIgnoringModifiers ?? ""
        let fr = window?.firstResponder as? NSView
        let focused = fr === self || (fr?.isDescendant(of: self) ?? false)
        guard focused else { return super.performKeyEquivalent(with: event) }
        if mods == .command, a == "w" { onClose?(); return true }
        if mods == .command, a == "\r" { onZoom?(); return true }
        if mods == .command, a == "r" { reload(); return true }
        if mods == [.command, .shift], a.lowercased() == "n" { newProject(); return true }
        if mods == .command, a == "p" { return pinSelectedFromList() }
        if mods == .command, a == "e" { return renameSelectedFromList() }
        if mods == [.command, .shift], a.lowercased() == "p" { return pinSelectedProject() }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Hilfen

    static func subfolders(of dir: String, _ excludes: Set<String>) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var isDir: ObjCBool = false
        return items.filter { name in
            !name.hasPrefix(".") && !excludes.contains(name)
                && FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDir)
                && isDir.boolValue
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func age(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "" }
        let delta = Date().timeIntervalSince(d)
        if delta < 3600 { return "vor \(max(1, Int(delta / 60))) min" }
        if delta < 86400 { return "vor \(Int(delta / 3600)) h" }
        if delta < 86400 * 14 { return "vor \(Int(delta / 86400)) d" }
        let f = DateFormatter(); f.dateFormat = "d. MMM"; f.locale = Locale(identifier: "de_DE")
        return f.string(from: d)
    }
}

// MARK: - Baum (NSOutlineView)

extension HomePaneView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if pinMode { return item == nil ? pinGroups.count : ((item as? PinGroup)?.items.count ?? 0) }
        if !filter.isEmpty { return item == nil ? filtered.count : 0 }
        if item == nil { return root == nil ? 0 : 1 }
        return (item as? Node).map { kids($0).count } ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if pinMode { return item == nil ? pinGroups[index] : (item as! PinGroup).items[index] }
        if !filter.isEmpty { return filtered[index] }
        if item == nil { return root! }
        return kids(item as! Node)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if pinMode { return item is PinGroup }
        return filter.isEmpty && ((item as? Node).map { !kids($0).isEmpty } ?? false)
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is PinGroup) }
    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { !(item is PinGroup) }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("treeCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? TreeCell) ?? { let c = TreeCell(); c.identifier = id; return c }()
        if let g = item as? PinGroup {
            cell.set(glyph: "", glyphColor: Self.faint, text: "── \(g.title) ", color: Self.faint, dot: nil)
            cell.toolTip = nil
            return cell
        }
        if let pp = (item as? PinProjectItem)?.p {
            let glyph: String, gc: NSColor
            switch pp.level {
            case "projekt", "unter-projekt": glyph = "▣"; gc = Self.cyan
            case "router", "bereich": glyph = "▤"; gc = Self.violet
            case "ohne-claude-md": glyph = "◇"; gc = Self.yellow
            default: glyph = "·"; gc = Self.faint
            }
            var dot: NSColor? = nil
            if let st = running.first(where: { $0.key == pp.path || $0.key.hasPrefix(pp.path + "/") })?.value {
                dot = st == "awaitingInput" ? Self.orange : Self.green
            }
            cell.set(glyph: glyph, glyphColor: gc, text: pp.name + (pp.aliases.first.map { "  \($0)" } ?? ""), color: Self.fg, dot: dot)
            cell.toolTip = Self.rootRelative(pp.path)
            return cell
        }
        if let pi = item as? PinItem {
            let s = pi.p
            let badge = Self.contextBadge(s.context)
            cell.set(glyph: "★", glyphColor: Self.yellow, text: "\(s.project)  \(s.title ?? "(ohne Titel)")", color: Self.fg,
                     dot: badge.map { $0.1 == Self.faint ? nil : $0.1 } ?? nil)
            cell.toolTip = (s.context.map(Self.contextLine) ?? "") + " · " + Self.age(s.lastAt)
            return cell
        }
        guard let n = item as? Node else { return nil }
        let p = byPath[n.path]
        let glyph: String, glyphColor: NSColor, color: NSColor
        switch p?.level {
        case "projekt", "unter-projekt": glyph = "▣"; glyphColor = Self.cyan;   color = Self.fg
        case "router", "bereich":        glyph = "▤"; glyphColor = Self.violet; color = Self.fg.withAlphaComponent(0.75)
        case "ohne-claude-md":           glyph = "◇"; glyphColor = Self.yellow; color = Self.fg
        default:                         glyph = "·"; glyphColor = Self.faint;  color = Self.dim
        }
        var label = filter.isEmpty ? n.name : String(n.path.dropFirst((root?.path.count ?? 0) + 1))
        // Nur am Wurzelknoten: sichtbarer Hinweis, dass gerade Ordner ausgeblendet sind (⌘⇧B).
        if onlyProjects, filter.isEmpty, n === root { label += "   nur Projekte" }
        var dot: NSColor? = nil
        if let st = running.first(where: { $0.key == n.path || $0.key.hasPrefix(n.path + "/") })?.value {
            dot = st == "awaitingInput" ? Self.orange : Self.green
        }
        cell.set(glyph: glyph, glyphColor: glyphColor, text: label, color: color, dot: dot)
        var tip: String
        switch p?.level {
        case "projekt", "unter-projekt": tip = "Projekt (CLAUDE.md)"
        case "router": tip = "Router — Karte der Kinder"
        case "bereich": tip = "Bereich — Arbeitsmuster für die Kinder"
        case "ohne-claude-md": tip = "Ordner mit Claude-Aktivität, aber ohne CLAUDE.md"
        default: tip = "Ordner"
        }
        if let a = p?.aliases, !a.isEmpty { tip += " · Alias: " + a.joined(separator: ", ") }
        if dot != nil { tip += " · hier läuft eine Claude-Kachel" }
        cell.toolTip = tip
        return cell
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let v = HomeRowBackground(); v.accent = accent; return v
    }
    func outlineViewSelectionDidChange(_ notification: Notification) { renderActions() }
}

// MARK: - Aktionen (NSTableView)

extension HomePaneView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { actions[row].isHeader }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !actions[row].isHeader }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if actions[row].isHeader { return HomePaneView.base + 19 }
        return isPrimary(row) ? HomePaneView.base + 22 : HomePaneView.base + 13
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("actionCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ActionCell) ?? { let c = ActionCell(); c.identifier = id; return c }()
        cell.toolTip = nil
        switch actions[row] {
        case .header(let t):
            cell.set(glyph: "", text: t, detail: "", meta: "", header: true, accent: Self.faint)
        case .resume(let s, _, let t, let age, let project):
            let r = templates.resume
            let star = (s.pinned ?? false) ? "★ " : ""
            var meta = age
            var metaColor: NSColor? = nil
            if let (badge, color) = Self.contextBadge(s.context) { meta = badge + "  " + age; metaColor = color }
            cell.set(glyph: r.glyph, text: star + (project.map { "\(r.label) · \($0)" } ?? r.label), detail: t, meta: meta, header: false, accent: Self.green, metaColor: metaColor)
            cell.toolTip = s.lastPrompt.map { "Zuletzt: „\($0)“" + (s.context.map { "\n" + Self.contextLine($0) } ?? "") }
        case .run(let t, _):
            let color: NSColor = t.command == nil ? Self.blue : (t.glyph == "+" ? Self.cyan : Self.violet)
            cell.set(glyph: t.glyph, text: t.label, detail: t.hint ?? "", meta: "", header: false, accent: color)
        case .compact(let s, _):
            let t = templates.compact!
            cell.set(glyph: t.glyph, text: t.label, detail: s.context.map(Self.contextLine) ?? (t.hint ?? ""), meta: "", header: false,
                     accent: s.context?.advice == "critical" ? Self.red : Self.yellow)
        case .togglePin(_, let pinned):
            let t = (pinned ? templates.unpin : templates.pin)!
            cell.set(glyph: t.glyph, text: t.label, detail: pinned ? "im Pin-Screen (⇧⇥)" : "wichtig — in den Pin-Screen (⇧⇥)", meta: "", header: false, accent: Self.yellow)
        case .more(let n, let expanded):
            cell.set(glyph: expanded ? "▾" : "▸", text: "Mehr", detail: (n == 0 ? "" : "\(n) ältere Sessions · ") + "anpinnen · umbenennen",
                     meta: "", header: false, accent: Self.faint)
        case .togglePinProject(_, let name, let pinned):
            let t = (pinned ? templates.unpinProject : templates.pinProject)!
            cell.set(glyph: t.glyph, text: t.label, detail: pinned ? "\(name) — im Pin-Screen (⇧⇥)" : "\(name) — oben im Pin-Screen (⇧⇥), ⌘⇧P", meta: "", header: false, accent: Self.yellow)
        case .rename(let s):
            let t = templates.rename!
            cell.set(glyph: t.glyph, text: t.label, detail: s.title ?? (t.hint ?? ""), meta: s.titleSource == "manual" ? "✎" : "", header: false, accent: Self.blue)
        case .jump(_, let st, let name):
            let waiting = st == "awaitingInput"
            cell.set(glyph: "→", text: "Zur Kachel", detail: name + (waiting ? " — wartet auf dich" : (st == "working" ? " — arbeitet" : "")),
                     meta: "", header: false, accent: waiting ? Self.orange : Self.green)
        case .wiedervorlage(let w, _):
            cell.set(glyph: "⏰", text: w.title, detail: w.overdue ? "seit \(-w.daysLeft) d fällig" : "heute fällig", meta: w.due, header: false, accent: Self.yellow)
        }
        cell.setPrimary(isPrimary(row))
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = HomeRowBackground(); v.accent = accent; v.isPrimary = isPrimary(row); return v
    }
}

/// Randlose Hinweiszeile über dem Baum; Klick = Aktion, kein Fokusklau.
final class NoticeButton: NSButton {
    var onClick: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; focusRingType = .none; setButtonType(.momentaryChange)
        target = self; action = #selector(fire)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { false }
    @objc private func fire() { onClick?() }
}

/// Baumzeile: Glyph · Name · (●)
final class TreeCell: NSView {
    private let glyph = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "●")
    override init(frame: NSRect) {
        super.init(frame: frame)
        for f in [glyph, name, dot] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        glyph.font = HomePaneView.mono(-1)
        name.font = HomePaneView.mono()
        dot.font = HomePaneView.mono(-3)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            name.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            dot.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(glyph g: String, glyphColor: NSColor, text: String, color: NSColor, dot d: NSColor?) {
        glyph.stringValue = g; glyph.textColor = glyphColor
        name.stringValue = text; name.textColor = color
        dot.isHidden = d == nil; dot.textColor = d ?? .clear
    }
}

/// Aktionszeile: Glyph · Text · Detail (dim) · Meta rechts; Kopfzeilen dim und klein.
final class ActionCell: NSView {
    /// Nachträglich (die Zelle kennt ihre Zeile nicht): Schriftgrade für Knopf- vs. Listenzeile.
    func setPrimary(_ p: Bool) {
        let header = text.stringValue.hasPrefix("── ")
        guard !header else { return }
        glyph.font = HomePaneView.mono(p ? 1 : -1, .bold)
        text.font = HomePaneView.mono(p ? 0 : -1, p ? .semibold : .regular)
        text.textColor = p ? HomePaneView.fg : HomePaneView.fg.withAlphaComponent(0.85)
        detail.font = HomePaneView.mono(p ? 0 : -1)
    }
    private let glyph = NSTextField(labelWithString: "")
    private let text = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        for f in [glyph, text, detail, meta] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            addSubview(f)
        }
        meta.alignment = .right
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        text.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 4),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: text.trailingAnchor, constant: 10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            meta.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 10),
            meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            meta.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(glyph g: String, text t: String, detail d: String, meta m: String, header: Bool, accent: NSColor, metaColor: NSColor? = nil, primary: Bool = true) {
        let fg = HomePaneView.fg
        glyph.stringValue = g; glyph.textColor = accent
        glyph.font = HomePaneView.mono(primary ? 1 : -1, .bold)
        text.stringValue = header ? "── \(t) " : t
        text.font = header ? HomePaneView.mono(-2) : HomePaneView.mono(primary ? 0 : -1, primary ? .semibold : .regular)
        text.textColor = header ? HomePaneView.faint : (primary ? fg : fg.withAlphaComponent(0.85))
        detail.stringValue = d; detail.textColor = fg.withAlphaComponent(primary ? 0.6 : 0.5)
        detail.font = HomePaneView.mono(primary ? 0 : -1)
        meta.stringValue = m; meta.textColor = metaColor ?? HomePaneView.dim
        meta.font = HomePaneView.mono(-2)
    }
}

/// Auswahl als weiche, abgerundete Fläche in der Akzentfarbe statt des System-Blaus.
final class HomeRowBackground: NSTableRowView {
    var accent: NSColor = .controlAccentColor
    var isPrimary = false
    /// Knopf-Zeilen bekommen eine leise Fläche — so liest sich „das hier kann ich drücken" ohne Rahmen.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isPrimary, !isSelected else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        HomePaneView.fg.withAlphaComponent(0.045).setFill()
        path.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6)
        accent.withAlphaComponent(isEmphasized ? 0.22 : 0.10).setFill()
        path.fill()
        if isEmphasized {   // Akzentbalken nur in der fokussierten Spalte: „hier wirkt ⏎"
            let bar = NSBezierPath(roundedRect: NSRect(x: 2, y: 5, width: 3, height: bounds.height - 10), xRadius: 1.5, yRadius: 1.5)
            accent.setFill(); bar.fill()
        }
    }
    override var isEmphasized: Bool { get { window?.firstResponder.map { ($0 as? NSView)?.isDescendant(of: self.superview ?? self) ?? false } ?? false } set {} }
}

/// Tabellen/Outline, die Tasten und Fokuswechsel an die Home-Kachel melden.
final class HomeTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); if ok { onFocus?() }; return ok }
    override func resignFirstResponder() -> Bool { let ok = super.resignFirstResponder(); if ok { onFocus?() }; return ok }
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }   // Klick = Fokus, wie ⇥
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) { if onKey?(event) == true { return }; super.keyDown(with: event) }
}
final class HomeOutline: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); if ok { onFocus?() }; return ok }
    override func resignFirstResponder() -> Bool { let ok = super.resignFirstResponder(); if ok { onFocus?() }; return ok }
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) { if onKey?(event) == true { return }; super.keyDown(with: event) }
}


/// Quickstarts für Dock-Menü und URL-Scheme. Quelle 1: das letzte `projekte --json` (jede
/// Home-Kachel füllt den Store); Quelle 2: der Spiegel `~/.cache/projekte/quickstarts.json`,
/// den `projekte` mitschreibt — nötig beim Kaltstart per URL, bevor eine Kachel geladen hat, und
/// dieselbe Datei liest das Dock-Tile-Plugin, wenn die App gar nicht läuft.
final class QuickstartStore {
    static let shared = QuickstartStore()
    static let cacheFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/projekte/quickstarts.json")

    private var loaded: [ProjekteData.Quickstart] = []
    var items: [ProjekteData.Quickstart] {
        get { loaded.isEmpty ? Self.readCache() : loaded }
        set { loaded = newValue }
    }
    /// Per URL angeforderter Quickstart, den noch kein Fenster übernommen hat (Kaltstart).
    var pending: ProjekteData.Quickstart?

    func find(key: String) -> ProjekteData.Quickstart? { items.first { $0.key == key } }

    private struct Cache: Decodable { var quickstarts: [ProjekteData.Quickstart] }
    static func readCache() -> [ProjekteData.Quickstart] {
        guard let data = try? Data(contentsOf: cacheFile),
              let c = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return c.quickstarts
    }
}
