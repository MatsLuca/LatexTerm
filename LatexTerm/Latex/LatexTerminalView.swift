import AppKit
import SwiftTerm

final class OverlayHost: NSView {
    override var isFlipped: Bool { true }

    /// Standardmäßig komplett klick-durchlässig (Terminal bekommt Selektion/Scroll).
    /// Ausnahme: Treffer INNERHALB eines interaktiven Subviews – z.B. die Buttons des
    /// gepinnten Formel-Panels – werden durchgelassen, damit sie Klicks bekommen.
    /// Klicks auf leere Fläche liefern `self` aus `super.hitTest` und bleiben durchlässig.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return (hit !== self) ? hit : nil
    }

    /// Hover-Tracking für den Formel-Vorschau-Modus. Liefert nur mouseMoved/Exited;
    /// Klicks/Selektion bleiben über hitTest==nil beim Terminal.
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    private var trackingRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingRef { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(t)
        trackingRef = t
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onMouseExited?()
    }
}

final class LatexTerminalView: LocalProcessTerminalView {
    /// Schrift (Familie + Größe) kommt aus `ThemeStore` — global, eine Kachel ändert per
    /// ⌘±/0, alle übernehmen über `ThemeStore.didChange(.font)`.
    private var fontObserver: NSObjectProtocol?

    let overlay = OverlayHost()
    /// Inhalt geändert: `startY..endY` ist der von SwiftTerm gemeldete (viewport-relative)
    /// Änderungsbereich → inkrementeller Rescan.
    var onRangeChanged: ((_ startY: Int, _ endY: Int) -> Void)?
    /// Geometrie/Konfiguration geändert (z.B. Schriftgröße) → voller Rescan nötig.
    var onNeedsFullRescan: (() -> Void)?
    /// Reiner Scroll: Inhalt unverändert, nur neu positionieren → Sofort-Pfad ohne Debounce.
    var onScrolled: (() -> Void)?
    /// BEL (\a) vom Kindprozess — Claude Codes Standard-Notification-Kanal
    /// (`preferredNotifChannel: terminal_bell`), präziser Sofort-Auslöser für #30.
    var onBell: (() -> Void)?

    /// Zuletzt via AX gesetzter Text (für read-back durch Dictation-Apps wie SuperWhisper).
    /// Siehe Accessibility-Block weiter unten.
    private var lastAXInsertedValue: String = ""

    /// ⌘F-Suchleiste im Stil „Linie“ (23.09.2026) — derselbe Baustein wie in Vorschau/Web, statt der AppKit-Leiste
    /// des SwiftTerm-Forks (Vibrancy, Checkboxen). Sucht live beim Tippen, ⏎/⇧⏎ springen, Esc schließt.
    private lazy var lineFind: PreviewFindBar = {
        let bar = PreviewFindBar(placeholder: "Im Terminal suchen")
        bar.addToggle("Aa", tooltip: "Groß-/Kleinschreibung beachten") { [weak self] on in self?.findOptions.caseSensitive = on; self?.refind() }
        bar.addToggle(".*", tooltip: "Regulärer Ausdruck") { [weak self] on in self?.findOptions.regex = on; self?.refind() }
        bar.addToggle("Wort", tooltip: "Nur ganze Wörter") { [weak self] on in self?.findOptions.wholeWord = on; self?.refind() }
        bar.onChange = { [weak self] _ in self?.refind() }
        bar.onSearch = { [weak self] text, backwards in self?.runFind(text, backwards: backwards) }
        bar.onClose = { [weak self] in self?.hideLineFind() }
        bar.applyTheme(ThemeStore.shared.theme)
        addSubview(bar)
        return bar
    }()
    private var findOptions = SearchOptions()

    /// ⌘F: Leiste zeigen, mit Auswahl vorbelegt.
    func showLineFind() {
        let selected = getSelection() ?? ""
        lineFind.show(text: selected.contains("\n") ? "" : selected)
        lineFind.applyTheme(ThemeStore.shared.theme)
        window?.makeFirstResponder(lineFind.field)
        refind()
    }

    private func hideLineFind() {
        lineFind.hide()
        clearSearch()
        window?.makeFirstResponder(self)
    }

    private func refind() {
        let text = lineFind.field.stringValue
        clearSearch()
        guard !text.isEmpty else { lineFind.setCount(""); return }
        lineFind.setCount(findPrevious(text, options: findOptions) ? "" : "keine Treffer")
    }

    private func runFind(_ text: String, backwards: Bool) {
        guard !text.isEmpty else { return }
        let found = backwards ? findPrevious(text, options: findOptions) : findNext(text, options: findOptions)
        lineFind.setCount(found ? "" : "keine Treffer")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !lineFind.isHidden { lineFind.layoutIn(bounds) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        notifyUpdateChanges = true
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        font = AppFonts.mono(size: ThemeStore.shared.fontSize)
        fontObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, note.userInfo?[ThemeStore.changeKey] as? ThemeStore.Change == .font else { return }
            self.applyFont(size: ThemeStore.shared.fontSize)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onRangeChanged?(startY, endY)
    }

    /// Kommt vom Parse-Pfad — für UI-Konsumenten auf den Main-Runloop heben.
    override func bell(source: Terminal) {
        super.bell(source: source)
        DispatchQueue.main.async { [weak self] in self?.onBell?() }
    }

    // MARK: - Link-Öffnen (Cmd-Klick)
    //
    // Cmd-Klick auf einen Link (OSC-8-Hyperlink oder implizit erkannte URL) landet hier.
    // SwiftTerms Default macht stumpf `URL(string:)` + `NSWorkspace.open` — bei einem
    // RELATIVEN Pfad (wie ihn Claude Code & Co. oft als Link ausgeben, z.B.
    // `Vorschussantrag_42_SGBI_2026-06/`) ergibt das eine relative URL, die der Finder
    // nicht öffnen kann → Dialog "Programm kann nicht geöffnet werden, -50".
    // Wir lösen Datei-Links daher selbst auf: file://-URLs entpacken, relative Pfade
    // gegen das per OSC 7 gemeldete Arbeitsverzeichnis auflösen, ~ expandieren, Existenz
    // prüfen und erst dann öffnen. Echte Web-/Sonstige-Schemes (http, https, mailto …)
    // gehen unverändert ans System.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let raw = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Nicht-Datei-URLs mit Schema direkt ans System geben.
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty, scheme != "file" {
            NSWorkspace.shared.open(url)
            return
        }

        // file://-URL oder schemenloser Pfad → selbst auflösen.
        if let path = resolveFilePath(raw) {
            openFile(atPath: path)
        } else if let url = URL(string: raw) {
            NSWorkspace.shared.open(url) // Fallback
        } else {
            NSSound.beep()
        }
    }

    /// Wandelt einen Link (file://-URL, absoluter, ~- oder relativer Pfad) in einen
    /// konkreten Dateipfad. Relative Pfade werden gegen das Arbeitsverzeichnis (OSC 7)
    /// aufgelöst; nil, wenn das nicht möglich ist.
    private func resolveFilePath(_ link: String) -> String? {
        var s = link

        // "file://…" abstreifen. file:///abs → "/abs"; file://host/abs → "/abs".
        if let r = s.range(of: "file://", options: [.caseInsensitive, .anchored]) {
            s = String(s[r.upperBound...])
            if !s.hasPrefix("/"), let slash = s.firstIndex(of: "/") {
                s = String(s[slash...]) // Authority (host) verwerfen
            }
        }
        s = s.removingPercentEncoding ?? s
        guard !s.isEmpty else { return nil }

        if s.hasPrefix("/") { return s }
        if s.hasPrefix("~") { return (s as NSString).expandingTildeInPath }

        // Relativ → gegen das aktuelle Arbeitsverzeichnis auflösen.
        guard let cwd = currentWorkingDirectory() else { return nil }
        return (cwd as NSString).appendingPathComponent(s)
    }

    /// Das per OSC 7 gemeldete Arbeitsverzeichnis als nackter Dateipfad (typ.
    /// "file://host/Users/…"), oder nil wenn (noch) keines gemeldet wurde.
    /// Intern sichtbar: ⌘T-CWD-Vererbung (#8) und Session-Restore lesen es.
    func currentWorkingDirectory() -> String? {
        guard let raw = getTerminal().hostCurrentDirectory else { return nil }
        if let url = URL(string: raw), url.isFileURL { return url.path }
        return raw.hasPrefix("/") ? raw : nil
    }

    /// Öffnet einen existierenden Pfad (Ordner → Finder, Datei → Standard-App).
    /// Existiert er nicht, kurz piepen statt den kryptischen Finder-Fehler -50.
    private func openFile(atPath path: String) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Appearance-/Theme-Wechsel zur Laufzeit sofort an die Overlays pushen (#12):
    /// rescan() liest Terminal-Hintergrund & Co. frisch und sendet bei Änderung ein
    /// setConfig() (restylt alle Formel-Divs ohne KaTeX-Rebuild). Ohne diesen Trigger
    /// fror der Overlay-Hintergrund bis zum nächsten Output-Rescan ein. Die App
    /// erzwingt aktuell Dark + feste Farben — der Pfad greift, sobald echtes
    /// Theming existiert, und kostet bis dahin nichts.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onNeedsFullRescan?()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScrolled?()
    }

    /// Terminal-eigene Kürzel. Die Kachel-Kürzel (⌘T/⌘W/⌘1–9/⌘⏎) verteilt die Hülle
    /// (`PaneContainerView`); sie reicht Tasten nur an den Inhalt der fokussierten Kachel
    /// weiter. Esc bleibt bewusst frei — das gehört vim/TUIs/Claude Code.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.subtracting(.shift) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let a = event.charactersIgnoringModifiers ?? ""
        let b = event.characters ?? ""
        if (a == "f" || b == "f"), !mods.contains(.shift) {
            // ⌘F: Suchleiste (#9) — nur wenn das Terminal selbst den Fokus hat: unter einer
            // Home-Ansicht liegt es ungestartet in derselben Kachel und bekäme sonst eine
            // unsichtbare Leiste. Die Leiste (Fork: TerminalFindBarView) übernimmt Enter/Esc.
            let fr = window?.firstResponder
            let focused = (fr === self) || ((fr as? NSView)?.isDescendant(of: self) ?? false)
            if focused { showLineFind(); return true }
            return super.performKeyEquivalent(with: event)
        }
        // ⌘⇧+/−/0 gehören dem Zeilenabstand-Menü. Shift ist nur beim `=`-Zeichen
        // toleriert: auf US-Layouts ist ⌘+ physisch ⌘⇧= — auf Layouts mit
        // ungeshiftetem `+` (deutsch) ist ⌘⇧+ dagegen eine bewusst andere Kombi
        // und darf hier nicht als Schriftgröße verschluckt werden.
        let shifted = mods.contains(.shift)
        if a == "=" || b == "=" || (!shifted && (a == "+" || b == "+")) {
            adjustFont(by: +1); return true
        }
        if !shifted, a == "-" || b == "-" {
            adjustFont(by: -1); return true
        }
        if !shifted, a == "0" || b == "0" {
            ThemeStore.shared.fontSize = ThemeStore.defaultFontSize; return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func cellSize() -> CGSize {
        return lineCellSize
    }

    /// ⌘±: global über den Store (der clampt und broadcastet, `applyFont` übernimmt hier).
    private func adjustFont(by delta: CGFloat) {
        ThemeStore.shared.fontSize += delta
    }

    /// Wendet Größe + gewählte Familie lokal an (vom Broadcast) und scannt die Overlays neu.
    private func applyFont(size: CGFloat) {
        let desired = AppFonts.mono(size: size)
        guard desired.fontName != font.fontName || size != font.pointSize else { return }
        font = desired
        onNeedsFullRescan?()
    }

    // MARK: - Accessibility (Dictation-Support, z.B. SuperWhisper)
    //
    // SwiftTerm's `TerminalView` exponiert keine Text-Rolle, deshalb sehen
    // Diktier-Apps via AX kein gültiges Textziel und behandeln das Einfügen als
    // fehlgeschlagen → ihr Overlay bleibt nach dem Paste stehen. Wir melden uns
    // als `AXTextArea`. Wenn die App den Text via AX-Value setzt, schreiben wir
    // ihn direkt in die PTY und merken ihn für den Read-Back, damit die App den
    // Insert als erfolgreich verifizieren kann.

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { "terminal" }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityValue() -> Any? { lastAXInsertedValue }
    override func accessibilityNumberOfCharacters() -> Int { lastAXInsertedValue.count }
    override func accessibilitySelectedText() -> String? { "" }
    override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: lastAXInsertedValue.count, length: 0)
    }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: lastAXInsertedValue.count)
    }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let str = accessibilityValue as? String, !str.isEmpty else { return }
        lastAXInsertedValue = str
        send(txt: str)
    }

    override func setAccessibilitySelectedText(_ accessibilitySelectedText: String?) {
        guard let str = accessibilitySelectedText, !str.isEmpty else { return }
        lastAXInsertedValue = str
        send(txt: str)
    }

    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == #selector(setAccessibilityValue(_:)) { return true }
        if selector == #selector(setAccessibilitySelectedText(_:)) { return true }
        return super.isAccessibilitySelectorAllowed(selector)
    }
}
