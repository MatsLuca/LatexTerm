import SwiftUI
import AppKit

@main
struct LatexTermApp: App {

    @ObservedObject private var settings = FormulaSettings.shared

    var body: some Scene {
        WindowGroup("LatexTerm") {
            TerminalContainer()
                .frame(minWidth: 640, minHeight: 400)
        }
        .commands {
            CommandMenu("Formeln") {

                // MARK: Toggle
                Toggle("Formeln anzeigen", isOn: $settings.formulasEnabled)
                    .keyboardShortcut("l", modifiers: .command)

                Divider()

                // MARK: Formelfarbe
                Button("Formelfarbe…") {
                    settings.openColorPicker()
                }

                Divider()

                // MARK: Zeilenabstand
                Button("Zeilenabstand erhöhen") {
                    settings.increaseLineSpacing()
                }
                .keyboardShortcut("+", modifiers: [.command, .shift])

                Button("Zeilenabstand verringern") {
                    settings.decreaseLineSpacing()
                }
                .keyboardShortcut("-", modifiers: [.command, .shift])

                Button("Zeilenabstand zurücksetzen  (aktuell: \(Int(settings.extraLineSpacing)) px)") {
                    settings.resetLineSpacing()
                }
                .keyboardShortcut("0", modifiers: [.command, .shift])

                Divider()

                // MARK: Formelgröße
                Button("Formelgröße erhöhen") {
                    settings.increaseFormulaScale()
                }
                .keyboardShortcut("+", modifiers: [.command, .option])

                Button("Formelgröße verringern") {
                    settings.decreaseFormulaScale()
                }
                .keyboardShortcut("-", modifiers: [.command, .option])

                Button("Formelgröße zurücksetzen  (aktuell: \(String(format: "%.1f", settings.formulaScale))×)") {
                    settings.resetFormulaScale()
                }
                .keyboardShortcut("0", modifiers: [.command, .option])
            }
        }
    }
}
