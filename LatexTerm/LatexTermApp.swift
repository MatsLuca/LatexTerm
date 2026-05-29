import SwiftUI
import AppKit

@main
struct LatexTermApp: App {

    @ObservedObject private var settings = FormulaSettings.shared

    var body: some Scene {
        WindowGroup("LatexTerm") {
            ZStack {
                Color(red: 23/255.0, green: 20/255.0, blue: 20/255.0)
                TerminalContainer()
                    .padding(.horizontal, 12)
            }
            .frame(minWidth: 640, minHeight: 400)
            .preferredColorScheme(.dark)
        }
        .commands {
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
    }
}
