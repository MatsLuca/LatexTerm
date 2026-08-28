import SwiftUI

/// Kacheln: Akzentfarbe und Fokus-Darstellung.
struct PanesPage: View {
    @ObservedObject private var store = ThemeStore.shared

    var body: some View {
        Form {
            SettingsGroup("Akzentfarbe",
                          help: "Caret, Kachelrahmen und Home-Ring tragen die Akzentfarbe. „Automatisch“ leitet sie aus dem Kachelinhalt ab (Kontrastanalyse). Kacheln mit Projektfarbe aus dem Launcher oder per OSC-Override behalten ihre eigene.") {
                Toggle("Automatisch aus dem Inhalt", isOn: $store.isAdaptiveAccent)
                ColorRow(title: "Feste Akzentfarbe", color: $store.accentColor)
                    .disabled(store.isAdaptiveAccent)
            }

            SettingsGroup("Fokus",
                          help: "Der Rahmen zeigt die Session-Kennung in ihrer Akzentfarbe (bei ≥ 2 Kacheln die fokussierte kräftiger). Ohne Abdunkeln bleiben alle Kacheln voll sichtbar; den Fokus zeigt dann nur der Rahmen.") {
                Toggle("Kachel-Akzentrahmen", isOn: $store.paneBorders)
                Toggle("Unfokussierte Kacheln abdunkeln", isOn: $store.focusDimming)
            }
        }
    }
}
