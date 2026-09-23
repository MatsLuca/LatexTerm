import SwiftUI
import AppKit
import os

private let qlog = Logger(subsystem: "com.mats.LatexTerm", category: "quickstart")

/// Einstiege von außen — beide führen auf denselben Weg (`QuickstartStore` → Fenster):
/// - URL-Scheme `latexterm://quickstart/<key>` und `latexterm://home` (Dock-Tile-Plugin bei nicht
///   laufender App, Raycast/Spotlight/`open`). Beim Kaltstart gibt es noch kein Fenster: der
///   Eintrag wartet in `QuickstartStore.pending`, `TerminalSplitView.viewDidMoveToWindow` holt ihn.
/// - Dock-Menü (`applicationDockMenu`) bei laufender App — dieselbe Liste wie das Plugin.
/// Die App kennt keine Pfade und keine Befehle; alles kommt aus `projekte` (`config.toml`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        WidgetRefresher.shared.start()   // Desktop-Widgets füttern (projekte widget), dann alle 5 min
        // macOS hängt ans App-Menü ein verstecktes „Quit and Keep Windows“ (⌥-Variante von „Beenden“) —
        // doppelt zu „Beenden und Kacheln merken“. AppKit/SwiftUI fügen es auch später noch ein
        // (Menüaufbau, Öffnen des Menüs), darum bei beidem wieder entfernen.
        DispatchQueue.main.async { Self.removeSystemKeepWindowsItem() }
        for name in [NSMenu.didAddItemNotification, NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Self.removeSystemKeepWindowsItem()
            }
        }
    }

    private static let systemKeepWindowsTitles: Set<String> = ["Quit and Keep Windows", "Beenden und Fenster behalten"]

    private static func removeSystemKeepWindowsItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        for item in appMenu.items where systemKeepWindowsTitles.contains(item.title) {
            appMenu.removeItem(item)
        }
    }

    // MARK: Neu starten / Beenden und Kacheln merken
    //
    // Mats baut LatexTerm in LatexTerm: nach jedem Build ⌘Q, wieder öffnen, jede Session im Home
    // suchen und „Weiter“. Die beiden Menüpunkte beenden wie ⌘Q (samt VM-Schutz), setzen aber die
    // Marke im Snapshot — beim nächsten Start kommen dieselben Kacheln wieder, Sessions über „Weiter“.
    // „Neu starten“ öffnet die App danach selbst (`AppRelaunch`). Normales ⌘Q bleibt bei Home.

    private enum KeepPanes { case quit, relaunch }
    private var keepPanes: KeepPanes?

    func quitKeepingPanes(relaunch: Bool) {
        guard confirmBusyPanes(relaunch: relaunch) else { return }
        keepPanes = relaunch ? .relaunch : .quit
        NSApp.terminate(nil)
    }

    /// Eine arbeitende Session verliert beim Beenden ihren laufenden Schritt — vorher fragen.
    private func confirmBusyPanes(relaunch: Bool) -> Bool {
        let busy = ControlServer.shared.router.panes.filter { $0.state == "working" }.count
        guard busy > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = busy == 1 ? "Eine Kachel arbeitet noch" : "\(busy) Kacheln arbeiten noch"
        alert.informativeText = "Der laufende Schritt bricht ab. Die Session kommt "
            + (relaunch ? "nach dem Neustart" : "beim nächsten Öffnen") + " wieder und kann dort weitermachen."
        alert.addButton(withTitle: relaunch ? "Neu starten" : "Beenden")
        alert.addButton(withTitle: "Abbrechen")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Stand aller Fenster sichern (Snapshot v2). Erst hier, nach dem Ja von `VMQuitGuard`: ein
    /// abgebrochenes Beenden hinterlässt so keine Wiederherstell-Marke.
    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.save(TerminalSplitView.sessionSnapshot(restoreOnce: keepPanes != nil))
        guard keepPanes == .relaunch else { return }
        do { try AppRelaunch.reopen(Bundle.main.bundleURL) } catch {
            // Marke steht trotzdem: das nächste Öffnen von Hand stellt wieder her.
            qlog.error("Neustart-Helfer nicht startbar: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Beenden mit laufender Windows-VM
    //
    // ⌘Q reißt eine laufende VMware-VM mit (`vmware-vmx` bekommt SIGTERM, Absender unklar; 21.09. und 22.09.2026
    // nachgestellt — auch wenn Fusion die VM selbst gestartet hat). Statt Mats jedes Mal `/labor aus` abzuverlangen,
    // hält die App die VM vor dem Beenden selbst an: `vm suspend` (Skill in der Werkstatt) friert sie auf der Platte
    // ein. Fehler oder Timeout brechen das Beenden ab; ein später Erfolg beendet die App nicht nachträglich.
    private let vmQuitGuard = VMQuitGuard(helperURL:
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/skills/vm/vm"))
    private var vmPanel: NSWindow?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !vmQuitGuard.isPreparing else { return .terminateLater }
        vmQuitGuard.prepare(onSuspending: { [weak self] in
            qlog.notice("Beenden: Windows-VM läuft — halte sie erst an")
            self?.showVMPanel()
        }) { [weak self] decision in
            self?.vmPanel?.orderOut(nil)
            self?.vmPanel = nil
            switch decision {
            case .allow:
                NSApp.reply(toApplicationShouldTerminate: true)
            case .cancel(let failure):
                qlog.error("Beenden abgebrochen: \(failure.message, privacy: .public)")
                self?.keepPanes = nil   // App bleibt offen → keine Marke fürs nächste Beenden
                NSApp.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = "LatexTerm bleibt geöffnet"
                alert.informativeText = failure.message + "\n\nPrüfe die VM und halte sie bei Bedarf in VMware Fusion an. Danach kannst du LatexTerm erneut beenden."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        return .terminateLater
    }

    private func showVMPanel() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 84),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "LatexTerm beenden"
        panel.isFloatingPanel = true
        let label = NSTextField(wrappingLabelWithString: "Windows-VM wird angehalten, damit sie den Neustart übersteht … (bis zu 2 min)")
        label.frame = NSRect(x: 20, y: 40, width: 320, height: 34)
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 12, width: 320, height: 16))
        spinner.style = .bar; spinner.isIndeterminate = true; spinner.startAnimation(nil)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(spinner)
        panel.center()
        panel.orderFrontRegardless()
        vmPanel = panel
    }

    /// „+“ in der Tab-Leiste (AppKit zeigt den Knopf, sobald die Aktion in der Responder-Kette steht).
    @objc func newWindowForTab(_ sender: Any?) {
        WindowTabs.open?()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let items = QuickstartStore.shared.items
        if items.isEmpty {
            let hint = NSMenuItem(title: "Keine Quickstarts (config.toml der Werkstatt)", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        for (i, q) in items.enumerated() {
            let item = NSMenuItem(title: "\(q.glyph)  \(q.label)", action: #selector(runQuickstart(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.isEnabled = q.exists
            item.toolTip = q.hint ?? q.path
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let home = NSMenuItem(title: "Neue Home-Kachel", action: #selector(newHomePane), keyEquivalent: "")
        home.target = self
        menu.addItem(home)
        return menu
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        qlog.notice("application(open:) \(urls.map(\.absoluteString).joined(separator: " "), privacy: .public)")
        urls.forEach(handle)
    }

    /// Dieselbe URL kann doppelt ankommen (AppDelegate *und* SwiftUI `onOpenURL`) — einmal reicht.
    private var lastURL: (URL, Date)?
    func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "latexterm" else { return }
        if let (u, t) = lastURL, u == url, Date().timeIntervalSince(t) < 1.5 { return }
        lastURL = (url, Date())
        let parts = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }
        switch parts.first {
        case "quickstart":
            guard let key = parts.dropFirst().first, let q = QuickstartStore.shared.find(key: key) else {
                qlog.error("unbekannter Quickstart in \(url.absoluteString, privacy: .public); Store hat \(QuickstartStore.shared.items.count) Einträge")
                NSSound.beep(); return
            }
            deliver(q)
        case "home":
            showHome()
        default:
            qlog.error("unbekannte URL \(url.absoluteString, privacy: .public)")
            NSSound.beep()
        }
    }

    /// Zustellen mit Wiederholung: beim Kaltstart existiert das Fenster oft schon, ist aber noch
    /// unsichtbar/nicht Key — `viewDidMoveToWindow` ist dann längst vorbei. Also `pending` setzen
    /// und alle 0,2 s anklopfen, bis ein `TerminalSplitView` übernimmt (`pending` wieder nil).
    private func deliver(_ q: ProjekteData.Quickstart) {
        NSApp.activate(ignoringOtherApps: true)
        QuickstartStore.shared.pending = q
        qlog.notice("deliver \(q.key, privacy: .public): Fenster \(NSApp.windows.count), sichtbar \(NSApp.windows.filter { $0.isVisible }.count)")
        knock(q, attempt: 0)
    }

    private func knock(_ q: ProjekteData.Quickstart, attempt: Int) {
        guard QuickstartStore.shared.pending?.key == q.key else { return }   // übernommen (oder ersetzt)
        NotificationCenter.default.post(name: .latexTermQuickstart, object: nil, userInfo: ["quickstart": q])
        guard QuickstartStore.shared.pending != nil, attempt < 50 else {
            if attempt >= 50 { qlog.error("Quickstart \(q.key, privacy: .public) nach 10 s nicht zugestellt") }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.knock(q, attempt: attempt + 1) }
    }

    @objc private func runQuickstart(_ sender: NSMenuItem) {
        let items = QuickstartStore.shared.items
        guard items.indices.contains(sender.tag) else { return }
        deliver(items[sender.tag])
    }

    /// Widget/Dock-Tile/`open latexterm://home`: zur Home-Kachel, ohne zu stapeln. Kaltstart oder kein
    /// sichtbares Fenster → das neue Fenster beginnt ohnehin mit Home, nichts anhängen. Sonst zeigt das
    /// Key-Fenster eine unberührte Home-Kachel oder legt eine an (`.latexTermShowHome`).
    private func showHome() {
        NSApp.activate(ignoringOtherApps: true)
        guard NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .latexTermShowHome, object: nil)
        }
    }

    @objc private func newHomePane() {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .latexTermNewHomePane, object: nil)
        }
    }
}

@main
struct LatexTermApp: App {

    private func paneCommand(_ c: PaneCommand) {
        NotificationCenter.default.post(name: .latexTermPaneCommand, object: nil, userInfo: ["command": c])
    }

    /// Id der einen WindowGroup — `WindowTabs.open` öffnet darüber neue Tabs.
    static let windowGroupID = "main"

    init() { AppearanceMigration.run() }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = FormulaSettings.shared
    @ObservedObject private var homeFocus = HomeFocus.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var cockpit = CockpitSettings.shared

    var body: some Scene {
        WindowGroup("LatexTerm", id: Self.windowGroupID) {
            ZStack {
                Color(nsColor: themeStore.theme.background)
                // Bewusst OHNE horizontales Padding: die Akzent-Outlines der
                // Kacheln sollen an den physischen Fensterkanten anliegen.
                TerminalContainer()
            }
            .frame(minWidth: 640, minHeight: 400)
            .preferredColorScheme(.dark)
            // Kaltstart per URL: SwiftUI liefert die URL hier — der AppDelegate dedupliziert.
            .onOpenURL { url in
                qlog.notice("onOpenURL \(url.absoluteString, privacy: .public)")
                appDelegate.handle(url)
            }
        }
        .commands {
            // App-Menü, über „Beenden“: wie ⌘Q, aber dieselben Kacheln kommen wieder (AppDelegate).
            // ⌥⌘Q folgt der macOS-Geste „Beenden und Fenster behalten“.
            CommandGroup(before: .appTermination) {
                Button("Neu starten") { appDelegate.quitKeepingPanes(relaunch: true) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Beenden und Kacheln merken") { appDelegate.quitKeepingPanes(relaunch: false) }
                    .keyboardShortcut("q", modifiers: [.command, .option])
            }
            // Ablage/File → Neu bleibt leer: SwiftUIs „Neues Fenster“ fliegt raus, alle neuen Kacheln
            // stehen oben im Menü „Kachel“ (Mats, 22.09.: dort sucht man sie, nicht in File).
            CommandGroup(replacing: .newItem) {}
            // Home-Kachel: die Befehle stehen im Menü statt in einer Fußzeile in der Kachel
            // (Runde 15). Die Tastenwege selbst fängt HomePaneView.performKeyEquivalent ab —
            // die Kachel ist vor dem Menü dran; die Einträge hier sind Schaufenster + Mausweg.
            CommandMenu("Home") {
                let aus = homeFocus.active == nil
                Button("Projekte, Sessions, Aktionen suchen…") { HomeFocus.shared.active?.menuSearch() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(aus)
                Button("Aufgaben und Wiedervorlagen") { HomeFocus.shared.active?.menuToday() }
                    .disabled(aus)
                Divider()
                Button("Neues Projekt mit Claude…") { HomeFocus.shared.active?.menuNewProject() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(aus)
                Button("Neu laden") { HomeFocus.shared.active?.menuReload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(aus)
                Divider()
                Button("Session anpinnen / lösen") { HomeFocus.shared.active?.menuPinSession() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(aus)
                Button("Projekt anpinnen") { HomeFocus.shared.active?.menuPinProject() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(aus)
                Button("Session umbenennen") { HomeFocus.shared.active?.menuRename() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(aus)
                Divider()
                Toggle("Nur Projekte", isOn: $cockpit.homeOnlyProjects)
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                    .disabled(aus)
                Button("Alles ausklappen") { HomeFocus.shared.active?.menuExpandAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(aus)
                Button("Alles einklappen") { HomeFocus.shared.active?.menuCollapseAll() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(aus)
                Divider()
                // Kein ⇧⇥ als Menükürzel: das würde Shift-Tab auch in Terminal-Kacheln schlucken.
                Button("Angepinntes zeigen  (⇧⇥)") { HomeFocus.shared.active?.menuShowPins() }
                    .disabled(aus)
                Button("Tastenhilfe") { HomeFocus.shared.active?.toggleKeyHelp() }
                    .keyboardShortcut("/", modifiers: .command)
                    .disabled(aus)
            }
            // Kachel-Aktionen, die sonst nur als Taste existieren — Menü = Nachschlagewerk der
            // Kürzel. Einstellungen (Theme, Akzent, Zeilenabstand, Formelgröße …) stehen NICHT
            // hier, sondern nur in ⌘, (Menüs = Aktionen, Einstellungen = Einstellungen).
            CommandMenu("Kachel") {
                // Neue Kacheln: ⌘N Home (Projekt-Launcher), ⌘T Terminal (nackte Shell, CWD-Erbe),
                // darunter die App-Kacheln aus der Registry — eine neue Art erscheint hier ohne
                // Menü-Code. Die Tasten fängt die Kachel-Hülle (PaneContainerView.performKeyEquivalent);
                // das Menü ist Schaufenster + Mausweg.
                // Neuer Tab = neues Fenster in der Tab-Leiste, beginnt mit Home. ⌘T bleibt Terminal
                // (Mats, 22.09.); ⇧⌘T ist in Terminals sonst frei.
                Button("Neuer Tab") { WindowTabs.open?() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Neue Home-Kachel") {
                    NotificationCenter.default.post(name: .latexTermNewHomePane, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Neue Terminal-Kachel") { paneCommand(.split) }
                    .keyboardShortcut("t", modifiers: .command)
                ForEach(PaneKindRegistry.menuEntries, id: \.kind) { entry in
                    Button(entry.displayName) {
                        NotificationCenter.default.post(name: .latexTermNewAppPane, object: nil,
                                                        userInfo: ["kind": entry.kind])
                    }
                }
                Divider()
                Button("Zoomen / Zoom beenden") { paneCommand(.zoom) }
                    .keyboardShortcut(.return, modifiers: .command)
                // Kachel-Layout: gezogene Trennlinien und Agenten-Anordnung verwerfen.
                Button("Automatisch anordnen") { paneCommand(.rearrange) }
                // ⌘1–9 springen seit Stufe 2 zur Kachel n; Auffüllen bleibt hier.
                Menu("Auffüllen auf") {
                    ForEach(2...6, id: \.self) { n in
                        Button("\(n) Kacheln") { paneCommand(.fill(n)) }
                    }
                }
                Button("Suchen…") { paneCommand(.find) }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Toggle("LaTeX-Formeln anzeigen", isOn: $settings.formulasEnabled)
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Schrift größer") { ThemeStore.shared.fontSize += 1 }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Schrift kleiner") { ThemeStore.shared.fontSize -= 1 }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Schriftgröße zurücksetzen") { ThemeStore.shared.fontSize = ThemeStore.defaultFontSize }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                // Kein ⌘W als Menükürzel: SwiftUIs „Schließen“ im File-Menü trägt es schon;
                // die Kachel fängt die Taste selbst.
                Button("Kachel schließen  (⌘W)") { paneCommand(.close) }
            }
        }

        // Natives Einstellungen-Fenster (⌘, — der Menüpunkt "Einstellungen…" im
        // App-Menü kommt mit der Settings-Szene automatisch). Aufbau: `Settings/`.
        Settings {
            SettingsWindow()
        }
    }
}
