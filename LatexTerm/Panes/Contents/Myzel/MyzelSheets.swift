import AppKit

/// Zulassen eines fremden Auftrags (PROTOKOLL §10.1): der Auftrag steht **wörtlich** da (Rohtext, kein Markdown, damit
/// nichts versteckt werden kann), dazu der Umfang, den der Agent sehen darf, und ein optionaler Grund fürs Ablehnen.
enum MyzelApproveSheet {
    enum Result {
        case approve(MyzelScope)
        case reject(String?)
        case cancel
    }

    static func run(on window: NSWindow, trigger: String, agent: String, text: String, projects: [MyzelConfig.Project],
                    done: @escaping (Result) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Auftrag von \(trigger) an \(agent)"
        alert.informativeText = "So steht er im Chat, Zeichen für Zeichen. Zulassen startet noch nichts — danach "
            + "startest du den Agenten selbst."
        alert.addButton(withTitle: "Zulassen")
        alert.addButton(withTitle: "Ablehnen")
        alert.addButton(withTitle: "Später")

        let width: CGFloat = 440
        let box = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 250))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 100, width: width, height: 150))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = AppFonts.mono(size: 12)
        textView.string = text
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        box.addSubview(scroll)

        let scopeLabel = NSTextField(labelWithString: "Der Agent darf sehen:")
        scopeLabel.frame = NSRect(x: 0, y: 68, width: 150, height: 20)
        box.addSubview(scopeLabel)
        let popup = NSPopUpButton(frame: NSRect(x: 150, y: 64, width: width - 150, height: 26))
        var scopes: [MyzelScope] = [.chat]
        scopes += projects.map { .project(name: $0.name, path: $0.path) }
        scopes.append(.free)
        popup.addItems(withTitles: scopes.map(\.label))
        popup.toolTip = "Wird zur Lese-Freigabe der Sandbox: nur Chat = nur der Auftragsordner; Projekt = dieser "
            + "Ordner lesend dazu; frei = alles lesen außer der Sperrliste. Schreiben immer nur im Auftragsordner."
        box.addSubview(popup)

        let reasonLabel = NSTextField(labelWithString: "Grund fürs Ablehnen (optional):")
        reasonLabel.frame = NSRect(x: 0, y: 32, width: width, height: 18)
        box.addSubview(reasonLabel)
        let reason = NSTextField(frame: NSRect(x: 0, y: 4, width: width, height: 24))
        reason.placeholderString = "z. B. dazu sage ich lieber selbst etwas"
        box.addSubview(reason)
        alert.accessoryView = box

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                done(.approve(scopes[max(0, popup.indexOfSelectedItem)]))
            case .alertSecondButtonReturn:
                let text = reason.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                done(.reject(text.isEmpty ? nil : String(text.prefix(500))))
            default:
                done(.cancel)
            }
        }
    }
}

/// Entwurf prüfen und senden (PROTOKOLL §10.2/§10.3): Auftrag, editierbarer Text, **jeder** Anhang; große Anhänge
/// (`pruefen`) lassen sich erst abhaken, nachdem sie geöffnet wurden; Senden schickt die gesehene `version`.
final class MyzelDraftSheet: NSObject, NSWindowDelegate {
    enum Action {
        case send(text: String, confirmed: Set<String>)
        case discard
        case close
    }

    let panel: NSPanel
    private(set) var draft: MyzelDraft
    private let textView = NSTextView()
    private let sendButton = NSButton(title: "Senden", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let attachmentsBox = NSView()
    private let accessTitle = NSTextField(labelWithString: "")
    private let accessView = NSTextView()
    private var checkboxes: [String: NSButton] = [:]
    private var opened: Set<String> = []
    private var onAction: ((Action) -> Void)?
    /// Anhang öffnen (lädt über den Inhalt, ruft danach `markOpened`).
    var openAttachment: ((MyzelAttachment) -> Void)?
    var loadImage: ((MyzelAttachment, @escaping (NSImage?) -> Void) -> Void)?

    init(draft: MyzelDraft, agent: String, trigger: String, triggerText: String) {
        self.draft = draft
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 720),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        panel.title = "Entwurf von \(agent)"
        panel.minSize = NSSize(width: 480, height: 420)
        super.init()
        panel.delegate = self
        build(agent: agent, trigger: trigger, triggerText: triggerText)
        fill()
    }

    func begin(on window: NSWindow, onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        window.beginSheet(panel)
    }

    func end() {
        panel.sheetParent?.endSheet(panel)
        onAction = nil
    }

    /// Neuer Stand vom Server (409 „hat sich geändert“): Text und Anhänge neu, Bestätigungen zurück.
    func reload(_ draft: MyzelDraft, note: String) {
        self.draft = draft
        opened = []
        fill()
        showStatus(note, error: true)
    }

    func showStatus(_ text: String, error: Bool) {
        status.stringValue = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }

    /// Lesezugriffs-Protokoll aus dem Transkript der Agenten-Session (nur lokal); nil = keins gefunden.
    func setAccessLog(_ lines: [String]?) {
        if let lines {
            accessTitle.stringValue = "Was der Agent angefasst hat (\(lines.count)) — ✓ ging, ✗ abgelehnt"
            accessView.string = lines.isEmpty ? "(nichts außer dem Chat)" : lines.joined(separator: "\n")
        } else {
            accessTitle.stringValue = "Was der Agent angefasst hat — kein Transkript gefunden (anderswo gestartet?)"
            accessView.string = ""
        }
    }

    func markOpened(_ id: String) {
        opened.insert(id)
        checkboxes[id]?.isEnabled = true
        refreshSend()
    }

    private func build(agent: String, trigger: String, triggerText: String) {
        let content = panel.contentView!
        let pad: CGFloat = 16

        let head = NSTextField(wrappingLabelWithString: "Auftrag von \(trigger): \(triggerText.prefix(600))")
        head.font = AppFonts.mono(size: 11.5)
        head.textColor = .secondaryLabelColor
        head.maximumNumberOfLines = 4
        head.lineBreakMode = .byTruncatingTail
        head.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(head)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = AppFonts.mono(size: 12.5)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        content.addSubview(scroll)

        let attachScroll = NSScrollView()
        attachScroll.hasVerticalScroller = true
        attachScroll.drawsBackground = false
        attachScroll.translatesAutoresizingMaskIntoConstraints = false
        attachScroll.documentView = attachmentsBox
        content.addSubview(attachScroll)

        accessTitle.font = AppFonts.mono(size: 11, weight: .bold)
        accessTitle.textColor = .secondaryLabelColor
        accessTitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(accessTitle)
        let accessScroll = NSScrollView()
        accessScroll.hasVerticalScroller = true
        accessScroll.borderType = .bezelBorder
        accessScroll.translatesAutoresizingMaskIntoConstraints = false
        accessView.isEditable = false
        accessView.isSelectable = true
        accessView.font = AppFonts.mono(size: 10.5)
        accessView.textColor = .secondaryLabelColor
        accessView.textContainerInset = NSSize(width: 4, height: 4)
        accessView.isVerticallyResizable = true
        accessView.autoresizingMask = [.width]
        accessView.textContainer?.widthTracksTextView = true
        accessScroll.documentView = accessView
        content.addSubview(accessScroll)
        setAccessLog(nil)

        status.translatesAutoresizingMaskIntoConstraints = false
        status.lineBreakMode = .byTruncatingTail
        content.addSubview(status)

        let discard = NSButton(title: "Verwerfen", target: self, action: #selector(discardClicked))
        let close = NSButton(title: "Schließen", target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.toolTip = "⌘⏎ — sendet den Text so, wie er hier steht, als Nachricht von \(agent)"
        for b in [discard, close, sendButton] { b.bezelStyle = .rounded; b.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(b) }

        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            head.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            head.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            attachScroll.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            attachScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            attachScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            attachScroll.heightAnchor.constraint(equalToConstant: 130),
            accessTitle.topAnchor.constraint(equalTo: attachScroll.bottomAnchor, constant: 8),
            accessTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            accessTitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            accessScroll.topAnchor.constraint(equalTo: accessTitle.bottomAnchor, constant: 4),
            accessScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            accessScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            accessScroll.heightAnchor.constraint(equalToConstant: 96),
            status.topAnchor.constraint(equalTo: accessScroll.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            sendButton.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
            sendButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            close.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            discard.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
            discard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
        ])
    }

    private func fill() {
        textView.string = draft.text
        attachmentsBox.subviews.forEach { $0.removeFromSuperview() }
        checkboxes = [:]
        var y: CGFloat = 0
        let rowWidth: CGFloat = 600
        let list = draft.attachments
        for attachment in list.reversed() {
            let row = NSView(frame: NSRect(x: 0, y: y, width: rowWidth, height: attachment.isImage ? 76 : 28))
            var x: CGFloat = 0
            if attachment.isImage {
                let image = NSImageView(frame: NSRect(x: 0, y: 4, width: 96, height: 68))
                image.imageScaling = .scaleProportionallyUpOrDown
                loadImage?(attachment) { [weak image] loaded in image?.image = loaded }
                row.addSubview(image)
                x = 104
            }
            let label = NSTextField(labelWithString: "\(attachment.name) · \(MyzelRender.byteCount(attachment.bytes))")
            label.font = AppFonts.mono(size: 11.5)
            label.frame = NSRect(x: x, y: row.frame.height / 2 - 9, width: 300, height: 18)
            label.lineBreakMode = .byTruncatingMiddle
            row.addSubview(label)
            let open = NSButton(title: "Öffnen", target: self, action: #selector(openClicked(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(attachment.id)
            open.bezelStyle = .rounded
            open.controlSize = .small
            open.frame = NSRect(x: x + 306, y: row.frame.height / 2 - 12, width: 76, height: 24)
            row.addSubview(open)
            if attachment.pruefen == true {
                let box = NSButton(checkboxWithTitle: "geprüft, darf mit", target: self, action: #selector(checkChanged))
                box.frame = NSRect(x: x + 388, y: row.frame.height / 2 - 10, width: 150, height: 20)
                box.isEnabled = opened.contains(attachment.id)
                box.toolTip = "Großer Anhang (> 2 MB): erst öffnen und ansehen, dann abhaken."
                row.addSubview(box)
                checkboxes[attachment.id] = box
            }
            attachmentsBox.addSubview(row)
            y += row.frame.height + 4
        }
        if list.isEmpty {
            let none = NSTextField(labelWithString: "Keine Anhänge.")
            none.textColor = .secondaryLabelColor
            none.frame = NSRect(x: 0, y: 0, width: 200, height: 18)
            attachmentsBox.addSubview(none)
            y = 20
        }
        attachmentsBox.frame = NSRect(x: 0, y: 0, width: rowWidth, height: max(y, 20))
        let hint = draft.needsConfirmation.isEmpty ? "" : "Große Anhänge gehen nur mit, wenn du sie geöffnet und abgehakt hast."
        showStatus(hint, error: false)
        refreshSend()
    }

    private var confirmed: Set<String> {
        Set(checkboxes.filter { $0.value.state == .on }.map(\.key))
    }

    private func refreshSend() {
        sendButton.isEnabled = draft.missing(confirmed: confirmed).isEmpty
    }

    @objc private func checkChanged() { refreshSend() }

    @objc private func openClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let attachment = draft.attachments.first(where: { $0.id == id }) else { return }
        openAttachment?(attachment)
    }

    @objc private func sendClicked() {
        guard draft.missing(confirmed: confirmed).isEmpty else { return NSSound.beep() }
        onAction?(.send(text: textView.string, confirmed: confirmed))
    }

    @objc private func discardClicked() { onAction?(.discard) }
    @objc private func closeClicked() { onAction?(.close) }
}
