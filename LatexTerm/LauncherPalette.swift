import AppKit

/// ⌘K: eine schwebende Karte über der Home-Kachel. Leer zeigt sie, was gerade zählt (wartende
/// Kacheln, Fälliges, letzte Sessions, Aktionen hier); Tippen durchsucht alles in Gruppen mit
/// hervorgehobenen Treffern; führendes `/` macht den Rest zum freien KI-Prompt (⏎ sendet).
/// Tasten: ↑↓ · ⏎ Hauptaktion · ⌘⏎ Zweitaktion · ⌘C kopieren · ⇥ Filter · Esc zurück.
final class LauncherPalette: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Kind { case session, project, folder, action, pane, task, hint, launch, answer, status }
    struct Badge { var text: String; var color: NSColor }
    struct Entry {
        var id: String
        var kind: Kind
        var title: String
        var subtitle: String = ""
        var keywords: String = ""
        var agent: String? = nil           // "claude" | "codex" — färbt das Symbol
        var accent: NSColor? = nil         // Projektfarbe (Balken links, Auswahl-Tönung)
        var badge: Badge? = nil            // rechts: Kontext-%, Kachelzustand, Fälligkeit
        var recency: Date? = nil           // Gleichstand-Sortierung, Leerzustand „Zuletzt“
        var pinned: Bool = false
        var primaryHint: String = "⏎ Öffnen"
        var secondaryHint: String? = nil   // ⌘⏎
        var secondary: (() -> Void)? = nil
        var copyText: String? = nil        // ⌘C
        var body: String? = nil            // .answer: mehrzeiliger Text
        var closesPalette: Bool = true
        var action: () -> Void = {}
    }
    struct Section { var title: String; var entries: [Entry] }
    /// Was die Home-Kachel liefert: Leerzustand in Gruppen + alles Durchsuchbare.
    struct Catalog {
        var home: [Section]
        var searchable: [Entry]
    }
    struct AIResults { var entries: [Entry]; var message: String }
    enum Filter: CaseIterable {
        case all, sessions, projects, actions, folders
        var label: String {
            switch self {
            case .all: return "Alles"; case .sessions: return "Sessions"; case .projects: return "Projekte"
            case .actions: return "Aktionen"; case .folders: return "Ordner"
            }
        }
        func admits(_ k: Kind) -> Bool {
            switch self {
            case .all: return true
            case .sessions: return k == .session
            case .projects: return k == .project
            case .actions: return k == .action || k == .pane || k == .task
            case .folders: return k == .folder
            }
        }
    }
    private enum Row {
        case header(String)
        case entry(Entry)
        var entry: Entry? { if case .entry(let e) = self { return e }; return nil }
    }

    var onAI: ((String, String, @escaping (Result<AIResults, Error>) -> Void) -> (() -> Void))?
    var onClose: (() -> Void)?

    private let catalog: Catalog
    private var rows: [Row] = []
    private var filter: Filter = .all
    private var isPrompt: Bool { LauncherSearch.prompt(field.stringValue) != nil }
    private var cancelAI: (() -> Void)?
    private var generation = 0
    private var aiResults: AIResults?
    private var aiStarted: Date?
    private var aiTimer: Timer?
    private var toastTimer: Timer?

    private let theme = ThemeStore.shared.theme
    private let scrim = NSView()
    private let card = NSView()
    private let icon = NSImageView()
    private let field = LauncherSearchField()
    private let chips = NSStackView()
    private var chipButtons: [NSButton] = []
    private let escButton = NSButton(title: "esc", target: nil, action: nil)
    private let sendPill = NSTextField(labelWithString: "⏎ senden")
    private let rule = NSView()
    private let table = PaletteTable()
    private let scroll = NSScrollView()
    private let footRule = NSView()
    private let hints = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var cardHeight: NSLayoutConstraint!
    private var cardTop: NSLayoutConstraint!
    private var fieldToChips: NSLayoutConstraint!
    private var fieldToPill: NSLayoutConstraint!

    private static let searchHeight: CGFloat = 58
    private static let footerHeight: CGFloat = 36
    private static let recentKey = "LatexTerm.paletteRecent"

    init(frame: NSRect, catalog: Catalog, query: String) {
        self.catalog = catalog
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        buildUI()
        field.stringValue = query
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    deinit { cancelAI?(); aiTimer?.invalidate(); toastTimer?.invalidate() }

    // MARK: Aufbau

    private func buildUI() {
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = theme.background.withAlphaComponent(0.78).cgColor
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)

        card.wantsLayer = true
        card.layer?.backgroundColor = theme.background.lightened(by: 0.05).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = theme.foreground.withAlphaComponent(0.14).cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.55
        card.layer?.shadowRadius = 30
        card.layer?.shadowOffset = CGSize(width: 0, height: -12)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Suche")
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        icon.contentTintColor = theme.dim

        field.font = AppFonts.mono(size: 18)
        field.textColor = theme.foreground
        field.delegate = self
        field.setAccessibilityLabel("Launcher durchsuchen oder KI fragen")

        chips.orientation = .horizontal
        chips.spacing = 4
        for f in Filter.allCases {
            let b = NSButton(title: f.label, target: self, action: #selector(chipClicked(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 7
            b.font = AppFonts.mono(size: 11, weight: .medium)
            b.setButtonType(.momentaryChange)
            b.tag = Filter.allCases.firstIndex(of: f)!
            b.setAccessibilityLabel("Filter \(f.label)")
            chipButtons.append(b)
            chips.addArrangedSubview(b)
        }

        escButton.isBordered = false
        escButton.wantsLayer = true
        escButton.layer?.cornerRadius = 6
        escButton.layer?.borderWidth = 1
        escButton.layer?.borderColor = theme.foreground.withAlphaComponent(0.18).cgColor
        escButton.font = AppFonts.mono(size: 10, weight: .medium)
        escButton.contentTintColor = theme.dim
        escButton.attributedTitle = NSAttributedString(string: "esc", attributes: [.foregroundColor: theme.dim, .font: AppFonts.mono(size: 10, weight: .medium)])
        escButton.target = self
        escButton.action = #selector(dismiss)
        escButton.setAccessibilityLabel("Suche schließen")

        sendPill.font = AppFonts.mono(size: 11, weight: .semibold)
        sendPill.textColor = HomePaneView.orange
        sendPill.wantsLayer = true
        sendPill.layer?.cornerRadius = 7
        sendPill.layer?.backgroundColor = HomePaneView.orange.withAlphaComponent(0.14).cgColor
        sendPill.alignment = .center
        sendPill.isHidden = true

        rule.wantsLayer = true
        rule.layer?.backgroundColor = theme.foreground.withAlphaComponent(0.08).cgColor
        footRule.wantsLayer = true
        footRule.layer?.backgroundColor = theme.foreground.withAlphaComponent(0.08).cgColor

        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(rowClicked)
        table.onHover = { [weak self] row in self?.hover(row) }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        hints.font = AppFonts.mono(size: 11)
        hints.textColor = theme.dim
        hints.lineBreakMode = .byTruncatingTail
        status.font = AppFonts.mono(size: 11)
        status.textColor = theme.faint
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hints.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(rawValue: 251), for: .horizontal)

        for v in [icon, field, chips, escButton, sendPill, rule, scroll, footRule, hints, status] {
            v.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(v)
        }
        cardTop = card.topAnchor.constraint(equalTo: topAnchor, constant: 40)
        cardHeight = card.heightAnchor.constraint(equalToConstant: 200)
        fieldToChips = field.trailingAnchor.constraint(equalTo: chips.leadingAnchor, constant: -12)
        fieldToPill = field.trailingAnchor.constraint(equalTo: sendPill.leadingAnchor, constant: -12)
        fieldToChips.isActive = true
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor), scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor), scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardTop, cardHeight,
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            { let c = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -40); c.priority = .defaultHigh; return c }(),

            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: card.topAnchor, constant: Self.searchHeight / 2),
            icon.widthAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            chips.trailingAnchor.constraint(equalTo: escButton.leadingAnchor, constant: -12),
            chips.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            sendPill.trailingAnchor.constraint(equalTo: escButton.leadingAnchor, constant: -12),
            sendPill.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            sendPill.widthAnchor.constraint(equalToConstant: 84),
            sendPill.heightAnchor.constraint(equalToConstant: 22),
            escButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            escButton.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            escButton.widthAnchor.constraint(equalToConstant: 34),
            escButton.heightAnchor.constraint(equalToConstant: 20),

            rule.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.searchHeight),
            rule.leadingAnchor.constraint(equalTo: card.leadingAnchor), rule.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footRule.topAnchor),
            footRule.leadingAnchor.constraint(equalTo: card.leadingAnchor), footRule.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footRule.heightAnchor.constraint(equalToConstant: 1),
            footRule.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.footerHeight),
            hints.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            hints.centerYAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.footerHeight / 2),
            status.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            status.centerYAnchor.constraint(equalTo: hints.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: hints.trailingAnchor, constant: 16)
        ])
        for b in chipButtons { b.heightAnchor.constraint(equalToConstant: 22).isActive = true }
        styleChips()
    }

    /// Einblenden: kurzes Aufhellen plus ein paar Punkte von oben — die Karte kommt aus der Kachel.
    private var slide: CGFloat = 0
    func present() {
        scrim.alphaValue = 0
        card.alphaValue = 0
        slide = 14
        needsLayout = true; layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrim.animator().alphaValue = 1
            card.animator().alphaValue = 1
            slide = 0
            needsLayout = true; layoutSubtreeIfNeeded()
        }
        focus()
    }

    func focus() { field.focusForTyping() }

    override func layout() {
        super.layout()
        // Anker: die Karte sitzt im oberen Drittel, nie zentriert — das Auge bleibt beim Suchfeld.
        let top = max(24, min(72, bounds.height * 0.10)) + slide
        if cardTop.constant != top { cardTop.constant = top }
        // Schatten muss die Ecken kennen, sonst zeichnet Core Animation ein Rechteck.
        card.layer?.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 18, cornerHeight: 18, transform: nil)
        fitCardHeight()
    }

    private func fitCardHeight() {
        var content: CGFloat = 0
        for i in rows.indices { content += height(of: rows[i]) }
        content += 12   // contentInsets
        let wanted = Self.searchHeight + 1 + max(content, 72) + 1 + Self.footerHeight
        let room = bounds.height - cardTop.constant - max(24, min(72, bounds.height * 0.10))
        let h = max(140, min(wanted, room))
        if abs(cardHeight.constant - h) > 0.5 { cardHeight.constant = h }
    }

    override func mouseDown(with event: NSEvent) {
        // Klick ins Dunkel schließt; Klick auf die Karte macht nichts Besonderes.
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    // MARK: Zustand

    @objc private func dismiss() { stopAI(); onClose?() }
    private func stopAI() {
        generation += 1; cancelAI?(); cancelAI = nil
        aiTimer?.invalidate(); aiTimer = nil; aiStarted = nil
    }

    func controlTextDidChange(_ obj: Notification) {
        stopAI(); aiResults = nil; update()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch NSStringFromSelector(selector) {
        case "moveDown:": move(1); return true
        case "moveUp:": move(-1); return true
        case "moveToBeginningOfDocument:", "scrollToBeginningOfDocument:": selectRow(firstEntryRow(from: 0, step: 1)); return true
        case "moveToEndOfDocument:", "scrollToEndOfDocument:": selectRow(firstEntryRow(from: rows.count - 1, step: -1)); return true
        case "scrollPageDown:": move(8); return true
        case "scrollPageUp:": move(-8); return true
        case "insertNewline:":
            if isPrompt && aiResults == nil { askAI() } else { choose() }
            return true
        case "insertTab:": cycleFilter(1); return true
        case "insertBacktab:": cycleFilter(-1); return true
        case "cancelOperation:": dismiss(); return true
        default: return false
        }
    }

    /// ⌘⏎ / ⌘C kommen als Tastenkürzel an der Kachel vorbei — sie reicht sie hierher, bevor Zoom/Kopieren greifen.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods == .command else { return false }
        switch event.charactersIgnoringModifiers {
        case "\r": chooseSecondary(); return true
        case "c":
            if let editor = field.currentEditor(), editor.selectedRange.length > 0 { return false }
            copySelected(); return true
        case "k": focus(); return true
        default: return false
        }
    }

    // MARK: Inhalt

    private func update() {
        let prompt = isPrompt
        icon.image = NSImage(systemSymbolName: prompt ? "sparkles" : "magnifyingglass", accessibilityDescription: prompt ? "KI" : "Suche")
        icon.contentTintColor = prompt ? HomePaneView.orange : theme.dim
        chips.isHidden = prompt
        sendPill.isHidden = !prompt
        fieldToChips.isActive = !prompt
        fieldToPill.isActive = prompt
        field.setPlaceholder(prompt ? "Frag, finde, starte …" : "Suchen · / fragt die KI",
                             color: theme.faint, font: AppFonts.mono(size: 18))
        if prompt { updatePrompt() } else { updateLocal() }
        table.reloadData()
        fitCardHeight()
        selectRow(firstEntryRow(from: 0, step: 1))
    }

    private func updateLocal() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            rows = flatten(catalog.home.map { Section(title: $0.title, entries: $0.entries.filter { filter.admits($0.kind) }) })
            status.stringValue = filter == .all ? "\(catalog.searchable.count) Einträge" : filter.label
            if rows.isEmpty { rows = [.header("Nichts in „\(filter.label)“ — ⇥ wechselt den Filter")] }
            return
        }
        let recent = Self.recentUses()
        struct Scored { var entry: Entry; var score: Int; var ranges: [NSRange] }
        var scored: [Scored] = []
        for e in catalog.searchable where filter.admits(e.kind) {
            guard let m = LauncherSearch.match(query: query, title: e.title, detail: e.subtitle + " " + e.keywords) else { continue }
            var s = m.score
            if let t = recent[e.id], Date().timeIntervalSince(t) < 14 * 86400 { s += 120 }
            if e.pinned { s += 30 }
            scored.append(Scored(entry: e, score: s, ranges: m.ranges))
        }
        highlight = [:]
        for s in scored { highlight[s.entry.id] = s.ranges }
        let order: [Kind] = [.session, .project, .action, .pane, .task, .folder]
        let caps: [Kind: Int] = filter == .all
            ? [.session: 10, .project: 8, .action: 8, .pane: 6, .task: 6, .folder: 8]
            : [:]
        var sections: [(best: Int, index: Int, section: Section)] = []
        for (i, kind) in order.enumerated() {
            let group = scored.filter { $0.entry.kind == kind }
                .sorted { a, b in
                    if a.score != b.score { return a.score > b.score }
                    return (a.entry.recency ?? .distantPast) > (b.entry.recency ?? .distantPast)
                }
            guard let best = group.first?.score else { continue }
            let cut = Array(group.prefix(caps[kind] ?? 60))
            sections.append((best, i, Section(title: Self.sectionTitle(kind, total: group.count, shown: cut.count), entries: cut.map(\.entry))))
        }
        sections.sort { $0.best == $1.best ? $0.index < $1.index : $0.best > $1.best }
        rows = flatten(sections.map(\.section))
        let n = scored.count
        status.stringValue = n == 0 ? "" : "\(n) Treffer" + (filter == .all ? "" : " · \(filter.label)")
        if rows.isEmpty {
            rows = [.header("Keine Treffer für „\(query)“ — Projektname, Sessiontitel, letzter Prompt oder „codex reisen“")]
        }
    }

    private static func sectionTitle(_ k: Kind, total: Int, shown: Int) -> String {
        let name: String
        switch k {
        case .session: name = "Sessions"; case .project: name = "Projekte"; case .folder: name = "Ordner"
        case .action: name = "Aktionen"; case .pane: name = "Kacheln"; case .task: name = "Aufgaben"
        default: name = "Treffer"
        }
        return total > shown ? "\(name) · \(shown) von \(total)" : name
    }

    private func flatten(_ sections: [Section]) -> [Row] {
        var out: [Row] = []
        for s in sections where !s.entries.isEmpty {
            out.append(.header(s.title))
            out += s.entries.map(Row.entry)
        }
        return out
    }

    private func updatePrompt() {
        status.stringValue = "OpenAI · Codex-Kontingent"
        status.toolTip = "Enter schickt den Prompt an das Launcher-Modell (Codex-Login). Je nach Auftrag gehen die Projektliste oder bis zu 48 Gesprächsausschnitte aus den 160 jüngsten Launcher-Sessions mit. Neue Kacheln brauchen eine weitere Startbestätigung."
        if let r = aiResults {
            var sections: [Section] = []
            let hits = r.entries.filter { $0.kind == .session }
            let launches = r.entries.filter { $0.kind == .launch }
            let answers = r.entries.filter { $0.kind == .answer }
            if !answers.isEmpty { sections.append(Section(title: "Antwort", entries: answers)) }
            if !launches.isEmpty { sections.append(Section(title: "Start prüfen", entries: launches)) }
            if !hits.isEmpty { sections.append(Section(title: "Gefundene Sessions · mit Beleg", entries: hits)) }
            rows = flatten(sections)
            if rows.isEmpty { rows = [.header(r.message.isEmpty ? "Keine Vorschläge" : r.message)] }
            return
        }
        if aiStarted != nil {
            rows = [.entry(Entry(id: "ai:status", kind: .status, title: "KI prüft deine Anfrage …", subtitle: "Keine Kachel startet von selbst", primaryHint: "Esc bricht ab", closesPalette: false))]
            return
        }
        let examples: [(String, String)] = [
            ("finde die Session, in der wir den Kalender-Sync gebaut haben", "Sucht in Titeln und Gesprächsausschnitten, Treffer mit Beleg"),
            ("starte Claude in claude-werkstatt: Launcher-Tests grün machen", "Startvorschau mit Ziel, Befehl und Prompt — du bestätigst"),
            ("team: Claude schlägt vor, Codex prüft — Widget-Timeline", "Zwei Kacheln mit lesenden Briefings"),
            ("was war zuletzt in der Werkstatt offen?", "Freie Antwort aus den jüngsten Sessions")
        ]
        let hint = examples.map { ex in
            Entry(id: "ex:" + ex.0, kind: .hint, title: ex.0, subtitle: ex.1, primaryHint: "⏎ Übernehmen", closesPalette: false) { [weak self] in
                self?.field.stringValue = "/" + ex.0; self?.focus(); self?.update()
            }
        }
        let typed = LauncherSearch.prompt(field.stringValue) ?? ""
        if typed.isEmpty {
            rows = flatten([Section(title: "Beispiele — ⏎ übernimmt, dann anpassen", entries: hint)])
        } else {
            rows = [.header("⏎ sendet · Finden, Starten, Team oder freie Frage — die KI ordnet selbst ein")]
        }
    }

    @objc private func askAI() {
        guard let prompt = LauncherSearch.prompt(field.stringValue), !prompt.isEmpty, cancelAI == nil, let onAI else { return }
        generation += 1; let token = generation
        aiResults = nil; aiStarted = Date()
        aiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickAI() }
        update()
        cancelAI = onAI("auto", prompt) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.cancelAI = nil
            self.aiTimer?.invalidate(); self.aiTimer = nil; self.aiStarted = nil
            switch result {
            case .success(let r): self.aiResults = r
            case .failure(let error):
                let msg = (error as? LoaderError)?.message ?? error.localizedDescription
                self.aiResults = AIResults(entries: [], message: msg)
            }
            self.update()
            self.status.stringValue = self.aiResults?.message.isEmpty == false ? String(self.aiResults!.message.prefix(80)) : "Antwort bereit"
            self.status.toolTip = self.aiResults?.message
        }
    }
    private func tickAI() {
        guard let started = aiStarted else { return }
        status.stringValue = "KI denkt · \(Int(Date().timeIntervalSince(started))) s"
    }

    // MARK: Filter

    @objc private func chipClicked(_ sender: NSButton) { setFilter(Filter.allCases[sender.tag]) }
    private func cycleFilter(_ delta: Int) {
        guard !isPrompt else { return }
        let all = Filter.allCases
        let i = all.firstIndex(of: filter)!
        setFilter(all[(i + delta + all.count) % all.count])
    }
    private func setFilter(_ f: Filter) {
        filter = f; styleChips(); update(); focus()
    }
    private func styleChips() {
        for (i, b) in chipButtons.enumerated() {
            let on = Filter.allCases[i] == filter
            let color = on ? theme.background : theme.dim
            b.attributedTitle = NSAttributedString(string: Filter.allCases[i].label, attributes: [.foregroundColor: color, .font: AppFonts.mono(size: 11, weight: on ? .semibold : .medium)])
            b.layer?.backgroundColor = on ? HomePaneView.cyan.withAlphaComponent(0.85).cgColor : theme.foreground.withAlphaComponent(0.05).cgColor
        }
    }

    // MARK: Auswahl & Aktionen

    private var highlight: [String: [NSRange]] = [:]

    private func firstEntryRow(from start: Int, step: Int) -> Int? {
        var i = start
        while rows.indices.contains(i) { if rows[i].entry != nil { return i }; i += step }
        return nil
    }
    private func move(_ delta: Int) {
        let entryRows = rows.indices.filter { rows[$0].entry != nil }
        guard !entryRows.isEmpty else { return }
        let pos = entryRows.firstIndex(of: table.selectedRow) ?? (delta > 0 ? -1 : entryRows.count)
        let next = max(0, min(entryRows.count - 1, pos + delta))
        selectRow(entryRows[next])
    }
    private func selectRow(_ row: Int?) {
        guard let row, rows.indices.contains(row) else {
            table.deselectAll(nil); updateHints(nil); return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateHints(rows[row].entry)
    }
    private func hover(_ row: Int) {
        guard rows.indices.contains(row), rows[row].entry != nil, row != table.selectedRow else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateHints(rows[row].entry)
    }
    private func updateHints(_ e: Entry?) {
        guard let e else {
            hints.stringValue = isPrompt ? "⏎ senden   Esc zurück" : "↑↓ wählen   ⇥ Filter   / KI fragen   Esc"
            return
        }
        var parts = [e.primaryHint]
        if let s = e.secondaryHint { parts.append("⌘⏎ " + s) }
        if e.copyText != nil { parts.append("⌘C " + (e.kind == .session ? "ID" : (e.kind == .answer ? "Text" : "Pfad"))) }
        if !isPrompt { parts.append("⇥ Filter") }
        hints.stringValue = parts.joined(separator: "   ")
    }
    @objc private func rowClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), rows[row].entry != nil else { return }
        selectRow(row); choose()
    }
    private var selected: Entry? {
        let row = table.selectedRow
        return rows.indices.contains(row) ? rows[row].entry : nil
    }
    @objc private func choose() {
        guard let e = selected else { return }
        if e.kind == .answer, let body = e.body {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(body, forType: .string)
            toast("Antwort kopiert"); return
        }
        if e.kind == .status { return }
        Self.remember(e.id)
        if e.closesPalette { stopAI(); onClose?() }
        e.action()
    }
    private func chooseSecondary() {
        guard let e = selected, let run = e.secondary else { NSSound.beep(); return }
        Self.remember(e.id)
        stopAI(); onClose?()
        run()
    }
    private func copySelected() {
        guard let e = selected, let text = e.copyText ?? e.body else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        toast("Kopiert: " + String(text.prefix(40)))
    }
    private func toast(_ text: String) {
        let keep = hints.stringValue
        hints.stringValue = text
        hints.textColor = HomePaneView.cyan
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hints.textColor = self.theme.dim
            self.hints.stringValue = keep
        }
    }

    /// Zuletzt gewählte Einträge (ID → Zeitpunkt) — heben sich beim nächsten Suchen an. 40 Stück reichen.
    private static func recentUses() -> [String: Date] {
        (UserDefaults.standard.dictionary(forKey: recentKey) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
    }
    private static func remember(_ id: String) {
        guard !id.hasPrefix("ai:"), !id.hasPrefix("ex:") else { return }
        var d = UserDefaults.standard.dictionary(forKey: recentKey) as? [String: Double] ?? [:]
        d[id] = Date().timeIntervalSince1970
        if d.count > 40 { for k in d.sorted(by: { $0.value < $1.value }).prefix(d.count - 40).map(\.key) { d[k] = nil } }
        UserDefaults.standard.set(d, forKey: recentKey)
    }

    // MARK: Tabelle

    private func height(of row: Row) -> CGFloat {
        switch row {
        case .header: return 30
        case .entry(let e):
            switch e.kind {
            case .answer:
                let width = max(200, scroll.bounds.width - 40)
                let h = (e.body ?? "").boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                     attributes: [.font: AppFonts.mono(size: 13)]).height
                return min(360, max(60, ceil(h) + 28))
            case .status: return 60
            default: return e.subtitle.count > 72 || e.subtitle.contains("\n") ? 66 : 52
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(of: rows[row]) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].entry != nil }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = PaletteRow()
        v.tint = rows[row].entry?.accent ?? (rows[row].entry?.kind == .launch ? HomePaneView.orange : HomePaneView.cyan)
        return v
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let t): return PaletteHeaderCell(title: t, theme: theme)
        case .entry(let e):
            switch e.kind {
            case .answer: return PaletteAnswerCell(text: e.body ?? "", theme: theme)
            case .status: return PaletteStatusCell(entry: e, theme: theme)
            default: return PaletteEntryCell(entry: e, ranges: highlight[e.id] ?? [], theme: theme)
            }
        }
    }
}

// MARK: - Tabelle mit Hover

/// Bewegt sich die Maus über eine Zeile, wandert die Auswahl mit (Pfeiltasten bleiben unberührt).
final class PaletteTable: NSTableView {
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover?(row) }
    }
    override var acceptsFirstResponder: Bool { false }   // Fokus bleibt im Suchfeld
}

private final class PaletteRow: NSTableRowView {
    var tint: NSColor = HomePaneView.cyan
    override func drawBackground(in dirtyRect: NSRect) {}
    override func drawSelection(in dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 10, yRadius: 10)
        tint.withAlphaComponent(0.12).setFill(); path.fill()
        // Akzentbalken links — die Projektfarbe der Kachel, die gleich aufgeht.
        let bar = NSBezierPath(roundedRect: NSRect(x: 6, y: bounds.midY - 10, width: 3, height: 20), xRadius: 1.5, yRadius: 1.5)
        tint.setFill(); bar.fill()
    }
}

private final class PaletteHeaderCell: NSView {
    init(title: String, theme: TerminalTheme) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = AppFonts.mono(size: 10, weight: .semibold)
        label.textColor = theme.faint
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class PaletteEntryCell: NSView {
    init(entry e: LauncherPalette.Entry, ranges: [NSRange], theme: TerminalTheme) {
        super.init(frame: .zero)
        let symbol: String
        switch e.kind {
        case .session: symbol = e.agent == "codex" ? "chevron.left.forwardslash.chevron.right" : "bubble.left.and.text.bubble.right"
        case .project: symbol = "folder.fill"
        case .folder: symbol = "folder"
        case .action: symbol = "bolt.fill"
        case .pane: symbol = "rectangle.on.rectangle"
        case .task: symbol = "checklist"
        case .hint: symbol = "text.quote"
        case .launch: symbol = "play.fill"
        default: symbol = "circle"
        }
        let tint: NSColor
        switch (e.kind, e.agent) {
        case (.session, "codex"): tint = HomePaneView.cyan
        case (.session, _): tint = HomePaneView.orange
        case (.launch, _): tint = HomePaneView.orange
        case (.task, _): tint = e.badge?.color ?? HomePaneView.yellow
        case (.pane, _): tint = e.badge?.color ?? HomePaneView.green
        case (.project, _), (.folder, _): tint = e.accent ?? theme.dim
        default: tint = theme.dim
        }
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = tint.withAlphaComponent(0.13).cgColor
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = tint

        let title = NSTextField(labelWithString: "")
        let attributed = NSMutableAttributedString(string: e.title, attributes: [.font: AppFonts.mono(size: 14.5, weight: .medium), .foregroundColor: theme.foreground])
        for r in ranges where r.location + r.length <= attributed.length {
            attributed.addAttributes([.foregroundColor: HomePaneView.cyan, .font: AppFonts.mono(size: 14.5, weight: .bold)], range: r)
        }
        if e.pinned { attributed.append(NSAttributedString(string: "  ★", attributes: [.font: AppFonts.mono(size: 11), .foregroundColor: HomePaneView.yellow])) }
        title.attributedStringValue = attributed
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: e.subtitle)
        subtitle.font = AppFonts.mono(size: 11.5)
        subtitle.textColor = theme.dim
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 2
        for f in [title, subtitle] { f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }

        let badge = NSTextField(labelWithString: e.badge?.text ?? "")
        badge.font = AppFonts.mono(size: 10.5, weight: .medium)
        badge.textColor = e.badge?.color ?? theme.faint
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = (e.badge?.color ?? theme.faint).withAlphaComponent(0.12).cgColor
        badge.alignment = .center
        badge.isHidden = e.badge == nil
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        for v in [box, icon, title, subtitle, badge] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(box); addSubview(icon); addSubview(title); addSubview(subtitle); addSubview(badge)
        let twoLine = e.subtitle.count > 72 || e.subtitle.contains("\n")
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 30), box.heightAnchor.constraint(equalToConstant: 30),
            icon.centerXAnchor.constraint(equalTo: box.centerXAnchor), icon.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: twoLine ? 8 : 9),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 20),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 28)
        ])
        // Pillenpolster: 6 pt links/rechts über das Textmaß hinaus.
        if e.badge != nil {
            let w = (e.badge!.text as NSString).size(withAttributes: [.font: badge.font!]).width + 14
            badge.widthAnchor.constraint(equalToConstant: ceil(w)).isActive = true
        }
        toolTip = e.subtitle.isEmpty ? e.title : e.title + "\n" + e.subtitle
        setAccessibilityLabel(e.title + (e.subtitle.isEmpty ? "" : ", " + e.subtitle))
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class PaletteAnswerCell: NSView {
    init(text: String, theme: TerminalTheme) {
        super.init(frame: .zero)
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = HomePaneView.orange.withAlphaComponent(0.06).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = HomePaneView.orange.withAlphaComponent(0.25).cgColor
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = AppFonts.mono(size: 13)
        label.textColor = theme.foreground
        label.isSelectable = false
        for v in [box, label] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 4), box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12), label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.bottomAnchor.constraint(lessThanOrEqualTo: box.bottomAnchor, constant: -10)
        ])
        toolTip = "⏎ oder ⌘C kopiert die Antwort — keine automatische Faktenprüfung."
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class PaletteStatusCell: NSView {
    init(entry e: LauncherPalette.Entry, theme: TerminalTheme) {
        super.init(frame: .zero)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let title = NSTextField(labelWithString: e.title)
        title.font = AppFonts.mono(size: 14, weight: .medium)
        title.textColor = theme.foreground
        let sub = NSTextField(labelWithString: e.subtitle)
        sub.font = AppFonts.mono(size: 11.5)
        sub.textColor = theme.dim
        for v in [spinner, title, sub] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
