import AppKit
import Combine

/// Zentrale Einstellungen für die LaTeX-Formel-Darstellung.
/// Persistiert in UserDefaults, broadcastet Änderungen via NotificationCenter.
final class FormulaSettings: ObservableObject {

    static let shared = FormulaSettings()

    /// Notification, die nach jeder Einstellungsänderung gepostet wird.
    /// OverlayController hört darauf und triggert einen Rescan.
    static let didChange = Notification.Name("FormulaSettings.didChange")

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let formulaColorRed   = "LatexTerm.formulaColor.red"
        static let formulaColorGreen = "LatexTerm.formulaColor.green"
        static let formulaColorBlue  = "LatexTerm.formulaColor.blue"
        static let formulaColorAlpha = "LatexTerm.formulaColor.alpha"
        static let accentColorRed    = "LatexTerm.accentColor.red"
        static let accentColorGreen  = "LatexTerm.accentColor.green"
        static let accentColorBlue   = "LatexTerm.accentColor.blue"
        static let accentColorAlpha  = "LatexTerm.accentColor.alpha"
        static let isAdaptiveAccent  = "LatexTerm.isAdaptiveAccent"
        static let formulasEnabled   = "LatexTerm.formulasEnabled"
        static let extraLineSpacing  = "LatexTerm.extraLineSpacing"
        static let formulaScale      = "LatexTerm.formulaScale"
    }

    // MARK: - Defaults

    static let defaultFormulaColor   = NSColor(red: 230/255.0, green: 225/255.0, blue: 225/255.0, alpha: 1.0)
    static let defaultAccentColor    = NSColor(red: 232/255.0, green: 94/255.0, blue: 62/255.0, alpha: 1.0)
    static let defaultLineSpacing: CGFloat = 8
    static let defaultFormulaScale: CGFloat = 1.0
    static let minLineSpacing: CGFloat = 0
    static let maxLineSpacing: CGFloat = 40
    static let minFormulaScale: CGFloat = 0.5
    static let maxFormulaScale: CGFloat = 2.0
    static let lineSpacingStep: CGFloat = 2
    static let formulaScaleStep: CGFloat = 0.1

    // MARK: - Published Properties

    @Published var formulaColor: NSColor {
        didSet { saveColor(formulaColor); postChange() }
    }

    @Published var accentColor: NSColor {
        didSet { saveAccentColor(accentColor); postChange() }
    }

    @Published var isAdaptiveAccent: Bool {
        didSet {
            UserDefaults.standard.set(isAdaptiveAccent, forKey: Keys.isAdaptiveAccent)
            postChange()
        }
    }

    @Published var formulasEnabled: Bool {
        didSet {
            UserDefaults.standard.set(formulasEnabled, forKey: Keys.formulasEnabled)
            postChange()
        }
    }

    @Published var extraLineSpacing: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(extraLineSpacing), forKey: Keys.extraLineSpacing)
            postChange()
        }
    }

    @Published var formulaScale: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(formulaScale), forKey: Keys.formulaScale)
            postChange()
        }
    }

    // MARK: - Init

    private init() {
        let d = UserDefaults.standard

        // Formelfarbe laden
        let r = d.object(forKey: Keys.formulaColorRed) != nil
            ? CGFloat(d.double(forKey: Keys.formulaColorRed)) : CGFloat(230/255.0)
        let g = d.object(forKey: Keys.formulaColorGreen) != nil
            ? CGFloat(d.double(forKey: Keys.formulaColorGreen)) : CGFloat(225/255.0)
        let b = d.object(forKey: Keys.formulaColorBlue) != nil
            ? CGFloat(d.double(forKey: Keys.formulaColorBlue)) : CGFloat(225/255.0)
        let a = d.object(forKey: Keys.formulaColorAlpha) != nil
            ? CGFloat(d.double(forKey: Keys.formulaColorAlpha)) : CGFloat(1.0)
        formulaColor = NSColor(calibratedRed: r, green: g, blue: b, alpha: a)

        // Akzentfarbe laden
        let ar = d.object(forKey: Keys.accentColorRed) != nil
            ? CGFloat(d.double(forKey: Keys.accentColorRed)) : CGFloat(232/255.0)
        let ag = d.object(forKey: Keys.accentColorGreen) != nil
            ? CGFloat(d.double(forKey: Keys.accentColorGreen)) : CGFloat(94/255.0)
        let ab = d.object(forKey: Keys.accentColorBlue) != nil
            ? CGFloat(d.double(forKey: Keys.accentColorBlue)) : CGFloat(62/255.0)
        let aa = d.object(forKey: Keys.accentColorAlpha) != nil
            ? CGFloat(d.double(forKey: Keys.accentColorAlpha)) : CGFloat(1.0)
        accentColor = NSColor(calibratedRed: ar, green: ag, blue: ab, alpha: aa)

        // isAdaptiveAccent laden (default: false)
        isAdaptiveAccent = d.object(forKey: Keys.isAdaptiveAccent) != nil
            ? d.bool(forKey: Keys.isAdaptiveAccent) : false

        // formulasEnabled laden (default: true)
        formulasEnabled = d.object(forKey: Keys.formulasEnabled) != nil
            ? d.bool(forKey: Keys.formulasEnabled) : true

        // Zeilenabstand laden (default: 8)
        let spacing = d.object(forKey: Keys.extraLineSpacing) != nil
            ? CGFloat(d.double(forKey: Keys.extraLineSpacing)) : Self.defaultLineSpacing
        extraLineSpacing = max(Self.minLineSpacing, min(Self.maxLineSpacing, spacing))

        // Formelgröße laden (default: 1.0)
        let scale = d.object(forKey: Keys.formulaScale) != nil
            ? CGFloat(d.double(forKey: Keys.formulaScale)) : Self.defaultFormulaScale
        formulaScale = max(Self.minFormulaScale, min(Self.maxFormulaScale, scale))
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

    private func saveAccentColor(_ c: NSColor) {
        guard let rgb = c.usingColorSpace(.sRGB) else { return }
        let d = UserDefaults.standard
        d.set(Double(rgb.redComponent),   forKey: Keys.accentColorRed)
        d.set(Double(rgb.greenComponent), forKey: Keys.accentColorGreen)
        d.set(Double(rgb.blueComponent),  forKey: Keys.accentColorBlue)
        d.set(Double(rgb.alphaComponent), forKey: Keys.accentColorAlpha)
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: - Mutating Actions (für Menüleiste)

    func increaseLineSpacing() {
        extraLineSpacing = min(Self.maxLineSpacing, extraLineSpacing + Self.lineSpacingStep)
    }

    func decreaseLineSpacing() {
        extraLineSpacing = max(Self.minLineSpacing, extraLineSpacing - Self.lineSpacingStep)
    }

    func resetLineSpacing() {
        extraLineSpacing = Self.defaultLineSpacing
    }

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

    func openColorPicker(for target: FormulaColorProxy.ColorTarget) {
        FormulaColorProxy.shared.currentTarget = target
        let panel = NSColorPanel.shared
        panel.color = target == .formula ? formulaColor : accentColor
        panel.isContinuous = true
        panel.showsAlpha = false
        panel.orderFront(nil)

        // NSColorPanel target/action auf AppDelegate-Proxy setzen
        NSColorPanel.shared.setTarget(FormulaColorProxy.shared)
        NSColorPanel.shared.setAction(#selector(FormulaColorProxy.colorChanged(_:)))
    }

    func openColorPicker() {
        openColorPicker(for: .formula)
    }

    func openAccentColorPicker() {
        openColorPicker(for: .accent)
    }
}

// MARK: - Proxy für NSColorPanel-Callback

/// NSColorPanel braucht ein Objective-C-kompatibles target/action.
/// Dieser Proxy leitet die Farbänderung an FormulaSettings weiter.
final class FormulaColorProxy: NSObject {
    enum ColorTarget {
        case formula
        case accent
    }

    static let shared = FormulaColorProxy()
    var currentTarget: ColorTarget = .formula

    @objc func colorChanged(_ sender: NSColorPanel) {
        if currentTarget == .formula {
            FormulaSettings.shared.formulaColor = sender.color
        } else {
            FormulaSettings.shared.accentColor = sender.color
        }
    }
}

// MARK: - Double rounding helper

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let factor = pow(10.0, CGFloat(places))
        return (self * factor).rounded() / factor
    }
}
