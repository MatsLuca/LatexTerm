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
    static let fontSizeKey = "LatexTerm.fontSize"
    static let defaultFontSize: CGFloat = 13
    static let minFontSize: CGFloat = 6
    static let maxFontSize: CGFloat = 48
    /// Schriftgröße ist global: eine Kachel ändert sie, alle übernehmen sie (Cmd ±/0
    /// wirkt damit gleichzeitig über alle Splits). userInfo["size"] = neue Größe.
    static let fontDidChange = Notification.Name("LatexTerm.fontDidChange")

    private var fontObserver: NSObjectProtocol?

    let overlay = OverlayHost()
    var onRangeChanged: (() -> Void)?
    /// Reiner Scroll: Inhalt unverändert, nur neu positionieren → Sofort-Pfad ohne Debounce.
    var onScrolled: (() -> Void)?
    /// Cmd+T: neue Terminal-Kachel rechts anlegen.
    var onSplitRequested: (() -> Void)?
    /// Cmd+W: diese Kachel schließen (Shell beenden).
    var onCloseRequested: (() -> Void)?
    /// Cmd+1…9: auf so viele Kacheln auffüllen (nur erweitern, nie schließen).
    var onEnsurePaneCount: ((Int) -> Void)?
    /// Fokus-Änderung an den Kachel-Controller melden.
    var onFocusChanged: ((Bool) -> Void)?

    /// Zuletzt via AX gesetzter Text (für read-back durch Dictation-Apps wie SuperWhisper).
    /// Siehe Accessibility-Block weiter unten.
    private var lastAXInsertedValue: String = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        notifyUpdateChanges = true
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        font = NSFont.monospacedSystemFont(ofSize: Self.storedFontSize(), weight: .regular)
        // Größenänderung einer beliebigen Kachel auch hier anwenden → alle synchron.
        fontObserver = NotificationCenter.default.addObserver(
            forName: Self.fontDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let size = note.userInfo?["size"] as? CGFloat else { return }
            self.applyFont(size: size)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onRangeChanged?()
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
    private func currentWorkingDirectory() -> String? {
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

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScrolled?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard mods.subtracting(.shift) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let a = event.charactersIgnoringModifiers ?? ""
        let b = event.characters ?? ""
        if (a == "t" || b == "t"), !mods.contains(.shift) {
            onSplitRequested?(); return true
        }
        if (a == "w" || b == "w"), !mods.contains(.shift) {
            // performKeyEquivalent wird in View-Reihenfolge durchgereicht (älteste Kachel
            // zuerst). Nur die tatsächlich fokussierte Kachel darf sich schließen – sonst
            // an die nächste weiterreichen, bis die fokussierte dran ist.
            let fr = window?.firstResponder
            let focused = (fr === self) || ((fr as? NSView)?.isDescendant(of: self) ?? false)
            if focused { onCloseRequested?(); return true }
            return super.performKeyEquivalent(with: event)
        }
        if let d = Int(a) ?? Int(b), (1...9).contains(d), !mods.contains(.shift) {
            onEnsurePaneCount?(d); return true
        }
        if a == "+" || b == "+" || a == "=" || b == "=" {
            adjustFont(by: +1); return true
        }
        if a == "-" || b == "-" {
            adjustFont(by: -1); return true
        }
        if a == "0" || b == "0" {
            setFont(size: Self.defaultFontSize); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func cellSize() -> CGSize {
        return lineCellSize
    }

    private static func storedFontSize() -> CGFloat {
        let v = UserDefaults.standard.double(forKey: fontSizeKey)
        guard v > 0 else { return defaultFontSize }
        return CGFloat(min(max(v, Double(minFontSize)), Double(maxFontSize)))
    }

    private func adjustFont(by delta: CGFloat) {
        let new = max(Self.minFontSize, min(Self.maxFontSize, font.pointSize + delta))
        setFont(size: new)
    }

    /// Vom Shortcut ausgelöst: global persistieren und an alle Kacheln broadcasten
    /// (inkl. dieser – die Übernahme passiert im `fontDidChange`-Observer via `applyFont`).
    private func setFont(size: CGFloat) {
        guard size != font.pointSize else { return }
        UserDefaults.standard.set(Double(size), forKey: Self.fontSizeKey)
        NotificationCenter.default.post(
            name: Self.fontDidChange, object: nil, userInfo: ["size": size]
        )
    }

    /// Wendet eine Größe lokal an (vom Broadcast) und scannt die Overlays neu.
    private func applyFont(size: CGFloat) {
        guard size != font.pointSize else { return }
        font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        onRangeChanged?()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChanged?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChanged?(false) }
        return ok
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
