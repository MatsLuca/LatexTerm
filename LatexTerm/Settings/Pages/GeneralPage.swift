import SwiftUI

/// Allgemein: Home-Kachel-Ansicht und die Ghostty-Übernahme. (Die Datenquellen-Befehle stehen unter „Erweitert“.)
struct GeneralPage: View {
    @ObservedObject private var cockpit = CockpitSettings.shared
    @State private var ghosttyPlan: GhosttyConfig.Plan?
    @State private var showGhosttyPreview = false
    private let ghosttyConfig = GhosttyConfig.load()

    var body: some View {
        Form {
            SettingsGroup("Home-Kachel",
                          help: "Reduziert den Ordnerbaum auf Projekte und die Ordner dorthin (⌘⇧B in der Kachel).") {
                Toggle("Nur Projekte im Ordnerbaum", isOn: $cockpit.homeOnlyProjects)
            }

            SettingsGroup("Ghostty",
                          help: "Übernimmt Theme, Schrift, Größe, Innenabstand, Cursor und Fett-Darstellung aus ~/.config/ghostty/config — nur auf Knopfdruck, mit Vorschau. LatexTerm liest die Datei sonst nie.") {
                LabeledContent("Konfiguration") {
                    HStack {
                        Button("Aus Ghostty übernehmen…") {
                            guard let cfg = ghosttyConfig else { return }
                            ghosttyPlan = cfg.plan()
                            showGhosttyPreview = true
                        }
                        .disabled(ghosttyConfig == nil)
                        if ghosttyConfig == nil {
                            Text("keine ~/.config/ghostty/config").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                }
            }
        }
        .alert("Aus Ghostty übernehmen", isPresented: $showGhosttyPreview, presenting: ghosttyPlan) { plan in
            if !plan.isEmpty {
                Button("Übernehmen") { GhosttyConfig.apply(plan) }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { plan in
            Text(GhosttyConfig.describe(plan).joined(separator: "\n"))
        }
    }
}
