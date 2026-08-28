import AppKit
import os
import SwiftTerm

/// Äußere Hülle einer Terminal-Kachel: trägt abgerundete Ecken, Fokus-Rahmen und
/// Dimmung und hält den Terminal-Inhalt per Innenabstand von der Kante weg —
/// SwiftTerm zeichnet ab x=0, ohne Inset klebte der Text Pixel an Pixel am Rahmen.
/// Das Inset lebt bewusst HIER statt im Fork: Zeichnen, Maus-Koordinaten und die
/// Overlay-Grid→Pixel-Mathematik nehmen alle den Terminal-Ursprung 0 an.
final class PaneContainerView: NSView {
    /// Innenabstand aus den Darstellungs-Einstellungen (`ThemeStore.padding`, Runde 28).
    static var contentInset: CGFloat { ThemeStore.shared.padding }
    override var isFlipped: Bool { true }

    /// Schwebende Live-Status-Pille (#25 v2) oben rechts — liegt ÜBER dem
    /// Terminal-Inhalt (zPosition) und ist vom Innen-Layout ausgenommen:
    /// die Fill-Loops unten würden sie sonst auf Kachelgröße aufblasen.
    let statusBadge = PaneStatusBadgeView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(statusBadge)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Pille oben rechts verankern (flipped: y wächst nach unten).
    func layoutStatusBadge() {
        statusBadge.frame.origin = NSPoint(
            x: bounds.width - statusBadge.frame.width - Self.contentInset - 6,
            y: Self.contentInset + 6)
    }

    /// Ziel einer laufenden (animierten) Umsortierung. Solange gesetzt, ignorieren
    /// die per Animations-Tick eintrudelnden Zwischengrößen die Subviews.
    private var pinnedTargetSize: NSSize?

    /// Terminal SOFORT auf die Ziel-Geometrie der Umsortierung setzen; die Hülle
    /// animiert hinterher und gibt den Inhalt progressiv frei (masksToBounds).
    /// Ohne das Pinning setzte `animator().frame` den Frame pro Animations-Tick
    /// (~13× in 0,22s) → ebenso viele PTY-Resizes: SwiftTerm reflowt bei JEDER
    /// Spaltenänderung den kompletten Scrollback (verlustbehaftet über
    /// Zwischenbreiten!), und laufende TUIs zeichnen bei jeder Zwischenbreite neu —
    /// deren Fragmente vermüllen den Scrollback dauerhaft.
    func pinContent(forTargetSize target: NSSize) {
        let inner = NSRect(origin: .zero, size: target)
            .insetBy(dx: Self.contentInset, dy: Self.contentInset)
        guard inner.width > 0, inner.height > 0 else { pinnedTargetSize = nil; return }
        pinnedTargetSize = target
        for sub in subviews where !(sub is PaneStatusBadgeView) { sub.frame = inner }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Die Pille folgt jeder Zwischengröße (gleitet in der Animation mit).
        layoutStatusBadge()
        if let target = pinnedTargetSize {
            // Zwischengröße der Animation → Inhalt steht schon auf dem Ziel.
            // Ziel erreicht → Pin lösen (jede Umsortierung pinnt ohnehin neu).
            if newSize == target { pinnedTargetSize = nil }
            return
        }
        // Direkter Frame-Set außerhalb einer Umsortierung (Robustheits-Fallback):
        // synchron mitziehen, damit der Inhalt der Hülle nie einen Tick hinterherläuft.
        let inner = bounds.insetBy(dx: Self.contentInset, dy: Self.contentInset)
        guard inner.width > 0, inner.height > 0 else { return }
        for sub in subviews where !(sub is PaneStatusBadgeView) { sub.frame = inner }
    }
}

/// Eine einzelne Terminal-Kachel: eigener Shell-Prozess, eigener OverlayController
/// (= eigene LaTeX-Overlays). Mehrere Panes leben nebeneinander in `TerminalSplitView`.
/// Übernimmt die Rolle, die früher der `TerminalContainer.Coordinator` für das einzelne
/// Terminal hatte (Process-Delegate + Settings-Observer + Shell-Spawn).
final class TerminalPane: NSObject, LocalProcessTerminalViewDelegate {

    /// Stabile Identität der Pane über UI-Umbauten hinweg — Notifications (#30)
    /// referenzieren die Ziel-Pane darüber (der Klick kommt Sekunden später,
    /// wenn Indizes längst verschoben sein können).
    let id = UUID()

    /// Passiv erkannter Zustand der Claude-Code-Session in dieser Pane (#30).
    /// `none` = kein CC-typisches UI im Blick (nackte Shell, fremde TUI).
    enum SessionState { case none, working, awaitingInput }

    let view: LatexTerminalView
    /// Von der Split-View gemountete/layoutete Hülle; `view` (das Terminal) lebt darin.
    let container: PaneContainerView
    private let controller: OverlayController
    private var themeObserver: NSObjectProtocol?
    /// Aktueller Fokus-Zustand (vom `onFocusChanged`-Callback gepflegt).
    private var hasFocus = false
    /// Fokus-Rahmen nur zeigen, wenn es mehrere Kacheln gibt — bei einer einzelnen
    /// umrandet er nur das ganze Fenster und erklärt nichts. Setzt die Split-View.
    var showsFocusBorder = true {
        didSet { if showsFocusBorder != oldValue { applyFocusStyle(animated: false) } }
    }
    /// Diese Kachel füllt das ganze Fenster — gezoomt (#26) ODER die einzige
    /// Kachel: voller Akzent-Rahmen statt Fokus-Abstufung, der Rahmen ist dann
    /// die Session-Farbkennung des Fensters. Setzt die Split-View.
    var fillsWindow = false {
        didSet { if fillsWindow != oldValue { applyFocusStyle(animated: false) } }
    }

    /// Private OSC-Sequenz für In-Band-Steuerung dieser Pane (#24, Fundament für #25/#27):
    /// `printf '\e]5522;accent=#RRGGBB\a'` in der Pane-Shell setzt die Akzentfarbe.
    /// In-Band statt Socket/Env-Var: reist durch die PTY der Pane → per-Pane by
    /// construction, funktioniert durch SSH, keine Integrations-Infra nötig.
    static let controlOscCode = 5522

    /// Per-Pane-Akzent-Override (OSC `accent=…`): überstimmt die globale Akzentfarbe
    /// für Caret/Fokus-Rahmen DIESER Kachel bis `accent=reset` oder Pane-Ende.
    private var accentOverride: NSColor? {
        didSet { applyAccent(); applyFocusStyle(animated: false) }
    }
    /// Passiv erkannte TUI-Rahmenfarbe dieser Kachel (#24): Claude Code & Co.
    /// zeichnen ihre Box-Rahmen (`╭────╮`) in der Session-Akzentfarbe. Nur aktiv
    /// im adaptiven Modus; schwächer als ein expliziter OSC-Override.
    private var borderAccent: NSColor? {
        didSet { applyAccent(); applyFocusStyle(animated: false) }
    }
    /// Wirksame Akzentfarbe dieser Kachel: OSC-Override > erkannter Rahmen > global.
    var effectiveAccent: NSColor { accentOverride ?? borderAccent ?? ThemeStore.shared.accentColor }
    /// Pane-EIGENE Farbe (Override oder erkannt) — nil, wenn die Kachel nur der
    /// globalen Farbe folgt. Steuert Hüll-Tint und Session-Persistierung.
    var paneAccent: NSColor? { accentOverride ?? borderAccent }
    /// Optik dieser Kachel hat sich geändert (Akzent/Fokus) → Titlebar-HUD & Co.
    var onStyleChanged: (() -> Void)?

    /// Bestätigter Session-Zustand (#30) — Schreibzugriff nur über
    /// `registerSessionScan` (Hysterese). UI (HUD-Puls) liest hier.
    private(set) var sessionState: SessionState = .none {
        didSet {
            guard sessionState != oldValue else { return }
            // Session vorbei/unbekannt → kein veralteter Tool-Name beim nächsten Start.
            if sessionState == .none { statusDetail = nil }
            updateStatusBadge()
            onStyleChanged?()
        }
    }
    /// Live-Status-Detail aus dem Hook-Kanal (#25 v2), z. B. der Tool-Name aus
    /// dem PreToolUse-Hook. Nur die Hooks liefern es — die passive Erkennung
    /// kennt keins (Badge zeigt dann den generischen Zustandstext).
    private var statusDetail: String? {
        didSet { if statusDetail != oldValue { updateStatusBadge() } }
    }

    /// Text der Kachel-Pille aus Zustand + Detail ableiten. nil = Pille weg.
    private func updateStatusBadge() {
        let text: String?
        switch sessionState {
        case .none: text = nil
        case .working: text = statusDetail ?? "arbeitet…"
        case .awaitingInput: text = statusDetail ?? "braucht Input"
        }
        container.statusBadge.update(text: text, accent: effectiveAccent,
                                     pulsing: sessionState == .working)
        container.layoutStatusBadge()
    }
    /// Feuert bei BESTÄTIGTEM Übergang working→awaitingInput — der Moment,
    /// in dem eine unbeobachtete Session Aufmerksamkeit braucht (#27 v1).
    var onSessionAwaitingInput: ((TerminalPane) -> Void)?
    /// Natives Aufmerksamkeits-Signal des Kindprozesses (BEL bzw. OSC 777) —
    /// Claude Codes eigener Notification-Kanal, Sofort-Auslöser ohne Hysterese.
    /// title/body sind nur beim OSC-777-Pfad gefüllt.
    var onAttentionSignal: ((TerminalPane, _ title: String?, _ body: String?) -> Void)?

    /// Shell-Prozess beendet → diese Pane soll entfernt werden.
    var onClosed: ((TerminalPane) -> Void)?
    /// Cmd+T in dieser Pane → neue Pane anlegen.
    var onSplitRequested: ((TerminalPane) -> Void)?
    /// Cmd+W in dieser Pane → schließen.
    var onCloseRequested: ((TerminalPane) -> Void)?
    /// Cmd+1…9 in dieser Pane → auf so viele Kacheln auffüllen.
    var onEnsurePaneCount: ((Int) -> Void)?
    /// Cmd+⏎ in dieser Pane → Zoom-Toggle (#26).
    var onZoomRequested: ((TerminalPane) -> Void)?

    // MARK: Home-Kachel (Projekt-Launcher)

    /// Liegt über dem noch nicht gestarteten Terminal; `launch` ersetzt sie durch die Shell.
    private(set) var homeView: HomePaneView?
    /// Erst `start()` spawnt die Shell — eine Home-Kachel hat keinen Prozess.
    private(set) var isStarted = false
    var isHome: Bool { homeView != nil }
    /// Was den Tastaturfokus dieser Kachel trägt: Terminal oder Home-Ansicht.
    var focusTarget: NSView { homeView?.keyView ?? view }

    /// Kachel als Home-Kachel zeigen (statt Shell). `otherPanes` liefert die Kopfzeile
    /// mit dem Status der übrigen Kacheln.
    func showHome(otherPanes: @escaping () -> [(String, String)], focusPane: @escaping (String) -> Void) {
        guard !isStarted, homeView == nil else { return }
        let home = HomePaneView(frame: container.bounds)
        home.autoresizingMask = [.width, .height]
        home.otherPanes = otherPanes
        home.onFocusPane = focusPane
        home.onLaunch = { [weak self] req in
            self?.launch(in: req.path, command: req.command, label: req.label,
                         followUps: [req.colorFollowUp, req.followUp].compactMap { $0 },
                         accent: req.accent, accentName: req.accentName)
        }
        home.resolveAccentName = { [weak self] wanted, alternatives, palette in
            self?.resolveLaunchAccentName?(wanted, alternatives, palette) ?? wanted
        }
        home.onClose = { [weak self] in
            guard let self else { return }
            self.onCloseRequested?(self)
        }
        home.onZoom = { [weak self] in
            guard let self else { return }
            self.onZoomRequested?(self)
        }
        home.onFocusChanged = { [weak self] focused in
            guard let self else { return }
            self.hasFocus = focused
            self.applyFocusStyle(animated: true)
            if focused { self.view.window?.title = "LatexTerm — Projekte" }
        }
        container.addSubview(home)
        homeView = home
    }

    /// Home → Terminal: Shell in `directory` starten und `command` tippen (Kernel puffert,
    /// die Shell liest es nach dem Prompt — gleicher Pfad wie `new-pane --exec`).
    func launch(in directory: String, command: String?, label: String? = nil, followUps: [String] = [],
                accent: NSColor? = nil, accentName: String? = nil) {
        guard !isStarted else { return }   // ein Prozess pro Kachel — kein zweiter Start ins laufende Terminal
        // Projektfarbe (Runde 25): vor dem Start setzen, damit Ring, Rahmen und HUD-Punkt von der
        // ersten Sekunde an die Session-Farbe tragen — dieselbe Palette, in der Claude seine Box malt.
        // Bewusst in den „erkannt"-Slot, nicht als OSC-Override: tippt Mats später von Hand /color,
        // zieht die passive Rahmenerkennung die Kachel nach — Box und Rahmen bleiben eins.
        if let accent { borderAccent = accent }
        self.accentName = accentName
        start(in: directory)
        guard let command, !command.isEmpty, let home = homeView else {
            // Nur Shell: sofort zeigen.
            homeView?.removeFromSuperview(); homeView = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.view.window?.makeFirstResponder(self.view)
            }
            return
        }
        // Claude-Start: Home-Ansicht bleibt als Vorhang liegen, bis die Session wirklich steht
        // (Hook-Status / passive Erkennung), höchstens 12 s — der User sieht weder das getippte
        // Kommando noch Plugin-Sync und Ladezeilen. Der Ring im Vorhang füllt sich gegen die
        // erwartete Dauer (Mittel der letzten echten Starts).
        home.beginLaunch(label ?? "Claude", eta: Self.launchEta, accent: effectiveAccent)
        // Start-Timer: T0 = dieser Tastendruck, als Umgebung vor das Kommando (zsh exportiert
        // Zuweisungen vor einem Funktionsaufruf an dessen Kinder). Der SessionStart-Hook
        // hooks/start-timer.sh (mats-tools) rechnet daraus die Phasen und loggt sie; wir
        // hängen unten die Vorhang-Zeit (bis reveal, Grund) an dasselbe Log.
        let t0 = Int(Date().timeIntervalSince1970 * 1000)
        launchReady = false
        view.send(txt: "MATS_START_T0=\(t0) " + command + "\r")
        let started = Date()
        launchTimer?.invalidate()
        launchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            // `status=ready` aus dem SessionStart-Hook ist das eigentliche Signal; die passive
            // Grid-Erkennung (sessionState) bleibt Fallback, dann harter Timeout.
            let ready = self.launchReady || self.sessionState != .none
            let timeout = Date().timeIntervalSince(started) > 12
            guard ready || timeout else { return }
            t.invalidate()
            self.launchTimer = nil
            let curtain = Date().timeIntervalSince(started)
            if ready { Self.recordLaunch(curtain) }
            self.revealTerminal(success: ready)
            Self.startTimerLog(t0: t0, curtain: curtain,
                               reason: self.launchReady ? "signal" : (ready ? "passiv" : "timeout"))
            // Folgebefehle (z. B. /color, /compact): Text in die Claude-TUI, Enter separat nach 1 s —
            // ein mitgesendetes Enter wird beim Paste geschluckt (Regel aus dem latexterm-Skill).
            // Mehrere nacheinander im 2-s-Takt, damit jeder Befehl vor dem nächsten verarbeitet ist.
            if ready {
                for (i, followUp) in followUps.filter({ !$0.isEmpty }).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + 2.0 * Double(i)) { [weak self] in
                        self?.view.send(txt: followUp)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.view.send(txt: "\r") }
                    }
                }
            }
        }
    }
    private var launchTimer: Timer?
    /// `status=ready` vom SessionStart-Hook (settings.json) ist angekommen — Session steht.
    private var launchReady = false
    /// Claude-Code-Farbname dieser Kachel (Runde 25) — Kollisionsschutz der Split-View liest ihn.
    private(set) var accentName: String?
    /// Split-View: (gewünschter Name, Alternativen, Palette) → vergebener Name (frei unter den offenen Kacheln).
    var resolveLaunchAccentName: ((String, [String], [String]) -> String)?

    // MARK: Erwartete Startdauer (für den Ring im Vorhang)

    private static let launchEtaKey = "LatexTerm.launchEtaMs"
    /// Gleitender Mittelwert der letzten echten Starts (nur Signal/passiv, nie Timeout);
    /// Erstwert 1,4 s. Persistiert, damit der erste Start nach App-Neustart schon passt.
    static var launchEta: TimeInterval {
        let ms = UserDefaults.standard.double(forKey: launchEtaKey)
        return ms > 0 ? ms / 1000 : 1.4
    }
    private static func recordLaunch(_ curtain: TimeInterval) {
        let clamped = min(max(curtain, 0.4), 8)
        let next = UserDefaults.standard.double(forKey: launchEtaKey) > 0
            ? 0.6 * launchEta + 0.4 * clamped
            : clamped
        UserDefaults.standard.set(Int(next * 1000), forKey: launchEtaKey)
    }

    /// Vorhang-Zeile ins Start-Timer-Log (gleiches Log wie hooks/start-timer.sh; t0 verknüpft beide).
    private static func startTimerLog(t0: Int, curtain: TimeInterval, reason: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".cache/mats-tools")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("start-timer.log")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  t0=\(t0) vorhang=\(Int(curtain * 1000)) grund=\(reason)  (LatexTerm: Tastendruck bis Vorhang weg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }

    /// Vorhang weg: Fokus sofort ans Terminal (Tasten landen ab jetzt bei Claude), die
    /// Home-Ansicht schließt ihren Ring (bei Erfolg) und blendet dann aus.
    private func revealTerminal(success: Bool) {
        guard let home = homeView else { return }
        homeView = nil
        view.window?.makeFirstResponder(view)
        home.finishLaunch(success: success) { home.removeFromSuperview() }
    }

    /// Theme auf eine Terminal-Ansicht legen. Opaker Hintergrund ist Pflicht: die
    /// Formel-Overlays maskieren den Quelltext mit einer volldeckenden Box in genau dieser
    /// Farbe (Alpha wird in OverlayController.css verworfen); wäre der Terminal-BG
    /// transluzent, erschiene die Maske dunkler als die Umgebung. Vibrancy bleibt in den
    /// Kachel-Stegen (`TerminalTheme.gap`).
    static func applyTheme(_ theme: TerminalTheme, to term: LatexTerminalView) {
        let store = ThemeStore.shared
        term.installColors(theme.swiftTermPalette)
        term.nativeForegroundColor = theme.foreground.withAlphaComponent(1)
        term.nativeBackgroundColor = theme.background.withAlphaComponent(1)
        term.selectedTextBackgroundColor = theme.selectionBackground
        term.useBrightColors = store.boldIsBright
        term.fontSmoothing = store.fontThicken
        term.getTerminal().setCursorStyle(store.cursorBlink ? .blinkBlock : .steadyBlock)
    }

    /// Theme-Wechsel zur Laufzeit: Terminal, Hülle und Home-Kachel nachziehen.
    private func applyTheme() {
        let theme = ThemeStore.shared.theme
        Self.applyTheme(theme, to: view)
        // Padding-Änderung: Inhalt neu einpassen (setFrameSize rechnet den Inset frisch).
        container.setFrameSize(container.frame.size)
        applyAccent()   // Hüll-Tint auf dem neuen Grund, Caret (Akzent oder Theme-Cursor)
        applyFocusStyle(animated: false)   // Rahmen an/aus
        updateRainbowTimer()
        homeView?.applyTheme(theme)
        view.needsDisplay = true
    }

    override init() {
        let store = ThemeStore.shared
        let term = LatexTerminalView(frame: .zero)
        // Farben, Palette, Cursor, Auswahl: alles aus dem Theme (Runde 26) — siehe applyTheme().
        // 256-Farben nach xterm-Würfel wie in jedem anderen Emulator, nicht LAB-interpoliert
        // aus den 16 Basisfarben (SwiftTerm-Default) — sonst sähe Claude Codes TUI hier
        // anders aus als in Ghostty. Vor installColors setzen, das baut die Tabelle neu.
        term.getTerminal().options.ansi256PaletteStrategy = .xterm
        Self.applyTheme(ThemeStore.shared.theme, to: term)
        term.caretColor = store.accentColor
        term.extraLineSpacing = store.lineSpacing

        // Kachel-Styling (Ecken/Rahmen/Dimmung) liegt auf der Container-Hülle;
        // ihr Hintergrund füllt das Content-Inset in der Terminal-Farbe auf.
        let box = PaneContainerView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.masksToBounds = true
        box.layer?.backgroundColor = term.nativeBackgroundColor.cgColor
        box.layer?.borderWidth = 0
        box.layer?.borderColor = store.accentColor.withAlphaComponent(0.65).cgColor
        // Kachel ist standardmäßig inaktiv (abgedunkelt), bis sie fokussiert wird
        box.alphaValue = store.focusDimming ? 0.65 : 1.0
        box.addSubview(term)

        self.view = term
        self.container = box
        self.controller = OverlayController(terminal: term)
        super.init()

        // Fokus-Visualisierung
        term.onFocusChanged = { [weak self] focused in
            guard let self else { return }
            self.hasFocus = focused
            self.applyFocusStyle(animated: true)
            // Fokuswechsel übernimmt den zuletzt von DIESER Shell gemeldeten Titel (#21).
            if focused { self.applyStoredTitle() }
        }

        term.processDelegate = self
        term.onRangeChanged = { [weak self, weak controller] startY, endY in
            controller?.scheduleRescan(dirtyStart: startY, dirtyEnd: endY)
            self?.scheduleContrastAnalysis()
            self?.updatePromptBox()
        }
        term.onNeedsFullRescan = { [weak controller] in controller?.scheduleRescan() }
        // Prompt-Tint (experimentell): Standard-FG-Zellen in den Box-Zeilen stylen.
        term.cellStyleOverride = { [weak self] row, col, isDefaultFg in
            guard let self, let box = self.promptBoxAbsolute, box.contains(row) else { return nil }
            let store = ThemeStore.shared
            guard store.promptTintMode != .off else { return nil }
            if !isDefaultFg {
                // Von Claude gefärbt (Slash-Command, @-Erwähnung, Marker ❯): nur auf Wunsch übersteuern,
                // und nie die Marker-Spalten 0–1 (Nutzertext beginnt in Claude Code bei Spalte 2).
                guard store.promptOverrideColored, col >= 2 else { return nil }
                if store.promptColoredOwnColor {
                    return CellStyleOverride(color: store.promptColoredColor, glow: store.promptGlow)
                }
            }
            let color: NSColor
            switch store.promptTintMode {
            case .off: return nil
            case .accent: color = self.effectiveAccent
            case .custom: color = store.promptColor
            case .rainbow:
                // Farbverlauf über die Spalten (ein Zyklus je 28 Zellen), Phase läuft über den Timer.
                let hue = ((CGFloat(col) + self.rainbowPhase) / 28).truncatingRemainder(dividingBy: 1)
                color = NSColor(hue: hue < 0 ? hue + 1 : hue, saturation: 0.85, brightness: 1.0, alpha: 1)
            }
            return CellStyleOverride(color: color, glow: store.promptGlow)
        }
        term.onScrolled = { [weak controller] in controller?.scheduleReposition() }
        term.onSplitRequested = { [weak self] in
            guard let self else { return }
            self.onSplitRequested?(self)
        }
        term.onCloseRequested = { [weak self] in
            guard let self else { return }
            self.onCloseRequested?(self)
        }
        term.onEnsurePaneCount = { [weak self] n in self?.onEnsurePaneCount?(n) }
        term.onZoomRequested = { [weak self] in
            guard let self else { return }
            self.onZoomRequested?(self)
        }

        // In-Band-Steuerkanal (#24). Der Parser läuft auf dem Feed-Pfad —
        // UI-Änderungen sicherheitshalber auf den Main-Runloop verschieben.
        term.getTerminal().registerOscHandler(code: Self.controlOscCode) { [weak self] data in
            let payload = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.handleControlSequence(payload) }
        }

        // Claude Codes NATIVE Notification-Kanäle (#30): BEL (`terminal_bell`,
        // der Default) und OSC 777 (`notify;title;body`). Beide sind der präzise
        // Sofort-Auslöser; die passive Grid-Erkennung bleibt Fallback + Status.
        term.onBell = { [weak self] in
            guard let self else { return }
#if DEBUG
            Self.statusLog("BELL")
#endif
            self.onAttentionSignal?(self, nil, nil)
        }
        // Eigene Registrierung überschreibt SwiftTerms eingebauten 777-Handler
        // (der nur an den ungenutzten TerminalDelegate weiterreicht).
        term.getTerminal().registerOscHandler(code: 777) { [weak self] data in
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                let parts = text.components(separatedBy: ";")
                guard parts.count >= 2, parts[0] == "notify" else { return }
                let body = parts.count > 2 ? parts[2...].joined(separator: ";") : nil
                self.onAttentionSignal?(self, parts[1], body)
            }
        }

        // Darstellungs-Änderungen, nach Art gefiltert: das volle Theme-Installieren nur, wenn
        // Theme/Grund-Schalter sich ändern — nicht bei jeder (adaptiv gesetzten) Akzentfarbe.
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self, weak term] note in
            guard let self, let change = note.userInfo?[ThemeStore.changeKey] as? ThemeStore.Change else { return }
            let store = ThemeStore.shared
            switch change {
            case .theme, .appearance:
                self.applyTheme()
            case .font:
                break   // LatexTerminalView übernimmt selbst (applyFont)
            case .lineSpacing:
                term?.extraLineSpacing = store.lineSpacing
                term?.onNeedsFullRescan?()
            case .accent:
                // Globale Akzent-Änderungen nur anwenden, wo kein OSC-Override liegt
                // (applyAccent respektiert den Override von selbst).
                self.applyAccent()
            case .adaptiveAccent:
                // Nur wenn der Modus selbst eingeschaltet wurde, sofort analysieren —
                // sonst stieße jede (adaptiv gesetzte) accentColor-Änderung gleich die
                // nächste Analyse an.
                if store.isAdaptiveAccent {
                    self.scheduleContrastAnalysis()
                } else {
                    // Adaptiv aus → auch die passiv erkannte Rahmenfarbe loslassen,
                    // die Kachel folgt wieder der manuellen globalen Farbe.
                    self.borderAccent = nil
                    self.applyAccent()
                }
            case .prompt:
                self.updateRainbowTimer()
                self.view.needsDisplay = true
            case .panes:
                self.applyAccent()
                self.applyFocusStyle(animated: true)
            }
        }
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        rainbowTimer?.invalidate()
    }

    /// Verarbeitet eine OSC-5522-Payload (`key=value`; das Format ist bewusst
    /// erweiterbar — #25 Live-Status und #27 Notifications sollen denselben Kanal
    /// nutzen). Unbekannte Keys/kaputte Payloads werden still ignoriert: die
    /// Sequenz kommt aus untrusted Programm-Output (siehe SECURITY.md).
    private func handleControlSequence(_ payload: String) {
        let parts = payload.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "accent":
            if parts[1] == "reset" {
                accentOverride = nil
            } else if let color = NSColor(srgbHex: String(parts[1])) {
                accentOverride = color
            }
        case "status":
            applyHookStatus(String(parts[1]))
        default:
            break
        }
    }

    /// Hook-getriebener Session-Status (#27 Vollausbau): `status=<working|input|done|ready>[;detail]`
    /// über den 5522-Kanal — präzise Events aus Claude-Code-Hooks statt Grid-Heuristik.
    /// Setzt den Zustand OHNE Hysterese (der Hook weiß es sicher); die passive
    /// Erkennung läuft weiter und bestätigt ihn beim nächsten Scan von selbst.
    /// Notifications laufen über den bestehenden `onAttentionSignal`-Pfad
    /// (unbeobachtet-Check + 5-s-Cooldown sitzen dort). `done` setzt bewusst
    /// `.none`: der anschließend sichtbaren Eingabe-Box darf die passive
    /// Erkennung NICHT „working→awaitingInput" unterstellen (ihr Notification-
    /// Trigger verlangt old == .working, .none → .awaitingInput bleibt stumm).
    private func applyHookStatus(_ value: String) {
        let pieces = value.split(separator: ";", maxSplits: 1)
        guard let state = pieces.first else { return }
        // Detail kommt aus untrusted Programm-Output und landet als Klartext in
        // Badge + Notification: Steuerzeichen raus, Länge gedeckelt, leer = nil.
        var detail = pieces.count > 1
            ? String(pieces[1].prefix(200)).filter { ch in
                !ch.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
            }
            : nil
        if detail?.isEmpty == true { detail = nil }
        pendingSessionScans = 0
#if DEBUG
        Self.statusLog("HOOK status=\(state) detail=\(detail ?? "-")")
#endif
        switch state {
        case "working":
            lastHookStatusAt = Date()
            sessionState = .working
            statusDetail = detail          // nil (z. B. UserPromptSubmit) löscht bewusst
        case "input":
            lastHookStatusAt = Date()
            sessionState = .awaitingInput
            statusDetail = detail
            onAttentionSignal?(self, "Claude braucht Input", detail)
        case "done":
            lastHookStatusAt = Date()
            sessionState = .none           // räumt statusDetail im didSet mit ab
            onAttentionSignal?(self, "Claude ist fertig", detail)
        case "ready":
            // SessionStart-Hook: Session steht, wartet auf die erste Eingabe. Hebt nur den
            // Home-Vorhang (launch) — kein Zustand, keine Pille, keine Notification. Erneuert
            // die Hook-Frist, damit der Grid-Rater der frischen Eingabe-Box nichts unterstellt.
            lastHookStatusAt = Date()
            launchReady = true
        default:
            break                          // unbekannter/kaputter Status erneuert NICHT
        }
    }

    /// Caret, Rahmenfarbe und Hüll-Tint auf die wirksame Akzentfarbe setzen.
    /// Der Tint (Terminal-BG leicht Richtung Akzent) greift nur bei Pane-EIGENER
    /// Farbe — ein globaler Tint auf allen Kacheln gleich würde nichts erklären.
    /// Bewusst nur die Hülle (das 4px-Inset-Band): der Terminal-BG selbst muss
    /// unangetastet bleiben, die Formel-Masken malen exakt in seiner Farbe.
    private func applyAccent() {
        view.caretColor = ThemeStore.shared.cursorThemeColor ? ThemeStore.shared.theme.cursor : effectiveAccent
        container.layer?.borderColor = effectiveAccent.withAlphaComponent(0.65).cgColor
        let bg = view.nativeBackgroundColor
        let hull = ThemeStore.shared.paneBorders
            ? (paneAccent.flatMap { bg.blended(withFraction: 0.12, of: $0) } ?? bg) : bg
        container.layer?.backgroundColor = hull.cgColor
        updateStatusBadge()   // Pille trägt die Akzentfarbe mit (#25 v2)
        onStyleChanged?()
    }

    /// Dimmung immer. Rahmen bei ≥2 Kacheln (`showsFocusBorder`) auf JEDER Kachel
    /// in ihrer Akzentfarbe (Session-Identität auf einen Blick) — die fokussierte
    /// kräftiger und dicker, unfokussierte dünn und zurückgenommen.
    private func applyFocusStyle(animated: Bool) {
        let alpha: CGFloat = (hasFocus || !ThemeStore.shared.focusDimming) ? 1.0 : 0.65
        // Fenster-füllend (gezoomt oder einzige Kachel): voller Akzent — der
        // Rahmen IST dann die Session-Kennung; sonst Fokus-Abstufung im Grid.
        var borderWidth: CGFloat = fillsWindow ? 2.0 : (showsFocusBorder ? (hasFocus ? 1.5 : 1.0) : 0)
        if !ThemeStore.shared.paneBorders { borderWidth = 0 }   // Darstellung → „Kachel-Akzentrahmen“ aus
        let borderColor = effectiveAccent.withAlphaComponent(
            fillsWindow ? 1.0 : (hasFocus ? 0.65 : 0.35)).cgColor
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                container.animator().alphaValue = alpha
                container.layer?.borderColor = borderColor
                container.layer?.borderWidth = borderWidth
            }
        } else {
            container.alphaValue = alpha
            container.layer?.borderColor = borderColor
            container.layer?.borderWidth = borderWidth
        }
        onStyleChanged?()
    }

    private var contrastPending = false

    /// Ist diese Kachel gerade fokussiert (First Responder im oder unterm Terminal-View)?
    private var isFocused: Bool {
        let fr = container.window?.firstResponder
        return (fr === view) || ((fr as? NSView)?.isDescendant(of: container) ?? false)
    }

    /// 0,3-s-Sammelticker für alle billigen Grid-Scans (Rahmenfarbe #24,
    /// Session-Status #30); die teure Pixel-Analyse behält darin ihren
    /// 1,8-s-Mindestabstand über `lastPixelAnalysis`.
    func scheduleContrastAnalysis() {
        if contrastPending { return }
        contrastPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.contrastPending = false
            // Session-Status (#30) läuft IMMER — unabhängig vom Adaptiv-Modus.
            self.registerSessionScan(self.detectSessionState())
            // Akzent-Detektion nur im adaptiven Modus; eine explizit per OSC
            // gefärbte Kachel ist autoritativ — sie soll die globale adaptive
            // Farbe weder treiben noch von ihr überschrieben werden.
            guard ThemeStore.shared.isAdaptiveAccent, self.accentOverride == nil else { return }
            // Stufe 1 (per-Pane, läuft für JEDE Kachel — auch unfokussierte CC-
            // Sessions färben ihre eigene Kachel): TUI-Rahmenfarbe aus dem Grid.
            if let border = self.detectBorderAccent() {
                if !(self.borderAccent?.srgbMatches(border) ?? false) {
                    self.borderAccent = border
                }
                return
            }
            // Kein Rahmen im Blick (hochgescrollt, Vollbild-TUI, mitten im
            // Redraw): eine einmal erkannte Farbe STICKY behalten, bis eindeutig
            // eine andere erkannt wird — das Live-Wegkippen beim Scrollen war
            // sichtbar unschön. Zurücksetzen nur über den Adaptiv-Toggle.
            if self.borderAccent != nil { return }
            // Stufe 2 (global): Pixel-Kontrastanalyse — nur die fokussierte
            // Kachel darf die globale Akzentfarbe anpassen!
            let now = CACurrentMediaTime()
            if self.isFocused, now - self.lastPixelAnalysis > 1.8 {
                self.lastPixelAnalysis = now
                self.analyzeContrast()
            }
        }
    }

    /// Zeitpunkt der letzten Pixel-Kontrastanalyse (drosselt Stufe 2 auf den
    /// alten 1,8-s-Takt, während Stufe 1 alle 0,3 s laufen darf).
    private var lastPixelAnalysis: CFTimeInterval = 0

#if DEBUG
    /// Debug-Log der Akzent-Detektion, direkt als Datei (NSLog/os_log sind beim
    /// Standalone-Lauf unpraktisch auszulesen — Verifikations-Workflow, CLAUDE.md).
    private static let accentLogHandle: FileHandle? = {
        let path = "/tmp/latexterm-accent.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private static func accentLog(_ msg: String) {
        guard let data = (msg + "\n").data(using: .utf8) else { return }
        accentLogHandle?.write(data)
    }
#endif

    /// Sucht von unten nach oben (Claude Codes Input-Box liegt am unteren Rand)
    /// nach einer Viewport-Zeile, die überwiegend aus Box-Drawing-Zeichen
    /// (U+2500–U+257F) in EINER gesättigten Vordergrundfarbe besteht — das ist
    /// ein TUI-Rahmen, seine Farbe der Session-Akzent. Anders als die Pixel-
    /// Analyse liest das die exakten Zell-Attribute aus dem Buffer-Grid: kein
    /// Downsampling, kein Diff-Grün-Rauschen (Box-Zeichen kommen in normalem
    /// Output praktisch nicht vor). Graue/ungesättigte Rahmen (CC ohne /color,
    /// Dim-Borders) liefern bewusst nil → Fallback auf die globale Analyse.
    private func detectBorderAccent() -> NSColor? {
        let term = view.getTerminal()
        let cols = term.cols
        guard cols >= 16 else { return nil }
        let minRun = max(8, cols / 2)
#if DEBUG
        var dbg: [String] = []
#endif
        for row in stride(from: term.rows - 1, through: 0, by: -1) {
            guard let line = term.getLine(row: row) else { continue }
            var boxCells = 0
            var fg: Attribute.Color?
            var mixed = false
            for col in 0..<cols {
                let cell = line[col]
                guard let scalar = cell.getCharacter().unicodeScalars.first,
                      (0x2500...0x257F).contains(scalar.value) else { continue }
                boxCells += 1
                let cellFg = cell.attribute.fg
                if fg == nil { fg = cellFg } else if fg != cellFg { mixed = true; break }
            }
#if DEBUG
            if boxCells >= 4 {
                dbg.append("row \(row): box=\(boxCells)/\(minRun) fg=\(fg.map(String.init(describing:)) ?? "-") mixed=\(mixed)")
            }
#endif
            guard !mixed, boxCells >= minRun, let fg else { continue }
            guard let color = nsColor(from: fg, terminal: term),
                  let srgb = color.usingColorSpace(.sRGB),
                  srgb.saturationComponent > 0.25 else {
#if DEBUG
                dbg.append("row \(row): REJECT color/sat fg=\(String(describing: fg))")
#endif
                continue
            }
#if DEBUG
            Self.accentLog("HIT row \(row) fg=\(String(describing: fg)) → \(color)")
#endif
            return color
        }
#if DEBUG
        // Nichts gefunden: welche Nicht-ASCII-Zeichen stehen unten überhaupt im Grid?
        // (Entlarvt Rahmen aus anderen Unicode-Blöcken, z. B. Block-Elemente U+2580–259F.)
        var nonAscii: [String] = []
        outer: for row in stride(from: term.rows - 1, through: max(0, term.rows - 12), by: -1) {
            guard let line = term.getLine(row: row) else { continue }
            for col in 0..<cols {
                if let sc = line[col].getCharacter().unicodeScalars.first, sc.value > 0x7F {
                    nonAscii.append(String(format: "U+%04X", sc.value))
                    if nonAscii.count >= 24 { break outer }
                }
            }
        }
        Self.accentLog("MISS rows=\(term.rows) cols=\(cols)\n  " + dbg.joined(separator: "\n  ")
                       + "\n  nonascii(bottom12): \(nonAscii.joined(separator: " "))")
#endif
        return nil
    }

    // MARK: - Eingabe-Box (Prompt) live lokalisieren

    /// Wie viele Live-Zeilen ab unten der Box-Scan betrachtet (mehrzeilige Eingaben wachsen nach oben).
    private static let promptScanRows = 64
    /// Zuletzt gefundene Box als absolute Buffer-Zeilen (`yBase + liveRow`) — so bleibt sie beim
    /// Scrollen an ihrem Inhalt und verschwindet nicht „mit“, wenn der Nutzer hochscrollt.
    private(set) var promptBoxAbsolute: Range<Int>?

    /// Strukturscan der unteren Live-Zeilen (`PromptBoxLocator`), nach jedem Inhaltswechsel.
    /// Kosten: ≤ 64 Zeilen × Spalten Zeichenvergleiche — im Rauschen des Rescans.
    private func updatePromptBox() {
        let term = view.getTerminal()
        let cols = term.cols
        guard cols >= 8, term.rows > 0 else { setPromptBox(nil); return }
        let first = max(0, term.rows - Self.promptScanRows)
        var rows: [[PromptBoxLocator.Cell]] = []
        rows.reserveCapacity(term.rows - first)
        for row in first..<term.rows {
            guard let line = term.getLiveLine(row: row) else { rows.append(Array(repeating: .init(" "), count: cols)); continue }
            var cells: [PromptBoxLocator.Cell] = []
            cells.reserveCapacity(cols)
            for col in 0..<cols {
                let cd = line[col]
                let isDefault: Bool
                if case .defaultColor = cd.attribute.fg { isDefault = true } else { isDefault = false }
                cells.append(.init(cd.getCharacter(), defaultFg: isDefault))
            }
            rows.append(cells)
        }
        // Erst streng (Linien müssen gefärbt sein — schließt getippte ────-Zeilen aus), sonst locker:
        // sollte Claude Code die Linien einmal in Standard-FG zeichnen, bleibt die Erkennung erhalten.
        guard let box = PromptBoxLocator.locate(rows: rows, requireStyledRules: true)
                ?? PromptBoxLocator.locate(rows: rows, requireStyledRules: false) else { setPromptBox(nil); return }
        let base = term.buffer.yBase + first
        setPromptBox((base + box.contentRows.lowerBound)..<(base + box.contentRows.upperBound))
    }

    /// Regenbogen: Phase (Zellen) und 12-Hz-Timer, nur solange Box + Modus.
    private var rainbowPhase: CGFloat = 0
    private var rainbowTimer: Timer?

    private func updateRainbowTimer() {
        let wanted = ThemeStore.shared.promptTintMode == .rainbow && promptBoxAbsolute != nil
        if wanted, rainbowTimer == nil {
            rainbowTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.rainbowPhase -= 0.4   // 12 Hz × 0,4 Zellen ≈ ein Zyklus (28 Zellen) in ~6 s
                self.view.needsDisplay = true
            }
        } else if !wanted, let t = rainbowTimer {
            t.invalidate(); rainbowTimer = nil
        }
    }

    private func setPromptBox(_ range: Range<Int>?) {
        guard range != promptBoxAbsolute else { return }
        promptBoxAbsolute = range
        if ThemeStore.shared.promptTint { view.needsDisplay = true }
        updateRainbowTimer()
#if DEBUG
        if let r = range {
            Self.statusLog("BOX rows \(r.lowerBound)..<\(r.upperBound) (abs, yBase=\(view.getTerminal().buffer.yBase))")
        } else {
            Self.statusLog("BOX none")
        }
#endif
    }

    // MARK: - Passive Session-Statuserkennung (#30)

    /// Wie viele Zeilen ab live-Bottom der Status-Scan betrachtet. Claude Codes
    /// Spinner-Zeile und Input-Box liegen in den untersten ~6 Zeilen; 12 gibt
    /// Luft für Permission-Dialoge und Todo-Hinweiszeilen.
    private static let statusScanRows = 12

    /// Struktureller Scan der unteren Live-Zeilen (unabhängig von der Scroll-
    /// Position, via `getLiveLine`): Claude Codes Spinner-Zeile trägt immer den
    /// Text „esc to interrupt" = *working*; die Input-/Dialog-Box (Box-Drawing-
    /// Rahmenzeile wie in `detectBorderAccent`, hier aber farb-agnostisch —
    /// auch graue Rahmen zählen) ohne Spinner = *awaitingInput*; keins von
    /// beidem = *none*. Zeichenklassen + festes UI-Vokabular, keine Semantik —
    /// dieselbe Robustheits-Klasse wie die Rahmenfarb-Erkennung (#24).
    /// Claude Codes Spinner-Frames (✻ Thinking… etc.) — kommen in normalem
    /// Terminal-Output praktisch nicht als ERSTES Zeichen einer Zeile vor.
    private static let spinnerGlyphs: Set<Character> = ["·", "✢", "✳", "✶", "✻", "✽", "∗", "*"]

    private func detectSessionState() -> SessionState {
        let term = view.getTerminal()
        let cols = term.cols
        guard cols >= 16 else { return .none }
        let minRun = max(8, cols / 2)
        var sawBorder = false
        for row in stride(from: term.rows - 1, through: max(0, term.rows - Self.statusScanRows), by: -1) {
            guard let line = term.getLiveLine(row: row) else { continue }
            var boxCells = 0
            var text = ""
            text.reserveCapacity(cols)
            for col in 0..<cols {
                let ch = line[col].getCharacter()
                // NULL = leere Zelle (siehe OverlayController.rescan) → Space.
                text.append(ch == "\u{0}" ? " " : ch)
                if let sc = ch.unicodeScalars.first, (0x2500...0x257F).contains(sc.value) {
                    boxCells += 1
                }
            }
            // Working-Anker, zwei unabhängige Signale: (a) der Interrupt-Hinweis
            // (CC setzt ihn zur Laufzeit aus der Keybinding-Tabelle zusammen —
            // „esc/ctrl+c to interrupt", daher nur das stabile Suffix matchen);
            // (b) Spinner-Glyph als erstes Nicht-Space-Zeichen + „…" in der Zeile.
            if text.contains(" to interrupt") { return .working }
            if let first = text.first(where: { $0 != " " }),
               Self.spinnerGlyphs.contains(first), text.contains("…") {
                return .working
            }
            if boxCells >= minRun { sawBorder = true }
        }
        return sawBorder ? .awaitingInput : .none
    }

    /// Roh-Ergebnis des letzten Scans + Zähler für die Hysterese.
    private var pendingSessionState: SessionState = .none
    private var pendingSessionScans = 0

    /// Hook-Vorfahrt (#25 v2): Zeitpunkt des letzten gültigen Hook-Status.
    /// Solange er frisch ist, hat die Session nachweislich Hooks → die passive
    /// Erkennung schweigt komplett (sie funkte sonst dazwischen: Statuslines
    /// mit Box-Zeichen sehen für sie wie der Eingabe-Kasten aus, und Claudes
    /// Zwischenzustände wie „nichts"). Ablaufzeit statt „für immer": bricht
    /// eine Session hart ab (Ctrl+C/Absturz — da feuert kein Stop-Hook),
    /// übernimmt der Rater nach Ablauf wieder und räumt die Pille ab.
    /// Jedes Hook-Signal (auch jeder PreToolUse) erneuert die Frist.
    private var lastHookStatusAt: Date?
    private static let hookStatusLease: TimeInterval = 600

#if DEBUG
    /// Status-Debug-Log analog zum Accent-Log (Verifikations-Workflow, CLAUDE.md).
    private static let statusLogHandle: FileHandle? = {
        let path = "/tmp/latexterm-status.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    static func statusLog(_ msg: String) {
        guard let data = (msg + "\n").data(using: .utf8) else { return }
        statusLogHandle?.write(data)
    }
    /// Letztes geloggtes Roh-Ergebnis — nur Änderungen dumpen, sonst flutet's.
    private var lastLoggedRaw: SessionState?
    /// Untere Live-Zeilen als Text (Ground-Truth-Dump bei Roh-Zustandswechsel).
    private func bottomRowsDump() -> String {
        let term = view.getTerminal()
        var rows: [String] = []
        for row in max(0, term.rows - Self.statusScanRows)..<term.rows {
            guard let line = term.getLiveLine(row: row) else { continue }
            var text = ""
            for col in 0..<term.cols {
                let ch = line[col].getCharacter()
                text.append(ch == "\u{0}" ? " " : ch)
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { rows.append("    [\(row)] \(trimmed.prefix(120))") }
        }
        return rows.joined(separator: "\n")
    }
#endif

    /// Hysterese-Torwächter: nimmt das Roh-Ergebnis jedes 0,3-s-Scans entgegen
    /// und entscheidet, wann `sessionState` wirklich kippt. Wichtig: Scans
    /// laufen nur bei Terminal-Output — wenn Claude fertig ist, kommt nach dem
    /// letzten Redraw KEIN weiterer Output. Wer einen Übergang über mehrere
    /// Scans bestätigen will, muss sich Folge-Scans selbst nachlegen
    /// (`scheduleContrastAnalysis()`), sonst bleibt der Zustand ewig hängen.
    private func registerSessionScan(_ raw: SessionState) {
#if DEBUG
        if raw != lastLoggedRaw {
            lastLoggedRaw = raw
            Self.statusLog("RAW \(raw) (committed=\(sessionState), pending=\(pendingSessionScans))\n" + bottomRowsDump())
        }
#endif
        // Hook-Vorfahrt: frisches Hook-Signal = die Hooks sind die Wahrheit,
        // der Rater hält still (sonst Pillen-Flackern, siehe lastHookStatusAt).
        if let hookAt = lastHookStatusAt, Date().timeIntervalSince(hookAt) < Self.hookStatusLease {
            pendingSessionScans = 0
            return
        }
        guard raw != sessionState else {
            // Beobachtung bestätigt den Ist-Zustand → angefangenen Übergang verwerfen.
            pendingSessionScans = 0
            return
        }
        if raw == pendingSessionState {
            pendingSessionScans += 1
        } else {
            pendingSessionState = raw
            pendingSessionScans = 1
        }
        // Asymmetrische Trägheit: `awaitingInput` löst die Notification aus und
        // muss Redraw-Lücken (Spinner kurz weg) sicher überstehen → 5 Scans
        // (~1,5 s). Rein optische Übergänge (working/none) kippen nach 2.
        let needed = pendingSessionState == .awaitingInput ? 5 : 2
        if pendingSessionScans >= needed {
            let old = sessionState
            sessionState = pendingSessionState
            pendingSessionScans = 0
#if DEBUG
            Self.statusLog("COMMIT \(old) → \(sessionState)")
#endif
            if old == .working && sessionState == .awaitingInput { onSessionAwaitingInput?(self) }
        } else {
            // Scans sind output-getrieben — nach Claudes letztem Redraw kommt
            // keiner mehr von allein. Zum Bestätigen selbst nachlegen.
            scheduleContrastAnalysis()
        }
    }

    /// Zell-Vordergrundfarbe → NSColor. `defaultColor` (Theme-Grau) zählt nicht
    /// als Akzent; 256er-Indizes löst der Fork-Accessor gegen die live Palette auf.
    private func nsColor(from fg: Attribute.Color, terminal: Terminal) -> NSColor? {
        switch fg {
        case .trueColor(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                           blue: CGFloat(b) / 255, alpha: 1)
        case .ansi256(let code):
            guard let c = terminal.ansiColor(code: Int(code)) else { return nil }
            return NSColor(srgbRed: CGFloat(c.red) / 65535, green: CGFloat(c.green) / 65535,
                           blue: CGFloat(c.blue) / 65535, alpha: 1)
        case .defaultColor, .defaultInvertedColor:
            return nil
        }
    }

    /// Skaliert den Terminalinhalt hocheffizient auf 64x64 Pixel herunter, filtert alle
    /// Hintergrundpixel heraus und berechnet den Farbdurchschnitt des reinen Vordergrundtexts.
    private func analyzeContrast() {
        guard ThemeStore.shared.isAdaptiveAccent else { return }
        let bounds = view.bounds
        guard bounds.width > 20, bounds.height > 20 else { return }

        // Wir blenden den Kachelrahmen aus (10% Rand ignorieren)
        let insetRect = bounds.insetBy(dx: bounds.width * 0.1, dy: bounds.height * 0.1)

        guard let bitmapRep = view.bitmapImageRepForCachingDisplay(in: insetRect) else { return }
        view.cacheDisplay(in: insetRect, to: bitmapRep)

        let targetSize = NSSize(width: 64, height: 64)
        guard let smallRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }

        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: smallRep)
        NSGraphicsContext.current = context

        let image = NSImage(size: insetRect.size)
        image.addRepresentation(bitmapRep)
        image.draw(in: NSRect(origin: .zero, size: targetSize),
                   from: NSRect(origin: .zero, size: insetRect.size),
                   operation: .copy,
                   fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        var sampleCount = 0

        // Hintergrundfarbe des Terminals (aus dem Theme) — Pixel nahe daran zählen nicht.
        let (bgR, bgG, bgB) = ThemeStore.shared.theme.backgroundRGB

        for y in 0..<64 {
            for x in 0..<64 {
                if let color = smallRep.colorAt(x: x, y: y) {
                    let r = color.redComponent
                    let g = color.greenComponent
                    let b = color.blueComponent
                    
                    // Distanz zur Hintergrundfarbe berechnen (Anti-Hintergrund-Filter)
                    let rDiff = r - bgR
                    let gDiff = g - bgG
                    let bDiff = b - bgB
                    let dist = sqrt(rDiff*rDiff + gDiff*gDiff + bDiff*bDiff)
                    
                    // Pixel nur werten, wenn es signifikant vom Hintergrund abweicht
                    if dist > 0.08 {
                        totalR += r
                        totalG += g
                        totalB += b
                        sampleCount += 1
                    }
                }
            }
        }

        if sampleCount > 0 {
            let avgR = totalR / CGFloat(sampleCount)
            let avgG = totalG / CGFloat(sampleCount)
            let avgB = totalB / CGFloat(sampleCount)
            let avgColor = NSColor(red: avgR, green: avgG, blue: avgB, alpha: 1.0)
            let bestColor = Self.findBestContrastColor(to: avgColor)

            // Farbraumfest vergleichen: die geladene Akzentfarbe (sRGB) wäre per
            // NSColor-`==` nie gleich einer Palettenfarbe (anderer Farbraum).
            if !ThemeStore.shared.accentColor.srgbMatches(bestColor) {
                ThemeStore.shared.accentColor = bestColor
            }
        }
    }

    /// Kandidaten aus dem Theme (Runde 28) statt der alten Neon-Palette — letzter Eintrag = Vordergrund.
    private static var palette: [NSColor] { ThemeStore.shared.theme.contrastCandidates }

    private static func findBestContrastColor(to baseColor: NSColor) -> NSColor {
        let palette = Self.palette
        let r = baseColor.redComponent
        let g = baseColor.greenComponent
        let b = baseColor.blueComponent
        
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
        let saturation = maxC == 0 ? 0 : delta / maxC
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        
        // Ist der Vordergrund-Text überwiegend Weiß oder Grau?
        let isWhiteOrGrayText = luminance > 0.65 && saturation < 0.20
        
        var bestColor = palette[0]
        var maxDistance: CGFloat = -1
        
        for color in palette {
            // Wenn der Text weiß/grau ist, weiche auf Buntheiten aus
            if isWhiteOrGrayText && color == palette[palette.count - 1] {
                continue
            }
            
            let rDiff = baseColor.redComponent - color.redComponent
            let gDiff = baseColor.greenComponent - color.greenComponent
            let bDiff = baseColor.blueComponent - color.blueComponent
            let dist = sqrt(rDiff*rDiff + gDiff*gDiff + bDiff*bDiff)
            
            if dist > maxDistance {
                maxDistance = dist
                bestColor = color
            }
        }
        return bestColor
    }

    /// Beendet die Shell (SIGTERM). Das Prozess-Ende läuft über `processTerminated`
    /// → `onClosed` und entfernt die Kachel auf demselben Pfad wie ein `exit`.
    func terminate() {
        launchTimer?.invalidate(); launchTimer = nil   // ⌘W mitten im Start: kein Reveal ins Leere
        guard isStarted else { return }   // Home-Kachel hat keinen Prozess
        view.terminate()
    }

    /// Aktuelles Arbeitsverzeichnis dieser Pane (OSC 7), falls die Shell eins gemeldet hat.
    var currentDirectory: String? { view.currentWorkingDirectory() }

    /// Startet die Login-Shell des Users. `directory` (z.B. das CWD der fokussierten
    /// Kachel bei ⌘T, #8) geht als Arbeitsverzeichnis an den KINDPROZESS
    /// (`startProcess(currentDirectory:)`) statt prozessweit an die ganze App (#20).
    /// Nicht (mehr) existierende Verzeichnisse fallen auf Home zurück.
    func start(in directory: String? = nil) {
        let shell = Self.userShell()
        let shellIdiom = "-" + (shell as NSString).lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dir = directory ?? home
        var isDir: ObjCBool = false
        if !(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue) {
            dir = home
        }
        // Pane-Identität für Kindprozesse (#28): Claude-Code-Hooks/-Scripts und das
        // `latexterm`-CLI ordnen sich darüber der richtigen Kachel zu.
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LATEXTERM_PANE_ID=\(id.uuidString)")
        // OSC-7-CWD-Meldung: /etc/zshrc lädt /etc/zshrc_$TERM_PROGRAM — als
        // "Apple_Terminal" bekommt jede zsh Apples update_terminal_cwd-Hook
        // (Basis für ⌘T-CWD-Erbe #8 und `list-panes`-CWD #28) ohne Eingriff in
        // die User-Config. Apples Session-Save-Teil bleibt aus, solange wir
        // KEIN TERM_SESSION_ID setzen — nicht hinzufügen.
        env.append("TERM_PROGRAM=Apple_Terminal")
        isStarted = true
        view.startProcess(executable: shell, environment: env, execName: shellIdiom, currentDirectory: dir)
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        controller.scheduleRescan()
    }
    /// Zuletzt von der Shell dieser Kachel gemeldeter Titel (für Fokuswechsel-Übernahme).
    private var lastTitle = ""

    /// Nur die FOKUSSIERTE Kachel darf den Fenstertitel setzen (#21) — sonst gewinnt
    /// bei mehreren Panes der letzte Schreiber, unabhängig davon, wo man arbeitet.
    /// Unfokussierte Panes merken sich den Titel; der Fokuswechsel holt ihn nach.
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        lastTitle = title
        if isFocused { applyStoredTitle() }
    }

    fileprivate func applyStoredTitle() {
        view.window?.title = lastTitle.isEmpty ? "LatexTerm" : lastTitle
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onClosed?(self)
    }

    private static func userShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else { return "/bin/zsh" }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        // Reiner Out-Pointer: getpwuid_r setzt ihn auf &pwd oder NULL. NULL bei
        // Rückgabewert 0 heißt „kein Eintrag" — pwd ist dann undefiniert.
        var result: UnsafeMutablePointer<passwd>? = nil
        guard getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) == 0, result != nil else {
            return "/bin/zsh"
        }
        let s = String(cString: pwd.pw_shell)
        return s.isEmpty ? "/bin/zsh" : s
    }
}

/// Kachelt beliebig viele `TerminalPane`s in einem automatischen Grid. Cmd+T hängt eine
/// Kachel an, Cmd+W/`exit` entfernt eine; bei jeder Änderung wird neu gekachelt. Die
/// Grid-Form (Reihen × Spalten) wird abhängig von Fensterbreite UND -höhe gewählt, sodass
/// die Zellen einem Ziel-Seitenverhältnis möglichst nahekommen. Reihen sind gleich hoch,
/// jede Reihe teilt die Breite unabhängig auf (Masonry: obere Reihen ggf. eine Spalte mehr).
final class TerminalSplitView: NSView {

    private var panes: [TerminalPane] = []
    /// Gezoomte Kachel (#26): liegt über allen anderen auf voller Fenstergröße.
    /// Das Grid darunter bleibt unangetastet — Entzoomen ist ein normales relayout().
    /// Weak als Robustheitsnetz; jede Grid-Änderung entzoomt ohnehin explizit.
    private weak var zoomedPane: TerminalPane?
    private let vibrancyView = NSVisualEffectView()
    private var isFirstLayout = true
    private var terminateObserver: NSObjectProtocol?
    private var newHomeObserver: NSObjectProtocol?
    private var quickstartObserver: NSObjectProtocol?

    /// Lücke (Steg) zwischen den Kacheln in Punkten.
    private static let gap: CGFloat = 8

    /// Radius, mit dem macOS die UNTEREN Fensterecken rundet — die Kacheln der
    /// untersten Reihe folgen ihm, damit die Akzent-Outline nicht von der
    /// Fenster-Maske beschnitten wird. Kein API dafür; bei sichtbarem Versatz
    /// (macOS-Update) hier nachjustieren.
    private static let windowCornerRadius: CGFloat = 16.5

    /// Farbe des Stegs (aus dem Theme, transluzent), damit die Vibrancy in den Stegen durchschimmert.
    private static var gapColor: NSColor { ThemeStore.shared.theme.gap }
    private var themeObserver: NSObjectProtocol?

    /// Ziel-Seitenverhältnis (Breite/Höhe) einer Kachel. < 1 = leicht hochkant → erlaubt
    /// mehr Spalten nebeneinander, bevor eine Reihe aufgemacht wird. Höher = früher umbrechen.
    /// 0.82 ergibt auf ~3:2-Fenstern: bis 3 nebeneinander, ab 4 → 2×2, dann auffüllen.
    private static let idealCellAspect: CGFloat = 0.82

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.gapColor.cgColor   // scheint in den Kachel-Lücken durch
        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.layer?.backgroundColor = Self.gapColor.cgColor }

        // Session-Restore (#11): letztes Layout (Pane-Anzahl + CWDs) wiederherstellen;
        // ohne/mit korruptem Snapshot startet wie bisher eine Kachel im Home.
        // Erste Kachel = Projekt-Launcher (Mats' Entscheidung 24.08.). Der Session-Snapshot (#11)
        // wird weiter geschrieben, aber nicht mehr als Startlayout benutzt — die Home-Kachel
        // zeigt ohnehin, woran zuletzt gearbeitet wurde.
        addPane(home: true)

        // ⌘N (Menü „Neue Home-Kachel"): nur das Key-Fenster reagiert.
        newHomeObserver = NotificationCenter.default.addObserver(
            forName: .latexTermNewHomePane, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.addPane(home: true)
        }

        // Dock-Menü „Quickstart": neue Home-Kachel im Key-Fenster (ohne Key-Fenster: im ersten
        // sichtbaren) und sofort starten — gleicher Weg wie ein Klick in der Kachel.
        quickstartObserver = NotificationCenter.default.addObserver(
            forName: .latexTermQuickstart, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let q = note.userInfo?["quickstart"] as? ProjekteData.Quickstart, self.window != nil else { return }
            // Key-Fenster, sonst erstes sichtbares, beim Kaltstart das erste überhaupt.
            let target = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first
            guard self.window === target else { return }
            self.runQuickstart(q)
        }

        // Beim Beenden den aktuellen Stand sichern (CWDs werden live ausgelesen).
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.saveSession() }

        // Notification-Klick → Pane fokussieren + zoomen (#30). Der Zugriff
        // setzt zugleich den UNUserNotificationCenter-Delegate früh.
        SessionNotifier.shared.onActivatePane = { [weak self] id in self?.activatePane(id: id) }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        if let newHomeObserver { NotificationCenter.default.removeObserver(newHomeObserver) }
        if let quickstartObserver { NotificationCenter.default.removeObserver(quickstartObserver) }
    }

    /// Quickstart ausführen: eine noch unberührte Home-Kachel (Kaltstart: die einzige) wird
    /// direkt benutzt, sonst entsteht eine neue — gleicher Startweg wie ein Klick in der Kachel.
    func runQuickstart(_ q: ProjekteData.Quickstart) {
        Logger(subsystem: "com.mats.LatexTerm", category: "quickstart").notice("runQuickstart \(q.key, privacy: .public) in \(q.path, privacy: .public); panes \(self.panes.count)")
        QuickstartStore.shared.pending = nil
        let fresh = (panes.count == 1 && panes[0].isHome && !panes[0].isStarted) ? panes[0] : nil
        let pane = fresh ?? addPane(home: true)
        focusPane(pane)
        // Quickstart: nur die Kachelfarbe — der Prompt startet sofort einen Turn, ein getipptes
        // /color würde dort als Eingabe in die Warteschlange fallen.
        pane.launch(in: q.path, command: q.command, label: q.label, accent: q.accent?.nsColor, accentName: q.accent?.name)
    }

    /// Kollisionsschutz für Projektfarben (Runde 25): trägt eine andere offene Kachel den Namen
    /// schon, kommt die erste freie Alternative der Familie dran, danach der Rest der Palette
    /// (ohne red — das bleibt der Hand vorbehalten). Nur für diese Kachel, nichts wird gespeichert.
    private func distinctAccentName(_ wanted: String, alternatives: [String], palette: [String],
                                    excluding me: TerminalPane?) -> String {
        let taken = Set(panes.compactMap { $0 !== me ? $0.accentName : nil })
        let order = [wanted] + alternatives + palette.filter { $0 != "red" }
        return order.first { !taken.contains($0) } ?? wanted
    }

    /// Home-Kacheln sind flüchtig: nur gestartete Shells landen im Snapshot. Sind es
    /// keine, wird nichts gespeichert → nächster Start beginnt wieder mit Home.
    private func saveSession() {
        let started = panes.filter { $0.isStarted }
        SessionStore.save(SessionSnapshot(paneDirectories: started.map { $0.currentDirectory }))
    }

    /// Für die Home-Kachel: (CWD, Claude-Status) aller ANDEREN gestarteten Kacheln — der Baum
    /// markiert Ordner, in denen gerade eine Session läuft.
    private func paneSummary(excluding me: TerminalPane) -> [(String, String)] {
        panes.compactMap { p in
            guard p !== me, p.isStarted, let cwd = p.currentDirectory else { return nil }
            switch p.sessionState {
            case .working: return (cwd, "working")
            case .awaitingInput: return (cwd, "awaitingInput")
            case .none: return (cwd, "none")
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }

        // Kaltstart per URL/Dock-Plugin: die Anforderung kam, bevor es ein Fenster gab.
        if let q = QuickstartStore.shared.pending {
            QuickstartStore.shared.pending = nil
            DispatchQueue.main.async { [weak self] in self?.runQuickstart(q) }
        }

        // Window-Styling für rahmenlosen Premium-Desktop-Blend
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true // Ermöglicht das Verschieben des Fensters am Hintergrund

        // Visual Effect (Vibrancy) einrichten
        vibrancyView.material = .underWindowBackground
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.autoresizingMask = [.width, .height]
        vibrancyView.frame = bounds

        if vibrancyView.superview == nil {
            addSubview(vibrancyView, positioned: .below, relativeTo: nil)
        }

        // Session-Restore legt die Panes VOR dem Fenster-Attach an — HUD nachziehen.
        updateTitlebarHUD()

        // Steuerkanal (#28): dieses Fenster als Ziel für `latexterm`-Kommandos.
        ControlServer.shared.register(self)
    }

    override var isFlipped: Bool { true }   // Reihe 0 oben

    // Frame-Layout: SwiftUI/Autoresizing ändert nur unsere Größe – darauf neu kacheln.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout(animated: false)
    }

    @discardableResult
    func addPane(startingIn directory: String? = nil, home: Bool = false) -> TerminalPane {
        let pane = TerminalPane()
        pane.onClosed = { [weak self] p in self?.removePane(p) }
        // ⌘T: die anfordernde Kachel ist die fokussierte → ihr CWD vererben (#8).
        pane.onSplitRequested = { [weak self] requester in
            self?.addPane(startingIn: requester.currentDirectory)
        }
        pane.onCloseRequested = { [weak self] p in self?.closePane(p) }
        pane.onEnsurePaneCount = { [weak self] n in self?.ensurePaneCount(n) }
        pane.onZoomRequested = { [weak self] p in self?.toggleZoom(p) }
        pane.resolveLaunchAccentName = { [weak self, weak pane] w, alts, pal in self?.distinctAccentName(w, alternatives: alts, palette: pal, excluding: pane) ?? w }
        pane.onStyleChanged = { [weak self] in self?.updateTitlebarHUD() }
        pane.onSessionAwaitingInput = { [weak self] p in self?.notifySessionAwaiting(p) }
        pane.onAttentionSignal = { [weak self] p, title, body in
            self?.notifyAttention(p, title: title, body: body)
        }
        // Grid-Änderung beendet einen aktiven Zoom: die neue Kachel soll sichtbar
        // im Grid entstehen, nicht unsichtbar unter der gezoomten (⌘T/⌘1–9-Policy).
        setZoomedPane(nil)
        panes.append(pane)
        updateTitlebarHUD()
        addSubview(pane.container)
        if home {
            pane.showHome(otherPanes: { [weak self, weak pane] in
                guard let self, let pane else { return [] }
                return self.paneSummary(excluding: pane)
            }, focusPane: { [weak self] cwd in
                guard let self, let target = self.panes.first(where: { $0.isStarted && $0.currentDirectory == cwd }) else { return }
                self.focusPane(target)
            })
        } else {
            pane.start(in: directory)
        }
        updateFocusBorders()
        relayout(animated: true)
        // Fokus erst im nächsten Runloop – der frisch hinzugefügte View ist dann bereit.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(pane.focusTarget) }
        return pane
    }

    /// Cmd+1…9: auf `n` Kacheln auffüllen – nur erweitern, nie schließen.
    func ensurePaneCount(_ n: Int) {
        while panes.count < n { addPane() }
    }

    /// Cmd+W: Shell beenden UND Kachel sofort entfernen. `terminate()` cancelt den
    /// Exit-Monitor, daher feuert hier kein `processTerminated`/`onClosed` – wir müssen
    /// die UI selbst aufräumen (im Gegensatz zum `exit`-Pfad, der über `onClosed` läuft).
    private func closePane(_ pane: TerminalPane) {
        pane.terminate()
        removePane(pane)
    }

    private func removePane(_ pane: TerminalPane) {
        guard let idx = panes.firstIndex(where: { $0 === pane }) else { return }
        // Auch wenn eine ANDERE (verdeckte) Kachel stirbt: das Grid darunter ändert
        // sich — Zoom beenden, damit der Nutzer den neuen Zustand sieht.
        setZoomedPane(nil)
        panes.remove(at: idx)
        updateTitlebarHUD()
        pane.container.removeFromSuperview()
        guard !panes.isEmpty else { window?.close(); return }
        updateFocusBorders()
        relayout(animated: true)
        window?.makeFirstResponder(panes[min(idx, panes.count - 1)].focusTarget)
    }

    /// Rahmen-Regeln: Fokus-Abstufung nur im sichtbaren Grid (≥2 Kacheln, kein
    /// Zoom); eine fenster-füllende Kachel (gezoomt oder einzige) trägt statt-
    /// dessen den vollen Akzent-Rahmen als Session-Kennung (`fillsWindow`).
    private func updateFocusBorders() {
        let multi = panes.count > 1 && zoomedPane == nil
        for pane in panes {
            pane.showsFocusBorder = multi
            pane.fillsWindow = (panes.count == 1) || (pane === zoomedPane)
        }
    }

    // MARK: - Zoom (#26)

    /// ⌘⏎: `pane` über das ganze Fenster ziehen bzw. zurück ins Grid. Kein Umbau
    /// des Grids — nur ein Merker, den relayout() als Sonderfall behandelt.
    /// Einzige Schreibstelle für `zoomedPane`; die Rahmen-Flags der Panes zieht
    /// das (an allen Aufrufstellen folgende) `updateFocusBorders()` nach.
    private func setZoomedPane(_ pane: TerminalPane?) {
        zoomedPane = pane
    }

    private func toggleZoom(_ pane: TerminalPane) {
        guard panes.count > 1 else { return }   // eine Kachel füllt das Fenster eh
        setZoomedPane(zoomedPane === pane ? nil : pane)
        updateFocusBorders()
        updateTitlebarHUD()
        relayout(animated: true)
        window?.makeFirstResponder(pane.focusTarget)
    }

    // MARK: - Titlebar-HUD (Session-Punkte + Zoom-Badge)

    private var titlebarHUD: NSTitlebarAccessoryViewController?
    /// Inhalts-Signatur der aktuellen HUD: Rebuild nur bei ECHTER Änderung.
    /// `onStyleChanged` feuert bei jeder Settings-Notification — ein Rebuild
    /// unter dem Cursor würde sonst gelegentlich Klicks auf die Punkte schlucken.
    private var hudSignature = ""

    /// Leiste rechts in der (transparenten) Titelleiste: ein klickbarer Punkt je
    /// Kachel in ihrer Akzentfarbe (Session-Identität auch im Zoom, wo das Grid
    /// verdeckt ist; Klick fokussiert die Pane) — plus die „⤢ Zoom ⌘⏎"-Pille,
    /// solange gezoomt ist. Accessory-VC statt Subview: kollidiert nicht mit
    /// Terminal-Content/Traffic-Lights. Wird bei jeder Stil-/Struktur-Änderung
    /// komplett neu aufgebaut — eine Handvoll kleiner Views, trivial billig.
    private func updateTitlebarHUD() {
        guard let window else { return }
        let showDots = panes.count > 1
        let showZoom = zoomedPane != nil

        let signature = panes.map {
            "\($0.effectiveAccent.srgbHexString ?? "-")\(isFocused($0) ? "*" : "")"
                + ($0.sessionState == .working ? "~" : "")
        }.joined(separator: ",") + "|zoom:\(showZoom)"
        if signature == hudSignature, titlebarHUD != nil || !(showDots || showZoom) { return }
        hudSignature = signature

        if let hud = titlebarHUD { hud.removeFromParent(); titlebarHUD = nil }
        guard showDots || showZoom else { return }

        var elements: [NSView] = []
        if showDots {
            for pane in panes {
                let focused = isFocused(pane)
                let dot = PaneDotView(color: pane.effectiveAccent, focused: focused,
                                      pulsing: pane.sessionState == .working) { [weak self, weak pane] in
                    guard let self, let pane else { return }
                    self.focusPane(pane)
                }
                dot.toolTip = pane.currentDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }
                elements.append(dot)
            }
        }
        if showZoom, let zoomed = zoomedPane {
            elements.append(Self.makeZoomPill(accent: zoomed.effectiveAccent))
        }

        let spacing: CGFloat = 6
        let contentWidth = elements.reduce(0) { $0 + $1.frame.width }
            + spacing * CGFloat(max(0, elements.count - 1))
        let contentHeight = elements.map(\.frame.height).max() ?? 20
        // Wrapper gibt dem Accessory Höhe (≈ Titlebar) und rechts etwas Luft.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth + 10, height: contentHeight + 8))
        var x: CGFloat = 0
        for element in elements {
            element.frame.origin = NSPoint(x: x, y: ((wrapper.frame.height - element.frame.height) / 2).rounded())
            wrapper.addSubview(element)
            x += element.frame.width + spacing
        }

        let vc = NSTitlebarAccessoryViewController()
        vc.view = wrapper
        vc.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(vc)
        titlebarHUD = vc
    }

    private static func makeZoomPill(accent: NSColor) -> NSView {
        let label = NSTextField(labelWithString: "⤢ Zoom   ⌘⏎")
        label.font = AppFonts.mono(size: 11, weight: .semibold)
        label.textColor = accent
        label.sizeToFit()
        let pill = NSView(frame: NSRect(x: 0, y: 0,
                                        width: label.frame.width + 16,
                                        height: label.frame.height + 6))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        pill.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.cornerRadius = pill.frame.height / 2
        label.frame.origin = NSPoint(x: 8, y: 3)
        pill.addSubview(label)
        return pill
    }

    /// Ist diese Kachel gerade fokussiert (First Responder im/unterm Terminal-View)?
    private func isFocused(_ pane: TerminalPane) -> Bool {
        let fr = window?.firstResponder
        return (fr === pane.view) || ((fr as? NSView)?.isDescendant(of: pane.container) ?? false)
    }

    // MARK: - Session-Status → Notification (#30)

    /// Melden nur, wenn die Session gerade niemand ansieht — App im Hintergrund ODER andere
    /// Kachel fokussiert; Einstellung „Claude → nur wenn unbeobachtet“ (aus = immer).
    private func isUnobserved(_ pane: TerminalPane) -> Bool {
        !CockpitSettings.shared.notifyOnlyUnobserved || !NSApp.isActive || !isFocused(pane)
    }

    /// Bestätigter working→awaitingInput: nur melden, wenn die Session gerade
    /// niemand ansieht — App im Hintergrund ODER andere Kachel fokussiert.
    private func notifySessionAwaiting(_ pane: TerminalPane) {
#if DEBUG
        TerminalPane.statusLog("NOTIFY? passive appActive=\(NSApp.isActive) focused=\(isFocused(pane))")
#endif
        guard isUnobserved(pane) else { return }
        SessionNotifier.shared.notify(paneID: pane.id, title: "Claude braucht Input",
                                      body: pane.currentDirectory.map {
                                          ($0 as NSString).abbreviatingWithTildeInPath
                                      })
    }

    /// Natives Signal (BEL/OSC 777): sofort melden, wenn unbeobachtet. Der
    /// Fallback-Titel nutzt den passiv erkannten Status — eine Glocke in einer
    /// CC-Session heißt „Claude braucht Input", in einer nackten Shell nicht.
    private func notifyAttention(_ pane: TerminalPane, title: String?, body: String?) {
#if DEBUG
        TerminalPane.statusLog("NOTIFY? native title=\(title ?? "-") appActive=\(NSApp.isActive) focused=\(isFocused(pane))")
#endif
        guard isUnobserved(pane) else { return }
        let fallback = pane.sessionState != .none ? "Claude braucht Input" : "Terminal-Glocke"
        let detail = body ?? pane.currentDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }
        SessionNotifier.shared.notify(paneID: pane.id, title: title ?? fallback, body: detail)
    }

    /// Notification-Klick: App nach vorn, Pane fokussieren und (im Grid) zoomen —
    /// der Nutzer will JETZT mit genau dieser Session sprechen.
    private func activatePane(id: UUID) {
        guard let pane = panes.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if panes.count > 1 {
            setZoomedPane(pane)
            updateFocusBorders()
            relayout(animated: true)
        }
        window?.makeFirstResponder(pane.focusTarget)
        updateTitlebarHUD()
    }

    /// Klick auf einen Session-Punkt: Kachel fokussieren. Ist gerade eine ANDERE
    /// Kachel gezoomt, WANDERT der Zoom zur angeklickten — die Punkte sind im
    /// Zoom der Session-Umschalter, ein Rückfall ins Grid wäre ein Bruch.
    private func focusPane(_ pane: TerminalPane) {
        if let zoomed = zoomedPane, zoomed !== pane {
            setZoomedPane(pane)
            updateFocusBorders()
            relayout(animated: true)
        }
        window?.makeFirstResponder(pane.focusTarget)
        updateTitlebarHUD()
    }

    // MARK: - Grid

    /// Wählt die Reihenzahl für `n` Kacheln so, dass das Zellen-Seitenverhältnis dem Ziel
    /// am nächsten kommt. Bei Gleichstand gewinnt die kleinere Reihenzahl (= mehr Spalten,
    /// breiter). Für die Bewertung zählt die volle Spaltenzahl `ceil(n/rows)` (die schmalsten
    /// Zellen sind der limitierende Faktor).
    private func gridRows(for n: Int, width: CGFloat, height: CGFloat) -> Int {
        guard n > 1, width > 0, height > 0 else { return 1 }
        let targetLog = log(Self.idealCellAspect)
        var bestRows = 1
        var bestScore = CGFloat.greatestFiniteMagnitude
        for rows in 1...n {
            let cols = Int((Double(n) / Double(rows)).rounded(.up))
            let cellAspect = (width / CGFloat(cols)) / (height / CGFloat(rows))
            let score = abs(log(cellAspect) - targetLog)
            if score < bestScore - 1e-9 {   // strikt besser → Gleichstand behält weniger Reihen
                bestScore = score
                bestRows = rows
            }
        }
        return bestRows
    }

    /// Verteilt `n` Kacheln top-heavy auf `rows` Reihen (obere Reihen kriegen die Extra-Kachel).
    private func rowCounts(n: Int, rows: Int) -> [Int] {
        let base = n / rows, rem = n % rows
        return (0..<rows).map { $0 < rem ? base + 1 : base }
    }

    /// Setzt die Frames aller Kacheln gemäß aktuellem Grid. Kanten werden pixelgerundet,
    /// damit keine Lücken/Überlappungen durch Rundung entstehen; `gap` als dunkler Steg.
    private func relayout(animated: Bool = false) {
        let n = panes.count
        guard n > 0 else { return }
        let W = bounds.width, H = bounds.height
        guard W > 0, H > 0 else { return }
        let g = Self.gap
        let rows = gridRows(for: n, width: W, height: H)
        let counts = rowCounts(n: n, rows: rows)

        var frames: [NSRect] = []
        var cornerMasks: [CACornerMask] = []
        var cornerRadii: [CGFloat] = []
        frames.reserveCapacity(n)
        cornerMasks.reserveCapacity(n)
        cornerRadii.reserveCapacity(n)
        for r in 0..<rows {
            let yTop = (H * CGFloat(r) / CGFloat(rows)).rounded()
            let yBot = (H * CGFloat(r + 1) / CGFloat(rows)).rounded()
            let c = counts[r]
            for k in 0..<c {
                let xL = (W * CGFloat(k) / CGFloat(c)).rounded()
                let xR = (W * CGFloat(k + 1) / CGFloat(c)).rounded()
                let left   = xL + (k == 0 ? 0 : g / 2)
                let right  = xR - (k == c - 1 ? 0 : g / 2)
                let top    = yTop + (r == 0 ? 0 : g / 2)
                let bottom = yBot - (r == rows - 1 ? 0 : g / 2)
                frames.append(NSRect(x: left, y: top,
                                     width: max(0, right - left),
                                     height: max(0, bottom - top)))

                // Ecken-Regeln (AppKit flippt die Layer-Geometrie mit, isFlipped
                // → minY = oben):
                // - Obere Außenecken ECKIG: die Kachel sitzt unterhalb der
                //   Titlebar, die Fenster-Rundung ist dort schon vorbei — ein
                //   eigener Radius ergäbe die alte „Doppelabrundung".
                // - Untere Außenecken RUNDEN, mit Fenster-Radius: die Kachel
                //   liegt seit dem Wegfall des SwiftUI-Seitenpaddings IN der
                //   unteren Fenster-Rundung; eine eckige Akzent-Outline würde
                //   dort von der Fenster-Maske abgeschnitten.
                // - Innen-Steg-Ecken runden wie gehabt (8px).
                let topOuter = r == 0, bottomOuter = r == rows - 1
                let leftOuter = k == 0, rightOuter = k == c - 1
                var mask = CACornerMask()
                if !(topOuter && leftOuter)     { mask.insert(.layerMinXMinYCorner) }
                if !(topOuter && rightOuter)    { mask.insert(.layerMaxXMinYCorner) }
                mask.insert(.layerMinXMaxYCorner)
                mask.insert(.layerMaxXMaxYCorner)
                cornerMasks.append(mask)
                cornerRadii.append(bottomOuter ? Self.windowCornerRadius : 8)
            }
        }

        // Zoom-Sonderfall (#26): die gezoomte Kachel bekommt statt ihres Grid-Frames
        // die vollen Bounds und wird per Subview-Reorder über alle anderen gehoben;
        // deren Grid-Frames bleiben unverändert darunter liegen. Alle Ecken sind
        // dann Außenkanten → keine eigene Rundung, die Fenster-Rundung übernimmt.
        if let z = zoomedPane, let zi = panes.firstIndex(where: { $0 === z }) {
            frames[zi] = bounds
            // Oben eckig (unter der Titlebar), unten dem Fenster-Radius folgen.
            cornerMasks[zi] = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            cornerRadii[zi] = Self.windowCornerRadius
            addSubview(z.container)   // re-add hebt den View ans Ende der Subview-Liste (= nach vorn)
        }

        for (pane, mask) in zip(panes, cornerMasks) { pane.container.layer?.maskedCorners = mask }
        for (pane, radius) in zip(panes, cornerRadii) { pane.container.layer?.cornerRadius = radius }

        // Terminals in beiden Zweigen VOR dem Frame-Set auf die Zielgröße pinnen:
        // genau EIN PTY-Resize (+ Scrollback-Reflow) pro Umsortierung, egal wie
        // viele Zwischengrößen die Animation produziert.
        for (pane, frame) in zip(panes, frames) { pane.container.pinContent(forTargetSize: frame.size) }

        if animated && !isFirstLayout && window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for (pane, frame) in zip(panes, frames) { pane.container.animator().frame = frame }
            }
        } else {
            for (pane, frame) in zip(panes, frames) { pane.container.frame = frame }
        }
        isFirstLayout = false
    }
}

// MARK: - Steuerkanal (#28)

/// Ausführung der `latexterm`-CLI-Kommandos. Lebt in DIESER Datei, damit die
/// Pane-Verwaltung (`panes`, `toggleZoom`, …) privat bleiben kann. Der
/// `ControlServer` ruft `handleControl` synchron auf dem Main-Thread.
extension TerminalSplitView: ControlCommandHandler {

    func handleControl(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case "list-panes":
            return ControlResponse(ok: true, panes: panes.map { info(for: $0) })

        case "new-pane":
            let pane = addPane(startingIn: request.cwd)
            if let exec = request.exec, !exec.isEmpty {
                // Sofort in die PTY — der Kernel puffert, die Shell liest das
                // Kommando, sobald sie bereit ist (kein Delay/Poll nötig).
                pane.view.send(txt: exec + "\r")
            }
            return ControlResponse(ok: true, pane: info(for: pane))

        case "send", "zoom", "focus":
            guard let pane = resolvePane(request.pane ?? request.paneID) else {
                return .failure("Kachel nicht gefunden: „\(request.pane ?? request.paneID ?? "kein Ziel angegeben")“ — `latexterm list-panes` zeigt Index und ID")
            }
            switch request.cmd {
            case "send":
                guard let text = request.text, !text.isEmpty else {
                    return .failure("send braucht einen Text")
                }
                pane.view.send(txt: text + ((request.enter ?? true) ? "\r" : ""))
            case "zoom":
                toggleZoom(pane)
            default:
                focusPane(pane)
            }
            return ControlResponse(ok: true, pane: info(for: pane))

        default:
            return .failure("Unbekanntes Kommando „\(request.cmd)“")
        }
    }

    private func info(for pane: TerminalPane) -> PaneInfo {
        let state: String
        switch pane.sessionState {
        case .none: state = "none"
        case .working: state = "working"
        case .awaitingInput: state = "awaitingInput"
        }
        return PaneInfo(id: pane.id.uuidString,
                        index: (panes.firstIndex(where: { $0 === pane }) ?? 0) + 1,
                        cwd: pane.currentDirectory,
                        focused: isFocused(pane),
                        zoomed: pane === zoomedPane,
                        state: state)
    }

    /// Löst den Ziel-Selektor des CLI auf eine Kachel auf. Semantik: reine Ziffern
    /// sind IMMER der 1-basierte Index aus `list-panes` (nie UUID-Präfix — vorhersagbar
    /// schlägt bequem); alles andere matcht case-insensitiv als UUID-Präfix, aber nur
    /// bei GENAU einem Treffer. Mehrdeutig = nil: `send` in die falsche Shell wäre
    /// Command-Execution, da ist ein Fehler die sichere Antwort.
    private func resolvePane(_ selector: String?) -> TerminalPane? {
        guard let selector, !selector.isEmpty else { return nil }
        if let index = Int(selector) {
            guard (1...panes.count).contains(index) else { return nil }
            return panes[index - 1]
        }
        let prefix = selector.uppercased()
        let matches = panes.filter { $0.id.uuidString.hasPrefix(prefix) }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Live-Status-Pille (#25 v2): schwebt oben rechts über dem Terminal-Inhalt
/// einer Kachel und zeigt, was die Claude-Session dort gerade tut (Tool-Name
/// aus dem PreToolUse-Hook bzw. generisch „arbeitet…"/„braucht Input").
/// Rein visuell: `hitTest` = nil, Klicks/Selektion gehen ans Terminal durch.
final class PaneStatusBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var lastText: String?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.zPosition = 10          // über dem später hinzugefügten Terminal-View
        layer?.borderWidth = 1
        label.font = AppFonts.mono(size: 10.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// nil blendet aus. Größe passt sich dem Text an (Deckel 240px, dann „…");
    /// der Aufrufer positioniert danach via `layoutStatusBadge()` neu.
    func update(text: String?, accent: NSColor, pulsing: Bool) {
        defer { lastText = text }
        guard let text else {
            isHidden = true
            layer?.removeAnimation(forKey: "badgePulse")
            return
        }
        isHidden = false
        // Dunkler, fast opaker Grund: die Pille liegt über Terminal-Text und
        // muss lesbar bleiben (das 0.16-Alpha der Zoom-Pille reicht hier nicht).
        layer?.backgroundColor = ThemeStore.shared.theme.badgeBackground.cgColor
        layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        label.textColor = accent

        if text != lastText {
            label.stringValue = text
            label.sizeToFit()
            label.frame.size.width = min(label.frame.width, 240)
            setFrameSize(NSSize(width: label.frame.width + 16, height: label.frame.height + 6))
            label.frame.origin = NSPoint(x: 8, y: 3)
            layer?.cornerRadius = frame.height / 2
        }

        // Dezenter Atem-Puls solange gearbeitet wird (Optik wie der HUD-Punkt).
        if pulsing {
            if layer?.animation(forKey: "badgePulse") == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.55
                pulse.duration = 0.9
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer?.add(pulse, forKey: "badgePulse")
            }
        } else {
            layer?.removeAnimation(forKey: "badgePulse")
        }
    }
}

/// Klickbarer Session-Punkt in der Titlebar-HUD: trägt die Akzentfarbe seiner
/// Kachel, der fokussierte bekommt vollen Alpha + hellen Ring. Die Klickfläche
/// (18×18) ist bewusst größer als der gemalte Kreis (12×12).
private final class PaneDotView: NSView {
    private let onClick: () -> Void

    /// Ohne das frisst der Fenster-Drag den Klick: `isMovableByWindowBackground`
    /// + nicht-opaker View ⇒ AppKit deutet mouseDown als „Fenster anfassen".
    override var mouseDownCanMoveWindow: Bool { false }

    init(color: NSColor, focused: Bool, pulsing: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        wantsLayer = true
        let circle = CALayer()
        circle.frame = CGRect(x: 3, y: 3, width: 12, height: 12)
        circle.cornerRadius = 6
        circle.backgroundColor = color.withAlphaComponent(focused ? 1.0 : 0.55).cgColor
        circle.borderWidth = focused ? 1.5 : 0
        circle.borderColor = ThemeStore.shared.theme.foreground.withAlphaComponent(0.8).cgColor
        layer?.addSublayer(circle)
        // Live-Status v1 (#25): dezenter Atem-Puls, solange die Session arbeitet.
        if pulsing {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            circle.add(pulse, forKey: "sessionPulse")
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }
}

extension NSColor {
    /// Strikter `#RRGGBB`-Parser für den OSC-Steuerkanal (#24). Bewusst eng:
    /// die Payload kommt aus untrusted Programm-Output — alles außer exakt
    /// 6 Hex-Ziffern (optionales `#`) wird verworfen statt geraten.
    convenience init?(srgbHex: String) {
        var hex = srgbHex
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit),
              let value = UInt32(hex, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    /// `#RRGGBB`-Form für den Session-Snapshot (Gegenstück zu `init(srgbHex:)`).
    var srgbHexString: String? {
        guard let c = usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// Farbraumfester Vergleich über sRGB-Komponenten. NSColor-`==` vergleicht den
    /// Farbraum mit — eine aus UserDefaults geladene Farbe wäre nie `==` zu einer
    /// Palettenfarbe, obwohl sie visuell identisch ist (#18). Die Toleranz deckt
    /// Rundungsverluste der Konvertierung/Persistierung ab.
    func srgbMatches(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        let eps: CGFloat = 0.5 / 255
        return abs(a.redComponent - b.redComponent) < eps
            && abs(a.greenComponent - b.greenComponent) < eps
            && abs(a.blueComponent - b.blueComponent) < eps
            && abs(a.alphaComponent - b.alphaComponent) < eps
    }
}
