import SwiftUI

/// Allgemein: Home-Launcher (Datenquelle) und die Ghostty-Übernahme.
struct GeneralPage: View {
    @ObservedObject private var cockpit = CockpitSettings.shared
    @State private var ghosttyPlan: GhosttyConfig.Plan?
    @State private var showGhosttyPreview = false
    private let ghosttyConfig = GhosttyConfig.load()

    var body: some View {
        Form {
            SettingsGroup("Home-Kachel",
                          help: "Die Projektliste kommt aus dem externen CLI „projekte“ (claude-werkstatt); die Befehle laufen in einer Login-Shell. Der Kontingent-Befehl darf fehlschlagen — die Zeile bleibt dann leer.") {
                TextField("Projekte-Befehl", text: $cockpit.projekteCommand)
                    .textFieldStyle(.roundedBorder)
                TextField("Kontingent-Befehl", text: $cockpit.limitsCommand)
                    .textFieldStyle(.roundedBorder)
                Toggle("Nur Projekte im Ordnerbaum", isOn: $cockpit.homeOnlyProjects)
                HStack {
                    Spacer()
                    Button("Standardbefehle") {
                        cockpit.projekteCommand = CockpitSettings.defaultProjekteCommand
                        cockpit.limitsCommand = CockpitSettings.defaultLimitsCommand
                    }
                    .disabled(cockpit.projekteCommand == CockpitSettings.defaultProjekteCommand
                              && cockpit.limitsCommand == CockpitSettings.defaultLimitsCommand)
                }
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
