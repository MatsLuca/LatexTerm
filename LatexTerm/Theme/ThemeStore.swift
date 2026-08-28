import AppKit
import Combine

/// Einzige Wahrheit für die Darstellung: aktuelles Theme + die Darstellungs-Schalter,
/// die nicht zur Formel-Welt (`FormulaSettings`) gehören. Persistiert in UserDefaults,
/// meldet Änderungen per `didChange` — jede Kachel, das Fenster und die Home-Kachel
/// hängen daran.
///
/// Themes kommen aus drei Quellen, in dieser Reihenfolge: eingebaut (`Dark+`, `Ember`),
/// `~/.config/ghostty/themes/<Name>`, Ghostty.app-Bundle (`…/Resources/ghostty/themes/`).
/// Gespeichert wird nur der Name; ein Name, den es nicht mehr gibt, fällt auf Dark+.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let didChange = Notification.Name("LatexTerm.ThemeStore.didChange")

    enum Keys {
        static let theme = "LatexTerm.theme"
        static let boldIsBright = "LatexTerm.boldIsBright"
        static let cursorBlink = "LatexTerm.cursorBlink"
        static let padding = "LatexTerm.padding"
        static let cursorThemeColor = "LatexTerm.cursorThemeColor"
        static let fontThicken = "LatexTerm.fontThicken"
        static let paneBorders = "LatexTerm.paneBorders"
        /// Ghostty-Config-Theme (Basis + Overrides) als `key = value`-Zeilen.
        static let customTheme = "LatexTerm.customTheme"
    }

    /// Name des aus `~/.config/ghostty/config` gebauten Themes (Basis-Theme + Farb-Overrides).
    static let customThemeName = "Ghostty (Config)"

    static let defaultPadding: CGFloat = 12
    static let paddingRange: ClosedRange<CGFloat> = 0...24

    @Published private(set) var theme: TerminalTheme

    /// Name des gewählten Themes (Menü/Settings binden hieran).
    var themeName: String {
        get { theme.name }
        set {
            guard newValue != theme.name, let t = Self.resolve(name: newValue) else { return }
            theme = t
            UserDefaults.standard.set(newValue, forKey: Keys.theme)
            post()
        }
    }

    /// Fetter Text in ANSI 0–7 springt auf die helle Palette (Terminal.app-Art). Ghostty: aus.
    @Published var boldIsBright: Bool {
        didSet { UserDefaults.standard.set(boldIsBright, forKey: Keys.boldIsBright); post() }
    }

    /// Block-Cursor blinkt. Ghostty: aus.
    @Published var cursorBlink: Bool {
        didSet { UserDefaults.standard.set(cursorBlink, forKey: Keys.cursorBlink); post() }
    }

    /// Cursor in der Theme-Cursorfarbe (Ghostty: Weiß) statt in der Projekt-/Akzentfarbe.
    @Published var cursorThemeColor: Bool {
        didSet { UserDefaults.standard.set(cursorThemeColor, forKey: Keys.cursorThemeColor); post() }
    }

    /// macOS-Font-Smoothing („Schrift verstärken“, Ghostty `font-thicken`): Striche ~1 Subpixel dicker.
    @Published var fontThicken: Bool {
        didSet { UserDefaults.standard.set(fontThicken, forKey: Keys.fontThicken); post() }
    }

    /// Farbige Akzentrahmen + Hüll-Tint der Kacheln (Session-Kennung). Aus = nur der Grund; Caret,
    /// HUD-Punkt und Home-Ring tragen die Projektfarbe weiter.
    @Published var paneBorders: Bool {
        didSet { UserDefaults.standard.set(paneBorders, forKey: Keys.paneBorders); post() }
    }

    /// Innenabstand Terminal-Text ↔ Kachelrand (Ghostty `window-padding` 15; hier 12, weil bei
    /// mehreren Kacheln der 8-px-Steg dazukommt).
    @Published var padding: CGFloat {
        didSet { UserDefaults.standard.set(Double(padding), forKey: Keys.padding); post() }
    }

    private init() {
        let d = UserDefaults.standard
        let name = d.string(forKey: Keys.theme) ?? TerminalTheme.darkPlus.name
        theme = Self.resolve(name: name) ?? .darkPlus
        boldIsBright = d.object(forKey: Keys.boldIsBright) != nil ? d.bool(forKey: Keys.boldIsBright) : false
        cursorBlink = d.object(forKey: Keys.cursorBlink) != nil ? d.bool(forKey: Keys.cursorBlink) : false
        cursorThemeColor = d.object(forKey: Keys.cursorThemeColor) != nil ? d.bool(forKey: Keys.cursorThemeColor) : false
        fontThicken = d.object(forKey: Keys.fontThicken) != nil ? d.bool(forKey: Keys.fontThicken) : false
        paneBorders = d.object(forKey: Keys.paneBorders) != nil ? d.bool(forKey: Keys.paneBorders) : true
        let pad = d.object(forKey: Keys.padding) != nil ? CGFloat(d.double(forKey: Keys.padding)) : Self.defaultPadding
        padding = min(max(pad, Self.paddingRange.lowerBound), Self.paddingRange.upperBound)
    }

    private func post() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    // MARK: Auflösung

    /// Ghostty-Config-Theme persistieren und aktivierbar machen (`resolve` findet es unter seinem Namen).
    func installCustomTheme(_ t: TerminalTheme) {
        let text = t.ghosttyPairs.map { "\($0.0) = \($0.1)" }.joined(separator: "\n")
        UserDefaults.standard.set(text, forKey: Keys.customTheme)
        if theme.name == Self.customThemeName { theme = t; post() }
    }

    private static var storedCustomTheme: TerminalTheme? {
        guard let text = UserDefaults.standard.string(forKey: Keys.customTheme) else { return nil }
        let pairs: [(String, String)] = text.split(separator: "\n").compactMap { line in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (line[..<eq].trimmingCharacters(in: .whitespaces), line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
        }
        return TerminalTheme(ghosttyPairs: pairs, name: customThemeName)
    }

    /// Eingebaut zuerst, dann das Config-Theme, dann die Ghostty-Verzeichnisse.
    static func resolve(name: String) -> TerminalTheme? {
        if let t = TerminalTheme.builtIn.first(where: { $0.name == name }) { return t }
        if name == customThemeName { return storedCustomTheme }
        for dir in ghosttyThemeDirectories {
            let url = dir.appendingPathComponent(name)
            if let t = TerminalTheme(ghosttyFile: url, name: name) { return t }
        }
        return nil
    }

    /// Alle wählbaren Namen: eingebaute zuerst, dann Ghostty-Themes alphabetisch (dedupliziert).
    static var availableNames: [String] {
        var seen = Set(TerminalTheme.builtIn.map(\.name))
        var names = TerminalTheme.builtIn.map(\.name)
        if storedCustomTheme != nil { names.append(customThemeName); seen.insert(customThemeName) }
        var external: [String] = []
        for dir in ghosttyThemeDirectories {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            for e in entries where !e.hasPrefix(".") && !seen.contains(e) {
                seen.insert(e)
                external.append(e)
            }
        }
        names.append(contentsOf: external.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        return names
    }

    static var ghosttyThemeDirectories: [URL] {
        var dirs: [URL] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        dirs.append(home.appendingPathComponent(".config/ghostty/themes"))
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            dirs.append(app.appendingPathComponent("Contents/Resources/ghostty/themes"))
        } else {
            dirs.append(URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"))
        }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
