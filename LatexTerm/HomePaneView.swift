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

/// Startbildschirm einer Kachel (⌘N / erste Kachel). Bewusst karg: EINE Liste, zwei Zeilen je
/// Eintrag. Zwei Modi (⇥ wechselt, letzter Modus wird gemerkt):
/// - **Zuletzt** — Ordner mit Claude-Aktivität nach letzter Session sortiert (Projekte wie
///   Router/Bereiche); `→` zeigt die Sessions als eigene Liste (`⏎` setzt fort, `←` zurück).
/// - **Struktur** — durch den echten Ordnerbaum unter `root` navigieren (`→` rein, `←` hoch);
///   jeder Ordner ist startbar, Einträge aus `projekte` (Alias, Alter, letzte Session) werden angeheftet.
/// Überall: Tippen filtert, `⏎` startet Claude im Ordner, `⌥⏎` nur Shell, `⌘⇧N` neues Projekt, `⌘R` neu laden.
/// Bei Auswahl wird die Kachel zur Terminal-Kachel (`TerminalPane.launch`).
final class HomePaneView: NSView {

    /// (Pfad, Befehl-oder-nil) → Kachel wird Terminal in `Pfad`, `Befehl` wird getippt.
    var onLaunch: ((String, String?) -> Void)?
    var onClose: (() -> Void)?
    /// First-Responder-Wechsel der Liste → Kachel-Dimmung (wie `onFocusChanged` des Terminals).
    var onFocusChanged: ((Bool) -> Void)?
    /// Reserviert (Kopfzeile mit anderen Kacheln); zurzeit nicht angezeigt — die Titlebar-Punkte reichen.
    var otherPanes: (() -> [(String, String)])?

    private enum Mode { case recent, sessions(ProjekteData.Project), tree(String) }
    private var mode: Mode = .recent { didSet { rebuildRows(); persistMode() } }
    private var data: ProjekteData?
    /// Einträge aus `projekte` nach absolutem Pfad — Anreicherung der Struktur-Ansicht.
    private var byPath: [String: ProjekteData.Project] = [:]
    private var filter = "" { didSet { rebuildRows() } }
    private static let treeExcludes: Set<String> = ["node_modules", ".build", "venv", "DerivedData", "7_AppData", "__pycache__"]

    /// Eine Zeile der Liste — Projekt oder Session, jeweils mit fertigen Texten.
    private struct Row {
        var title: String
        var meta: String        // rechts oben, dim (Alias · Alter)
        var sub: String         // zweite Zeile, dim
        var warn: Bool = false
        var path: String        // Startordner für ⏎ / ⌥⏎
        var project: ProjekteData.Project?
        var session: ProjekteData.Session?
        var hasChildren = false // Struktur: → kann hinein
    }
    private var rows: [Row] = []

    private let headline = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let table = HomeTable()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")

    static let fg = NSColor(red: 230/255.0, green: 225/255.0, blue: 225/255.0, alpha: 1)
    private static let dim = fg.withAlphaComponent(0.42)
    private static let yellow = NSColor(red: 235/255.0, green: 190/255.0, blue: 90/255.0, alpha: 1)
    private static let titleFont = NSFont.systemFont(ofSize: 15, weight: .medium)
    private static let metaFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private var accent: NSColor { FormulaSettings.shared.accentColor }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 23/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1).cgColor
        buildUI()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Das eigentliche Fokusziel der Kachel. WICHTIG: nicht über `becomeFirstResponder`
    /// umleiten — ein verschachteltes `makeFirstResponder` mit anschließendem `false`
    /// lässt AppKit den ALTEN Responder (ein anderes Terminal) wiederherstellen; die
    /// Tabelle sah dann fokussiert aus, Tasten gingen aber in die Nachbarkachel.
    var keyView: NSView { table }

    override var acceptsFirstResponder: Bool { false }

    /// Klick irgendwo in die Kachel (auch neben die Liste) holt den Fokus.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(table)
        super.mouseDown(with: event)
    }

    // MARK: Aufbau

    private func buildUI() {
        headline.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        headline.textColor = Self.fg
        hint.font = Self.metaFont
        hint.textColor = Self.dim
        hint.lineBreakMode = .byTruncatingTail
        footer.font = Self.metaFont
        footer.textColor = Self.dim
        footer.lineBreakMode = .byTruncatingTail

        table.headerView = nil
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.usesAlternatingRowBackgroundColors = false
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activate)
        table.onKey = { [weak self] ev in self?.handleKey(ev) ?? false }
        table.onFocus = { [weak self] f in self?.onFocusChanged?(f) }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        for v in [headline, hint, scroll, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let m: CGFloat = 28
        NSLayoutConstraint.activate([
            headline.topAnchor.constraint(equalTo: topAnchor, constant: 26),
            headline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            hint.centerYAnchor.constraint(equalTo: headline.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: headline.trailingAnchor, constant: 14),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m),
            scroll.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m - 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(m - 8)),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        renderChrome()
    }

    private func renderChrome() {
        var crumb = ""
        switch mode {
        case .recent:
            setHeadline(active: 0)
            footer.stringValue = "⏎ Claude    → Sessions    ⌥⏎ Shell    ⇥ Struktur    ⌘⇧N neues Projekt"
        case .sessions(let p):
            headline.attributedStringValue = NSAttributedString(string: p.name, attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: Self.fg])
            footer.stringValue = "⏎ Session fortsetzen    ← zurück    ⌥⏎ Shell"
        case .tree(let path):
            setHeadline(active: 1)
            footer.stringValue = "⏎ Claude hier    → hinein    ← hoch    ⌥⏎ Shell    ⇥ Zuletzt    ⌘⇧N neues Projekt"
            if let root = data?.root {
                let relParts = path.hasPrefix(root) ? String(path.dropFirst(root.count)).split(separator: "/").map(String.init) : []
                crumb = ([(root as NSString).lastPathComponent] + relParts).joined(separator: " › ")
            }
        }
        var h = crumb
        if !filter.isEmpty { h += (h.isEmpty ? "" : "    ") + "⌕ " + filter }
        hint.stringValue = h
        hint.textColor = filter.isEmpty ? Self.dim : accent
    }

    /// „Zuletzt · Struktur" — der aktive Modus hell, der andere dim.
    private func setHeadline(active: Int) {
        let a = NSMutableAttributedString()
        for (i, name) in ["Zuletzt", "Struktur"].enumerated() {
            if i > 0 { a.append(NSAttributedString(string: "   ·   ", attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .regular), .foregroundColor: Self.dim.withAlphaComponent(0.25)])) }
            a.append(NSAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: i == active ? .semibold : .regular),
                .foregroundColor: i == active ? Self.fg : Self.dim]))
        }
        headline.attributedStringValue = a
    }

    // MARK: Modus merken

    private func persistMode() {
        let d = UserDefaults.standard
        switch mode {
        case .recent: d.set("recent", forKey: "LatexTerm.homeMode")
        case .tree(let p): d.set("tree", forKey: "LatexTerm.homeMode"); d.set(p, forKey: "LatexTerm.homeTreePath")
        case .sessions: break
        }
    }

    private func restoreMode() {
        let d = UserDefaults.standard
        guard let root = data?.root else { mode = .recent; return }
        if d.string(forKey: "LatexTerm.homeMode") == "tree" {
            var p = d.string(forKey: "LatexTerm.homeTreePath") ?? root
            var isDir: ObjCBool = false
            if !(p.hasPrefix(root) && FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue) { p = root }
            mode = .tree(p)
        } else {
            mode = .recent
        }
    }

    private func toggleMode() {
        switch mode {
        case .recent:
            let root = data?.root ?? NSHomeDirectory()
            let saved = UserDefaults.standard.string(forKey: "LatexTerm.homeTreePath") ?? root
            filter = ""
            mode = .tree(saved.hasPrefix(root) && FileManager.default.fileExists(atPath: saved) ? saved : root)
        case .tree, .sessions:
            filter = ""
            mode = .recent
        }
    }

    // MARK: Daten

    @objc func reload() {
        hint.stringValue = "…"
        ProjekteLoader.load { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let d):
                self.data = d
                self.byPath = Dictionary(d.projects.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
                self.restoreMode()
            case .failure(let err):
                self.data = nil
                self.rows = [Row(title: "projekte nicht erreichbar", meta: "", sub: err.message, warn: true, path: NSHomeDirectory())]
                self.table.reloadData()
            }
            self.renderChrome()
        }
    }

    private func rebuildRows() {
        let keep = table.selectedRow
        let q = filter.lowercased()
        switch mode {
        case .recent:
            let list = (data?.projects ?? []).filter { p in
                q.isEmpty || p.name.lowercased().contains(q) || p.group.lowercased().contains(q)
                    || p.aliases.contains { $0.lowercased().contains(q) }
            }
            rows = list.map { p in
                var sub = p.group.isEmpty ? "" : p.group
                if let t = p.sessions.first?.title, !t.isEmpty { sub += (sub.isEmpty ? "" : "  ·  ") + t }
                if let g = p.git, let d = g.dirty, d > 0 { sub += "  ·  ✎\(d)" }
                return Row(title: (p.level == "unter-projekt" ? "↳ " : "") + p.name,
                           meta: Self.meta(for: p), sub: sub,
                           warn: p.level == "ohne-claude-md", path: p.path, project: p)
            }
        case .sessions(let p):
            rows = p.sessions.map { s in
                Row(title: s.title ?? "(ohne Titel)", meta: Self.age(s.lastAt),
                    sub: "\(s.turns) Nachrichten  ·  \(String(s.id.prefix(8)))", path: p.path, project: p, session: s)
            }
            if rows.isEmpty {
                rows = [Row(title: "Noch keine Session", meta: "", sub: "⏎ startet eine neue", path: p.path, project: p)]
            }
        case .tree(let dir):
            rows = Self.subfolders(of: dir).filter { q.isEmpty || $0.lowercased().contains(q) }.map { name in
                let path = (dir as NSString).appendingPathComponent(name)
                let p = byPath[path]
                var sub = ""
                if let t = p?.sessions.first?.title, !t.isEmpty { sub = t }
                else if let h = p?.claudeMdHeader { sub = h }
                return Row(title: name, meta: p.map(Self.meta(for:)) ?? "", sub: sub,
                           path: path, project: p, hasChildren: !Self.subfolders(of: path).isEmpty)
            }
            if rows.isEmpty {
                rows = [Row(title: "(keine Unterordner)", meta: "", sub: "⏎ startet Claude in " + (dir as NSString).lastPathComponent, path: dir)]
            }
        }
        table.reloadData()
        if !rows.isEmpty {
            let idx = min(max(keep, 0), rows.count - 1)
            table.selectRowIndexes(IndexSet(integer: q.isEmpty ? idx : 0), byExtendingSelection: false)
            table.scrollRowToVisible(table.selectedRow)
        }
        renderChrome()
    }

    private var selected: Row? {
        let r = table.selectedRow
        return (r >= 0 && r < rows.count) ? rows[r] : nil
    }

    private static func meta(for p: ProjekteData.Project) -> String {
        let alias = p.aliases.first.map { "\($0)   " } ?? ""
        return alias + age(p.lastActivity)
    }

    /// Sichtbare Unterordner, Finder-Reihenfolge (numerische Präfixe natürlich sortiert).
    private static func subfolders(of dir: String) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var isDir: ObjCBool = false
        return items.filter { name in
            !name.hasPrefix(".") && !treeExcludes.contains(name)
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

    // MARK: Aktionen

    private static let claude = "claude --dangerously-skip-permissions"

    @objc private func activate() {
        guard let row = selected else { return }
        if let s = row.session { onLaunch?(row.path, "\(Self.claude) --resume \(s.id)") }
        else { onLaunch?(row.path, Self.claude) }
    }

    private func shellOnly() {
        guard let row = selected else { return }
        onLaunch?(row.path, nil)
    }

    /// → : Zuletzt → Sessions des Eintrags; Struktur → in den Ordner hinein.
    private func forward() {
        switch mode {
        case .recent:
            guard let p = selected?.project else { return }
            filter = ""
            mode = .sessions(p)
        case .tree:
            guard let row = selected, row.hasChildren else { return }
            filter = ""
            mode = .tree(row.path)
        case .sessions:
            break
        }
    }

    /// ← : Sessions → Zuletzt; Struktur → eine Ebene hoch (nicht über root hinaus).
    private func back() {
        switch mode {
        case .sessions:
            mode = .recent
        case .tree(let dir):
            guard let root = data?.root, dir != root else { return }
            let parent = (dir as NSString).deletingLastPathComponent
            let child = (dir as NSString).lastPathComponent
            filter = ""
            mode = .tree(parent)
            if let i = rows.firstIndex(where: { $0.title == child }) {
                table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                table.scrollRowToVisible(i)
            }
        case .recent:
            break
        }
    }

    @objc private func newProject() {
        guard let data else { return }
        var groups: [String] = []
        for p in data.projects where !p.group.hasPrefix("/") && !p.group.hasPrefix("~") && !groups.contains(p.group) { groups.append(p.group) }
        for a in data.areas where a.id != "." && !groups.contains(a.id) { groups.append(a.id) }
        groups.sort()

        let alert = NSAlert()
        alert.messageText = "Neues Projekt"
        alert.informativeText = "Ordner anlegen, dann übernimmt Claude mit /neues-projekt (Interview, CLAUDE.md, Git)."
        alert.addButton(withTitle: "Anlegen")
        alert.addButton(withTitle: "Abbrechen")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 84))
        let nameField = NSTextField(frame: NSRect(x: 90, y: 56, width: 260, height: 22))
        nameField.placeholderString = "Ordnername"
        let groupPop = NSPopUpButton(frame: NSRect(x: 90, y: 28, width: 260, height: 24))
        groupPop.addItems(withTitles: groups)
        if let i = groups.firstIndex(of: selected?.project?.group ?? "") { groupPop.selectItem(at: i) }
        let aliasField = NSTextField(frame: NSRect(x: 90, y: 0, width: 260, height: 22))
        aliasField.placeholderString = "optional"
        for (y, t) in [(56, "Name"), (28, "Ordner"), (0, "Alias")] {
            let l = NSTextField(labelWithString: t); l.frame = NSRect(x: 0, y: y + 2, width: 84, height: 18); l.alignment = .right
            box.addSubview(l)
        }
        box.addSubview(nameField); box.addSubview(groupPop); box.addSubview(aliasField)
        alert.accessoryView = box
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
        guard !name.isEmpty, !name.contains("/"), let group = groupPop.titleOfSelectedItem else { return }
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespaces)
        let parent = (data.root as NSString).appendingPathComponent(group)
        let dir = (parent as NSString).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dir) {
            let a = NSAlert(); a.messageText = "Gibt es schon"; a.informativeText = dir; a.runModal(); return
        }
        // Shell startet im Elternordner (existiert); `hier` ist Mats' zsh-Funktion aus der .zshrc.
        var cmd = "mkdir -p \(Self.q(dir)) && cd \(Self.q(dir))"
        if !alias.isEmpty, alias.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil {
            cmd += " && hier \(alias)"
        }
        cmd += " && \(Self.claude) '/neues-projekt'"
        onLaunch?(parent, cmd)
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Tastatur

    /// Tasten der Liste (First Responder). true = verbraucht.
    private func handleKey(_ ev: NSEvent) -> Bool {
        let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.contains(.command), !mods.contains(.control) else { return false }
        switch ev.keyCode {
        case 36, 76: // Return / Enter
            if mods.contains(.option) { shellOnly() } else { activate() }
            return true
        case 53: // Esc
            if !filter.isEmpty { filter = "" } else { back() }
            return true
        case 51: // Backspace
            if !filter.isEmpty { filter.removeLast() } else { back() }
            return true
        case 48: toggleMode(); return true     // ⇥
        case 123: back(); return true          // ←
        case 124: forward(); return true       // →
        case 125, 126: return false            // ↑↓ → Tabelle
        default:
            if case .sessions = mode { return false }
            if let chars = ev.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                filter += chars
                return true
            }
            return false
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
}

// MARK: - Liste

extension HomePaneView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let r = rows[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? HomeRowView) ?? {
            let c = HomeRowView(); c.identifier = id; return c
        }()
        cell.set(title: r.title, meta: r.meta, sub: r.sub,
                 titleColor: r.warn ? Self.yellow : Self.fg, dim: Self.dim,
                 titleFont: Self.titleFont, metaFont: Self.metaFont)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = HomeRowBackground()
        v.accent = accent
        return v
    }
}

/// Zweizeilige Zelle: Titel + Meta rechts, darunter eine dimme Zeile.
final class HomeRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let meta = NSTextField(labelWithString: "")
    private let sub = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        for f in [title, meta, sub] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.lineBreakMode = .byTruncatingTail
            f.maximumNumberOfLines = 1
            addSubview(f)
        }
        meta.alignment = .right
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            meta.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            meta.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            meta.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: meta.trailingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(title t: String, meta m: String, sub s: String, titleColor: NSColor, dim: NSColor,
             titleFont: NSFont, metaFont: NSFont) {
        title.stringValue = t; title.textColor = titleColor; title.font = titleFont
        meta.stringValue = m; meta.textColor = dim; meta.font = metaFont
        sub.stringValue = s; sub.textColor = dim; sub.font = metaFont
    }
}

/// Auswahl als weiche, abgerundete Fläche in der Akzentfarbe statt des System-Blaus.
final class HomeRowBackground: NSTableRowView {
    var accent: NSColor = .controlAccentColor
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 8, yRadius: 8)
        accent.withAlphaComponent(isEmphasized ? 0.22 : 0.12).setFill()
        path.fill()
        let bar = NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: 3, height: bounds.height - 12), xRadius: 1.5, yRadius: 1.5)
        accent.setFill()
        bar.fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

/// NSTableView, das Tasten an die Home-Kachel weiterreicht (Filter tippen, Enter, ←→).
final class HomeTable: NSTableView {
    var onKey: ((NSEvent) -> Bool)?
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}
