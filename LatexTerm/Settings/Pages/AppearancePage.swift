import SwiftUI
import AppKit

/// Darstellung: Theme, Schrift, Fenster, Cursor — alles aus `ThemeStore`.
struct AppearancePage: View {
    @ObservedObject private var store = ThemeStore.shared
    private let themeNames = ThemeStore.availableNames
    private let fontFamilies = AppFonts.availableMonospaceFamilies

    var body: some View {
        Form {
            SettingsGroup("Theme",
                          help: "Eingebaut sind Dark+ und Ember; dazu alle Ghostty-Themes, sobald Ghostty installiert ist (~/.config/ghostty/themes und Ghostty.app).") {
                Picker("Theme", selection: themeName) {
                    ForEach(themeNames, id: \.self) { Text($0).tag($0) }
                }
                ThemePreviewRow(theme: store.theme)
            }

            SettingsGroup("Schrift",
                          help: "„Schrift verstärken“ ist macOS-Font-Smoothing (Ghostty font-thicken). „Fett als helle Farbe“ lässt fetten Text in ANSI 0–7 auf die helle Palette springen — Terminal.app-Art, Ghostty: aus.") {
                Picker("Familie", selection: $store.fontFamily) {
                    ForEach(fontFamilies, id: \.self) { Text($0).tag($0) }
                    Text("System (SF Mono)").tag("")
                }
                SliderRow(title: "Größe", value: $store.fontSize.asDouble,
                          range: Double(ThemeStore.fontSizeRange.lowerBound)...Double(ThemeStore.fontSizeRange.upperBound),
                          unit: " pt")
                SliderRow(title: "Zeilenabstand", value: $store.lineSpacing.asDouble,
                          range: Double(ThemeStore.lineSpacingRange.lowerBound)...Double(ThemeStore.lineSpacingRange.upperBound),
                          step: Double(ThemeStore.lineSpacingStep), unit: " px")
                Toggle("Schrift verstärken (Font-Smoothing)", isOn: $store.fontThicken)
                Toggle("Fett als helle Farbe", isOn: $store.boldIsBright)
            }

            SettingsGroup("Fenster") {
                SliderRow(title: "Innenabstand", value: $store.padding.asDouble,
                          range: Double(ThemeStore.paddingRange.lowerBound)...Double(ThemeStore.paddingRange.upperBound),
                          unit: " px")
            }

            SettingsGroup("Cursor",
                          help: "Standard ist die Projekt- bzw. Akzentfarbe der Kachel; alternativ die Cursorfarbe des Themes (Ghostty: Weiß).") {
                Toggle("Cursor blinkt", isOn: $store.cursorBlink)
                Toggle("Cursor in Theme-Farbe", isOn: $store.cursorThemeColor)
            }
        }
    }

    private var themeName: Binding<String> {
        Binding(get: { store.themeName }, set: { store.themeName = $0 })
    }
}

/// Grund, Vordergrund und die 16 ANSI-Farben als Kacheln — bei 460 Ghostty-Themes hilft
/// blindes Durchklicken nicht.
struct ThemePreviewRow: View {
    let theme: TerminalTheme

    var body: some View {
        LabeledContent("Vorschau") {
            HStack(spacing: 3) {
                swatch(theme.background, wide: true)
                swatch(theme.foreground, wide: true)
                Spacer().frame(width: 6)
                ForEach(0..<8, id: \.self) { i in
                    VStack(spacing: 3) {
                        swatch(theme.ansi[i])
                        swatch(theme.ansi[i + 8])
                    }
                }
            }
        }
    }

    private func swatch(_ c: NSColor, wide: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: c))
            .frame(width: wide ? 28 : 14, height: wide ? 31 : 14)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.primary.opacity(0.15), lineWidth: 0.5))
    }
}
