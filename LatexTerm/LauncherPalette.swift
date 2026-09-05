import AppKit

/// One search surface: local by default, slash-prefixed prompts submitted explicitly with Enter.
final class LauncherPalette: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    struct Entry {
        var title: String
        var detail: String
        var keywords: String = ""
        var closesPalette: Bool = true
        var action: () -> Void
    }
    struct AIResults { var entries: [Entry]; var message: String }
    var onAI: ((String, String, @escaping (Result<AIResults, Error>) -> Void) -> (() -> Void))?
    private var isPrompt: Bool { LauncherSearch.prompt(search.stringValue) != nil }
    private var cancelAI: (() -> Void)?
    private var generation = 0
    private var hasAIResults = false
    private let search = LauncherSearchField()
    private let results = HomeTable()
    private let scroll = NSScrollView()
    private let panel = NSView()
    private let heading = NSTextField(labelWithString: "Schnellzugriff")
    private let count = NSTextField(labelWithString: "")
    private let close = NSButton(title: "Esc", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "Keine Treffer\nVersuche einen Projektnamen, Sessiontitel oder „codex“.")
    private let help = NSTextField(labelWithString: "↑↓ auswählen · ⏎ öffnen · Esc zurück")
    private var entries: [Entry]
    private var matches: [Entry] = []
    var onClose: (() -> Void)?

    init(frame: NSRect, entries: [Entry], query: String) {
        self.entries = entries
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = ThemeStore.shared.theme.background.cgColor
        let theme = ThemeStore.shared.theme
        panel.wantsLayer = true
        panel.layer?.backgroundColor = theme.foreground.withAlphaComponent(0.025).cgColor
        panel.layer?.cornerRadius = 16
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = theme.foreground.withAlphaComponent(0.10).cgColor
        heading.font = AppFonts.mono(size: 13, weight: .semibold)
        heading.textColor = theme.dim
        count.font = AppFonts.mono(size: 11)
        count.textColor = theme.faint
        close.bezelStyle = .rounded
        close.font = AppFonts.mono(size: 11)
        close.target = self
        close.action = #selector(dismiss)
        close.setAccessibilityLabel("Suche schließen")
        search.placeholderString = "Suchen oder / KI fragen …"
        search.setAccessibilityLabel("Launcher durchsuchen")
        search.font = AppFonts.mono(size: 17)
        search.controlSize = .large
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.stringValue = query
        results.headerView = nil
        results.backgroundColor = .clear
        results.rowHeight = 68
        results.intercellSpacing = NSSize(width: 0, height: 4)
        results.selectionHighlightStyle = .regular
        results.allowsEmptySelection = false
        results.focusRingType = .none
        results.addTableColumn(NSTableColumn(identifier: .init("result")))
        results.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        results.delegate = self
        results.dataSource = self
        results.target = self
        results.doubleAction = #selector(choose)
        results.onKey = { [weak self] event in
            if event.keyCode == 36 { self?.choose(); return true }
            if event.keyCode == 53 { self?.dismiss(); return true }
            return false
        }
        scroll.documentView = results
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        help.font = AppFonts.mono(size: 11)
        help.textColor = ThemeStore.shared.theme.faint
        help.lineBreakMode = .byTruncatingTail
        empty.font = AppFonts.mono(size: 13)
        empty.textColor = theme.dim
        empty.maximumNumberOfLines = 3
        empty.alignment = .center
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        for v in [heading, count, close, search, scroll, help, empty] { v.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(v) }
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            { let c = panel.widthAnchor.constraint(equalTo: widthAnchor, constant: -36); c.priority = .defaultHigh; return c }(),
            heading.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
            close.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            count.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -12),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: heading.trailingAnchor, constant: 12),
            search.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            search.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            search.heightAnchor.constraint(equalToConstant: 42),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: help.topAnchor, constant: -10),
            help.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            help.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: search.leadingAnchor, constant: 12),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: search.trailingAnchor, constant: -12)
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
    @objc private func dismiss() { stopAI(); onClose?() }
    deinit { cancelAI?() }
    private func stopAI() {
        generation += 1; cancelAI?(); cancelAI = nil
    }
    @objc private func askAI() {
        guard let prompt = LauncherSearch.prompt(search.stringValue) else { return }
        beginAI("auto", query: prompt)
    }
    private func beginAI(_ requestMode: String, query: String) {
        guard cancelAI == nil, let onAI else { return }
        guard !query.isEmpty else { return }
        generation += 1; let token = generation
        hasAIResults = false
        matches = []; results.reloadData(); empty.isHidden = false
        empty.stringValue = "KI prüft deine Anfrage …\nEsc bricht ab."
        count.stringValue = "Anfrage läuft"
        help.stringValue = "Esc bricht ab · keine Kachel wird automatisch gestartet"
        cancelAI = onAI(requestMode, query) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.cancelAI = nil
            switch result {
            case .success(let response):
                self.hasAIResults = true; self.matches = response.entries
                self.help.stringValue = response.message
                self.help.toolTip = response.message
                self.empty.stringValue = response.message
            case .failure(let error):
                self.matches = []
                self.empty.stringValue = (error as? LoaderError)?.message ?? error.localizedDescription
                self.help.stringValue = "Lokal bleibt verfügbar · KI erneut fragen oder Esc zurück"
            }
            self.empty.isHidden = !self.matches.isEmpty
            self.count.stringValue = "\(self.matches.count) Vorschläge"
            self.results.reloadData()
            if !self.matches.isEmpty { self.results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
    }
    func focus() {
        search.focusForTyping()
    }
    func controlTextDidChange(_ obj: Notification) { stopAI(); hasAIResults = false; update() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch NSStringFromSelector(selector) {
        case "moveDown:": move(1); return true
        case "moveUp:": move(-1); return true
        case "insertNewline:":
            if isPrompt && !hasAIResults { askAI() } else { choose() }
            return true
        case "cancelOperation:": dismiss(); return true
        default: return false
        }
    }
    private func update() {
        heading.stringValue = isPrompt ? "KI · freier Prompt" : "Schnellzugriff"
        if isPrompt {
            matches = []; results.reloadData(); count.stringValue = "⏎ senden"
            empty.isHidden = false
            empty.stringValue = "Was möchtest du tun?\nFragen, wiederfinden, starten oder brainstormen.\nSchreib einfach — Enter schickt deinen Prompt ab."
            help.stringValue = "⏎ an OpenAI senden · Codex-Kontingent · Esc zurück"
            help.toolTip = "Enter bestätigt den KI-Aufruf. Je nach Auftrag werden die Projektliste oder bis zu 48 Gesprächsausschnitte aus den 160 jüngsten Launcher-Sessions mitgesendet. Neue Kacheln brauchen eine weitere Startbestätigung."
            return
        }
        empty.stringValue = "Keine Treffer\nVersuche einen Projektnamen, Sessiontitel oder „codex“."
        matches = entries.enumerated().compactMap { index, entry -> (Int, Int, Entry)? in
            guard let score = LauncherSearch.score(query: search.stringValue, title: entry.title, detail: entry.detail + " " + entry.keywords) else { return nil }
            return (score, index, entry)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.prefix(100).map(\.2)
        results.reloadData()
        if !matches.isEmpty { results.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        empty.isHidden = !matches.isEmpty
        count.stringValue = "\(matches.count) Treffer"
        help.stringValue = "↑↓ auswählen   ⏎ öffnen   / freier KI-Prompt"
        help.toolTip = nil
    }
    private func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        let row = max(0, min(matches.count - 1, results.selectedRow + delta))
        results.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        results.scrollRowToVisible(row)
    }
    @objc private func choose() {
        let row = results.selectedRow
        guard matches.indices.contains(row) else { return }
        let entry = matches[row]
        let action = entry.action
        if entry.closesPalette { stopAI(); onClose?() }
        action()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRow() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        PaletteCell(entry: matches[row])
    }
}

private final class PaletteRow: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        guard !isSelected else { return }
        ThemeStore.shared.theme.foreground.withAlphaComponent(0.025).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        // Selection stays visible while arrows are handled by the search field.
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10)
        HomePaneView.cyan.withAlphaComponent(0.13).setFill(); path.fill()
        HomePaneView.cyan.withAlphaComponent(0.45).setStroke(); path.lineWidth = 1; path.stroke()
    }
}

private final class PaletteCell: NSView {
    init(entry: LauncherPalette.Entry) {
        super.init(frame: .zero)
        let theme = ThemeStore.shared.theme
        let parts = entry.detail.components(separatedBy: " · ")
        let kind = parts.first ?? "Treffer"
        let badge = NSTextField(labelWithString: kind)
        let title = NSTextField(labelWithString: entry.title)
        let detail = NSTextField(labelWithString: parts.dropFirst().joined(separator: " · "))
        let icon = NSImageView()
        let symbol = kind == "Projekt" || kind == "Ordner" ? "folder" : (kind == "Aktion" ? "bolt" : (kind == "Läuft" ? "terminal" : "bubble.left.and.bubble.right"))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: kind)
        icon.contentTintColor = kind == "Codex" ? HomePaneView.cyan : (kind == "Claude" ? HomePaneView.orange : theme.dim)
        title.font = AppFonts.mono(size: 15, weight: .medium)
        title.textColor = theme.foreground
        detail.font = AppFonts.mono(size: 12)
        detail.textColor = theme.dim
        badge.font = AppFonts.mono(size: 10, weight: .medium)
        badge.textColor = icon.contentTintColor
        badge.alignment = .right
        for field in [title, detail] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [icon, title, detail, badge] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -12),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
        toolTip = entry.title + "\n" + entry.detail
        setAccessibilityLabel(entry.title + ", " + entry.detail)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}
