import SwiftUI
import AppKit

/// Natives Einstellungen-Fenster (⌘,). Macht alle Optionen, die bisher nur über das
/// "Terminal"-Menü + NSColorPanel erreichbar waren, an einem Ort sichtbar und direkt
/// manipulierbar (Slider mit Live-Wert statt blinder ±-Menüpunkte).
///
/// Schreibt über dieselben Pfade wie die Menü-Shortcuts — `FormulaSettings` für alles
/// Formel-/Akzent-bezogene, UserDefaults + `fontDidChange`-Broadcast für die global
/// synchronisierte Schriftgröße. Keine zweite Wahrheit, Menü und Fenster bleiben
/// automatisch konsistent.
struct SettingsView: View {
    @ObservedObject private var settings = FormulaSettings.shared
    @ObservedObject private var themeStore = ThemeStore.shared
    private let themeNames = ThemeStore.availableNames
    @AppStorage(LatexTerminalView.fontSizeKey)
    private var fontSize: Double = Double(LatexTerminalView.defaultFontSize)

    var body: some View {
        Form {
            Section("Formeln") {
                Toggle("LaTeX-Formeln anzeigen", isOn: $settings.formulasEnabled)
                ColorPicker("Formelfarbe", selection: formulaColor, supportsOpacity: false)
                LabeledContent("Formelgröße") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.formulaScale,
                               in: FormulaSettings.minFormulaScale...FormulaSettings.maxFormulaScale,
                               step: FormulaSettings.formulaScaleStep)
                        Text(String(format: "%.1f×", settings.formulaScale))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section("Darstellung") {
                // Eingebaut (Dark+, Ember) + alle Ghostty-Themes, sofern Ghostty installiert ist.
                Picker("Theme", selection: themeName) {
                    ForEach(themeNames, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Fett als helle Farbe", isOn: $themeStore.boldIsBright)
                Toggle("Cursor blinkt", isOn: $themeStore.cursorBlink)
            }

            Section("Terminal") {
                LabeledContent("Schriftgröße") {
                    HStack(spacing: 8) {
                        Slider(value: $fontSize,
                               in: Double(LatexTerminalView.minFontSize)...Double(LatexTerminalView.maxFontSize),
                               step: 1)
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Zeilenabstand") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.extraLineSpacing,
                               in: FormulaSettings.minLineSpacing...FormulaSettings.maxLineSpacing,
                               step: FormulaSettings.lineSpacingStep)
                        Text("\(Int(settings.extraLineSpacing)) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Automatische Akzentfarbe", isOn: $settings.isAdaptiveAccent)
                ColorPicker("Akzentfarbe", selection: accentColor, supportsOpacity: false)
                    .disabled(settings.isAdaptiveAccent)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        // Schriftgröße geht nicht über FormulaSettings, sondern über den bestehenden
        // Broadcast — jede Kachel übernimmt sie in `applyFont` (dort gegen den
        // aktuellen Wert geguardet, der Slider-Drag ist also nicht teuer).
        .onChange(of: fontSize) { _, new in
            NotificationCenter.default.post(
                name: LatexTerminalView.fontDidChange, object: nil,
                userInfo: ["size": CGFloat(new)])
        }
    }

    // NSColor (Modell, AppKit) ↔ Color (SwiftUI-Picker). Der Setter läuft durch
    // FormulaSettings.saveColor und wird dort nach sRGB konvertiert.
    private var formulaColor: Binding<Color> {
        Binding(get: { Color(nsColor: settings.formulaColor) },
                set: { settings.formulaColor = NSColor($0) })
    }

    private var themeName: Binding<String> {
        Binding(get: { themeStore.themeName }, set: { themeStore.themeName = $0 })
    }

    private var accentColor: Binding<Color> {
        Binding(get: { Color(nsColor: settings.accentColor) },
                set: { settings.accentColor = NSColor($0) })
    }
}
