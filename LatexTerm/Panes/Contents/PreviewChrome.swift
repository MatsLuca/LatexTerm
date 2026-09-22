import AppKit
import PDFKit

// Bedienteile der Vorschau-Kachel: Werkzeugleiste (erscheint beim Überfahren), Markier-Leiste (Stellen an die
// Session), Seitenleiste (Miniaturen/Inhalt), Pille, Such-/Gehe-zu-Leiste. Alle Farben aus dem Theme.

/// Knopf mit SF Symbol oder Text, Theme-Tönung, Closure statt Target/Action.
final class PreviewButton: NSButton {
    private let handler: () -> Void

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
        font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        toolTip = tooltip
        target = self
        action = #selector(run)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func tint(_ color: NSColor) {
        contentTintColor = color
        attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: font as Any])
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
        layer?.backgroundColor = theme.keyHelpBackground.cgColor
        layer?.borderColor = theme.faint.cgColor
        layer?.borderWidth = 0.5
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
        for (item, button) in buttons { button.tint(item.active ? ThemeStore.shared.accentColor : theme.foreground.withAlphaComponent(0.85)) }
    }

    func layoutIn(_ bounds: NSRect, left: CGFloat = 10) {
        var x: CGFloat = 4
        for (_, button) in buttons {
            button.frame = NSRect(x: x, y: 2, width: button.width, height: 26)
            x += button.width + 1
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
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11.5)
        label.lineBreakMode = .byTruncatingTail
        note.placeholderString = "Notiz, z. B. „kürzen“ (optional)"
        note.font = .systemFont(ofSize: 12)
        note.focusRingType = .none
        note.bezelStyle = .roundedBezel
        note.delegate = self
        for view in [label, note, keep, send, clear] as [NSView] { addSubview(view) }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        layer?.backgroundColor = theme.keyHelpBackground.cgColor
        layer?.borderColor = ThemeStore.shared.accentColor.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1
        label.textColor = theme.foreground.withAlphaComponent(0.8)
        keep.tint(theme.foreground)
        send.tint(ThemeStore.shared.accentColor)
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
            button.frame = NSRect(x: right, y: 5, width: button.width, height: 26)
            right -= 2
        }
        if hasSelection {
            let labelWidth = max(80, min(220, (right - 12) * 0.42))
            label.frame = NSRect(x: 10, y: 10, width: labelWidth, height: 16)
            note.frame = NSRect(x: 16 + labelWidth, y: 6, width: max(60, right - labelWidth - 22), height: 24)
        } else {
            label.frame = NSRect(x: 12, y: 10, width: max(40, right - 16), height: 16)
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
    private let tabs = NSSegmentedControl(labels: ["Seiten", "Inhalt"], trackingMode: .selectOne, target: nil, action: nil)
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
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.controlSize = .small
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
        empty.font = .systemFont(ofSize: 11.5)
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
        tabs.sizeToFit()
        tabs.frame = NSRect(x: (bounds.width - tabs.frame.width) / 2, y: bounds.height - tabs.frame.height - 10,
                            width: tabs.frame.width, height: tabs.frame.height)
        let content = NSRect(x: 0, y: 0, width: bounds.width, height: tabs.frame.minY - 8)
        thumbs.frame = content
        outlineScroll.frame = content.insetBy(dx: 4, dy: 0)
        empty.frame = NSRect(x: 8, y: content.midY - 10, width: bounds.width - 16, height: 20)
    }

    @objc private func tabChanged() {
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
        cell.textField?.font = .systemFont(ofSize: 11.5, weight: outlineView.level(forItem: item) == 0 ? .medium : .regular)
        cell.textField?.textColor = theme.foreground.withAlphaComponent(outlineView.level(forItem: item) == 0 ? 0.95 : 0.75)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let item = outline.item(atRow: outline.selectedRow) as? PDFOutline,
              NSApp.currentEvent?.type == .keyDown else { return }
        onJump?(item)
    }
}

/// Kurz eingeblendete Pille unten mittig: Seite, Zoom, „neu geladen“.
final class PreviewPill: NSView {
    private let label = NSTextField(labelWithString: "")
    private var fadeWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 11
        alphaValue = 0
        label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func applyTheme(_ theme: TerminalTheme) {
        layer?.backgroundColor = theme.badgeBackground.cgColor
        layer?.borderColor = theme.faint.cgColor
        layer?.borderWidth = 0.5
        label.textColor = theme.foreground
    }

    func flash(_ text: String, hold: TimeInterval = 1.3) {
        label.stringValue = text
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
        let width = min(size.width + 24, area - 24)
        frame = NSRect(x: left + (area - width) / 2, y: 12, width: width, height: 22)
        label.frame = NSRect(x: 12, y: (22 - size.height) / 2, width: width - 24, height: size.height)
    }
}

/// Eingabeleiste oben rechts: Suche (⌘F: ⏎ nächster, ⇧⏎ voriger Treffer) oder Gehe-zu-Seite (⌘L). Esc schließt.
final class PreviewFindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    var isVisible: Bool { !isHidden }

    init(placeholder: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        field.placeholderString = placeholder
        field.sendsWholeSearchString = true
        field.sendsSearchStringImmediately = false
        field.delegate = self
        field.focusRingType = .none
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.alignment = .right
        addSubview(field)
        addSubview(count)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        layer?.backgroundColor = theme.keyHelpBackground.cgColor
        layer?.borderColor = theme.faint.cgColor
        layer?.borderWidth = 0.5
        count.textColor = theme.dim
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

    func layoutIn(_ bounds: NSRect) {
        let width = min(300, bounds.width - 20)
        frame = NSRect(x: bounds.width - width - 10, y: bounds.height - 42, width: width, height: 32)
        count.frame = NSRect(x: width - 84, y: 8, width: 76, height: 16)
        field.frame = NSRect(x: 6, y: 5, width: width - 94, height: 22)
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
