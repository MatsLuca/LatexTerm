import SwiftUI

/// Claude-Code-Cockpit: Benachrichtigungen und der experimentelle Prompt-Text-Stil.
struct ClaudePage: View {
    @ObservedObject private var cockpit = CockpitSettings.shared
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        Form {
            SettingsGroup("Benachrichtigungen",
                          help: "„Claude braucht Input“ / „Claude ist fertig“ kommen aus den Claude-Code-Hooks (OSC 5522); Terminal-Glocke und passive Erkennung sind Fallback. Klick auf ein Banner holt die Kachel nach vorn.") {
                Toggle("Benachrichtigungen zeigen", isOn: $cockpit.notificationsEnabled)
                Toggle("Nur wenn die Session unbeobachtet ist", isOn: $cockpit.notifyOnlyUnobserved)
                    .disabled(!cockpit.notificationsEnabled)
                SliderRow(title: "Mindestabstand", value: $cockpit.notificationCooldown,
                          range: CockpitSettings.cooldownRange, unit: " s")
                    .disabled(!cockpit.notificationsEnabled)
            }

            SettingsGroup("Prompt-Text (experimentell)",
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
