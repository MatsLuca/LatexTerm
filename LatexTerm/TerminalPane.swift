import AppKit
import os
import SwiftTerm

/// Eine einzelne Terminal-Kachel: eigener Shell-Prozess, eigener OverlayController
/// (= eigene LaTeX-Overlays). Mehrere Panes leben nebeneinander in `TerminalSplitView`.
/// Übernimmt die Rolle, die früher der `TerminalContainer.Coordinator` für das einzelne
/// Terminal hatte (Process-Delegate + Settings-Observer + Shell-Spawn).
final class TerminalPane: NSObject, Pane, LocalProcessTerminalViewDelegate {

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
    private var cockpitObserver: NSObjectProtocol?

    /// Private OSC-Sequenz für In-Band-Steuerung dieser Pane (#24, Fundament für #25/#27):
    /// `printf '\e]5522;accent=#RRGGBB\a'` in der Pane-Shell setzt die Akzentfarbe.
    /// In-Band statt Socket/Env-Var: reist durch die PTY der Pane → per-Pane by
    /// construction, funktioniert durch SSH, keine Integrations-Infra nötig.
    static let controlOscCode = 5522

    /// Per-Pane-Akzent-Override (OSC `accent=…`): überstimmt die globale Akzentfarbe
    /// für Caret/Fokus-Rahmen DIESER Kachel bis `accent=reset` oder Pane-Ende.
    private var accentOverride: NSColor? {
        didSet { applyAccent() }
    }
    /// Passiv erkannte TUI-Rahmenfarbe dieser Kachel (#24): Claude Code & Co.
    /// zeichnen ihre Box-Rahmen (`╭────╮`) in der Session-Akzentfarbe. Nur aktiv
    /// im adaptiven Modus; schwächer als ein expliziter OSC-Override.
    private var borderAccent: NSColor? {
        didSet { applyAccent() }
    }
    /// Wirksame Akzentfarbe dieser Kachel: OSC-Override > erkannter Rahmen > global
    /// (die Hülle rechnet sie aus `ownAccent`, eine Quelle für Rahmen, Chip und Caret).
    var effectiveAccent: NSColor { container.effectiveAccent }
    /// Pane-EIGENE Farbe (Override oder erkannt) — nil, wenn die Kachel nur der
    /// globalen Farbe folgt. Steuert den Hüll-Tint.
    private var paneAccent: NSColor? { accentOverride ?? borderAccent }
    /// Rückkanal zur Split-View (Schließen, Zoom, Starts, Notifications, Titelleiste).
    weak var host: PaneHost?

    /// Bestätigter Session-Zustand (#30) — Schreibzugriff nur über
    /// `registerSessionScan` (Hysterese). UI (HUD-Puls) liest hier.
    private(set) var sessionState: SessionState = .none {
        didSet {
            guard sessionState != oldValue else { return }
            // Session vorbei/unbekannt → kein veralteter Tool-Name beim nächsten Start.
            if sessionState == .none { statusDetail = nil; turnStartedAt = nil; turnSteps = 0 }
            if sessionState == .working { turnSummary = nil }
            updateStatusBadge()
            host?.paneStyleChanged(self)
        }
    }
    /// Live-Status-Detail aus dem Hook-Kanal (#25 v2), z. B. der Tool-Name aus
    /// dem PreToolUse-Hook. Nur die Hooks liefern es — die passive Erkennung
    /// kennt keins (Badge zeigt dann den generischen Zustandstext).
    private var statusDetail: String? {
        didSet { if statusDetail != oldValue { updateStatusBadge() } }
    }

    // MARK: Turn-Verlauf aus der Bridge (15.09.2026)

    /// Laufender Turn aus dem Hook-Kanal: Start (die Pille tickt die Zeit lokal weiter),
    /// Werkzeug-Schritte und der Prompt-Anfang fürs Fertig-Banner. Felder liefert nur der
    /// Mod `latexterm-bridge` (Werkstatt); die alten Shell-Hooks starten höchstens die Uhr.
    private var turnStartedAt: Date?
    private var turnSteps = 0
    private var turnPrompt: String?
    private var badgeTicker: Timer?
    /// Hat diese Session schon Bridge-Felder geschickt? Dann werden feldlose Signale der
    /// alten Shell-Hooks ignoriert — sonst Doppel-Banner. Lokal seit 21.09. entfernt.
    private var bridgeSeen = false
    private(set) var agentSession = AgentSession()
    private var sessionOwnerGroup: pid_t?
    private var sessionWatch: Timer?
    private var agentName: String { agentSession.identity?.name ?? "Claude" }
    /// Nachklang nach Turn-Ende („✓ fertig · 1:42 · 7 Schritte"): bleibt, bis jemand hingesehen
    /// hat (Kachel beobachtet + 6 s), höchstens 10 min. Sichtbar nur bei `sessionState == .none`.
    private struct TurnSummary {
        let long: String; let short: String; let glyph: String
        let tone: NSColor; let shownAt: Date; var seenAt: Date?
    }
    private var turnSummary: TurnSummary? {
        didSet { updateStatusBadge() }
    }
    private var summaryTimer: Timer?

    /// Was die Titelleiste über diese Kachel zeigt (`StatusChip`, Tonfarben aus dem Theme).
    private(set) var statusChip = StatusChip(tone: .clear) {
        didSet { if statusChip != oldValue { host?.paneStyleChanged(self) } }
    }

    /// Chip-Inhalt aus Zustand, Detail und Turn-Verlauf ableiten.
    private func updateStatusBadge() {
        let mode = CockpitSettings.shared.statusBadgeMode
        let theme = ThemeStore.shared.theme
        var chip = StatusChip(tone: effectiveAccent)
        chip.tooltip = turnPrompt.map { "„\($0)“" }
            ?? currentDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }
        if mode != .off {
            switch sessionState {
            case .working:
                chip.pulsing = true
                let clock = turnStartedAt.map { Self.clock(Date().timeIntervalSince($0)) }
                let tool = mode == .detail ? statusDetail : nil
                let steps = (mode == .detail && turnSteps > 0) ? Self.stepsText(turnSteps) : nil
                chip.long = [tool ?? "arbeitet", clock, steps].compactMap { $0 }.joined(separator: " · ")
                let short = [tool, clock].compactMap { $0 }.joined(separator: " · ")
                chip.short = short.isEmpty ? "arbeitet" : short
                chip.glyph = "◐"
            case .awaitingInput:
                chip.tone = theme.yellow
                chip.pulsing = true
                chip.urgent = true
                var line = "braucht dich"
                if mode == .detail, let detail = statusDetail { line += " · " + String(detail.prefix(60)) }
                chip.long = line
                chip.short = "braucht dich"
                chip.glyph = "●"
            case .none:
                if let summary = turnSummary {
                    chip.tone = summary.tone
                    chip.long = summary.long
                    chip.short = summary.short
                    chip.glyph = summary.glyph
                }
            }
        }
        statusChip = chip
        syncBadgeTicker()
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total < 60 ? "\(total) s" : String(format: "%d:%02d", total / 60, total % 60)
    }

    static func stepsText(_ steps: Int) -> String {
        "\(steps) " + (steps == 1 ? "Schritt" : "Schritte")
    }

    /// Sekunden-Ticker nur, solange die Pille eine laufende Uhr zeigt.
    private func syncBadgeTicker() {
        let needed = sessionState == .working && turnStartedAt != nil
            && CockpitSettings.shared.statusBadgeMode != .off
        if needed {
            guard badgeTicker == nil else { return }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatusBadge() }
            RunLoop.main.add(timer, forMode: .common)
            badgeTicker = timer
        } else {
            badgeTicker?.invalidate()
            badgeTicker = nil
        }
    }

    private func showTurnSummary(long: String, short: String, glyph: String, tone: NSColor) {
        turnSummary = TurnSummary(long: long, short: short, glyph: glyph, tone: tone,
                                  shownAt: Date(), seenAt: nil)
        summaryTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tickSummary() }
        RunLoop.main.add(timer, forMode: .common)
        summaryTimer = timer
        tickSummary()
    }

    private func tickSummary() {
        guard var summary = turnSummary else {
            summaryTimer?.invalidate(); summaryTimer = nil
            return
        }
        let now = Date()
        if summary.seenAt == nil, host?.paneIsObserved(self) ?? true {
            summary.seenAt = now
            turnSummary = summary
        }
        let seenLongEnough = summary.seenAt.map { now.timeIntervalSince($0) > 6 } ?? false
        if seenLongEnough || now.timeIntervalSince(summary.shownAt) > 600 {
            turnSummary = nil
            summaryTimer?.invalidate(); summaryTimer = nil
        }
    }

    /// Ordnername der Kachel für Banner-Titel („Claude fertig · LatexTerm").
    private var folderName: String {
        currentDirectory.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "Terminal"
    }
    /// Aufmerksamkeit anfordern: bestätigter Übergang working→awaitingInput (#27 v1), natives
    /// Signal des Kindprozesses (BEL/OSC 777 — Claude Codes eigener Kanal, ohne Hysterese) oder
    /// Hook-Ereignis. Fehlende Teile füllt die Kachel selbst: eine Glocke in einer CC-Session
    /// heißt „Claude braucht Input", in einer nackten Shell nicht. Die Split-View meldet nur,
    /// wenn niemand hinsieht.
    private func requestAttention(title: String?, body: String?) {
        let fallback = sessionState != .none ? "\(agentName) braucht Input" : "Terminal-Glocke"
        let detail = body ?? currentDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath }
        host?.paneRequestsAttention(self, title: title ?? fallback, body: detail)
    }

    private var usesClaudeIntegration = true
    private(set) var launcherLabel: String?

    // MARK: Home-Kachel (Projekt-Launcher)

    /// Liegt über dem noch nicht gestarteten Terminal; `launch` ersetzt sie durch die Shell.
    private(set) var homeView: HomePaneView?
    /// Erst `start()` spawnt die Shell — eine Home-Kachel hat keinen Prozess.
    private(set) var isStarted = false
    var isHome: Bool { homeView != nil }
    /// Was den Tastaturfokus dieser Kachel trägt: Terminal oder Home-Ansicht.
    var focusTarget: NSView { homeView?.keyView ?? view }

    /// Kachel als Home-Kachel zeigen (statt Shell). Die Kopfzeile mit dem Status der übrigen
    /// Kacheln und den Sprung dorthin liefert der Host.
    func showHome() {
        guard !isStarted, homeView == nil else { return }
        let home = HomePaneView(frame: container.bounds)
        home.autoresizingMask = [.width, .height]
        home.otherPanes = { [weak self] in
            guard let self, let host = self.host else { return [] }
            return host.homePaneSummary(excluding: self)
        }
        home.onFocusPane = { [weak self] paneID in self?.host?.paneRequestsFocus(paneID: paneID) }
        // Team-Start (1–2 Sessions): jede in einer eigenen frischen Kachel, diese bleibt Home.
        home.onLaunchGroup = { [weak self] requests in
            guard let host = self?.host, (1...2).contains(requests.count) else { return }
            for req in requests {
                host.paneRequestsFreshTerminal(focus: false).launch(
                    in: req.path, command: req.command, label: req.label,
                    followUps: [req.colorFollowUp, req.followUp].compactMap { $0 },
                    accent: req.accent, accentName: req.accentName, integration: req.integration)
            }
        }
        home.onLaunch = { [weak self] req in
            self?.launch(in: req.path, command: req.command, label: req.label,
                         followUps: [req.colorFollowUp, req.followUp].compactMap { $0 },
                         accent: req.accent, accentName: req.accentName, integration: req.integration)
        }
        home.resolveAccentName = { [weak self] wanted, alternatives, palette in
            guard let self, let host = self.host else { return wanted }
            return host.distinctAccentName(wanted, alternatives: alternatives, palette: palette, excluding: self)
        }
        container.addSubview(home)
        homeView = home
    }

    /// Home → Terminal: Shell in `directory` starten und `command` tippen (Kernel puffert,
    /// die Shell liest es nach dem Prompt — gleicher Pfad wie `new-pane --exec`).
    func launch(in directory: String, command: String?, label: String? = nil, followUps: [String] = [],
                accent: NSColor? = nil, accentName: String? = nil, integration: String? = nil) {
        // Ein Prozess pro Kachel — kein zweiter Start ins laufende Terminal. Kommt der Start trotzdem
        // hier an (Home-Menü auf einer Kachel, die längst läuft), wandert er in eine frische Kachel
        // statt still zu verpuffen.
        guard !isStarted else {
            Logger(subsystem: "com.mats.LatexTerm", category: "launch").notice("launch auf gestarteter Kachel → neue Kachel: \(command ?? "-", privacy: .public)")
            host?.paneRequestsFreshTerminal(focus: true).launch(
                in: directory, command: command, label: label, followUps: followUps,
                accent: accent, accentName: accentName, integration: integration)
            return
        }
        // Projektfarbe (Runde 25): vor dem Start setzen, damit Ring, Rahmen und HUD-Punkt von der
        // ersten Sekunde an die Session-Farbe tragen — dieselbe Palette, in der Claude seine Box malt.
        // Bewusst in den „erkannt"-Slot, nicht als OSC-Override: tippt Mats später von Hand /color,
        // zieht die passive Rahmenerkennung die Kachel nach — Box und Rahmen bleiben eins.
        if let accent { borderAccent = accent }
        self.accentName = accentName
        usesClaudeIntegration = integration != "terminal"
        launcherLabel = label
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
        if !usesClaudeIntegration {
            home.beginLaunch(label ?? "Codex", eta: 2, accent: effectiveAccent)
            home.launchOverlay?.allowReveal { [weak self] in
                self?.launchTimer?.invalidate()
                self?.launchTimer = nil
                self?.revealTerminal(success: false)
            }
            view.send(txt: command + "\r")
            let started = Date()
            var readySince: Date?
            launchTimer?.invalidate()
            launchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let term = self.view.getTerminal()
                var lines: [String] = []
                for row in 0..<term.rows {
                    guard let line = term.getLiveLine(row: row) else { continue }
                    var text = ""
                    for col in 0..<term.cols {
                        let ch = line[col].getCharacter()
                        text.append(ch == "\u{0}" ? " " : ch)
                    }
                    lines.append(text)
                }
                let state = CodexLaunchReadiness.state(lines: lines)
                let signalled = self.launchReady
                if case .ready = state { readySince = readySince ?? Date() }
                else if signalled { readySince = readySince ?? Date() }
                else { readySince = nil }
                let stable = readySince.map { Date().timeIntervalSince($0) >= 0.5 } ?? false
                let timeout = Date().timeIntervalSince(started) >= 12
                let interaction: Bool
                if case .interaction = state { interaction = true } else { interaction = false }
                guard stable || interaction || timeout else { return }
                timer.invalidate()
                self.launchTimer = nil
                self.revealTerminal(success: stable)
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
            let bereit = Date().timeIntervalSince(started)
            if ready { Self.recordLaunch(bereit) }
            let reason = self.launchReady ? "signal" : (ready ? "passiv" : "timeout")
            // Folgebefehle (z. B. /color, /compact) nur bei echter Session. Runde 26: der Vorhang
            // bleibt liegen, bis der letzte Folgebefehl abgeschickt ist — vorher landete Mats'
            // erstes Tippen mitten im noch offenen „/color …" („cyanist es"). Text in die
            // Claude-TUI, Enter separat (ein mitgesendetes Enter wird beim Paste geschluckt —
            // Regel aus dem latexterm-Skill), nacheinander mit Abstand, dann erst Reveal.
            let queue = ready ? followUps.filter { !$0.isEmpty } : []
            guard !queue.isEmpty else {
                self.revealTerminal(success: ready)
                Self.startTimerLog(t0: t0, ready: bereit, curtain: bereit, reason: reason)
                return
            }
            self.sendFollowUps(queue) { [weak self] in
                guard let self else { return }
                self.revealTerminal(success: true)
                Self.startTimerLog(t0: t0, ready: bereit, curtain: Date().timeIntervalSince(started), reason: reason)
            }
        }
    }
    private var launchTimer: Timer?
    /// Laufende Folgebefehl-Schritte (Runde 26) — ⌘W mitten im Start bricht sie ab.
    private var followUpWork: [DispatchWorkItem] = []
    /// Folgebefehle unter dem Vorhang: je Befehl Text (+0,4 s), Enter (+0,6 s später), nächster
    /// Befehl 1 s nach dem Enter; `done` 0,4 s nach dem letzten Enter, wenn Claude ihn verarbeitet hat.
    private func sendFollowUps(_ commands: [String], done: @escaping () -> Void) {
        followUpWork.forEach { $0.cancel() }
        followUpWork = []
        var steps: [(TimeInterval, () -> Void)] = []
        var t: TimeInterval = 0.4
        for cmd in commands {
            steps.append((t, { [weak self] in self?.view.send(txt: cmd) }))
            t += 0.6
            steps.append((t, { [weak self] in self?.view.send(txt: "\r") }))
            t += 1.0
        }
        steps.append((t - 1.0 + 0.4, done))
        for (delay, action) in steps {
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.isStarted else { return }   // Prozess weg → nichts mehr tippen
                action()
            }
            followUpWork.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
    /// `status=ready` vom SessionStart-Hook (settings.json) ist angekommen — Session steht.
    private var launchReady = false
    /// Claude-Code-Farbname dieser Kachel (Runde 25) — Kollisionsschutz der Split-View liest ihn.
    private(set) var accentName: String?

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
    private static func startTimerLog(t0: Int, ready: TimeInterval, curtain: TimeInterval, reason: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".cache/mats-tools")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("start-timer.log")
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date()))  t0=\(t0) bereit=\(Int(ready * 1000)) vorhang=\(Int(curtain * 1000)) grund=\(reason)  (LatexTerm: Tastendruck bis Session steht / bis Vorhang weg; Differenz = Folgebefehle)\n"
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

    /// Theme-Wechsel zur Laufzeit: Terminal und Home-Kachel nachziehen (die Hülle hört selbst).
    private func applyTheme() {
        let theme = ThemeStore.shared.theme
        Self.applyTheme(theme, to: view)
        applyAccent()   // Caret (Akzent oder Theme-Cursor)
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

        // Kachel-Styling (Ecken/Rahmen/Dimmung/Tint) liegt auf der Hülle; ihr Grund füllt
        // das Content-Inset in der Terminal-Farbe auf. Unfokussiert = abgedunkelt.
        let box = PaneContainerView()
        box.addSubview(term)

        self.view = term
        self.container = box
        self.controller = OverlayController(terminal: term)
        super.init()
        box.pane = self   // Kachel-Kürzel der Hülle landen über diese Kachel beim Host

        term.processDelegate = self
        term.onRangeChanged = { [weak self, weak controller] startY, endY in
            controller?.scheduleRescan(dirtyStart: startY, dirtyEnd: endY)
            self?.scheduleContrastAnalysis()
            self?.updatePromptBox()
        }
        term.onNeedsFullRescan = { [weak controller] in controller?.scheduleRescan() }
        // Quellzellen unter Formel-Overlays unsichtbar zeichnen (statt WebView-Maske).
        controller.onHiddenCellsChanged = { [weak term] in term?.needsDisplay = true }
        // Prompt-Tint (experimentell): Standard-FG-Zellen in den Box-Zeilen stylen.
        term.cellStyleOverride = { [weak self, weak controller] row, col, isDefaultFg in
            if let controller, controller.isHidden(row: row, col: col) { return .hidden }
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
            self.requestAttention(title: nil, body: nil)
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
                self.requestAttention(title: parts[1], body: body)
            }
        }

        cockpitObserver = NotificationCenter.default.addObserver(
            forName: CockpitSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.updateStatusBadge() }

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
                // Zellhöhe ändert sich → Formeln neu aufbauen (wie früher über FormulaSettings).
                term?.extraLineSpacing = store.lineSpacing
                self.controller.invalidateAll()
                self.controller.scheduleRescan()
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
                break   // Rahmen/Dimmung/Tint: die Hülle hört selbst
            }
        }
    }

    deinit {
#if DEBUG
        // Nach ⌘W/close-pane muss diese Zeile kommen — fehlt sie, hält ein Zyklus die Kachel fest.
        Self.statusLog("PANE \(kind) freed \(id.uuidString.prefix(8))")
#endif
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        if let cockpitObserver { NotificationCenter.default.removeObserver(cockpitObserver) }
        rainbowTimer?.invalidate()
        badgeTicker?.invalidate()
        summaryTimer?.invalidate()
        sessionWatch?.invalidate()
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
    /// über den Socket (OSC 5522 nur für Altsender) — präzise Agenten-Events.
    /// Setzt den Zustand OHNE Hysterese (der Hook weiß es sicher); die passive
    /// Erkennung läuft weiter und bestätigt ihn beim nächsten Scan von selbst.
    /// Notifications laufen über `requestAttention` (unbeobachtet-Check im Host,
    /// 5-s-Cooldown im SessionNotifier). `done` setzt bewusst
    /// `.none`: der anschließend sichtbaren Eingabe-Box darf die passive
    /// Erkennung NICHT „working→awaitingInput" unterstellen (ihr Notification-
    /// Trigger verlangt old == .working, .none → .awaitingInput bleibt stumm).
    /// Payload seit 15.09.2026 (Bridge-Mod): `status=<state>[;detail][;k=v…]` — Stücke nach dem
    /// Zustand sind Felder (`t` Sekunden, `n` Schritte, `p` Prompt, `a` Antwort, `r` Grund) oder
    /// ein freier Detailtext (Tool-Name, Frage). Die alten Shell-Hooks schicken nur `state;detail`.
    struct HookStatus {
        var state: String
        var detail: String?
        var fields: [String: String] = [:]
        var seconds: Int? { fields["t"].flatMap { Int($0) } }
        var steps: Int? { fields["n"].flatMap { Int($0) } }
    }

    /// Zerlegt die Payload; alles kommt aus untrusted Programm-Output: Steuerzeichen raus,
    /// jedes Stück gedeckelt, unbekannte Schlüssel bleiben harmlos im Wörterbuch.
    static func parseHookStatus(_ value: String) -> HookStatus? {
        let pieces = value.split(separator: ";", omittingEmptySubsequences: true)
        guard let first = pieces.first else { return nil }
        var status = HookStatus(state: String(first))
        for raw in pieces.dropFirst() {
            let piece = String(raw.prefix(200)).filter { ch in
                !ch.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
            }
            if piece.isEmpty { continue }
            if let eq = piece.firstIndex(of: "="),
               piece.distance(from: piece.startIndex, to: eq) <= 4,
               piece[..<eq].allSatisfy({ $0.isLetter && $0.isLowercase }) {
                status.fields[String(piece[..<eq])] = String(piece[piece.index(after: eq)...])
            } else if status.detail == nil {
                status.detail = piece
            }
        }
        return status
    }

    @discardableResult
    func applyHookStatus(_ value: String, agent: String? = nil, sessionID: String? = nil,
                                    turnID: String? = nil, sourceGroup: Int32? = nil) -> Bool {
        let previousIdentity = agentSession.identity
        guard let hook = Self.parseHookStatus(value),
              sourceGroup == nil || sourceGroup == (hook.state == "closed" ? sessionOwnerGroup : foregroundProcessGroup),
              agent == nil || hook.state == "closed" || foregroundProcessGroup != nil,
              agent != nil || usesClaudeIntegration,
              agentSession.accept(state: hook.state, agent: agent, sessionID: sessionID, turnID: turnID,
                                  startsTurn: hook.state == "working" && hook.seconds == 0 && hook.steps == 0) else { return false }
        if previousIdentity != agentSession.identity {
            turnSummary = nil; turnPrompt = nil; turnStartedAt = nil; turnSteps = 0
            sessionState = .none; statusDetail = nil; bridgeSeen = false
        }
        if let identity = agentSession.identity {
            usesClaudeIntegration = identity.agent == "claude"
            watchAgentProcess()
        }
        pendingSessionScans = 0
#if DEBUG
        Self.statusLog("HOOK status=\(hook.state) detail=\(hook.detail ?? "-") fields=\(hook.fields)")
#endif
        // Bridge und alte Shell-Hooks laufen parallel: sobald die Bridge (mit Feldern) spricht,
        // schweigen die feldlosen Legacy-Signale dieser Session — sonst zweimal „fertig".
        if hook.state == "ready" {
            bridgeSeen = false
        } else if !hook.fields.isEmpty {
            bridgeSeen = true
        } else if bridgeSeen && agent == nil {
            lastHookStatusAt = Date()
            return true
        }
        switch hook.state {
        case "working":
            lastHookStatusAt = Date()
            if let steps = hook.steps {
                // Turn-Start (t=0, n=0) setzt die Uhr; spätere Schritte tragen nur die Zahl nach.
                if turnStartedAt == nil || (steps == 0 && hook.seconds == 0) {
                    turnStartedAt = Date().addingTimeInterval(-Double(hook.seconds ?? 0))
                    turnPrompt = hook.fields["p"]
                }
                turnSteps = steps
            } else if turnStartedAt == nil {
                turnStartedAt = Date()
            }
            if hook.fields["inc"] == "1" { turnSteps += 1 }
            sessionState = .working
            statusDetail = hook.detail     // nil (Turn-Start) löscht den alten Tool-Namen bewusst
            updateStatusBadge()            // Uhr/Schritte ändern sich auch ohne Zustandswechsel
        case "input":
            lastHookStatusAt = Date()
            sessionState = .awaitingInput
            statusDetail = hook.detail
            requestAttention(title: "\(agentName) braucht dich · \(folderName)", body: hook.detail ?? turnPrompt)
        case "done":
            lastHookStatusAt = Date()
            let seconds = hook.seconds.map(Double.init)
                ?? turnStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let steps = hook.steps ?? turnSteps
            let prompt = turnPrompt
            turnStartedAt = nil; turnSteps = 0; turnPrompt = nil
            sessionState = .none           // räumt statusDetail im didSet mit ab
            finishTurn(reason: hook.fields["r"] ?? "answer", seconds: seconds, steps: steps,
                       prompt: prompt, answer: hook.fields["a"])
        case "ready":
            // SessionStart-Hook: Session steht, wartet auf die erste Eingabe. Hebt nur den
            // Home-Vorhang (launch) — kein Zustand, keine Pille, keine Notification. Erneuert
            // die Hook-Frist, damit der Grid-Rater der frischen Eingabe-Box nichts unterstellt.
            lastHookStatusAt = Date()
            launchReady = true
        case "closed":
            clearAgentSession()
        default:
            break                          // unbekannter/kaputter Status erneuert NICHT
        }
        host?.paneStyleChanged(self)
        return true
    }

    /// SessionEnd may be delayed by an agent daemon. The PTY's foreground job is the
    /// authoritative attachment: once it changes, the old identity must not claim this pane.
    private func watchAgentProcess() {
        guard let process = view.process, process.childfd >= 0 else { return }
        let group = tcgetpgrp(process.childfd)
        if group > 0, group != process.shellPid { sessionOwnerGroup = group }
        guard sessionWatch == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let owner = self.sessionOwnerGroup,
                  let process = self.view.process, process.childfd >= 0 else { return }
            if tcgetpgrp(process.childfd) != owner { self.clearAgentSession() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sessionWatch = timer
    }

    private func clearAgentSession() {
        let wasCodex = agentSession.identity?.agent == "codex"
        agentSession.clear()
        sessionWatch?.invalidate(); sessionWatch = nil; sessionOwnerGroup = nil
        turnSummary = nil; turnPrompt = nil; turnStartedAt = nil; turnSteps = 0
        sessionState = .none; statusDetail = nil; bridgeSeen = false; lastHookStatusAt = nil
        launchReady = false
        // A former Codex pane remains free of Claude heuristics until a Claude hook identifies it.
        if wasCodex { usesClaudeIntegration = false }
        updateStatusBadge()
        host?.paneStyleChanged(self)
    }

    /// Turn-Ende: Nachklang-Pille je nach Grund, Banner nur wenn es sich lohnt — Abbruch (Ctrl+C)
    /// bleibt stumm, Fertig unter 2 s (Slash-Command, Einzeiler) auch. Fehler melden immer.
    private func finishTurn(reason: String, seconds: Double, steps: Int, prompt: String?, answer: String?) {
        let theme = ThemeStore.shared.theme
        let clock = Self.clock(seconds)
        let stepsPart = steps > 0 ? " · " + Self.stepsText(steps) : ""
        switch reason {
        case "aborted":
            showTurnSummary(long: "■ abgebrochen · \(clock)\(stepsPart)", short: "■ \(clock)", glyph: "■",
                            tone: theme.dim)
        case "error", "refusal":
            let label = reason == "error" ? "Fehler" : "abgelehnt"
            showTurnSummary(long: "⚠ \(label) · \(clock)\(stepsPart)", short: "⚠ \(label)", glyph: "⚠",
                            tone: theme.red)
            let body = [prompt.map { "„\($0)“" }, answer].compactMap { $0 }.joined(separator: "\n")
            requestAttention(title: "\(agentName): \(label) · \(folderName)", body: body.isEmpty ? nil : body)
        default:
            showTurnSummary(long: "✓ fertig · \(clock)\(stepsPart)", short: "✓ \(clock)", glyph: "✓",
                            tone: theme.green)
            guard seconds >= 2 else { return }
            var lines: [String] = []
            if let prompt { lines.append("„\(prompt)“") }
            lines.append(clock + stepsPart)
            if let answer { lines.append(answer) }
            requestAttention(title: "\(agentName) fertig · \(folderName)", body: lines.joined(separator: "\n"))
        }
    }

    /// Eigene Farbe an die Hülle (Rahmen + Tint rechnet sie), Caret und Chip nachziehen.
    private func applyAccent() {
        container.ownAccent = paneAccent
        view.caretColor = ThemeStore.shared.cursorThemeColor ? ThemeStore.shared.theme.cursor : effectiveAccent
        updateStatusBadge()   // Pille trägt die Akzentfarbe mit (#25 v2)
        host?.paneStyleChanged(self)
    }

    private var contrastPending = false

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
            if self.container.hasFocus, now - self.lastPixelAnalysis > 1.8 {
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
        guard usesClaudeIntegration else { return nil }
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
        guard usesClaudeIntegration else { setPromptBox(nil); return }
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
        guard usesClaudeIntegration else { return .none }
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
        // Explicit agent events remain authoritative for the lifetime of the foreground job.
        guard agentSession.identity == nil else { pendingSessionScans = 0; return }
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
            if old == .working && sessionState == .awaitingInput { requestAttention(title: "\(agentName) braucht Input", body: nil) }
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

    // MARK: - Pane

    /// Home = noch nicht gestartete Kachel mit Launcher; ab dem Start (auch unter dem Vorhang) Terminal.
    var kind: String { isHome && !isStarted ? "home" : "terminal" }

    /// ⌘W / close-pane: Shell beenden (SIGTERM). `terminate()` cancelt den Exit-Monitor, daher
    /// feuert danach kein `processTerminated` — der Host entfernt die Kachel selbst.
    func willClose() {
        launchTimer?.invalidate(); launchTimer = nil   // ⌘W mitten im Start: kein Reveal ins Leere
        followUpWork.forEach { $0.cancel() }; followUpWork = []   // … und keine Folgebefehle ins Nichts
        guard isStarted else { return }   // Home-Kachel hat keinen Prozess
        view.terminate()
    }

    /// Ohne `--force` schließt der Steuerkanal nur eine ruhende Shell ohne Vordergrundprozess.
    var closeGuard: CloseGuard {
        if sessionState == .working { return .busy("arbeitet gerade — warten oder --force") }
        if let name = foregroundProcessName {
            return .busy("hat einen laufenden Prozess (\(name)) — erst beenden oder --force")
        }
        return .free
    }

    /// ⌘F: Suchleiste (#9) — nur mit sichtbarem Terminal, Home hat keine.
    func handle(_ command: PaneCommand) -> Bool {
        guard command == .find, !isHome else { return false }
        view.showFindInterface()
        return true
    }

    /// Steuerkanal `send`: Text in die PTY (Kernel puffert, die Shell liest ihn nach dem Prompt).
    /// Home hat noch keine Shell, die ihn lesen könnte.
    func receive(_ text: String, enter: Bool) -> Bool {
        guard isStarted else { return false }
        view.send(txt: text + (enter ? "\r" : ""))
        return true
    }

    /// Nur gestartete Shells landen im Snapshot; Home ist flüchtig.
    func snapshot() -> PaneSnapshot? {
        guard isStarted else { return nil }
        return PaneSnapshot(kind: "terminal", args: currentDirectory.map { ["cwd": $0] } ?? [:])
    }

    /// Aktuelles Arbeitsverzeichnis dieser Pane (OSC 7), falls die Shell eins gemeldet hat.
    var currentDirectory: String? { view.currentWorkingDirectory() }

    /// Name des Prozesses, der die PTY gerade im Vordergrund hält, oder nil, wenn das die
    /// Shell selbst ist (Prompt sichtbar) bzw. nichts läuft. Grundlage für `close-pane`
    /// ohne `--force`: eine Kachel mit laufendem Vordergrundprozess (claude, vim, ssh …)
    /// schließt der Steuerkanal nicht ungefragt.
    var foregroundProcessName: String? {
        guard let pgrp = foregroundProcessGroup else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_name(pgrp, &buffer, UInt32(buffer.count))
        let name = n > 0 ? String(cString: buffer) : ""
        return name.isEmpty ? "pid \(pgrp)" : name
    }

    private var foregroundProcessGroup: pid_t? {
        guard isStarted, let process = view.process, process.childfd >= 0 else { return nil }
        let pgrp = tcgetpgrp(process.childfd)
        guard pgrp > 0, pgrp != process.shellPid else { return nil }
        return pgrp
    }

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
    /// Zuletzt von der Shell dieser Kachel gemeldeter Titel.
    private var lastTitle = ""

    /// Fenstertitel, solange diese Kachel fokussiert ist. Den Fenstertitel setzt nur die
    /// Split-View (#21: sonst gewänne bei mehreren Kacheln der letzte Schreiber).
    var title: String {
        if isStarted, !lastTitle.isEmpty { return lastTitle }
        return isHome ? "LatexTerm — Projekte" : "LatexTerm"
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        lastTitle = title
        host?.paneStyleChanged(self)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        host?.paneDidClose(self)
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
