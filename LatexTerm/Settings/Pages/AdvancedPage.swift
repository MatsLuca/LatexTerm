import SwiftUI
import AppKit

/// Erweitert: Steuerkanal, Diagnose, Zurücksetzen.
struct AdvancedPage: View {
    @State private var confirmReset = false
    @State private var socketActive = FileManager.default.fileExists(atPath: ControlProtocol.socketPath)

    var body: some View {
        Form {
            SettingsGroup("Steuerkanal",
                          help: "Die CLI „latexterm“ und die Claude-Code-Hooks sprechen über diesen Unix-Socket mit der App (nur der eigene Benutzer, Modus 0600). Jede Shell kennt ihre Kachel über $LATEXTERM_PANE_ID.") {
                LabeledContent("Socket") {
                    HStack {
                        Text((ControlProtocol.socketPath as NSString).abbreviatingWithTildeInPath)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Kopieren") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ControlProtocol.socketPath, forType: .string)
                        }
                    }
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(socketActive ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(socketActive ? "aktiv" : "kein Socket")
                    }
                }
            }

#if DEBUG
            SettingsGroup("Diagnose (Debug-Build)",
                          help: "Status-Log der Session-Erkennung: Roh-Wechsel, Hook-Signale, Notification-Entscheidungen.") {
                LabeledContent("Status-Log") {
                    Button("/tmp/latexterm-status.log öffnen") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/tmp/latexterm-status.log"))
                    }
                }
            }
#endif

            SettingsGroup("Zurücksetzen",
                          help: "Löscht alle gespeicherten Einstellungen (Darstellung, Kacheln, Claude, Formeln, Home-Befehle). Session-Snapshot und Ghostty-Config bleiben unberührt.") {
                HStack {
                    Spacer()
                    Button("Alle Einstellungen zurücksetzen…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .confirmationDialog("Alle Einstellungen auf die Standardwerte zurücksetzen?",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Zurücksetzen", role: .destructive) { SettingsReset.run() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Wirkt sofort auf alle Kacheln. Lässt sich nicht rückgängig machen.")
        }
        .onAppear { socketActive = FileManager.default.fileExists(atPath: ControlProtocol.socketPath) }
    }
}

/// Löscht alle `LatexTerm.*`-Keys und lässt die Stores neu laden — dieselben Setter-Pfade wie
/// bei jeder Einzeländerung, damit alle Kacheln live folgen. Der Migrations-Marker bleibt
/// (die Migration setzt nur Defaults, die nach dem Reset ohnehin gelten).
enum SettingsReset {
    static let prefix = "LatexTerm."

    static func run() {
        let d = UserDefaults.standard
        for key in d.dictionaryRepresentation().keys
        where key.hasPrefix(prefix) && !key.hasPrefix(prefix + "migration.") {
            d.removeObject(forKey: key)
        }
        ThemeStore.shared.load()
        FormulaSettings.shared.load()
        CockpitSettings.shared.load()
    }
}
