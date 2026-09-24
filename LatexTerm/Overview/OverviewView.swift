import AppKit

/// Ansicht der Übersicht: Karten in einer Scroll-Fläche, darunter Band (Chef / Rückmeldung) und Tippzeile.
/// Stil „Linie“: keine Kapseln, Kachelfarbe als Strich links, Farbe für Zustand nur bei wartet (gelb) und Fehler (rot).
final class OverviewView: NSView, NSTextFieldDelegate {
    var hostProvider: (() -> OverviewHost?)?
    let commandField = OverviewField()

    private let scroll = NSScrollView()
    private let cardsView = FlippedView()
    private let band = NSTextField(labelWithString: "")
    private let prompt = NSTextField(labelWithString: "›")
    private let bottomLine = NSView()
    private var cards: [ObjectIdentifier: OverviewCardView] = [:]
    private var boards: [OverviewBoard] = []
    private var order: [ObjectIdentifier] = []
    private var timer: Timer?
    /// Rückmeldung im Band (gesendet, Fehler), überdeckt den Chef für ein paar Sekunden.
    private var notice: (text: String, ok: Bool, until: Date)?
    /// Gerade beantwortet: bis sich der echte Zustand ändert, zeigt die Karte „an „…““ statt der alten Frage.
    private var sent: [String: (text: String, since: Date, at: Date)] = [:]

    private static let padding: CGFloat = 14
    private static let gap: CGFloat = 10
    private static let commandHeight: CGFloat = 38
    private static let bandHeight: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = cardsView
        addSubview(scroll)

        band.font = AppFonts.mono(size: 11.5)
        band.lineBreakMode = .byTruncatingTail
        band.maximumNumberOfLines = 1
        band.cell?.truncatesLastVisibleLine = true
        addSubview(band)
        bottomLine.wantsLayer = true
        addSubview(bottomLine)

        prompt.font = AppFonts.mono(size: 13, weight: .semibold)
        addSubview(prompt)
        commandField.font = AppFonts.mono(size: 12.5)
        commandField.isBordered = false
        commandField.drawsBackground = false
        commandField.focusRingType = .none
        commandField.cell?.isScrollable = true
        commandField.cell?.wraps = false
        commandField.placeholderString = "@brett Nachricht an ein Brett  ·  ohne @ an den Chef"
        commandField.target = self
        commandField.action = #selector(submitCommand)
        commandField.delegate = self
        addSubview(commandField)
        applyTheme(ThemeStore.shared.theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        layer?.backgroundColor = theme.background.withAlphaComponent(1).cgColor
        prompt.textColor = theme.foreground.withAlphaComponent(LineStyle.number)
        commandField.textColor = theme.foreground.withAlphaComponent(LineStyle.textFocused)
        commandField.placeholderAttributedString = NSAttributedString(
            string: commandField.placeholderString ?? "",
            attributes: [.font: AppFonts.mono(size: 12.5), .foregroundColor: theme.foreground.withAlphaComponent(LineStyle.faint + 0.08)])
        bottomLine.layer?.backgroundColor = theme.foreground.withAlphaComponent(LineStyle.track).cgColor
        cards.values.forEach { $0.needsDisplay = true }
        updateBand()
    }

    // MARK: Takt

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh(force: false) }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.async { [weak self] in self?.refresh(force: true) }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refresh(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Stand holen und zeichnen — nur, solange das Home-Brett vorn ist (verdeckt kostet es nichts).
    func refresh(force: Bool) {
        guard window != nil, !isHiddenOrHasHiddenAncestor, let host = hostProvider?() else { return }
        let fresh = applySent(host.overviewBoards())
        let changed = fresh != boards
        boards = fresh
        if changed || force { layoutCards(animated: !force) }
        else { cards.values.forEach { $0.needsDisplay = true } }   // Alter („4 min“) tickt
        updateBand()
    }

    /// Gerade Beantwortetes als „arbeitet an …“ zeigen, bis die Session selbst etwas meldet (höchstens 2 min).
    private func applySent(_ boards: [OverviewBoard]) -> [OverviewBoard] {
        let now = Date()
        return boards.map { board in
            var board = board
            board.agents = board.agents.map { agent in
                guard let mark = sent[agent.paneID] else { return agent }
                guard agent.since == mark.since, now.timeIntervalSince(mark.at) < 120 else {
                    sent[agent.paneID] = nil
                    return agent
                }
                var a = agent
                a.state = .working
                a.say = "an „\(mark.text)“"
                a.since = mark.at
                a.permission = false
                return a
            }
            return board
        }
    }

    // MARK: Karten legen

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        let w = bounds.width, h = bounds.height
        let commandY = h - Self.commandHeight
        bottomLine.frame = NSRect(x: 0, y: commandY - Self.bandHeight - 0.5, width: w, height: 1)
        band.frame = NSRect(x: Self.padding, y: commandY - Self.bandHeight + 5, width: w - Self.padding * 2, height: 17)
        prompt.frame = NSRect(x: Self.padding, y: commandY + 10, width: 14, height: 18)
        commandField.frame = NSRect(x: Self.padding + 16, y: commandY + 10, width: w - Self.padding * 2 - 16, height: 18)
        scroll.frame = NSRect(x: 0, y: 0, width: w, height: max(0, commandY - Self.bandHeight - 1))
        if abs(oldSize.width - w) > 0.5 || abs(oldSize.height - h) > 0.5 { layoutCards(animated: false) }
    }

    /// Schwerkraft: Reihenfolge nach Zustand, Größe in vier Stufen, Zeilen von links nach rechts. Solange Mats in
    /// einem Kartenfeld tippt, bleibt die Reihenfolge stehen (die Karte wandert ihm nicht unter den Fingern weg).
    private func layoutCards(animated: Bool) {
        let sorted = OverviewRules.sorted(boards)
        let typing = cards.values.first { $0.isTyping }
        if typing == nil || order.isEmpty { order = sorted.map(\.id) }
        let byID = Dictionary(boards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = order.filter { byID[$0] != nil } + sorted.map(\.id).filter { !order.contains($0) }
        order = ids

        for (id, card) in cards where byID[id] == nil {
            card.removeFromSuperview()
            cards[id] = nil
        }

        let width = max(scroll.contentSize.width, 200)
        let inner = width - Self.padding * 2
        var x = Self.padding, y = Self.padding, rowHeight: CGFloat = 0
        var frames: [(OverviewCardView, NSRect)] = []
        for id in ids {
            guard let board = byID[id] else { continue }
            let card = cards[id] ?? makeCard(id)
            card.board = board
            card.size = OverviewCardSize(board.state)
            let w = Self.cardWidth(card.size, inner: inner)
            let h = card.preferredHeight(width: w)
            if x > Self.padding, x + w > width - Self.padding + 0.5 {
                x = Self.padding
                y += rowHeight + Self.gap
                rowHeight = 0
            }
            frames.append((card, NSRect(x: x, y: y, width: w, height: h)))
            x += w + Self.gap
            rowHeight = max(rowHeight, h)
        }
        let total = y + rowHeight + Self.padding
        cardsView.frame = NSRect(x: 0, y: 0, width: width, height: max(total, scroll.contentSize.height))
        let moves = frames.filter { $0.0.frame != $0.1 }
        if animated, !moves.isEmpty, frames.contains(where: { $0.0.frame != .zero }) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.allowsImplicitAnimation = true
                for (card, frame) in moves {
                    if card.frame == .zero { card.frame = frame } else { card.animator().frame = frame }
                }
            }
        } else {
            for (card, frame) in moves { card.frame = frame }
        }
        frames.forEach { $0.0.needsDisplay = true; $0.0.layoutReply() }
        if boards.isEmpty { showEmptyHint() } else { emptyHint?.removeFromSuperview(); emptyHint = nil }
    }

    /// Breite je Stufe: groß = halbe Zeile, mittel = ein Drittel, klein = ein Viertel, winzig = ein Fünftel — bei
    /// schmaler Kachel entsprechend weniger je Zeile (nie unter 180 pt).
    private static func cardWidth(_ size: OverviewCardSize, inner: CGFloat) -> CGFloat {
        let perRow: CGFloat
        switch size {
        case .big: perRow = 2
        case .medium: perRow = 3
        case .small: perRow = 4
        case .tiny: perRow = 5
        }
        let minimum: CGFloat = size == .big ? 300 : 180
        var n = perRow
        while n > 1, (inner - gap * (n - 1)) / n < minimum { n -= 1 }
        return ((inner - gap * (n - 1)) / n).rounded(.down)
    }

    private func makeCard(_ id: ObjectIdentifier) -> OverviewCardView {
        let card = OverviewCardView(frame: .zero)
        card.onShowBoard = { [weak self] id in self?.hostProvider?()?.overviewShowBoard(id) }
        card.onShowPane = { [weak self] pane, board in self?.hostProvider?()?.overviewShowPane(pane, board: board) }
        card.onReply = { [weak self] agent, text in self?.reply(text, to: agent) }
        card.onPermission = { [weak self] agent, allow in self?.permission(allow, for: agent) }
        cardsView.addSubview(card)
        cards[id] = card
        return card
    }

    private var emptyHint: NSTextField?

    private func showEmptyHint() {
        guard emptyHint == nil else { return }
        let label = NSTextField(wrappingLabelWithString: "Noch keine anderen Bretter. ⇧⌘T legt eins an — dann steht hier je Brett eine Karte.")
        label.font = AppFonts.mono(size: 12)
        label.textColor = ThemeStore.shared.theme.foreground.withAlphaComponent(LineStyle.text)
        label.frame = NSRect(x: Self.padding, y: Self.padding, width: max(200, scroll.contentSize.width - Self.padding * 2), height: 40)
        cardsView.addSubview(label)
        emptyHint = label
    }

    // MARK: Antworten

    private func reply(_ text: String, to agent: OverviewAgent) {
        let name = boards.first { $0.agents.contains(agent) }?.name ?? agent.name
        let deliver = { [weak self] in
            AgentDelivery.deliver(text, toPane: agent.paneID, agent: agent.agent) { message, ok in
                self?.show(ok ? "→ \(name): \(message)" : "\(name): \(message)", ok: ok)
            }
        }
        sent[agent.paneID] = (text, agent.since, Date())
        // Eine offene Freigabe zuerst ablehnen — der Text ist dann die Anweisung, was stattdessen.
        if agent.permission {
            _ = AgentDelivery.answerPermission(false, toPane: agent.paneID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: deliver)
        } else {
            deliver()
        }
        refresh(force: false)
    }

    private func permission(_ allow: Bool, for agent: OverviewAgent) {
        let name = boards.first { $0.agents.contains(agent) }?.name ?? agent.name
        let ok = AgentDelivery.answerPermission(allow, toPane: agent.paneID)
        if ok { sent[agent.paneID] = (allow ? "erlaubt" : "abgelehnt", agent.since, Date()) }
        show(ok ? "→ \(name): \(allow ? "erlaubt" : "abgelehnt")" : "\(name): Kachel nimmt nichts an", ok: ok)
        refresh(force: false)
    }

    @objc private func submitCommand() {
        let line = commandField.stringValue
        guard let parsed = OverviewRules.parse(line, boards: boards.map { ($0.number, $0.name) }) else {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("@") {
                show("Brett nicht eindeutig — @name oder @nummer, dann der Text", ok: false)
            }
            return
        }
        commandField.stringValue = ""
        switch parsed.target {
        case .chef:
            guard let host = hostProvider?() else { return }
            show("→ Chef: „\(parsed.text)“", ok: true)
            host.overviewAskChef(parsed.text) { [weak self] message, ok in
                self?.show(ok ? "→ Chef: \(message)" : "Chef: \(message)", ok: ok)
            }
        case .board(let n):
            guard let board = boards.first(where: { $0.number == n }) else { return }
            guard let agent = board.lead ?? board.agents.first else {
                show("\(board.name): kein Agent auf dem Brett", ok: false)
                return
            }
            reply(parsed.text, to: agent)
        }
    }

    /// Esc in der Tippzeile leert sie; ⌘↑ holt den Chef-Verlauf nach vorn.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commandField.stringValue = ""
            return true
        }
        return false
    }

    // MARK: Band

    private func show(_ text: String, ok: Bool) {
        notice = (text, ok, Date().addingTimeInterval(5))
        updateBand()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in self?.updateBand() }
    }

    private func updateBand() {
        let theme = ThemeStore.shared.theme
        let fg = theme.foreground
        let who = NSAttributedString(string: "✻ Chef  ", attributes: [
            .font: AppFonts.mono(size: 11.5, weight: .semibold), .foregroundColor: fg.withAlphaComponent(LineStyle.number)])
        let text = NSMutableAttributedString()
        if let notice, notice.until > Date() {
            text.append(NSAttributedString(string: notice.text, attributes: [
                .font: AppFonts.mono(size: 11.5), .foregroundColor: notice.ok ? fg.withAlphaComponent(0.75) : theme.red]))
        } else {
            notice = nil
            text.append(who)
            let chef = hostProvider?()?.overviewChef
            let line: String
            var tone = fg.withAlphaComponent(0.75)
            switch chef {
            case nil: line = "schläft — schreib unten ohne @, dann fängt er an"; tone = fg.withAlphaComponent(LineStyle.text)
            case let chef? where chef.starting: line = "startet …"
            case let chef? where chef.state == .working: line = "arbeitet" + (chef.say.map { " · \($0)" } ?? " …")
            case let chef? where chef.state == .waiting: line = chef.say ?? "wartet auf dich"; tone = theme.yellow
            case let chef?: line = chef.say ?? "bereit"
            }
            text.append(NSAttributedString(string: line, attributes: [.font: AppFonts.mono(size: 11.5), .foregroundColor: tone]))
        }
        band.attributedStringValue = text
        band.toolTip = band.stringValue
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if band.frame.insetBy(dx: 0, dy: -4).contains(point), hostProvider?()?.overviewChef != nil {
            hostProvider?()?.overviewShowChef()
            return
        }
        window?.makeFirstResponder(commandField)
    }
}

/// Tippzeile: nimmt die Tastatur, wenn das Home-Brett vorn ist.
final class OverviewField: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Karte

/// Eine Karte: Kopf (Nummer, Name, Zustand · Alter), Miniatur der Anordnung, letzter Satz; groß mit Antwortfeld und
/// Schnellknöpfen. Zeichnet selbst; nur das Antwortfeld ist eine echte View.
final class OverviewCardView: NSView, NSTextFieldDelegate {
    var board: OverviewBoard? { didSet { if board != oldValue { needsDisplay = true; updateReplyPlaceholder() } } }
    var size: OverviewCardSize = .small {
        didSet { if size != oldValue { needsDisplay = true } }
    }
    var onShowBoard: ((ObjectIdentifier) -> Void)?
    var onShowPane: ((String, ObjectIdentifier) -> Void)?
    var onReply: ((OverviewAgent, String) -> Void)?
    var onPermission: ((OverviewAgent, Bool) -> Void)?

    private let field = NSTextField()
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var hoveredQuick: Int? { didSet { if hoveredQuick != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    private static let inset = NSEdgeInsets(top: 10, left: 14, bottom: 11, right: 12)
    private static let headerHeight: CGFloat = 18
    private static let replyHeight: CGFloat = 28
    private static let sayFont = NSFont.systemFont(ofSize: 12)
    private static let smallSayFont = NSFont.systemFont(ofSize: 11)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        field.font = AppFonts.mono(size: 12)
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.isHidden = true
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Mats tippt gerade hier (Feld fokussiert und nicht leer).
    var isTyping: Bool {
        guard let editor = field.currentEditor(), window?.firstResponder === editor else { return false }
        return !field.stringValue.isEmpty
    }

    private var lead: OverviewAgent? { board?.lead }
    private var hasReply: Bool { size == .big && lead != nil }
    private var quick: [String] { lead.map(OverviewRules.quickReplies(for:)) ?? [] }

    // MARK: Maße

    private var miniHeight: CGFloat {
        switch size { case .big: return 110; case .medium: return 74; case .small: return 60; case .tiny: return 48 }
    }
    private var sayLines: Int {
        switch size { case .big: return 3; case .medium: return 2; case .small, .tiny: return 1 }
    }
    private var sayFont: NSFont { size >= .medium ? Self.sayFont : Self.smallSayFont }
    /// Kleine Karten brechen den Kopf um: Zustand in eine zweite Zeile.
    private var headerLines: Int { size >= .medium ? 1 : 2 }

    private func sayHeight(width: CGFloat) -> CGFloat {
        guard let say = lead?.say, !say.isEmpty else { return 0 }
        let lineHeight = ceil(sayFont.ascender - sayFont.descender + sayFont.leading) + 2
        let rect = (say as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                  options: [.usesLineFragmentOrigin], attributes: [.font: sayFont])
        return min(ceil(rect.height), lineHeight * CGFloat(sayLines))
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        let inner = width - Self.inset.left - Self.inset.right
        var h = Self.inset.top + Self.headerHeight * CGFloat(headerLines) + 8 + miniHeight
        let say = sayHeight(width: inner)
        if say > 0 { h += 7 + say }
        if hasReply { h += 9 + Self.replyHeight }
        return ceil(h + Self.inset.bottom)
    }

    private var contentRect: NSRect {
        NSRect(x: Self.inset.left, y: Self.inset.top, width: bounds.width - Self.inset.left - Self.inset.right,
               height: bounds.height - Self.inset.top - Self.inset.bottom)
    }
    private var miniRect: NSRect {
        let c = contentRect
        return NSRect(x: c.minX, y: c.minY + Self.headerHeight * CGFloat(headerLines) + 8, width: c.width, height: miniHeight)
    }
    private var sayRect: NSRect {
        let c = contentRect
        return NSRect(x: c.minX, y: miniRect.maxY + 7, width: c.width, height: sayHeight(width: c.width))
    }
    private var replyRect: NSRect {
        let c = contentRect
        return NSRect(x: c.minX, y: c.maxY - Self.replyHeight, width: c.width, height: Self.replyHeight)
    }

    private func quickRects() -> [NSRect] {
        let font = AppFonts.mono(size: 11, weight: .medium)
        var x = replyRect.maxX
        var rects: [NSRect] = []
        for label in quick.reversed() {
            let w = (label as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 14
            x -= w
            rects.insert(NSRect(x: x, y: replyRect.midY - 12, width: w, height: 24), at: 0)
            x -= 4
        }
        return rects
    }

    func layoutReply() {
        field.isHidden = !hasReply
        guard hasReply else {
            if field.currentEditor() != nil { window?.makeFirstResponder(nil) }
            return
        }
        let quickWidth = quickRects().first.map { replyRect.maxX - $0.minX + 6 } ?? 0
        let r = replyRect
        field.frame = NSRect(x: r.minX, y: r.minY, width: max(80, r.width - quickWidth), height: r.height)
        // NSTextField zentriert nicht senkrecht: Höhe knapp, mittig setzen.
        let lineHeight = ceil((field.font?.ascender ?? 10) - (field.font?.descender ?? -3)) + 4
        field.frame.origin.y = r.minY + (r.height - lineHeight) / 2
        field.frame.size.height = lineHeight
        updateReplyPlaceholder()
    }

    private func updateReplyPlaceholder() {
        let fg = ThemeStore.shared.theme.foreground
        field.textColor = fg.withAlphaComponent(LineStyle.textFocused)
        field.backgroundColor = .clear
        let name = board?.name ?? ""
        let text = lead?.permission == true ? "oder: was stattdessen …" : "Antwort an \(name) …"
        field.placeholderAttributedString = NSAttributedString(string: text, attributes: [
            .font: AppFonts.mono(size: 12), .foregroundColor: fg.withAlphaComponent(LineStyle.faint + 0.08)])
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        guard let board else { return }
        let theme = ThemeStore.shared.theme
        let fg = theme.foreground
        let state = board.state

        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 8, yRadius: 8)
        fg.withAlphaComponent(hovered ? 0.05 : 0.025).setFill()
        card.fill()
        if state == .waiting || state == .error {
            (state == .error ? theme.red : theme.yellow).withAlphaComponent(0.55).setStroke()
            card.lineWidth = 1.5
            card.stroke()
        }
        // Identität: Strich links in der Kachelfarbe des Bretts.
        board.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 8, width: 3, height: bounds.height - 16), xRadius: 1.5, yRadius: 1.5).fill()
        alphaValue = size == .tiny ? 0.72 : 1

        drawHeader(board, theme: theme)
        drawMini(board, theme: theme)
        drawSay(theme: theme)
        if hasReply { drawReply(theme: theme) }
    }

    private func drawHeader(_ board: OverviewBoard, theme: TerminalTheme) {
        let fg = theme.foreground
        let c = contentRect
        let bold = AppFonts.mono(size: 12, weight: .semibold)
        let number = NSAttributedString(string: "\(board.number)  ", attributes: [
            .font: AppFonts.mono(size: 12, weight: .bold), .foregroundColor: fg.withAlphaComponent(LineStyle.number)])
        let name = NSAttributedString(string: board.name, attributes: [.font: bold, .foregroundColor: fg.withAlphaComponent(LineStyle.textFocused)])
        let title = NSMutableAttributedString(attributedString: number)
        title.append(name)

        let stateFont = AppFonts.mono(size: 10.5, weight: .medium)
        let age = board.lead.map { " · " + OverviewRules.age(since: $0.since) } ?? ""
        let stateText = board.agents.isEmpty ? "kein Agent" : board.state.label + age
        let status = NSAttributedString(string: stateText, attributes: [.font: stateFont, .foregroundColor: fg.withAlphaComponent(LineStyle.text)])
        let statusWidth = status.size().width.rounded(.up)
        let dot: CGFloat = 7

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        title.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: title.length))

        if headerLines == 1 {
            let titleWidth = c.width - statusWidth - dot - 14
            title.draw(with: NSRect(x: c.minX, y: c.minY + 1, width: titleWidth, height: Self.headerHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let sx = c.maxX - statusWidth
            status.draw(at: NSPoint(x: sx, y: c.minY + 2))
            drawDot(board.state, at: NSPoint(x: sx - dot - 5, y: c.minY + 5), size: dot, theme: theme)
        } else {
            title.draw(with: NSRect(x: c.minX, y: c.minY + 1, width: c.width, height: Self.headerHeight),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            drawDot(board.state, at: NSPoint(x: c.minX, y: c.minY + Self.headerHeight + 5), size: dot, theme: theme)
            status.draw(at: NSPoint(x: c.minX + dot + 5, y: c.minY + Self.headerHeight + 2))
        }
    }

    /// Punkt je Zustand: wartet gelb, Fehler rot, Ergebnis als Ring, arbeitet gedämpft, ruhig blass.
    private func drawDot(_ state: OverviewState, at origin: NSPoint, size: CGFloat, theme: TerminalTheme) {
        let rect = NSRect(x: origin.x, y: origin.y, width: size, height: size)
        let path = NSBezierPath(ovalIn: rect)
        let fg = theme.foreground
        switch state {
        case .waiting: theme.yellow.setFill(); path.fill()
        case .error: theme.red.setFill(); path.fill()
        case .outcome:
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            fg.withAlphaComponent(0.75).setStroke(); ring.lineWidth = 1.5; ring.stroke()
        case .working: fg.withAlphaComponent(LineStyle.text).setFill(); path.fill()
        case .idle: fg.withAlphaComponent(LineStyle.faint).setFill(); path.fill()
        }
    }

    /// Miniatur: die Kacheln des Bretts an ihrem echten Platz. Agenten mit Rahmen in Kachelfarbe (wartet/Fehler in
    /// Zustandsfarbe), Arbeitsflächen blass.
    private func drawMini(_ board: OverviewBoard, theme: TerminalTheme) {
        let fg = theme.foreground
        let area = miniRect
        guard !board.cells.isEmpty else {
            fg.withAlphaComponent(LineStyle.track).setStroke()
            let empty = NSBezierPath(roundedRect: area.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            empty.lineWidth = 1
            empty.stroke()
            return
        }
        let font = AppFonts.mono(size: size >= .medium ? 10 : 9)
        for cell in board.cells {
            let r = cellRect(cell, in: area)
            guard r.width > 4, r.height > 4 else { continue }
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
            if cell.agent != nil {
                let tone: NSColor = cell.state == .waiting ? theme.yellow : cell.state == .error ? theme.red : cell.accent
                tone.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            } else {
                fg.withAlphaComponent(0.02).setFill()
                path.fill()
                fg.withAlphaComponent(0.14).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
            guard r.width > 26, r.height > 14 else { continue }
            let dotSize: CGFloat = cell.agent != nil ? 6 : 0
            if cell.agent != nil { drawDot(cell.state, at: NSPoint(x: r.minX + 5, y: r.minY + 6), size: dotSize, theme: theme) }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let label = NSAttributedString(string: cell.label, attributes: [
                .font: font, .paragraphStyle: style,
                .foregroundColor: fg.withAlphaComponent(cell.agent != nil ? 0.75 : 0.35)])
            let x = r.minX + 5 + (dotSize > 0 ? dotSize + 4 : 0)
            label.draw(with: NSRect(x: x, y: r.minY + 3, width: r.maxX - x - 4, height: 14),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private func cellRect(_ cell: OverviewCell, in area: NSRect) -> NSRect {
        let gap: CGFloat = 1.5
        return NSRect(x: area.minX + cell.rect.minX * area.width + gap, y: area.minY + cell.rect.minY * area.height + gap,
                      width: cell.rect.width * area.width - gap * 2, height: cell.rect.height * area.height - gap * 2)
    }

    private func drawSay(theme: TerminalTheme) {
        guard let lead, let say = lead.say, !say.isEmpty else { return }
        let fg = theme.foreground
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let strong = lead.state.needsYou
        var prefix = ""
        if (board?.agents.count ?? 0) > 1 { prefix = lead.name + ": " }
        let text = NSMutableAttributedString(string: prefix, attributes: [
            .font: AppFonts.mono(size: sayFont.pointSize - 0.5, weight: .semibold), .foregroundColor: fg.withAlphaComponent(LineStyle.text),
            .paragraphStyle: style])
        text.append(NSAttributedString(string: say, attributes: [
            .font: sayFont, .paragraphStyle: style,
            .foregroundColor: fg.withAlphaComponent(strong ? LineStyle.textFocused : 0.72)]))
        text.draw(with: sayRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func drawReply(theme: TerminalTheme) {
        let fg = theme.foreground
        let fieldBox = NSRect(x: replyRect.minX, y: replyRect.minY, width: field.frame.width + 4, height: replyRect.height)
        fg.withAlphaComponent(0.045).setFill()
        NSBezierPath(roundedRect: fieldBox.offsetBy(dx: -6, dy: 0).insetBy(dx: 0, dy: 0), xRadius: 5, yRadius: 5).fill()
        let font = AppFonts.mono(size: 11, weight: .medium)
        for (i, rect) in quickRects().enumerated() where quick.indices.contains(i) {
            if hoveredQuick == i {
                fg.withAlphaComponent(LineStyle.hover).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let label = NSAttributedString(string: quick[i], attributes: [
                .font: font, .foregroundColor: fg.withAlphaComponent(hoveredQuick == i ? LineStyle.textFocused : LineStyle.text)])
            let s = label.size()
            label.draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
        }
    }

    // MARK: Maus

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; hoveredQuick = nil }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredQuick = hasReply ? quickRects().firstIndex { $0.contains(p) } : nil
    }

    override func resetCursorRects() {
        addCursorRect(miniRect, cursor: .pointingHand)
        if hasReply { quickRects().forEach { addCursorRect($0, cursor: .pointingHand) } }
    }

    /// Miniatur-Zelle → diese Kachel; Schnellknopf → Antwort; Rest → wer wartet, bekommt das Feld, sonst Brett zeigen.
    override func mouseUp(with event: NSEvent) {
        guard let board else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hasReply, let i = quickRects().firstIndex(where: { $0.contains(p) }), let lead, quick.indices.contains(i) {
            if lead.permission { onPermission?(lead, i == 0) } else { onReply?(lead, quick[i]) }
            return
        }
        if miniRect.contains(p), let cell = board.cells.first(where: { cellRect($0, in: miniRect).contains(p) }) {
            onShowPane?(cell.paneID, board.id)
            return
        }
        if hasReply, sayRect.contains(p) || replyRect.contains(p) {
            window?.makeFirstResponder(field)
            return
        }
        onShowBoard?(board.id)
    }

    override func mouseDown(with event: NSEvent) {}

    @objc private func submit() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let lead else { return }
        field.stringValue = ""
        onReply?(lead, text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            field.stringValue = ""
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}
