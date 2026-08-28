import SwiftUI

/// Einstellungen-Fenster (⌘,): Toolbar-Tabs wie in den Systemeinstellungen, eine Seite je
/// `SettingsPage`. Die Seiten schreiben ausschließlich über die Stores (`ThemeStore`,
/// `FormulaSettings`, `CockpitSettings`) — dieselben Pfade wie die Menü-Kürzel, keine zweite
/// Wahrheit und kein `@AppStorage` in einer View.
struct SettingsWindow: View {
    static let width: CGFloat = 560
    /// Zuletzt offene Seite (nur Komfort; ein Reset darf sie mitlöschen).
    @AppStorage("LatexTerm.settingsPage") private var pageID = SettingsPage.general.rawValue

    private var page: Binding<SettingsPage> {
        Binding(get: { SettingsPage(rawValue: pageID) ?? .general }, set: { pageID = $0.rawValue })
    }

    var body: some View {
        TabView(selection: page) {
            ForEach(SettingsPage.allCases) { p in
                p.view
                    .formStyle(.grouped)
                    .tabItem { Label(p.title, systemImage: p.symbol) }
                    .tag(p)
            }
        }
        .frame(width: Self.width, height: page.wrappedValue.height)
    }
}
