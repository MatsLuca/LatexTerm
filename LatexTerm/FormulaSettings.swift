import AppKit
import Combine

/// Einstellungen der LaTeX-Formel-Darstellung — und nur die (Akzent, Zeilenabstand, Schrift
/// liegen seit dem Settings-Umbau in `ThemeStore`). Persistiert in UserDefaults; jede Änderung
/// postet `didChange`, worauf der `OverlayController` alle Formeln neu rendert.
final class FormulaSettings: ObservableObject {

    static let shared = FormulaSettings()
    static let didChange = Notification.Name("FormulaSettings.didChange")

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let formulaColorRed   = "LatexTerm.formulaColor.red"
        static let formulaColorGreen = "LatexTerm.formulaColor.green"
        static let formulaColorBlue  = "LatexTerm.formulaColor.blue"
        static let formulaColorAlpha = "LatexTerm.formulaColor.alpha"
        static let formulasEnabled   = "LatexTerm.formulasEnabled"
        static let formulaScale      = "LatexTerm.formulaScale"
    }

    // MARK: - Defaults

    /// Formeln ohne eigene Farbwahl folgen dem Theme-Vordergrund.
    static var defaultFormulaColor: NSColor { ThemeStore.shared.theme.foreground }
    static let defaultFormulaScale: CGFloat = 1.0
    static let minFormulaScale: CGFloat = 0.5
    static let maxFormulaScale: CGFloat = 2.0
    static let formulaScaleStep: CGFloat = 0.1

    // MARK: - Published Properties

    @Published var formulaColor: NSColor = FormulaSettings.defaultFormulaColor {
        didSet { guard !loading else { return }; saveColor(formulaColor); post() }
    }

    @Published var formulasEnabled: Bool = true {
        didSet { guard !loading else { return }; UserDefaults.standard.set(formulasEnabled, forKey: Keys.formulasEnabled); post() }
    }

    @Published var formulaScale: CGFloat = FormulaSettings.defaultFormulaScale {
        didSet { guard !loading else { return }; UserDefaults.standard.set(Double(formulaScale), forKey: Keys.formulaScale); post() }
    }

    // MARK: - Init

    /// Während `load()` schreiben/posten die Setter nicht (sonst würde z. B. die Theme-FG
    /// als „eigene“ Formelfarbe gespeichert).
    private var loading = false

    private init() { load() }

    /// Aus UserDefaults (neu) lesen — Start und „Alle Einstellungen zurücksetzen“.
    func load() {
        loading = true
        defer { loading = false }
        let d = UserDefaults.standard

        // Formelfarbe laden (ohne gespeicherte Wahl: Theme-Vordergrund)
        let themeFg = ThemeStore.shared.theme.foreground.usingColorSpace(.sRGB) ?? ThemeStore.shared.theme.foreground
        let r = d.object(forKey: Keys.formulaColorRed) != nil
            ? CGFloat(d.double(forKey: Keys.formulaColorRed)) : themeFg.redComponent
        let g = d.object(forKey: Keys.formulaColorGreen) != nil
            ? CGFloat(d.double(forKey: Keys.formulaColorGreen)) : themeFg.greenComponent
        let b = d.object(forKey: Keys.formulaColorBlue) != nil
            ? CGFloat(d.double(forKey: Keys.formulaColorBlue)) : themeFg.blueComponent
        let a = d.object(forKey: Keys.formulaColorAlpha) != nil
            ? CGFloat(d.double(forKey: Keys.formulaColorAlpha)) : CGFloat(1.0)
        // sRGB laden, weil saveColor in sRGB-Komponenten speichert — ein calibrated
        // geladener NSColor wäre nie `==`/komponentengleich zu den gespeicherten Werten.
        formulaColor = NSColor(srgbRed: r, green: g, blue: b, alpha: a)

        // formulasEnabled laden (default: true)
        formulasEnabled = d.object(forKey: Keys.formulasEnabled) != nil
            ? d.bool(forKey: Keys.formulasEnabled) : true

        // Formelgröße laden (default: 1.0)
        let scale = d.object(forKey: Keys.formulaScale) != nil
            ? CGFloat(d.double(forKey: Keys.formulaScale)) : Self.defaultFormulaScale
        formulaScale = max(Self.minFormulaScale, min(Self.maxFormulaScale, scale))
        loading = false
        post()
    }

    // MARK: - Helpers

    private func saveColor(_ c: NSColor) {
        guard let rgb = c.usingColorSpace(.sRGB) else { return }
        let d = UserDefaults.standard
        d.set(Double(rgb.redComponent),   forKey: Keys.formulaColorRed)
        d.set(Double(rgb.greenComponent), forKey: Keys.formulaColorGreen)
        d.set(Double(rgb.blueComponent),  forKey: Keys.formulaColorBlue)
        d.set(Double(rgb.alphaComponent), forKey: Keys.formulaColorAlpha)
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Mutating Actions (für Menüleiste)

    func increaseFormulaScale() {
        formulaScale = min(Self.maxFormulaScale,
                           (formulaScale + Self.formulaScaleStep).rounded(toPlaces: 1))
    }

    func decreaseFormulaScale() {
        formulaScale = max(Self.minFormulaScale,
                           (formulaScale - Self.formulaScaleStep).rounded(toPlaces: 1))
    }

    func resetFormulaScale() {
        formulaScale = Self.defaultFormulaScale
    }

}

// MARK: - Double rounding helper

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10.0, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}
