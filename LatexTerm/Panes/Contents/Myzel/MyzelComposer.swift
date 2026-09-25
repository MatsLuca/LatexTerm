import AppKit
import UniformTypeIdentifiers

/// Eingabe unten in der Myzel-Kachel: Text (⏎ sendet, ⇧⏎ neue Zeile), @-Vorschläge (⇥ übernimmt), Antwort-Leiste,
/// Anhänge (📎, Ziehen, Einfügen). Senden ist immer ein bewusster Tastendruck oder Klick des Menschen.
final class MyzelComposerView: NSView, NSTextViewDelegate {
    struct Pending: Equatable {
        let localID: UUID
        let name: String
        /// nil, solange der Upload läuft.
        var uploaded: MyzelAttachment?
    }

    let input = MyzelInputText()
    private let scroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "Nachricht … (⏎ senden, ⇧⏎ neue Zeile, @ erwähnt)")
    private let sendButton = LineButton(title: "Senden", hint: "⏎")
    private let attachButton = LineButton(title: "📎")
    private let replyLabel = NSTextField(labelWithString: "")
    private let replyClose = LineButton(title: "×")
    private let line = NSView()
    private var suggestionButtons: [LineButton] = []
    private var pendingButtons: [LineButton] = []
    private var theme = ThemeStore.shared.theme

    private(set) var suggestions: [String] = []
    private var suggestionRange: NSRange?
    private(set) var replyTo: (id: String, label: String)?
    private(set) var pending: [Pending] = []
    var busy = false { didSet { refreshSendState() } }

    var participantIDs: [String] = []
    var me: String?
    var onSend: ((String) -> Void)?
    var onAttach: (([URL]) -> Void)?
    var onAttachData: ((Data, String) -> Void)?
    var onRemovePending: ((UUID) -> Void)?
    var onHeightChange: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = input
        input.delegate = self
        input.composer = self
        placeholder.font = LineStyle.font(12, .regular)
        replyLabel.font = LineStyle.font(11, .regular)
        replyLabel.lineBreakMode = .byTruncatingTail
        replyClose.onClick = { [weak self] in self?.setReply(nil) }
        sendButton.onClick = { [weak self] in self?.submit() }
        attachButton.toolTip = "Datei anhängen (PNG, JPEG, WebP, PDF, TXT, MD; bis 20 MB, 5 je Nachricht)"
        attachButton.onClick = { [weak self] in self?.chooseFiles() }
        line.wantsLayer = true
        [line, scroll, placeholder, sendButton, attachButton, replyLabel, replyClose].forEach(addSubview)
        registerForDraggedTypes([.fileURL])
        refreshSendState()
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Klick irgendwo in die Eingabezeile → ins Feld.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(input) }

    func applyTheme(_ theme: TerminalTheme) {
        self.theme = theme
        input.applyTheme(theme)
        placeholder.textColor = theme.foreground.withAlphaComponent(LineStyle.faint)
        replyLabel.textColor = theme.foreground.withAlphaComponent(LineStyle.text)
        line.layer?.backgroundColor = theme.foreground.withAlphaComponent(LineStyle.divider).cgColor
        sendButton.accent = ThemeStore.shared.accentColor
        needsLayout = true
    }

    // MARK: Zustand

    var text: String { input.string }

    func clear() {
        input.string = ""
        setReply(nil)
        closeSuggestions()
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func append(_ text: String) {
        let joined = input.string.isEmpty ? text : input.string + (input.string.hasSuffix("\n") ? "" : "\n") + text
        input.string = joined
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func setReply(_ reply: (id: String, label: String)?) {
        replyTo = reply
        replyLabel.stringValue = reply.map { "↳ Antwort auf \($0.label)" } ?? ""
        relayoutAndNotify()
    }

    func setPending(_ list: [Pending]) {
        pending = list
        pendingButtons.forEach { $0.removeFromSuperview() }
        pendingButtons = list.map { item in
            let button = LineButton(title: "📎 \(item.name)", hint: item.uploaded == nil ? "lädt …" : "×")
            button.toolTip = item.uploaded.map { "\($0.name) · \(MyzelRender.byteCount($0.bytes)) — Klick entfernt" } ?? "wird hochgeladen"
            button.onClick = { [weak self] in self?.onRemovePending?(item.localID) }
            addSubview(button)
            return button
        }
        refreshSendState()
        relayoutAndNotify()
    }

    private func refreshSendState() {
        let ready = !busy && pending.allSatisfy { $0.uploaded != nil }
            && MyzelCompose.canSend(text: input.string, attachments: pending.count)
        sendButton.alphaValue = ready ? 1 : 0.4
    }

    private func submit() {
        guard !busy, pending.allSatisfy({ $0.uploaded != nil }),
              MyzelCompose.canSend(text: input.string, attachments: pending.count) else { NSSound.beep(); return }
        onSend?(input.string)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .webP, .pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.message = "Anhänge für die nächste Nachricht"
        guard panel.runModal() == .OK else { return }
        onAttach?(panel.urls)
    }

    // MARK: @-Vorschläge

    private func updateSuggestions() {
        let cursor = input.selectedRange().location
        guard input.selectedRange().length == 0,
              let found = MyzelCompose.mentionPrefix(in: input.string, cursor: cursor) else { return closeSuggestions() }
        let list = Array(MyzelCompose.completions(found.partial, among: participantIDs, excluding: me).prefix(6))
        guard !list.isEmpty else { return closeSuggestions() }
        suggestions = list
        suggestionRange = found.range
        suggestionButtons.forEach { $0.removeFromSuperview() }
        suggestionButtons = list.enumerated().map { index, id in
            let button = LineButton(title: "@\(id)", hint: index == 0 ? "⇥" : nil)
            button.onClick = { [weak self] in self?.accept(id) }
            addSubview(button)
            return button
        }
        relayoutAndNotify()
    }

    func closeSuggestions() {
        guard !suggestions.isEmpty || !suggestionButtons.isEmpty else { return }
        suggestions = []
        suggestionRange = nil
        suggestionButtons.forEach { $0.removeFromSuperview() }
        suggestionButtons = []
        relayoutAndNotify()
    }

    private func accept(_ id: String) {
        guard let range = suggestionRange else { return }
        input.insertText("@\(id) ", replacementRange: range)
        closeSuggestions()
        window?.makeFirstResponder(input)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !input.string.isEmpty
        refreshSendState()
        updateSuggestions()
        relayoutAndNotify()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if !suggestions.isEmpty { updateSuggestions() }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else if let first = suggestions.first {
                accept(first)
            } else {
                submit()
            }
            return true
        case #selector(insertTab(_:)):
            guard let first = suggestions.first else { return false }
            accept(first)
            return true
        case #selector(cancelOperation(_:)):
            if !suggestions.isEmpty { closeSuggestions(); return true }
            if replyTo != nil { setReply(nil); return true }
            return false
        default:
            return false
        }
    }

    // MARK: Ziehen & Ablegen

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onAttach?(urls)
        return true
    }

    func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: Layout

    private static let lineHeight: CGFloat = 17

    var preferredHeight: CGFloat {
        var h: CGFloat = 10
        if replyTo != nil { h += 20 }
        if !suggestionButtons.isEmpty { h += LineStyle.tabHeight + 2 }
        if !pendingButtons.isEmpty { h += LineStyle.tabHeight + 2 }
        h += inputHeight + 10
        return h
    }

    private var inputHeight: CGFloat {
        guard let layout = input.layoutManager, let container = input.textContainer else { return Self.lineHeight + 8 }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        return min(max(used, Self.lineHeight), Self.lineHeight * 8) + 8
    }

    private var lastHeight: CGFloat = 0

    private func relayoutAndNotify() {
        needsLayout = true
        let h = preferredHeight
        if h != lastHeight { lastHeight = h; onHeightChange?() }
    }

    override func layout() {
        super.layout()
        let x: CGFloat = 14
        let w = bounds.width
        line.frame = NSRect(x: 0, y: 0, width: w, height: 1)
        var y: CGFloat = 8
        replyLabel.isHidden = replyTo == nil
        replyClose.isHidden = replyTo == nil
        if replyTo != nil {
            replyLabel.frame = NSRect(x: x, y: y + 1, width: w - 2 * x - 24, height: 16)
            replyClose.frame = NSRect(x: w - x - 20, y: y - 3, width: replyClose.intrinsicContentSize.width, height: LineStyle.tabHeight)
            y += 20
        }
        if !suggestionButtons.isEmpty {
            var bx = x - 5
            for button in suggestionButtons {
                let bw = button.intrinsicContentSize.width
                button.frame = NSRect(x: bx, y: y, width: bw, height: LineStyle.tabHeight)
                bx += bw + 2
            }
            y += LineStyle.tabHeight + 2
        }
        if !pendingButtons.isEmpty {
            var bx = x - 5
            for button in pendingButtons {
                let bw = min(button.intrinsicContentSize.width, 260)
                button.frame = NSRect(x: bx, y: y, width: bw, height: LineStyle.tabHeight)
                bx += bw + 2
            }
            y += LineStyle.tabHeight + 2
        }
        let sendW = sendButton.intrinsicContentSize.width
        let attachW = attachButton.intrinsicContentSize.width
        let fieldW = max(60, w - 2 * x - sendW - attachW - 12)
        let h = inputHeight
        scroll.frame = NSRect(x: x, y: y, width: fieldW, height: h)
        input.minSize = NSSize(width: fieldW, height: h)
        input.frame.size.width = fieldW
        input.textContainer?.containerSize = NSSize(width: fieldW, height: .greatestFiniteMagnitude)
        placeholder.frame = NSRect(x: x + 4, y: y + 4, width: fieldW - 8, height: 17)
        let by = y + h - LineStyle.tabHeight - 2
        attachButton.frame = NSRect(x: x + fieldW + 6, y: by, width: attachW, height: LineStyle.tabHeight)
        sendButton.frame = NSRect(x: attachButton.frame.maxX + 2, y: by, width: sendW, height: LineStyle.tabHeight)
    }
}

/// Eingabefeld: nur Klartext; Einfügen von Dateien/Bildern wird zum Anhang statt zu Text.
final class MyzelInputText: NSTextView {
    weak var composer: MyzelComposerView?

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = NSSize(width: 2, height: 4)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 2
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        font = LineStyle.font(12, .regular)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    func applyTheme(_ theme: TerminalTheme) {
        font = LineStyle.font(12, .regular)
        textColor = theme.foreground.withAlphaComponent(LineStyle.textFocused)
        insertionPointColor = ThemeStore.shared.accentColor
        typingAttributes = [.font: LineStyle.font(12, .regular), .foregroundColor: theme.foreground.withAlphaComponent(LineStyle.textFocused)]
    }

    override func paste(_ sender: Any?) {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            composer?.onAttach?(urls)
            return
        }
        if board.string(forType: .string) == nil, let image = NSImage(pasteboard: board),
           let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            composer?.onAttachData?(png, "Einfügung.png")
            return
        }
        pasteAsPlainText(sender)
    }
}
