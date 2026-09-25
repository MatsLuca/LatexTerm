import AppKit

/// Was die Chat-Ansicht vom Inhalt braucht (Bilder laden, Anhänge öffnen, Links).
protocol MyzelTimelineDelegate: AnyObject {
    func timelineImage(for attachment: MyzelAttachment, done: @escaping (NSImage?) -> Void)
    func timelineOpen(_ attachment: MyzelAttachment)
    func timelineOpenLink(_ url: URL)
    func timelineReply(to id: String)
    func timelineJob(_ jobID: String, action: MyzelJobAction)
}

/// Grundfläche der Kachel: Kopfzeile, Verlauf, (später) Eingabe; darüber bei Bedarf die Einrichtung.
final class MyzelRootView: NSView {
    let header = MyzelHeaderView()
    let scroll = NSScrollView()
    let timeline = MyzelTimelineView()
    let setup = MyzelSetupView()
    /// Unterer Bereich (Eingabe, Etappe 2); Höhe bestimmt er selbst.
    var footer: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let footer { addSubview(footer, positioned: .below, relativeTo: setup) }
            needsLayout = true
        }
    }
    var footerHeight: () -> CGFloat = { 0 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = timeline
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        addSubview(header)
        addSubview(setup)
        setup.isHidden = true
        registerForDraggedTypes([.fileURL])
    }

    /// Dateien irgendwo auf die Kachel gezogen → Anhänge.
    var onDropFiles: (([URL]) -> Void)?
    /// Wer den Fokus bekommt, wenn ein Klick sonst niemanden erreicht (Kachel-Fokus folgt dem First Responder).
    var focusTarget: (() -> NSView?)?

    override var acceptsFirstResponder: Bool { true }

    /// Klicks auf Hintergrund, Kopfzeile, Verlauf landen hier (NSView reicht mouseDown nach oben durch) → Fokus in die
    /// Kachel, sonst ließe sie sich per Maus nicht auswählen.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(focusTarget?() ?? self)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(focusTarget?() ?? self)
        super.rightMouseDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropFiles == nil || urls(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let list = urls(sender)
        guard !list.isEmpty, let onDropFiles else { return false }
        onDropFiles(list)
        return true
    }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        layer?.backgroundColor = theme.background.cgColor
        header.applyTheme(theme)
        timeline.applyTheme(theme)
        setup.applyTheme(theme)
    }

    override func layout() {
        super.layout()
        let headerHeight: CGFloat = 30
        let footH = footer == nil ? 0 : footerHeight()
        header.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: headerHeight)
        footer?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: footH)
        let wasAtBottom = timeline.isScrolledToBottom
        scroll.frame = NSRect(x: 0, y: footH, width: bounds.width, height: max(0, bounds.height - headerHeight - footH))
        timeline.relayout(width: scroll.contentSize.width)
        if wasAtBottom { timeline.scrollToBottom() }
        setup.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
    }
}

/// Kopfzeile: Punkt in Zustandsfarbe + Text (verbunden / verbinde / Fehler), rechts Platz für Knöpfe.
final class MyzelHeaderView: NSView {
    private let dot = LineDotView()
    private let label = NSTextField(labelWithString: "")
    private let line = NSView()
    private var theme = ThemeStore.shared.theme
    /// Knöpfe rechts (Warteliste, Menü) — von rechts nach links gesetzt.
    var trailing: [NSView] = [] {
        didSet { oldValue.forEach { $0.removeFromSuperview() }; trailing.forEach(addSubview); needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = LineStyle.font(11)
        label.lineBreakMode = .byTruncatingTail
        line.wantsLayer = true
        addSubview(dot)
        addSubview(label)
        addSubview(line)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        label.textColor = theme.foreground.withAlphaComponent(LineStyle.text)
        line.layer?.backgroundColor = theme.foreground.withAlphaComponent(LineStyle.divider).cgColor
    }

    func show(_ text: String, tone: NSColor, pulsing: Bool = false) {
        label.stringValue = text
        label.toolTip = text
        dot.color = tone
        dot.pulse = pulsing ? 0.9 : nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 14, y: (bounds.height - LineStyle.dotSize) / 2, width: LineStyle.dotSize, height: LineStyle.dotSize)
        var right = bounds.width - 8
        for view in trailing {
            let width = view.intrinsicContentSize.width
            right -= width
            view.frame = NSRect(x: right, y: (bounds.height - LineStyle.tabHeight) / 2, width: width, height: LineStyle.tabHeight)
            right -= 4
        }
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 26, y: (bounds.height - h) / 2, width: max(0, right - 30), height: h)
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }
}

/// Der Verlauf: eine Nachricht je Zeile, gekippt (oben = alt). Nachrichten-Views werden per id wiederverwendet.
final class MyzelTimelineView: NSView {
    weak var delegate: MyzelTimelineDelegate?
    private var views: [String: MyzelMessageView] = [:]
    private var order: [String] = []
    private var theme = ThemeStore.shared.theme
    private var width: CGFloat = 0
    private let empty = NSTextField(labelWithString: "Noch keine Nachrichten.")

    override init(frame: NSRect) {
        super.init(frame: frame)
        empty.font = LineStyle.font(11, .regular)
        empty.alignment = .center
        addSubview(empty)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        empty.textColor = theme.foreground.withAlphaComponent(LineStyle.faint)
        views.values.forEach { $0.applyTheme(theme) }
        relayout(width: width)
    }

    /// Verlauf an den Chat angleichen: neue Nachrichten anhängen, bestehende auffrischen (Namen, Aufträge).
    func update(chat: MyzelChat, me: String) {
        let wasAtBottom = isScrolledToBottom
        for message in chat.messages {
            let view: MyzelMessageView
            if let existing = views[message.id] {
                view = existing
            } else {
                view = MyzelMessageView(id: message.id)
                view.delegate = delegate
                views[message.id] = view
                order.append(message.id)
                addSubview(view)
            }
            view.configure(message: message, chat: chat, me: me, theme: theme)
        }
        empty.isHidden = !order.isEmpty
        relayout(width: width)
        if wasAtBottom { scrollToBottom() }
    }

    func reset() {
        views.values.forEach { $0.removeFromSuperview() }
        views = [:]
        order = []
        empty.isHidden = false
    }

    func relayout(width: CGFloat) {
        self.width = width
        guard width > 0 else { return }
        var y: CGFloat = 6
        for id in order {
            guard let view = views[id] else { continue }
            let h = view.fit(width: width)
            view.frame = NSRect(x: 0, y: y, width: width, height: h)
            y += h
        }
        y += 8
        let visible = enclosingScrollView?.contentSize.height ?? 0
        setFrameSize(NSSize(width: width, height: max(y, visible)))
        empty.frame = NSRect(x: 0, y: max(0, visible / 2 - 10), width: width, height: 20)
    }

    var isScrolledToBottom: Bool {
        guard let clip = enclosingScrollView?.contentView else { return true }
        return clip.bounds.maxY >= frame.height - 40
    }

    func scrollToBottom() {
        guard let scroll = enclosingScrollView else { return }
        let y = max(0, frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func scrollTo(message id: String) {
        guard let view = views[id] else { return }
        scrollToVisible(view.frame.insetBy(dx: 0, dy: -20))
        view.flash()
    }
}

/// Eine Nachricht: Kopf (Name · Zeit · „via …“), ggf. Antwort-Zitat, Text, Anhänge.
final class MyzelMessageView: NSView, NSTextViewDelegate {
    let id: String
    weak var delegate: MyzelTimelineDelegate?
    private let header = NSTextField(labelWithString: "")
    private let reply = NSTextField(labelWithString: "")
    private let body = MyzelBodyText()
    private var images: [(MyzelAttachment, NSImageView)] = []
    private var files: [LineButton] = []
    private var attachmentIDs: [String] = []
    private var jobRows: [(label: NSTextField, buttons: [LineButton])] = []
    private var jobKey = ""
    private var lastText: String?
    private(set) var rawText = ""
    private var theme = ThemeStore.shared.theme

    private static let inset: CGFloat = 14
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let dayClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd.MM. HH:mm"; return f
    }()

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        header.lineBreakMode = .byTruncatingTail
        reply.lineBreakMode = .byTruncatingTail
        reply.font = LineStyle.font(11, .regular)
        body.delegate = self
        addSubview(header)
        addSubview(reply)
        addSubview(body)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        lastText = nil   // Farben neu rendern beim nächsten configure
        reply.textColor = theme.foreground.withAlphaComponent(LineStyle.text)
    }

    func configure(message: MyzelEvent, chat: MyzelChat, me: String, theme: TerminalTheme) {
        self.theme = theme
        let sender = chat.participant(message.von)
        let tone: NSColor
        if sender?.isAgent == true { tone = Tone.claude.color }
        else if message.von == me { tone = ThemeStore.shared.accentColor }
        else { tone = theme.blue }
        var note: String?
        if let by = message.gesendet_von, by != message.von { note = "gesendet von \(chat.displayName(by))" }
        header.attributedStringValue = MyzelRender.header(name: chat.displayName(message.von), tone: tone,
                                                          time: Self.time(message.date), note: note, theme: theme)
        if let parentID = message.antwort_auf {
            let parent = chat.message(parentID)
            let who = parent.map { chat.displayName($0.von) } ?? "?"
            let text = parent.flatMap(\.text).map { MyzelMarkdown.plain($0) } ?? "…"
            reply.stringValue = "↳ \(who): \(text)"
            reply.isHidden = false
        } else {
            reply.isHidden = true
        }
        reply.textColor = theme.foreground.withAlphaComponent(LineStyle.text)

        let text = message.text ?? ""
        rawText = text
        let key = text + "\u{0}" + chat.participants.map(\.id).joined(separator: ",")
        if key != lastText {
            lastText = key
            let names = Set(chat.participants.map(\.id))
            body.textStorage?.setAttributedString(MyzelRender.attributed(MyzelMarkdown.blocks(text, mentions: names), theme: theme))
            body.isHidden = text.isEmpty
        }
        let ids = (message.anhaenge ?? []).map(\.id)
        if ids != attachmentIDs {
            attachmentIDs = ids
            setAttachments(message.anhaenge ?? [])
        }
        setJobs(chat.jobs(forMessage: message.id), chat: chat, me: me, theme: theme)
    }

    /// Auftragszeilen unter der auslösenden Nachricht: „⚙ @agent · Status“ + Knöpfe je nach Rolle.
    private func setJobs(_ jobs: [MyzelJob], chat: MyzelChat, me: String, theme: TerminalTheme) {
        let key = jobs.map { "\($0.id):\($0.status.rawValue):\(chat.displayName($0.agent))" }.joined(separator: ",") + "|" + me
        guard key != jobKey else { return }
        jobKey = key
        jobRows.forEach { row in row.label.removeFromSuperview(); row.buttons.forEach { $0.removeFromSuperview() } }
        jobRows = jobs.map { job in
            let label = NSTextField(labelWithString: "")
            let tone: NSColor
            switch job.status {
            case .wartet, .bereit: tone = Tone.waiting.color
            case .zugelassen, .laeuft: tone = Tone.running.color
            case .fehlgeschlagen: tone = Tone.error.color
            default: tone = theme.foreground.withAlphaComponent(LineStyle.text)
            }
            let text = NSMutableAttributedString(string: "⚙ @\(chat.displayName(job.agent))", attributes: [
                .font: LineStyle.font(11, .bold), .foregroundColor: Tone.claude.color])
            text.append(NSAttributedString(string: "  · " + MyzelStatusText.text(job, chat: chat), attributes: [
                .font: LineStyle.font(11, .regular), .foregroundColor: tone]))
            if job.isForeign && job.besitzer == me && job.status == .wartet {
                text.append(NSAttributedString(string: "  · Auftrag von \(chat.displayName(job.ausloeser))", attributes: [
                    .font: LineStyle.font(11, .regular), .foregroundColor: theme.foreground.withAlphaComponent(LineStyle.text)]))
            }
            label.attributedStringValue = text
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            let buttons = MyzelJobAction.available(for: job, me: me).map { action -> LineButton in
                let button = LineButton(title: action.label)
                if [.approve, .review, .start].contains(action) { button.accent = Tone.waiting.color }
                button.onClick = { [weak self] in self?.delegate?.timelineJob(job.id, action: action) }
                addSubview(button)
                return button
            }
            return (label, buttons)
        }
    }

    private func setAttachments(_ list: [MyzelAttachment]) {
        images.forEach { $0.1.removeFromSuperview() }
        files.forEach { $0.removeFromSuperview() }
        images = []
        files = []
        for attachment in list {
            if attachment.isImage {
                let view = NSImageView()
                view.imageScaling = .scaleProportionallyUpOrDown
                view.imageAlignment = .alignLeft
                view.wantsLayer = true
                view.layer?.cornerRadius = 6
                view.layer?.masksToBounds = true
                view.toolTip = "\(attachment.name) · \(MyzelRender.byteCount(attachment.bytes)) — Klick öffnet"
                let click = NSClickGestureRecognizer(target: self, action: #selector(imageClicked(_:)))
                view.addGestureRecognizer(click)
                addSubview(view)
                images.append((attachment, view))
                delegate?.timelineImage(for: attachment) { [weak self, weak view] image in
                    guard let view else { return }
                    view.image = image
                    self?.superview?.needsLayout = true
                    (self?.superview as? MyzelTimelineView)?.relayoutKeepingBottom()
                }
            } else {
                let button = LineButton(title: "📄 \(attachment.name)", hint: MyzelRender.byteCount(attachment.bytes))
                button.toolTip = "Öffnen (\(attachment.mime))"
                button.onClick = { [weak self] in self?.delegate?.timelineOpen(attachment) }
                addSubview(button)
                files.append(button)
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Antworten", action: #selector(replyClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Text kopieren", action: #selector(copyClicked), keyEquivalent: "").target = self
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { delegate?.timelineReply(to: id) } else { super.mouseDown(with: event) }
    }

    @objc private func replyClicked() { delegate?.timelineReply(to: id) }

    @objc private func copyClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawText, forType: .string)
    }

    @objc private func imageClicked(_ sender: NSClickGestureRecognizer) {
        guard let entry = images.first(where: { $0.1 === sender.view }) else { return }
        delegate?.timelineOpen(entry.0)
    }

    /// Höhe für diese Breite und Unterviews setzen.
    func fit(width: CGFloat) -> CGFloat {
        let x = Self.inset
        let inner = max(40, width - 2 * x)
        var y: CGFloat = 8
        header.frame = NSRect(x: x, y: y, width: inner, height: 16)
        y += 18
        if !reply.isHidden {
            reply.frame = NSRect(x: x, y: y, width: inner, height: 15)
            y += 18
        }
        if !body.isHidden {
            let h = body.fit(width: inner)
            body.frame = NSRect(x: x, y: y, width: inner, height: h)
            y += h + 4
        }
        for (_, view) in images {
            let size = view.image?.size ?? NSSize(width: 160, height: 100)
            let maxH: CGFloat = 220
            let scale = min(1, maxH / max(1, size.height), inner / max(1, size.width))
            let w = max(40, size.width * scale), h = max(30, size.height * scale)
            view.frame = NSRect(x: x, y: y, width: w, height: h)
            y += h + 6
        }
        var fx = x
        for button in files {
            let w = button.intrinsicContentSize.width
            if fx > x && fx + w > x + inner { fx = x; y += LineStyle.tabHeight + 2 }
            button.frame = NSRect(x: fx - 5, y: y, width: w, height: LineStyle.tabHeight)
            fx += w + 6
        }
        if !files.isEmpty { y += LineStyle.tabHeight + 2 }
        for row in jobRows {
            let labelW = min(inner, row.label.intrinsicContentSize.width)
            row.label.frame = NSRect(x: x, y: y + 4, width: labelW, height: 16)
            var bx = x + labelW + 8
            let total = row.buttons.reduce(0) { $0 + $1.intrinsicContentSize.width + 2 }
            if bx + total > x + inner && !row.buttons.isEmpty { y += 22; bx = x - 5 }
            for button in row.buttons {
                let w = button.intrinsicContentSize.width
                button.frame = NSRect(x: bx, y: y, width: w, height: LineStyle.tabHeight)
                bx += w + 2
            }
            y += LineStyle.tabHeight + 2
        }
        return ceil(y + 6)
    }

    func flash() {
        layer?.backgroundColor = theme.foreground.withAlphaComponent(LineStyle.hover * 1.5).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self?.layer?.backgroundColor = .clear }
        }
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        return Calendar.current.isDateInToday(date) ? clock.string(from: date) : dayClock.string(from: date)
    }

    // Links nie im Text-View öffnen, sondern über den Inhalt (prüft das Schema).
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { delegate?.timelineOpenLink(url) }
        return true
    }
}

extension MyzelTimelineView {
    /// Ein Bild ist nachgeladen: neu setzen, unten bleiben, falls man unten war.
    func relayoutKeepingBottom() {
        let wasAtBottom = isScrolledToBottom
        relayout(width: frame.width)
        if wasAtBottom { scrollToBottom() }
    }
}

/// Nur lesen, markieren, kopieren — kein Bearbeiten, kein Rich-Text-Einfügen.
final class MyzelBodyText: NSTextView {
    convenience init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        linkTextAttributes = [.cursor: NSCursor.pointingHand]
    }

    override var mouseDownCanMoveWindow: Bool { false }

    func fit(width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height) + 2
    }
}

/// Einrichtung, solange Token oder Einstellungen fehlen: erklärt, was fehlt, und nimmt das Token entgegen.
final class MyzelSetupView: NSView, NSTextFieldDelegate {
    private let title = NSTextField(labelWithString: "")
    private let text = NSTextField(wrappingLabelWithString: "")
    let field = NSSecureTextField()
    private let save = LineButton(title: "Speichern")
    private let importButton = LineButton(title: "")
    private var theme = ThemeStore.shared.theme
    var onSave: ((String) -> Void)?
    var onImport: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = LineStyle.font(13, .bold)
        text.font = LineStyle.font(11.5, .regular)
        text.isSelectable = true
        field.font = LineStyle.font(12, .regular)
        field.placeholderString = "mzm_…"
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.delegate = self
        save.onClick = { [weak self] in self?.submit() }
        importButton.onClick = { [weak self] in self?.onImport?() }
        [title, text, field, save, importButton].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.background.cgColor
        title.textColor = theme.foreground.withAlphaComponent(LineStyle.textFocused)
        text.textColor = theme.foreground.withAlphaComponent(LineStyle.text + 0.15)
        field.textColor = theme.foreground
        field.backgroundColor = theme.foreground.withAlphaComponent(LineStyle.hover)
        save.accent = ThemeStore.shared.accentColor
    }

    /// `askToken` false = nur Hinweis (z. B. Einstellungen fehlen), ohne Eingabe.
    func show(title: String, text: String, askToken: Bool, importLabel: String?) {
        self.title.stringValue = title
        self.text.stringValue = text
        field.isHidden = !askToken
        save.isHidden = !askToken
        importButton.isHidden = importLabel == nil
        importButton.title = importLabel ?? ""
        isHidden = false
        needsLayout = true
    }

    private func submit() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSave?(value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(insertNewline(_:)) else { return false }
        submit()
        return true
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let x: CGFloat = 24
        let w = min(520, bounds.width - 2 * x)
        var y: CGFloat = 28
        title.frame = NSRect(x: x, y: y, width: w, height: 20)
        y += 28
        let size = text.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude))
        text.frame = NSRect(x: x, y: y, width: w, height: size.height)
        y += size.height + 16
        if !importButton.isHidden {
            importButton.frame = NSRect(x: x - 5, y: y, width: importButton.intrinsicContentSize.width, height: LineStyle.tabHeight)
            y += LineStyle.tabHeight + 12
        }
        if !field.isHidden {
            field.frame = NSRect(x: x, y: y, width: min(w - 90, 360), height: 22)
            save.frame = NSRect(x: field.frame.maxX + 8, y: y - 1, width: save.intrinsicContentSize.width, height: LineStyle.tabHeight)
        }
    }
}
