import SwiftUI

/// Die Seiten des Einstellungen-Fensters (⌘,), in Anzeige-Reihenfolge = Häufigkeit des
/// Nachschauens. **Neue Seite = ein Case hier + eine Datei in `Pages/`.** Die Höhe steht hier,
/// weil SwiftUIs Settings-Fenster sich nicht selbst an den Tab-Inhalt anpasst.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, appearance, panes, claude, formulas, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Allgemein"
        case .appearance: return "Darstellung"
        case .panes: return "Kacheln"
        case .claude: return "Claude"
        case .formulas: return "Formeln"
        case .advanced: return "Erweitert"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gear"
        case .appearance: return "paintbrush"
        case .panes: return "rectangle.split.2x2"
        case .claude: return "sparkles"
        case .formulas: return "function"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var height: CGFloat {
        switch self {
        case .general: return 300
        case .appearance: return 600
        case .panes: return 330
        case .claude: return 560
        case .formulas: return 260
        case .advanced: return 560
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .general: GeneralPage()
        case .appearance: AppearancePage()
        case .panes: PanesPage()
        case .claude: ClaudePage()
        case .formulas: FormulasPage()
        case .advanced: AdvancedPage()
        }
    }
}
