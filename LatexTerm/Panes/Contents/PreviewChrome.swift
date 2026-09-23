import AppKit
import PDFKit

// Bedienteile der Vorschau-Kachel: Werkzeugleiste (erscheint beim Überfahren), Markier-Leiste (Stellen an die
// Session), Seitenleiste (Miniaturen/Inhalt), Pille, Such-/Gehe-zu-Leiste. Alle Farben aus dem Theme.
// Stil „Linie“ (23.09.2026, UI-Inventar B4/B5): schwebende Leisten stehen auf dem Schwebe-Grund (`LineStyle.applyGround`,
// die einzige erlaubte Fläche — über fremdem Inhalt nötig), ohne Rand; Knöpfe randlos mit Hover-Fläche, aktiv = Strich.

/// Knopf mit SF Symbol oder Text, Theme-Tönung, Closure statt Target/Action. Hover = leise Fläche, aktiv = Strich unten.
final class PreviewButton: NSButton {
    private let handler: () -> Void
    private let underline = CALayer()
    var active = false { didSet { underline.isHidden = !active; needsLayout = true } }
    private var hovered = false { didSet { layer?.backgroundColor = hovered ? LineStyle.fg.withAlphaComponent(LineStyle.hover).cgColor : nil } }

    init(symbol: String?, title: String = "", tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        self.title = title
        font = LineStyle.font(11.5)
        toolTip = tooltip
        target = self
        action = #selector(run)
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = LineStyle.hoverRadius
        underline.cornerRadius = 1
        underline.isHidden = true
        layer?.addSublayer(underline)
    }

    override func layout() {
        super.layout()
        underline.frame = CGRect(x: LineStyle.underlineInset, y: 0, width: bounds.width - LineStyle.underlineInset * 2, height: LineStyle.underline)
        underline.backgroundColor = ThemeStore.shared.accentColor.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var tintColor: NSColor?
    private var retinting = false

    func tint(_ color: NSColor) {
        tintColor = color
        contentTintColor = color
        retinting = true
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: font as Any])
        retinting = false
    }

    /// Titelwechsel (z. B. kurz „✓“) behält die Tönung.
    override var title: String {
        didSet { if !retinting, let tintColor { tint(tintColor) } }
    }

    var width: CGFloat {
        guard !title.isEmpty else { return 26 }
        return ceil(attributedTitle.size().width) + (image == nil ? 14 : 30)
    }

    @objc private func run() { handler() }
}

/// Schwebende Leiste oben links: erscheint, sobald die Maus in der Kachel ist, und blendet nach Ruhe aus.
final class PreviewToolbar: NSView {
    struct Item {
        var id: String
        var symbol: String?
        var title: String = ""
        var tooltip: String
        var active = false
    }

    var onAction: ((String) -> Void)?
    private var buttons: [(Item, PreviewButton)] = []
    private var theme = ThemeStore.shared.theme
    private var hideWork: DispatchWorkItem?
    private(set) var hovered = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        alphaValue = 0
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue < 0.05 ? nil : super.hitTest(point) }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        LineStyle.applyGround(to: self, theme: theme)
        tintButtons()
    }

    /// Knöpfe neu setzen (nur wenn sich etwas geändert hat — sonst flackert nichts).
    func setItems(_ items: [Item]) {
        let same = items.count == buttons.count && zip(items, buttons).allSatisfy {
            $0.id == $1.0.id && $0.title == $1.0.title && $0.active == $1.0.active && $0.symbol == $1.0.symbol
        }
        guard !same else { return }
        buttons.forEach { $0.1.removeFromSuperview() }
        buttons = items.map { item in
            let button = PreviewButton(symbol: item.symbol, title: item.title, tooltip: item.tooltip) { [weak self] in
                self?.onAction?(item.id)
            }
            addSubview(button)
            return (item, button)
        }
        tintButtons()
        if let superview { layoutIn(superview.bounds) }
    }

    private func tintButtons() {
        for (item, button) in buttons {
            button.tint(item.active ? ThemeStore.shared.accentColor : theme.foreground.withAlphaComponent(0.8))
            button.active = item.active
        }
    }

    func layoutIn(_ bounds: NSRect, left: CGFloat = 10) {
        var x: CGFloat = 4
        for (_, button) in buttons {
            button.frame = NSRect(x: x, y: 3, width: button.width, height: LineStyle.tabHeight)
            x += button.width + 2
        }
        frame = NSRect(x: left, y: bounds.height - 40, width: x + 3, height: 30)
    }

    /// Maus bewegt sich in der Kachel: zeigen, nach 2,5 s Ruhe wieder weg (nicht, solange sie auf der Leiste steht).
    func poke() {
        guard !buttons.isEmpty else { return }
        hideWork?.cancel()
        if alphaValue < 1 { NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 } }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.hovered else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; self.animator().alphaValue = 0 }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func hideNow() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; animator().alphaValue = 0 }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; poke() }
    override func mouseExited(with event: NSEvent) { hovered = false; poke() }
}

/// Leiste unten: was markiert ist, Notizfeld, Merken, ➤ Senden; ohne aktuelle Auswahl nur „N gemerkt · ➤ · ×“.
final class PreviewMarkBar: NSView, NSTextFieldDelegate {
    let note = NSTextField()
    private let label = NSTextField(labelWithString: "")
    private let dot = LineDotView()
    /// Eingabefeld im Stil „Linie“: nur ein Strich unten statt Rahmen.
    private let noteLine = NSView()
    private let keep: PreviewButton
    private let send: PreviewButton
    private let clear: PreviewButton
    private var hasSelection = false
    private var count = 0
    var onKeep: ((String) -> Void)?
    var onSend: ((String) -> Void)?
    var onDiscard: (() -> Void)?
    var onClear: (() -> Void)?

    override init(frame: NSRect) {
        var keepAction: () -> Void = {}
        var sendAction: () -> Void = {}
        var clearAction: () -> Void = {}
        keep = PreviewButton(symbol: "plus", title: "Merken", tooltip: "Stelle mit Notiz merken (⏎) — mehrere sammeln, dann zusammen senden") { keepAction() }
        send = PreviewButton(symbol: "paperplane.fill", title: "Senden", tooltip: "An die Claude-/Codex-Kachel (⇧⌘⏎, mit ⌥: Kachel wählen)") { sendAction() }
        clear = PreviewButton(symbol: "xmark", tooltip: "Gemerkte Stellen verwerfen") { clearAction() }
        super.init(frame: frame)
        keepAction = { [weak self] in self.map { $0.onKeep?($0.note.stringValue) } }
        sendAction = { [weak self] in self.map { $0.onSend?($0.note.stringValue) } }
        clearAction = { [weak self] in self?.onClear?() }
        wantsLayer = true
        label.font = LineStyle.font(11.5)
        label.lineBreakMode = .byTruncatingTail
        note.placeholderString = "Notiz, z. B. „kürzen“ (optional)"
        note.font = LineStyle.font(12, .regular)
        note.focusRingType = .none
        note.isBordered = false
        note.drawsBackground = false
        note.delegate = self
        noteLine.wantsLayer = true
        for view in [dot, label, noteLine, note, keep, send, clear] as [NSView] { addSubview(view) }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        LineStyle.applyGround(to: self, theme: theme)
        label.textColor = theme.foreground.withAlphaComponent(0.8)
        dot.color = ThemeStore.shared.accentColor
        noteLine.layer?.backgroundColor = theme.foreground.withAlphaComponent(LineStyle.faint).cgColor
        keep.tint(theme.foreground.withAlphaComponent(0.8))
        send.tint(ThemeStore.shared.accentColor)
        send.active = true
        clear.tint(theme.dim)
    }

    /// `selection` = Beschreibung der aktuellen Auswahl (nil = keine), `count` = gemerkte Stellen.
    func update(selection: String?, count: Int) {
        hasSelection = selection != nil
        self.count = count
        if let selection {
            label.stringValue = selection
        } else {
            label.stringValue = count == 1 ? "1 Stelle gemerkt" : "\(count) Stellen gemerkt"
            note.stringValue = ""
        }
        note.isHidden = !hasSelection
        noteLine.isHidden = !hasSelection
        keep.isHidden = !hasSelection
        clear.isHidden = count == 0
        send.title = count > 0 && hasSelection ? "Senden (\(count + 1))" : count > 1 ? "Senden (\(count))" : "Senden"
        send.tint(ThemeStore.shared.accentColor)
        isHidden = !hasSelection && count == 0
        if let superview { layoutIn(superview.bounds) }
    }

    func layoutIn(_ bounds: NSRect) {
        let width = min(hasSelection ? 640 : 330, bounds.width - 24)
        frame = NSRect(x: (bounds.width - width) / 2, y: 44, width: width, height: 36)
        var right = width - 6
        for button in [clear, send, keep] where !button.isHidden {
            right -= button.width
            button.frame = NSRect(x: right, y: 6, width: button.width, height: LineStyle.tabHeight)
            right -= 4
        }
        dot.frame = NSRect(x: 12, y: (36 - LineStyle.dotSize) / 2, width: LineStyle.dotSize, height: LineStyle.dotSize)
        let textX = dot.frame.maxX + 8
        if hasSelection {
            let labelWidth = max(80, min(220, (right - textX) * 0.42))
            label.frame = NSRect(x: textX, y: 10, width: labelWidth, height: 16)
            note.frame = NSRect(x: textX + labelWidth + 10, y: 9, width: max(60, right - textX - labelWidth - 20), height: 18)
            noteLine.frame = NSRect(x: note.frame.minX, y: 7, width: note.frame.width, height: 1)
        } else {
            label.frame = NSRect(x: textX, y: 10, width: max(40, right - textX - 4), height: 16)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onSend?(note.stringValue) } else { onKeep?(note.stringValue) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onDiscard?()
            return true
        default:
            return false
        }
    }
}

/// Seitenleiste links: Miniaturen (PDFThumbnailView) oder Inhaltsverzeichnis (PDFOutline).
final class PreviewSidebar: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    enum Mode: String { case thumbs, toc }

    static let width: CGFloat = 196
    let thumbs = PDFThumbnailView()
    private let tabs = LineTabsView(titles: ["Seiten", "Inhalt"])
    private let outlineScroll = NSScrollView()
    private let outline = NSOutlineView()
    private let empty = NSTextField(labelWithString: "Kein Inhaltsverzeichnis im PDF")
    private var root: PDFOutline?
    private var theme = ThemeStore.shared.theme
    private(set) var mode: Mode = .thumbs
    var onMode: ((Mode) -> Void)?
    var onJump: ((PDFOutline) -> Void)?
    private var syncing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        tabs.onChange = { [weak self] _ in self?.tabChanged() }
        tabs.selectedSegment = 0
        thumbs.thumbnailSize = NSSize(width: 132, height: 172)
        thumbs.maximumNumberOfColumns = 1
        let column = NSTableColumn(identifier: .init("title"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.rowSizeStyle = .small
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 12
        outline.target = self
        outline.action = #selector(rowClicked)
        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.autohidesScrollers = true
        outlineScroll.drawsBackground = false
        empty.alignment = .center
        empty.font = LineStyle.font(11.5, .regular)
        for view in [tabs, thumbs, outlineScroll, empty] as [NSView] { addSubview(view) }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.background.lightened(by: 0.035).withAlphaComponent(1).cgColor
        thumbs.backgroundColor = theme.background.lightened(by: 0.035).withAlphaComponent(1)
        empty.textColor = theme.dim
        outline.reloadData()
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        tabs.selectedSegment = mode == .thumbs ? 0 : 1
        thumbs.isHidden = mode != .thumbs
        outlineScroll.isHidden = mode != .toc
        empty.isHidden = mode != .toc || (root?.numberOfChildren ?? 0) > 0
    }

    func setDocument(_ document: PDFDocument?, pdfView: PDFView) {
        thumbs.pdfView = pdfView
        root = document?.outlineRoot
        outline.reloadData()
        if let root, root.numberOfChildren <= 8 { for i in 0..<root.numberOfChildren { outline.expandItem(root.child(at: i)) } }
        setMode(mode)
    }

    /// Den Abschnitt markieren, in dem `pageIndex` liegt (letzter Eintrag mit Zielseite ≤ Seite).
    func follow(pageIndex: Int, in document: PDFDocument) {
        guard mode == .toc, let root else { return }
        var best: PDFOutline?
        func walk(_ node: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let page = child.destination?.page, document.index(for: page) <= pageIndex { best = child }
                if child.isOpen || outline.isItemExpanded(child) { walk(child) }
            }
        }
        walk(root)
        guard let best else { return }
        let row = outline.row(forItem: best)
        guard row >= 0, outline.selectedRow != row else { return }
        syncing = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        syncing = false
    }

    override func layout() {
        super.layout()
        let tabSize = tabs.intrinsicContentSize
        tabs.frame = NSRect(x: (bounds.width - tabSize.width) / 2, y: bounds.height - tabSize.height - 8,
                            width: tabSize.width, height: tabSize.height)
        let content = NSRect(x: 0, y: 0, width: bounds.width, height: tabs.frame.minY - 8)
        thumbs.frame = content
        outlineScroll.frame = content.insetBy(dx: 4, dy: 0)
        empty.frame = NSRect(x: 8, y: content.midY - 10, width: bounds.width - 16, height: 20)
    }

    private func tabChanged() {
        let mode: Mode = tabs.selectedSegment == 0 ? .thumbs : .toc
        setMode(mode)
        onMode?(mode)
    }

    @objc private func rowClicked() {
        guard let item = outline.item(atRow: outline.clickedRow) as? PDFOutline else { return }
        onJump?(item)
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? root)?.numberOfChildren ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? root)!.child(at: index)!
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = outlineView.makeView(withIdentifier: .init("cell"), owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = .init("cell")
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text
            text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                         text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                                         text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }()
        let node = item as? PDFOutline
        cell.textField?.stringValue = node?.label ?? ""
        cell.textField?.font = LineStyle.font(11.5, outlineView.level(forItem: item) == 0 ? .medium : .regular)
        cell.textField?.textColor = theme.foreground.withAlphaComponent(outlineView.level(forItem: item) == 0 ? 0.95 : 0.75)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { LineRowView() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let item = outline.item(atRow: outline.selectedRow) as? PDFOutline,
              NSApp.currentEvent?.type == .keyDown else { return }
        onJump?(item)
    }
}

/// Kurz eingeblendeter Hinweis unten mittig (LineToast): Punkt in Tonfarbe · Text auf dem Schwebe-Grund.
/// Seite, Zoom, „neu geladen“, Download, Fehler (⚠ → rot).
final class PreviewPill: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dot = LineDotView()
    private var fadeWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        label.font = LineStyle.font(11.5)
        label.alignment = .left
        addSubview(dot)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTheme(_ theme: TerminalTheme) {
        LineStyle.applyGround(to: self, theme: theme)
        label.textColor = theme.foreground.withAlphaComponent(LineStyle.textFocused)
    }

    func flash(_ text: String, hold: TimeInterval = 1.3) {
        label.stringValue = text
        dot.color = LineToast.tone(for: text)
        if let superview { layoutIn(superview.bounds) }
        fadeWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.animator().alphaValue = 0 }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
    }

    func layoutIn(_ bounds: NSRect, left: CGFloat = 0) {
        let size = label.intrinsicContentSize
        let area = bounds.width - left
        let width = min(size.width + 36, area - 24)
        // Unten mittig — auch in gekippten Eltern (Scratchpad ist `isFlipped`).
        let y: CGFloat = superview?.isFlipped == true ? bounds.height - 36 : 12
        frame = NSRect(x: left + (area - width) / 2, y: y, width: width, height: 24)
        dot.frame = NSRect(x: 10, y: (24 - LineStyle.dotSize) / 2, width: LineStyle.dotSize, height: LineStyle.dotSize)
        label.frame = NSRect(x: 22, y: (24 - size.height) / 2, width: width - 32, height: size.height)
    }
}

/// Eingabeleiste oben rechts: Suche (⌘F: ⏎ nächster, ⇧⏎ voriger Treffer) oder Gehe-zu-Seite (⌘L). Esc schließt.
final class PreviewFindBar: NSView, NSTextFieldDelegate {
    /// Feld ohne Rahmen, nur Strich unten (Stil „Linie“); davor das Lupen-Zeichen.
    let field = NSTextField()
    private let glyph = NSTextField(labelWithString: "⌕")
    private let fieldLine = NSView()
    private let count = NSTextField(labelWithString: "")
    /// Schalter rechts im Feld (Terminal: Aa, .*, Wort) — aktiv = Akzent + Strich.
    private var toggles: [PreviewButton] = []
    var onSearch: ((String, Bool) -> Void)?
    /// Beim Tippen (Terminal sucht live); nil = erst mit ⏎.
    var onChange: ((String) -> Void)?
    var onClose: (() -> Void)?
    var isVisible: Bool { !isHidden }

    init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true
        field.placeholderString = placeholder
        field.delegate = self
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.font = LineStyle.font(12, .regular)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        glyph.font = LineStyle.font(13, .regular)
        fieldLine.wantsLayer = true
        count.font = LineStyle.font(11, .regular)
        count.alignment = .right
        addSubview(glyph)
        addSubview(fieldLine)
        addSubview(field)
        addSubview(count)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        LineStyle.applyGround(to: self, theme: theme)
        count.textColor = theme.dim
        glyph.textColor = theme.dim
        fieldLine.layer?.backgroundColor = ThemeStore.shared.accentColor.cgColor
    }

    func show(text: String) {
        isHidden = false
        if !text.isEmpty { field.stringValue = text }
        if let superview { layoutIn(superview.bounds) }
    }

    func hide() {
        isHidden = true
        count.stringValue = ""
    }

    func setCount(_ text: String) { count.stringValue = text }

    /// Schalter hinzufügen (Stil „Linie“: Text, aktiv = Akzent + Strich).
    func addToggle(_ title: String, tooltip: String, onChange: @escaping (Bool) -> Void) {
        var button: PreviewButton!
        button = PreviewButton(symbol: nil, title: title, tooltip: tooltip) { [weak self] in
            button.active.toggle()
            button.tint(button.active ? ThemeStore.shared.accentColor : ThemeStore.shared.theme.dim)
            onChange(button.active)
            self?.window?.makeFirstResponder(self?.field)
        }
        button.tint(ThemeStore.shared.theme.dim)
        toggles.append(button)
        addSubview(button)
    }

    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    func layoutIn(_ bounds: NSRect) {
        let togglesWidth = toggles.reduce(0) { $0 + $1.width + 2 }
        let width = min(300 + togglesWidth, bounds.width - 20)
        // Oben rechts — auch in gekippten Eltern.
        let y: CGFloat = superview?.isFlipped == true ? 10 : bounds.height - 42
        frame = NSRect(x: bounds.width - width - 10, y: y, width: width, height: 32)
        count.frame = NSRect(x: width - 84, y: 8, width: 76, height: 16)
        var right = count.frame.minX - 4
        for button in toggles.reversed() {
            right -= button.width
            button.frame = NSRect(x: right, y: 4, width: button.width, height: LineStyle.tabHeight)
            right -= 2
        }
        glyph.frame = NSRect(x: 10, y: 7, width: 14, height: 18)
        field.frame = NSRect(x: 28, y: 8, width: max(40, right - 36), height: 17)
        fieldLine.frame = NSRect(x: 28, y: 6, width: field.frame.width, height: LineStyle.underline)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSearch?(field.stringValue, NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
