import SwiftUI

/// Formeln: LaTeX-Overlays (KaTeX) über `$…$`, `$$…$$`, `\(…\)`, `\[…\]`.
struct FormulasPage: View {
    @ObservedObject private var settings = FormulaSettings.shared

    var body: some View {
        Form {
            SettingsGroup("LaTeX-Formeln",
                          help: "Formeln zwischen $…$, $$…$$, \\(…\\) und \\[…\\] werden als KaTeX-Overlay über den Quelltext gelegt (⌘L schaltet um). Ohne eigene Farbwahl folgt die Formelfarbe dem Theme-Vordergrund.") {
                Toggle("Formeln anzeigen", isOn: $settings.formulasEnabled)
                ColorRow(title: "Formelfarbe", color: $settings.formulaColor)
                SliderRow(title: "Größe", value: $settings.formulaScale.asDouble,
                          range: Double(FormulaSettings.minFormulaScale)...Double(FormulaSettings.maxFormulaScale),
                          step: Double(FormulaSettings.formulaScaleStep), unit: "×", decimals: 1)
            }
        }
    }
}
