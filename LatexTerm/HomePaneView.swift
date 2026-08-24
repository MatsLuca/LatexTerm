import AppKit

// MARK: - Datenmodell (Vertrag: `projekte --json`, claude-werkstatt/plans/projekt-launcher_2026-08-24.md)

struct ProjekteData: Decodable {
    struct Git: Decodable {
        var branch: String?
        var dirty: Int?
        var ahead: Int?
        var behind: Int?
    }
    struct Session: Decodable {
        var id: String
        var lastAt: String?
        var turns: Int
        var title: String?
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
    }
    struct Actions: Decodable {
        var resume: ActionTemplate
        var newProject: ActionTemplate
        var byLevel: [String: [ActionTemplate]]
    }
    var root: String
    var projects: [Project]
    var areas: [Area]
    var actions: Actions?
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
                DispatchQueue.main.async { completion(.success(parsed)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(LoaderError(message: "JSON von `\(command)` unlesbar: \(error)"))) }
            }
        }
    }
}

struct LoaderError: Error { let message: String }

extension Notification.Name {
    /// ⌘N (Menü): das Key-Fenster hängt eine Home-Kachel an.
    static let latexTermNewHomePane = Notification.Name("LatexTerm.newHomePane")
}

// MARK: - Home-Kachel

/// Startbildschirm einer Kachel (⌘N / erste Kachel): links der Ordnerbaum unter `root`
/// (Finder-Logik, lazy aus dem Dateisystem, Projekte/Sessions aus `projekte` angeheftet, ● wo
/// gerade eine Claude-Kachel läuft), rechts die Aktionen des gewählten Ordners:
/// „↻ Weiter" (letzte Session), „＋ Neue Session", „› Nur Shell", darunter „Zuletzt hier"
/// (Projekte unterhalb, nach Aktivität) bzw. „Frühere Sessions".
/// Tasten: ↑↓ · → in den Ordner / zu den Aktionen · ← zu / zurück · ⏎ ausführen · Tippen filtert
/// den Baum · Esc leert · ⌘⇧N neues Projekt im gewählten Ordner · ⌘R neu laden.
final class HomePaneView: NSView {

    /// (Pfad, Befehl-oder-nil) → Kachel wird Terminal in `Pfad`, `Befehl` wird getippt.
    var onLaunch: ((String, String?) -> Void)?
    var onClose: (() -> Void)?
    /// ⌘⏎ — Zoom wie bei Terminal-Kacheln (#26).
    var onZoom: (() -> Void)?
    /// First-Responder-Wechsel (Baum oder Aktionen) → Kachel-Dimmung.
    var onFocusChanged: ((Bool) -> Void)?
    /// (CWD, Claude-Status) der anderen gestarteten Kacheln → ● im Baum.
    var otherPanes: (() -> [(String, String)])?

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
        case header(String)
        var isHeader: Bool { if case .header = self { return true }; return false }
    }

    /// Fallback, falls `projekte` (noch) keine Templates liefert: nur Neu + Shell.
    private static let fallbackActions = ProjekteData.Actions(
        resume: .init(glyph: "↻", label: "Weiter", hint: nil, command: "claude --resume {session}", aliasCommand: nil),
        newProject: .init(glyph: "✚", label: "Neues Projekt", hint: nil, command: "claude", aliasCommand: nil),
        byLevel: ["ordner": [.init(glyph: "+", label: "Neue Session", hint: nil, command: "claude", aliasCommand: nil),
                             .init(glyph: "$", label: "Nur Shell", hint: nil, command: nil, aliasCommand: nil)]])
    private var templates: ProjekteData.Actions { data?.actions ?? Self.fallbackActions }

    private var data: ProjekteData?
    private var byPath: [String: ProjekteData.Project] = [:]
    private var root: Node?
    private var filter = "" { didSet { applyFilter() } }
    private var filtered: [Node] = []
    private var allFolders: [Node] = []          // flacher Index für die Suche (bis Tiefe 4)
    private var actions: [Action] = []
    private var running: [String: String] = [:]  // cwd → state
    private var refreshTimer: Timer?

    // MARK: Views

    private let tree = HomeOutline()
    private let treeScroll = NSScrollView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let list = HomeTable()
    private let listScroll = NSScrollView()
    private let footer = NSStackView()
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
        window?.makeFirstResponder(tree)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer?.invalidate()
        guard window != nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshRunning() }
    }
    deinit { refreshTimer?.invalidate() }

    // MARK: Aufbau

    private func buildUI() {
        title.font = Self.mono(4, .bold)
        title.textColor = Self.cyan
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Self.mono(-1)
        subtitle.textColor = Self.dim
        subtitle.lineBreakMode = .byTruncatingTail
        footer.orientation = .horizontal
        footer.spacing = 8
        let specs: [(String, String, Selector)] = [
            ("✚ Neues Projekt", "⌘⇧N — Ordner unter dem gewählten anlegen, dann /neues-projekt", #selector(newProject)),
            ("⟳ Neu laden", "⌘R", #selector(reload)),
            ("⤢ Zoom", "⌘⏎", #selector(zoomTapped)),
            ("▭ Kachel schließen", "⌘W", #selector(closeTapped)),
        ]
        for (label, tip, sel) in specs {
            let b = NSButton(title: label, target: self, action: sel)
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = Self.mono(-2)
            b.contentTintColor = Self.dim
            b.toolTip = tip
            b.focusRingType = .none
            footer.addArrangedSubview(b)
        }
        let help = NSTextField(labelWithString: "⏎ ausführen · →← Baum/Aktionen · tippen filtert")
        help.font = Self.mono(-2)
        help.textColor = Self.faint
        footer.addArrangedSubview(help)
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
        tree.onFocus = { [weak self] f in self?.focusChanged(f) }
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
        list.onFocus = { [weak self] f in self?.focusChanged(f) }
        listScroll.documentView = list
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder

        for v in [treeScroll, divider, title, subtitle, listScroll, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let m: CGFloat = 18
        NSLayoutConstraint.activate([
            treeScroll.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            treeScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            treeScroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.36),
            treeScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            divider.leadingAnchor.constraint(equalTo: treeScroll.trailingAnchor, constant: 8),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: treeScroll.topAnchor),
            divider.bottomAnchor.constraint(equalTo: treeScroll.bottomAnchor),

            title.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: m),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m),

            listScroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            listScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: m - 8),
            listScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(m - 8)),
            listScroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private var focusInside = false
    private func focusChanged(_ f: Bool) {
        if f { if !focusInside { focusInside = true; onFocusChanged?(true) }; return }
        // Wechsel Baum ↔ Aktionen: erst prüfen, ob der Fokus die Kachel wirklich verlässt.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let fr = self.window?.firstResponder as? NSView
            let inside = fr.map { $0 === self || $0.isDescendant(of: self) } ?? false
            if !inside && self.focusInside { self.focusInside = false; self.onFocusChanged?(false) }
        }
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
                self.index(root, depth: 0)
                self.tree.reloadData()
                self.tree.expandItem(root)
                self.refreshRunning()
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

    private func index(_ node: Node, depth: Int) {
        allFolders.append(node)
        guard depth < 4 else { return }
        for c in node.children(Self.treeExcludes) { index(c, depth: depth + 1) }
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
            tree.reloadData()
            if let n = selectedNode { let r = tree.row(forItem: n); if r >= 0 { tree.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) } }
        }
    }

    // MARK: Filter

    private func applyFilter() {
        let q = filter.lowercased()
        if q.isEmpty {
            filtered = []
            tree.reloadData()
            if let root { tree.expandItem(root) }
            if let sel = selectedNodeBeforeFilter { reveal(sel) }
            selectedNodeBeforeFilter = nil
        } else {
            if selectedNodeBeforeFilter == nil { selectedNodeBeforeFilter = selectedNode }
            filtered = allFolders.filter { n in
                n.name.lowercased().contains(q)
                    || (byPath[n.path]?.aliases.contains { $0.lowercased().contains(q) } ?? false)
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

    private func renderActions() {
        guard let node = selectedNode, let d = data else { actions = []; list.reloadData(); return }
        let p = byPath[node.path]
        let isRoot = node.path == d.root
        title.stringValue = isRoot ? (node.name) : node.name
        var sub: [String] = []
        if let a = p?.aliases, !a.isEmpty { sub.append(a.joined(separator: ", ")) }
        if let h = p?.claudeMdHeader { sub.append(h) } else if !isRoot { sub.append("keine CLAUDE.md") }
        subtitle.stringValue = sub.joined(separator: "   ·   ")

        var out: [Action] = []
        // „Weiter" = die neueste Session im GESAMTEN Teilbaum (eigene + alle Unterordner) —
        // ein Bereich zeigt so das zuletzt bearbeitete Projekt darunter, nicht seine eigene alte Session.
        var candidates: [(ProjekteData.Project, ProjekteData.Session)] = []
        if let p, let s = p.sessions.first { candidates.append((p, s)) }
        let below = d.projects.filter { $0.path != node.path && $0.path.hasPrefix(node.path + "/") && !$0.sessions.isEmpty }
        for q in below { if let s = q.sessions.first { candidates.append((q, s)) } }
        candidates.sort { ($0.1.lastAt ?? "") > ($1.1.lastAt ?? "") }
        if let (q, s) = candidates.first {
            out.append(.resume(s, path: q.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt),
                               project: q.path == node.path ? nil : q.name))
        }
        let level = p?.level ?? "ordner"
        for t in templates.byLevel[level] ?? templates.byLevel["ordner"] ?? [] {
            out.append(.run(t, path: node.path))
        }

        // Weitere Projekte unterhalb, nach Aktivität (Root: „Zuletzt überall"); das „Weiter"-Projekt nicht doppelt
        let rest = candidates.dropFirst().filter { $0.0.path != node.path }
        if !rest.isEmpty {
            out.append(.header(isRoot ? "Zuletzt überall" : "Zuletzt hier"))
            for (q, s) in rest.prefix(12) {
                out.append(.resume(s, path: q.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt), project: q.name))
            }
        }
        if let p, p.sessions.count > 1 {
            out.append(.header("Frühere Sessions"))
            for s in p.sessions.dropFirst() {
                out.append(.resume(s, path: node.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt), project: nil))
            }
        }
        actions = out
        list.reloadData()
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    private func run(_ a: Action) {
        switch a {
        case .resume(let s, let path, _, _, _):
            onLaunch?(path, (templates.resume.command ?? "").replacingOccurrences(of: "{session}", with: s.id))
        case .run(let t, let path):
            onLaunch?(path, t.command)
        case .header: break
        }
    }

    @objc private func zoomTapped() { onZoom?() }
    @objc private func closeTapped() { onClose?() }

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

    @objc private func newProject() {
        guard let parentNode = selectedNode else { return }
        let alert = NSAlert()
        alert.messageText = "Neues Projekt in \(parentNode.name)"
        alert.informativeText = "Ordner anlegen, dann übernimmt Claude mit /neues-projekt (Interview, CLAUDE.md, Git)."
        alert.addButton(withTitle: "Anlegen")
        alert.addButton(withTitle: "Abbrechen")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 54))
        let nameField = NSTextField(frame: NSRect(x: 70, y: 30, width: 260, height: 22))
        nameField.placeholderString = "Ordnername"
        let aliasField = NSTextField(frame: NSRect(x: 70, y: 0, width: 260, height: 22))
        aliasField.placeholderString = "optional"
        for (y, t) in [(30, "Name"), (0, "Alias")] {
            let l = NSTextField(labelWithString: t); l.frame = NSRect(x: 0, y: y + 2, width: 64, height: 18); l.alignment = .right
            box.addSubview(l)
        }
        box.addSubview(nameField); box.addSubview(aliasField)
        alert.accessoryView = box
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard !name.isEmpty, !name.contains("/") else { return }
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespaces)
        let dir = (parentNode.path as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dir) {
            let a = NSAlert(); a.messageText = "Gibt es schon"; a.informativeText = dir; a.runModal(); return
        }
        let t = templates.newProject
        var cmd = "mkdir -p \(Self.q(dir)) && cd \(Self.q(dir))"
        if !alias.isEmpty, alias.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
           let ac = t.aliasCommand {
            cmd += " && " + ac.replacingOccurrences(of: "{alias}", with: alias)
        }
        if let c = t.command { cmd += " && " + c }
        onLaunch?(parentNode.path, cmd)
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Tastatur

    private func treeKey(_ ev: NSEvent) -> Bool {
        let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.contains(.command), !mods.contains(.control) else { return false }
        switch ev.keyCode {
        case 36, 76:
            if let a = actions.first { run(a) }
            return true
        case 124: // → : aufklappen, sonst zu den Aktionen
            if let n = selectedNode, filter.isEmpty, n.hasChildren, !tree.isItemExpanded(n) {
                tree.expandItem(n); return true
            }
            focusList(); return true
        case 123: // ← : zuklappen, sonst zum Eltern-Ordner
            guard let n = selectedNode else { return true }
            if filter.isEmpty, tree.isItemExpanded(n) { tree.collapseItem(n); return true }
            if let p = n.parent { reveal(p) }
            return true
        case 53: if !filter.isEmpty { filter = "" }; return true
        case 51: if !filter.isEmpty { filter.removeLast() }; return true
        case 125, 126: return false
        default:
            if let chars = ev.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                filter += chars; return true
            }
            return false
        }
    }

    private func listKey(_ ev: NSEvent) -> Bool {
        let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.contains(.command), !mods.contains(.control) else { return false }
        switch ev.keyCode {
        case 36, 76: runSelectedAction(); return true
        case 123, 53: window?.makeFirstResponder(tree); return true   // ← / Esc zurück zum Baum
        case 125, 126: return false
        default: return true
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
        if !filter.isEmpty { return item == nil ? filtered.count : 0 }
        if item == nil { return root == nil ? 0 : 1 }
        return (item as? Node)?.children(Self.treeExcludes).count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if !filter.isEmpty { return filtered[index] }
        if item == nil { return root! }
        return (item as! Node).children(Self.treeExcludes)[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        filter.isEmpty && ((item as? Node)?.hasChildren ?? false)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? Node else { return nil }
        let id = NSUserInterfaceItemIdentifier("treeCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? TreeCell) ?? { let c = TreeCell(); c.identifier = id; return c }()
        let p = byPath[n.path]
        let glyph: String, glyphColor: NSColor, color: NSColor
        switch p?.level {
        case "projekt", "unter-projekt": glyph = "▣"; glyphColor = Self.cyan;   color = Self.fg
        case "router", "bereich":        glyph = "▤"; glyphColor = Self.violet; color = Self.fg.withAlphaComponent(0.75)
        case "ohne-claude-md":           glyph = "◇"; glyphColor = Self.yellow; color = Self.fg
        default:                         glyph = "·"; glyphColor = Self.faint;  color = Self.dim
        }
        let label = filter.isEmpty ? n.name : String(n.path.dropFirst((root?.path.count ?? 0) + 1))
        var dot: NSColor? = nil
        if let st = running.first(where: { $0.key == n.path || $0.key.hasPrefix(n.path + "/") })?.value {
            dot = st == "awaitingInput" ? Self.orange : Self.green
        }
        cell.set(glyph: glyph, glyphColor: glyphColor, text: label, color: color, dot: dot)
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
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { HomePaneView.base + (actions[row].isHeader ? 19 : 15) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("actionCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ActionCell) ?? { let c = ActionCell(); c.identifier = id; return c }()
        switch actions[row] {
        case .header(let t):
            cell.set(glyph: "", text: t, detail: "", meta: "", header: true, accent: Self.faint)
        case .resume(_, _, let t, let age, let project):
            let r = templates.resume
            cell.set(glyph: r.glyph, text: project.map { "\(r.label) · \($0)" } ?? r.label, detail: t, meta: age, header: false, accent: Self.green)
        case .run(let t, _):
            let color: NSColor = t.command == nil ? Self.blue : (t.glyph == "+" ? Self.cyan : Self.violet)
            cell.set(glyph: t.glyph, text: t.label, detail: t.hint ?? "", meta: "", header: false, accent: color)
        }
        return cell
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = HomeRowBackground(); v.accent = accent; return v
    }
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
    func set(glyph g: String, text t: String, detail d: String, meta m: String, header: Bool, accent: NSColor) {
        let fg = HomePaneView.fg
        glyph.stringValue = g; glyph.textColor = accent
        glyph.font = HomePaneView.mono(0, .bold)
        text.stringValue = header ? "── \(t) " : t
        text.font = header ? HomePaneView.mono(-2) : HomePaneView.mono(0, .semibold)
        text.textColor = header ? HomePaneView.faint : fg
        detail.stringValue = d; detail.textColor = fg.withAlphaComponent(0.6)
        detail.font = HomePaneView.mono()
        meta.stringValue = m; meta.textColor = HomePaneView.blue.withAlphaComponent(0.8)
        meta.font = HomePaneView.mono(-2)
    }
}

/// Auswahl als weiche, abgerundete Fläche in der Akzentfarbe statt des System-Blaus.
final class HomeRowBackground: NSTableRowView {
    var accent: NSColor = .controlAccentColor
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6)
        accent.withAlphaComponent(isEmphasized ? 0.22 : 0.12).setFill()
        path.fill()
    }
    override var isEmphasized: Bool { get { window?.firstResponder.map { ($0 as? NSView)?.isDescendant(of: self.superview ?? self) ?? false } ?? false } set {} }
}

/// Tabellen/Outline, die Tasten und Fokuswechsel an die Home-Kachel melden.
final class HomeTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); if ok { onFocus?(true) }; return ok }
    override func resignFirstResponder() -> Bool { let ok = super.resignFirstResponder(); if ok { onFocus?(false) }; return ok }
    override func keyDown(with event: NSEvent) { if onKey?(event) == true { return }; super.keyDown(with: event) }
}
final class HomeOutline: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); if ok { onFocus?(true) }; return ok }
    override func resignFirstResponder() -> Bool { let ok = super.resignFirstResponder(); if ok { onFocus?(false) }; return ok }
    override func keyDown(with event: NSEvent) { if onKey?(event) == true { return }; super.keyDown(with: event) }
}
