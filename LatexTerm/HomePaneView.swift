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
    }
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

/// Startbildschirm einer Kachel (⌘N / erste Kachel): Projekte nach letzter Claude-Aktivität,
/// Sessions zum Fortsetzen, Status der anderen Kacheln. Enter startet Claude im Projekt,
/// die Kachel wird dann zur normalen Terminal-Kachel (`TerminalPane.launch`).
///
/// Tasten: ↑↓ Projekt · ←→ Session · ⏎ Claude (neu bzw. gewählte Session) · ⇧⏎ letzte Session
/// fortsetzen · ⌥⏎ nur Shell · Tippen filtert · Esc Filter leeren · ⌘R neu laden ·
/// ⌘⇧N neues Projekt · ⌘W Kachel schließen.
final class HomePaneView: NSView {

    /// (Pfad, Befehl-oder-nil) → Kachel wird Terminal in `Pfad`, `Befehl` wird getippt.
    var onLaunch: ((String, String?) -> Void)?
    var onClose: (() -> Void)?
    /// First-Responder-Wechsel der Tabelle → Kachel-Dimmung (wie `onFocusChanged` des Terminals).
    var onFocusChanged: ((Bool) -> Void)?
    /// Kurzstatus der anderen Kacheln für die Kopfzeile: (Name, Status-Text).
    var otherPanes: (() -> [(String, String)])?

    private var data: ProjekteData?
    private var rows: [ProjekteData.Project] = []
    private var filter = "" { didSet { applyFilter() } }
    private var sessionIndex: Int? = nil { didSet { renderDetail() } }

    private let titleLabel = NSTextField(labelWithString: "Projekte")
    private let panesLabel = NSTextField(labelWithString: "")
    private let filterLabel = NSTextField(labelWithString: "")
    private let table = HomeTable()
    private let tableScroll = NSScrollView()
    private let detail = NSTextView()
    private let detailScroll = NSScrollView()
    private let helpLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Lade …")
    private var buttons: [NSButton] = []
    private var refreshTimer: Timer?

    private static let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private static let monoBold = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    private static let fg = NSColor(red: 230/255.0, green: 225/255.0, blue: 225/255.0, alpha: 1)
    private static let dim = NSColor(red: 230/255.0, green: 225/255.0, blue: 225/255.0, alpha: 0.45)
    private static let green = NSColor(red: 120/255.0, green: 200/255.0, blue: 130/255.0, alpha: 1)
    private static let yellow = NSColor(red: 235/255.0, green: 190/255.0, blue: 90/255.0, alpha: 1)

    enum Column: String, CaseIterable {
        case group, name, alias, age, git, title
        var title: String {
            switch self {
            case .group: return "Ordner"; case .name: return "Projekt"; case .alias: return "Alias"
            case .age: return "Aktiv"; case .git: return "Git"; case .title: return "Letzte Session"
            }
        }
        var width: CGFloat {
            switch self {
            case .group: return 190; case .name: return 170; case .alias: return 120
            case .age: return 80; case .git: return 110; case .title: return 260
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 23/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1).cgColor
        buildUI()
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(table)
        return false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshTimer?.invalidate()
        guard window != nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.renderPanes() }
        renderPanes()
    }

    deinit { refreshTimer?.invalidate() }

    // MARK: Aufbau

    private func buildUI() {
        let accent = FormulaSettings.shared.accentColor
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = Self.fg
        panesLabel.font = Self.mono
        panesLabel.textColor = Self.dim
        panesLabel.lineBreakMode = .byTruncatingTail
        filterLabel.font = Self.mono
        filterLabel.textColor = accent
        helpLabel.font = NSFont.systemFont(ofSize: 11)
        helpLabel.textColor = Self.dim
        helpLabel.stringValue = "↑↓ Projekt   ←→ Session   ⏎ Claude   ⇧⏎ letzte Session   ⌥⏎ nur Shell   Tippen filtert   Esc leert   ⌘R neu laden   ⌘⇧N neues Projekt"
        statusLabel.font = Self.mono
        statusLabel.textColor = Self.dim
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        table.headerView = NSTableHeaderView()
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for col in Column.allCases {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.rawValue))
            c.title = col.title
            c.width = col.width
            c.minWidth = 40
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onKey = { [weak self] ev in self?.handleKey(ev) ?? false }
        table.onFocus = { [weak self] f in self?.onFocusChanged?(f) }
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder

        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = true
        detail.backgroundColor = NSColor(white: 1, alpha: 0.04)
        detail.textContainerInset = NSSize(width: 10, height: 10)
        detail.font = Self.mono
        detail.textColor = Self.fg
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.borderType = .noBorder
        detailScroll.wantsLayer = true
        detailScroll.layer?.cornerRadius = 6

        let specs: [(String, Selector)] = [
            ("Claude  ⏎", #selector(actNew)), ("Fortsetzen  ⇧⏎", #selector(actResume)),
            ("Nur Shell  ⌥⏎", #selector(actShell)), ("Neues Projekt  ⌘⇧N", #selector(actNewProject)),
            ("Neu laden  ⌘R", #selector(reload)),
        ]
        for (title, sel) in specs {
            let b = NSButton(title: title, target: self, action: sel)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = NSFont.systemFont(ofSize: 11)
            buttons.append(b)
        }

        for v in [titleLabel, panesLabel, filterLabel, tableScroll, detailScroll, helpLabel, statusLabel] + buttons {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonRow)

        let m: CGFloat = 16
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: m),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            filterLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            filterLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 16),
            panesLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            panesLabel.leadingAnchor.constraint(greaterThanOrEqualTo: filterLabel.trailingAnchor, constant: 16),
            panesLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),

            tableScroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            tableScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            tableScroll.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.58, constant: -m),
            tableScroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -10),

            detailScroll.topAnchor.constraint(equalTo: tableScroll.topAnchor),
            detailScroll.leadingAnchor.constraint(equalTo: tableScroll.trailingAnchor, constant: 12),
            detailScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -m),
            detailScroll.bottomAnchor.constraint(equalTo: tableScroll.bottomAnchor),

            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            buttonRow.bottomAnchor.constraint(equalTo: helpLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: buttonRow.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m),
            statusLabel.centerYAnchor.constraint(equalTo: buttonRow.centerYAnchor),

            helpLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: m),
            helpLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -m),
            helpLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    // MARK: Daten

    @objc func reload() {
        statusLabel.stringValue = "Lade …"
        ProjekteLoader.load { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let d):
                self.data = d
                self.statusLabel.stringValue = "\(d.projects.count) Projekte"
                self.applyFilter()
            case .failure(let err):
                let msg = err.message
                self.data = nil
                self.rows = []
                self.table.reloadData()
                self.statusLabel.stringValue = "⚠ \(msg)"
                self.detail.string = ""
            }
        }
    }

    private func applyFilter() {
        guard let data else { rows = []; table.reloadData(); return }
        let selectedID = selectedProject?.id
        let q = filter.lowercased()
        rows = q.isEmpty ? data.projects : data.projects.filter { p in
            p.name.lowercased().contains(q) || p.group.lowercased().contains(q)
                || p.aliases.contains { $0.lowercased().contains(q) }
                || (p.sessions.first?.title?.lowercased().contains(q) ?? false)
        }
        filterLabel.stringValue = q.isEmpty ? "" : "▸ \(filter)"
        table.reloadData()
        if !rows.isEmpty {
            let idx = rows.firstIndex { $0.id == selectedID } ?? 0
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            table.scrollRowToVisible(idx)
        }
        sessionIndex = nil
    }

    private var selectedProject: ProjekteData.Project? {
        let r = table.selectedRow
        return (r >= 0 && r < rows.count) ? rows[r] : nil
    }

    // MARK: Darstellung

    private func renderPanes() {
        let list = otherPanes?() ?? []
        panesLabel.stringValue = list.isEmpty ? "" :
            "Kacheln: " + list.map { "\($0.0) \($0.1)" }.joined(separator: "  ·  ")
    }

    private func renderDetail() {
        guard let p = selectedProject else { detail.string = ""; return }
        let s = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor = HomePaneView.fg, bold: Bool = false) {
            s.append(NSAttributedString(string: text, attributes: [
                .font: bold ? Self.monoBold : Self.mono, .foregroundColor: color]))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        add(p.name + "\n", FormulaSettings.shared.accentColor, bold: true)
        add(p.path.replacingOccurrences(of: home, with: "~") + "\n", Self.dim)
        if !p.aliases.isEmpty { add("Aliase  ", Self.dim); add(p.aliases.joined(separator: ", ") + "\n", Self.green) }
        if let g = p.git { add("Git     ", Self.dim); add(Self.gitBadge(g) + "\n") }
        if p.level == "ohne-claude-md" { add("⚠ keine CLAUDE.md — ⌘⇧N legt sie nach\n", Self.yellow) }
        add("\nSessions\n", Self.fg, bold: true)
        if p.sessions.isEmpty { add("  (keine)\n", Self.dim) }
        for (i, sess) in p.sessions.enumerated() {
            let chosen = sessionIndex == i
            add(chosen ? "  ▶ " : "    ", FormulaSettings.shared.accentColor)
            add(Self.age(sess.lastAt).padding(toLength: 10, withPad: " ", startingAt: 0), Self.dim)
            add(String(sess.turns).leftPad(3) + "✉  ", Self.dim)
            add((sess.title ?? "(ohne Titel)") + "\n", chosen ? Self.fg : Self.dim, bold: chosen)
        }
        add("\n")
        add(sessionIndex == nil ? "⏎  neue Claude-Session\n" : "⏎  diese Session fortsetzen\n", Self.dim)
        let md = URL(fileURLWithPath: p.path).appendingPathComponent("CLAUDE.md")
        if let text = try? String(contentsOf: md, encoding: .utf8) {
            add("\nCLAUDE.md\n", Self.fg, bold: true)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines.prefix(30) { add("  " + line + "\n", Self.dim) }
            if lines.count > 30 { add("  …\n", Self.dim) }
        }
        detail.textStorage?.setAttributedString(s)
        detail.scroll(.zero)
    }

    static func age(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "–" }
        let delta = Date().timeIntervalSince(d)
        if delta < 3600 { return "vor \(Int(delta / 60)) min" }
        if delta < 86400 { return "vor \(Int(delta / 3600)) h" }
        if delta < 86400 * 14 { return "vor \(Int(delta / 86400)) d" }
        let f = DateFormatter(); f.dateFormat = "dd.MM.yy"
        return f.string(from: d)
    }

    static func gitBadge(_ g: ProjekteData.Git) -> String {
        var parts = ["⎇ " + (g.branch ?? "?")]
        if let d = g.dirty, d > 0 { parts.append("✎\(d)") }
        if let a = g.ahead, a > 0 { parts.append("↑\(a)") }
        if let b = g.behind, b > 0 { parts.append("↓\(b)") }
        if parts.count == 1 { parts.append("✓") }
        return parts.joined(separator: " ")
    }

    // MARK: Aktionen

    private func launch(shellOnly: Bool = false, sessionID: String? = nil) {
        guard let p = selectedProject else { return }
        let cmd: String?
        if shellOnly { cmd = nil }
        else if let sid = sessionID { cmd = "claude --dangerously-skip-permissions --resume \(sid)" }
        else { cmd = "claude --dangerously-skip-permissions" }
        onLaunch?(p.path, cmd)
    }

    @objc private func actNew() {
        if let i = sessionIndex, let p = selectedProject, i < p.sessions.count {
            launch(sessionID: p.sessions[i].id)
        } else {
            launch()
        }
    }
    @objc private func actResume() {
        guard let p = selectedProject else { return }
        launch(sessionID: p.sessions.first?.id)
    }
    @objc private func actShell() { launch(shellOnly: true) }
    @objc private func doubleClicked() { actNew() }

    @objc private func actNewProject() {
        guard let data else { return }
        var groups: [String] = []
        for p in data.projects where !p.group.hasPrefix("/") && !p.group.hasPrefix("~") && !groups.contains(p.group) { groups.append(p.group) }
        for a in data.areas where a.id != "." && !groups.contains(a.id) { groups.append(a.id) }
        groups.sort()

        let alert = NSAlert()
        alert.messageText = "Neues Projekt"
        alert.informativeText = "Ordner wird angelegt, Claude startet darin mit /neues-projekt (Interview, CLAUDE.md, Git)."
        alert.addButton(withTitle: "Anlegen")
        alert.addButton(withTitle: "Abbrechen")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 84))
        let nameField = NSTextField(frame: NSRect(x: 90, y: 56, width: 260, height: 22))
        nameField.placeholderString = "Ordnername (Unterstriche statt Leerzeichen)"
        let groupPop = NSPopUpButton(frame: NSRect(x: 90, y: 28, width: 260, height: 24))
        groupPop.addItems(withTitles: groups)
        if let i = groups.firstIndex(of: selectedProject?.group ?? "") { groupPop.selectItem(at: i) }
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
        cmd += " && claude --dangerously-skip-permissions '/neues-projekt'"
        onLaunch?(parent, cmd)
    }

    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Tastatur

    /// Tasten der Tabelle (First Responder). true = verbraucht.
    private func handleKey(_ ev: NSEvent) -> Bool {
        let mods = ev.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !mods.contains(.command), !mods.contains(.control) else { return false }
        switch ev.keyCode {
        case 36, 76: // Return / Enter
            if mods.contains(.option) { actShell() }
            else if mods.contains(.shift) { actResume() }
            else { actNew() }
            return true
        case 53: // Esc
            if !filter.isEmpty { filter = "" }
            return true
        case 51: // Backspace
            if !filter.isEmpty { filter.removeLast() }
            return true
        case 123: // ←
            guard let p = selectedProject, !p.sessions.isEmpty else { return true }
            if let i = sessionIndex { sessionIndex = i > 0 ? i - 1 : nil }
            return true
        case 124: // →
            guard let p = selectedProject, !p.sessions.isEmpty else { return true }
            if let i = sessionIndex { sessionIndex = min(i + 1, p.sessions.count - 1) } else { sessionIndex = 0 }
            return true
        case 125, 126: // ↑↓ → Tabelle selbst
            return false
        default:
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
        let focused: Bool = {
            let fr = window?.firstResponder as? NSView
            return fr === self || (fr?.isDescendant(of: self) ?? false)
        }()
        guard focused else { return super.performKeyEquivalent(with: event) }
        if mods == .command, a == "w" { onClose?(); return true }
        if mods == .command, a == "r" { reload(); return true }
        if mods == [.command, .shift], a.lowercased() == "n" { actNewProject(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Tabelle

extension HomePaneView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn.flatMap({ Column(rawValue: $0.identifier.rawValue) }), row < rows.count else { return nil }
        let p = rows[row]
        let id = NSUserInterfaceItemIdentifier("cell." + col.rawValue)
        let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            f.font = Self.mono
            return f
        }()
        var text = "", color = Self.fg, font = Self.mono
        switch col {
        case .group: text = p.group; color = Self.dim
        case .name:
            text = (p.level == "unter-projekt" ? "  └ " : "") + p.name
            font = Self.monoBold
            if p.level == "ohne-claude-md" { text += " ⚠"; color = Self.yellow }
        case .alias: text = p.aliases.joined(separator: ", "); color = Self.green
        case .age: text = Self.age(p.lastActivity)
        case .git: text = p.git.map(Self.gitBadge) ?? ""; color = Self.dim
        case .title: text = p.sessions.first?.title ?? ""; color = Self.dim
        }
        field.stringValue = text
        field.textColor = color
        field.font = font
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        sessionIndex = nil
    }
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

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
