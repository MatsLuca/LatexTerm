import SwiftUI

/// Gemeinsamer Agentenstatus plus Claude-spezifische Darstellung und Lokal-Modus.
struct ClaudePage: View {
    @ObservedObject private var cockpit = CockpitSettings.shared
    @ObservedObject private var store = ThemeStore.shared
    @ObservedObject private var lokal = LokalModusSettings.shared

    var body: some View {
        Form {
            SettingsGroup("Claude: Lokal-Modus (Ollama)",
                          help: "Launcher und Home-Kachel starten jedes Projekt über `lokal` statt `claude`: Claude Code gegen ein lokales Ollama-Modell — für „kein Internet“ oder „Tokens leer“. Permissions dann acceptEdits statt yolo; Statuszeile zeigt 🦙 mit CPU und Tok/s. Laufende Sessions bleiben unberührt.") {
                Toggle("Neue Sessions lokal starten", isOn: $lokal.enabled)
            }
            .onAppear { lokal.load() }

            SettingsGroup("Benachrichtigungen",
                          help: "Claude und Codex melden fertige Antworten und offene Fragen mit ihrem Namen. Banner zeigen Dauer, Schritte und einen kurzen Textauszug, soweit verfügbar. Abbrüche und Antworten unter 2 s bleiben stumm. Für präzisen Status braucht Claude den Bridge-Mod und Codex die LatexTerm-Hooks. Klick auf ein Banner holt die zugehörige Kachel nach vorn, auch aus einem anderen Fenster.") {
                Toggle("Benachrichtigungen zeigen", isOn: $cockpit.notificationsEnabled)
                Toggle("Nur wenn die Session unbeobachtet ist", isOn: $cockpit.notifyOnlyUnobserved)
                    .disabled(!cockpit.notificationsEnabled)
                SliderRow(title: "Mindestabstand", value: $cockpit.notificationCooldown,
                          range: CockpitSettings.cooldownRange, unit: " s")
                    .disabled(!cockpit.notificationsEnabled)
            }

            SettingsGroup("Status in der Titelleiste",
                          help: "Je Kachel ein Chip rechts in der Titelleiste: der Punkt in Kachelfarbe (Klick springt hin), daneben der Status. Kompakt: „arbeitet · 0:42“, „braucht dich“, danach „✓ fertig · 1:42“ als Nachklang, bis du hingesehen hast. Mit Details zusätzlich Werkzeug und Schritte („Bash · 0:42 · 3 Schritte“). Alle Chips in voller Länge, solange sie in die Leiste passen; sonst stufenweise kürzer bis zum Zeichen. Abbruch grau, Fehler rot. Aus: nur die Punkte.") {
                Picker("Anzeigen", selection: $cockpit.statusBadgeMode) {
                    ForEach(CockpitSettings.StatusBadgeMode.allCases) { Text($0.label).tag($0) }
                }
            }

            SettingsGroup("Claude: Prompt-Text (experimentell)",
                          help: "Färbt den getippten Text in Claude Codes Eingabe-Box (Erkennung der Box über ihre Rahmenlinien). Hängt an Claude Codes Zeichnung — kann nach einem Update aussetzen.") {
                Picker("Farbe", selection: $store.promptTintMode) {
                    ForEach(ThemeStore.PromptTintMode.allCases) { Text($0.label).tag($0) }
                }
                if store.promptTintMode == .custom {
                    ColorRow(title: "Eigene Farbe", color: $store.promptColor)
                }
                if store.promptTintMode != .off {
                    Toggle("Glühen", isOn: $store.promptGlow)
                    Toggle("Auch von Claude gefärbten Text übersteuern", isOn: $store.promptOverrideColored)
                    if store.promptOverrideColored {
                        Toggle("… in eigener Farbe", isOn: $store.promptColoredOwnColor)
                            .padding(.leading, 20)
                        if store.promptColoredOwnColor {
                            ColorRow(title: "Farbe für gefärbten Text", color: $store.promptColoredColor)
                                .padding(.leading, 20)
                        }
                    }
                    HelpText("Gefärbter Text sind Slash-Commands und @-Erwähnungen, die Claude Code selbst einfärbt.")
                }
            }
        }
    }
}
