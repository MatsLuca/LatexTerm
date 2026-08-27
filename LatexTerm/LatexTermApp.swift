import SwiftUI
import AppKit

/// Dock-Menü (Rechtsklick aufs Dock-Icon): Quickstarts aus der Datenschicht (`config.toml`
/// → `projekte --json` → `quickstarts[]`). Die App kennt keine Pfade und keine Befehle —
/// sie zeigt, was der Store zuletzt gesehen hat, und reicht den Eintrag an das Fenster weiter.
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

    @objc private func runQuickstart(_ sender: NSMenuItem) {
        let items = QuickstartStore.shared.items
        guard items.indices.contains(sender.tag) else { return }
        // Erst aktivieren, dann posten: das Fenster soll Key sein, wenn der Split-View prüft.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: .latexTermQuickstart, object: nil, userInfo: ["quickstart": items[sender.tag]])
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

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var settings = FormulaSettings.shared
    @ObservedObject private var homeFocus = HomeFocus.shared
    /// Reduzierter Baum (nur Projekte und die Ordner dorthin) — gilt für alle Home-Kacheln.
    @AppStorage("LatexTerm.homeOnlyProjects") private var onlyProjects = false

    var body: some Scene {
        WindowGroup("LatexTerm") {
            ZStack {
                Color(red: 23/255.0, green: 20/255.0, blue: 20/255.0)
                // Bewusst OHNE horizontales Padding: die Akzent-Outlines der
                // Kacheln sollen an den physischen Fensterkanten anliegen.
                TerminalContainer()
            }
            .frame(minWidth: 640, minHeight: 400)
            .preferredColorScheme(.dark)
        }
        .commands {
            // ⌘N: Home-Kachel (Projekt-Launcher) statt SwiftUIs „Neues Fenster".
            // ⌘T (nackte Shell, CWD-Erbe) bleibt in LatexTerminalView.performKeyEquivalent.
            CommandGroup(replacing: .newItem) {
                Button("Neue Home-Kachel") {
                    NotificationCenter.default.post(name: .latexTermNewHomePane, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
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
                Toggle("Nur Projekte", isOn: Binding(
                    get: { onlyProjects },
                    set: { onlyProjects = $0; NotificationCenter.default.post(name: .latexTermHomeTreeChanged, object: nil) }))
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
            CommandMenu("Terminal") {

                // MARK: LaTeX-Optionen
                Toggle("LaTeX-Formeln anzeigen", isOn: $settings.formulasEnabled)
                    .keyboardShortcut("l", modifiers: .command)

                Button("Formelfarbe…") {
                    settings.openColorPicker()
                }

                Menu("Formelgröße") {
                    Button("Erhöhen") {
                        settings.increaseFormulaScale()
                    }
                    .keyboardShortcut("+", modifiers: [.command, .option])

                    Button("Verringern") {
                        settings.decreaseFormulaScale()
                    }
                    .keyboardShortcut("-", modifiers: [.command, .option])

                    Button("Zurücksetzen  (aktuell: \(String(format: "%.1f", settings.formulaScale))×)") {
                        settings.resetFormulaScale()
                    }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                }

                Divider()

                // MARK: Terminal-Optionen
                Toggle("Automatische Akzentfarbe", isOn: $settings.isAdaptiveAccent)
                    .keyboardShortcut("a", modifiers: [.command, .control])

                Button("Terminal-Akzentfarbe…") {
                    settings.openAccentColorPicker()
                }
                .disabled(settings.isAdaptiveAccent)

                Menu("Zeilenabstand") {
                    Button("Erhöhen") {
                        settings.increaseLineSpacing()
                    }
                    .keyboardShortcut("+", modifiers: [.command, .shift])

                    Button("Verringern") {
                        settings.decreaseLineSpacing()
                    }
                    .keyboardShortcut("-", modifiers: [.command, .shift])

                    Button("Zurücksetzen  (aktuell: \(Int(settings.extraLineSpacing)) px)") {
                        settings.resetLineSpacing()
                    }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                }
            }
        }

        // Natives Einstellungen-Fenster (⌘, — der Menüpunkt "Einstellungen…" im
        // App-Menü kommt mit der Settings-Szene automatisch).
        Settings {
            SettingsView()
        }
    }
}
