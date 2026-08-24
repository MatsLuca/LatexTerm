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
    var root: String
    var projects: [Project]
    var areas: [Area]
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
        case new(path: String)
        case shell(path: String)
        case header(String)
        var isHeader: Bool { if case .header = self { return true }; return false }
    }

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
    private let footer = NSTextField(labelWithString: "")
    private let divider = NSView()

    static let fg = NSColor(red: 230/255.0, green: 225/255.0, blue: 225/255.0, alpha: 1)
    private static let dim = fg.withAlphaComponent(0.42)
    private static let faint = fg.withAlphaComponent(0.22)
    private static let yellow = NSColor(red: 235/255.0, green: 190/255.0, blue: 90/255.0, alpha: 1)
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
        title.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        title.textColor = Self.fg
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        subtitle.textColor = Self.dim
        subtitle.lineBreakMode = .byTruncatingTail
        footer.font = NSFont.systemFont(ofSize: 11)
        footer.textColor = Self.faint
        footer.stringValue = "⌘⇧N  Neues Projekt im gewählten Ordner"
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Self.fg.withAlphaComponent(0.08).cgColor

        // Baum
        tree.headerView = nil
        tree.rowHeight = 26
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
        list.rowHeight = 30
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
        if let s = p?.sessions.first {
            out.append(.resume(s, path: node.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt), project: nil))
        }
        out.append(.new(path: node.path))
        out.append(.shell(path: node.path))

        // Projekte unterhalb, nach Aktivität (Root: „Zuletzt überall")
        let below = d.projects.filter { $0.path != node.path && $0.path.hasPrefix(node.path + "/") && !$0.sessions.isEmpty }
        if !below.isEmpty {
            out.append(.header(isRoot ? "Zuletzt überall" : "Zuletzt hier"))
            for q in below.prefix(12) {
                if let s = q.sessions.first {
                    out.append(.resume(s, path: q.path, title: s.title ?? "(ohne Titel)", age: Self.age(s.lastAt), project: q.name))
                }
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

    private static let claude = "claude --dangerously-skip-permissions"

    private func run(_ a: Action) {
        switch a {
        case .resume(let s, let path, _, _, _): onLaunch?(path, "\(Self.claude) --resume \(s.id)")
        case .new(let path): onLaunch?(path, Self.claude)
        case .shell(let path): onLaunch?(path, nil)
        case .header: break
        }
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
        var cmd = "mkdir -p \(Self.q(dir)) && cd \(Self.q(dir))"
        if !alias.isEmpty, alias.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil {
            cmd += " && hier \(alias)"   // zsh-Funktion aus der .zshrc
        }
        cmd += " && \(Self.claude) '/neues-projekt'"
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
        let glyph: String, color: NSColor
        switch p?.level {
        case "projekt", "unter-projekt": glyph = "▣"; color = Self.fg
        case "router", "bereich":        glyph = "▤"; color = Self.dim
        case "ohne-claude-md":           glyph = "◇"; color = Self.fg
        default:                         glyph = "▫"; color = Self.dim
        }
        let label = filter.isEmpty ? n.name : String(n.path.dropFirst((root?.path.count ?? 0) + 1))
        var dot: NSColor? = nil
        if let st = running.first(where: { $0.key == n.path || $0.key.hasPrefix(n.path + "/") })?.value {
            dot = st == "awaitingInput" ? Self.yellow : accent
        }
        cell.set(glyph: glyph, text: label, color: color, dot: dot)
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
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { actions[row].isHeader ? 34 : 30 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("actionCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ActionCell) ?? { let c = ActionCell(); c.identifier = id; return c }()
        switch actions[row] {
        case .header(let t):
            cell.set(glyph: "", text: t, detail: "", meta: "", header: true, accent: accent)
        case .resume(_, _, let t, let age, let project):
            if let project {
                cell.set(glyph: "↻", text: project, detail: t, meta: age, header: false, accent: accent)
            } else {
                cell.set(glyph: "↻", text: "Weiter", detail: t, meta: age, header: false, accent: accent)
            }
        case .new:   cell.set(glyph: "＋", text: "Neue Session", detail: "", meta: "", header: false, accent: accent)
        case .shell: cell.set(glyph: "›", text: "Nur Shell", detail: "", meta: "", header: false, accent: accent)
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
        glyph.font = NSFont.systemFont(ofSize: 11)
        name.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        dot.font = NSFont.systemFont(ofSize: 9)
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
    func set(glyph g: String, text: String, color: NSColor, dot d: NSColor?) {
        glyph.stringValue = g; glyph.textColor = color.withAlphaComponent(0.6)
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
        glyph.font = NSFont.systemFont(ofSize: 13)
        text.stringValue = t
        text.font = header ? NSFont.systemFont(ofSize: 11, weight: .semibold) : NSFont.systemFont(ofSize: 14, weight: .medium)
        text.textColor = header ? fg.withAlphaComponent(0.35) : fg
        detail.stringValue = d; detail.textColor = fg.withAlphaComponent(0.5)
        detail.font = NSFont.systemFont(ofSize: 13)
        meta.stringValue = m; meta.textColor = fg.withAlphaComponent(0.35)
        meta.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
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
