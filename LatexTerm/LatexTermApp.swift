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
            newHomePane()
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

    init() { AppearanceMigration.run() }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = FormulaSettings.shared
    @ObservedObject private var homeFocus = HomeFocus.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    @ObservedObject private var cockpit = CockpitSettings.shared

    var body: some Scene {
        WindowGroup("LatexTerm") {
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
            // Ablage → Neu: ⌘N Home-Kachel (Projekt-Launcher) statt SwiftUIs „Neues Fenster",
            // ⌘T Terminal-Kachel (nackte Shell, CWD-Erbe). Die Tasten fängt die Kachel selbst
            // (LatexTerminalView.performKeyEquivalent); das Menü ist Schaufenster + Mausweg.
            CommandGroup(replacing: .newItem) {
                Button("Neue Home-Kachel") {
                    NotificationCenter.default.post(name: .latexTermNewHomePane, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Neue Terminal-Kachel") { paneCommand(.split) }
                    .keyboardShortcut("t", modifiers: .command)
            }
            // Home-Kachel: die Befehle stehen im Menü statt in einer Fußzeile in der Kachel
            // (Runde 15). Die Tastenwege selbst fängt HomePaneView.performKeyEquivalent ab —
            // die Kachel ist vor dem Menü dran; die Einträge hier sind Schaufenster + Mausweg.
            CommandMenu("Home") {
                let aus = homeFocus.active == nil
                Button("Neues Projekt…") { HomeFocus.shared.active?.menuNewProject() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(aus)
                Button("Neu laden") { HomeFocus.shared.active?.menuReload() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(aus)
                Divider()
                Button("Session anpinnen") { HomeFocus.shared.active?.menuPinSession() }
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
                Button("Zoomen / Zoom beenden") { paneCommand(.zoom) }
                    .keyboardShortcut(.return, modifiers: .command)
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
                // Kein ⌘W als Menükürzel: SwiftUIs „Schließen“ im Ablage-Menü trägt es schon;
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
