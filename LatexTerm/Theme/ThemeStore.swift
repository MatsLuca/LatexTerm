import AppKit
import Combine

/// Einzige Wahrheit für die Darstellung: Theme, Schrift (Familie/Größe/Zeilenabstand),
/// Kachel-Akzent, Cursor, Prompt-Stil — alles, was nicht Formel (`FormulaSettings`) oder
/// Cockpit-Verhalten (`CockpitSettings`) ist. Persistiert in UserDefaults, meldet Änderungen
/// per `didChange`; `userInfo[changeKey]` sagt als `Change`, **was** sich geändert hat, damit
/// Kacheln nicht bei jeder (adaptiv gesetzten) Akzentfarbe das ganze Theme neu installieren.
///
/// Themes kommen aus drei Quellen, in dieser Reihenfolge: eingebaut (`Dark+`, `Ember`),
/// `~/.config/ghostty/themes/<Name>`, Ghostty.app-Bundle (`…/Resources/ghostty/themes/`).
/// Gespeichert wird nur der Name; ein Name, den es nicht mehr gibt, fällt auf Dark+.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    static let didChange = Notification.Name("LatexTerm.ThemeStore.didChange")
    static let changeKey = "change"

    /// Was sich geändert hat. Observer filtern darauf (Kachel: Theme neu installieren nur bei
    /// `.theme`/`.appearance`, Schrift nur bei `.font`, …).
    nonisolated enum Change {
        case theme, appearance, font, lineSpacing, accent, adaptiveAccent, prompt, panes
    }

    enum Keys {
        static let theme = "LatexTerm.theme"
        static let boldIsBright = "LatexTerm.boldIsBright"
        static let cursorBlink = "LatexTerm.cursorBlink"
        static let padding = "LatexTerm.padding"
        static let cursorThemeColor = "LatexTerm.cursorThemeColor"
        static let fontThicken = "LatexTerm.fontThicken"
        static let paneBorders = "LatexTerm.paneBorders"
        static let promptTint = "LatexTerm.promptTint"          // alt (Bool) — migriert auf promptTintMode
        static let promptTintMode = "LatexTerm.promptTintMode"
        static let promptGlow = "LatexTerm.promptGlow"
        static let promptColor = "LatexTerm.promptColor"        // "#rrggbb"
        static let promptOverrideColored = "LatexTerm.promptOverrideColored"
        static let promptColoredOwnColor = "LatexTerm.promptColoredOwnColor"
        static let promptColoredColor = "LatexTerm.promptColoredColor"   // "#rrggbb"
        /// Ghostty-Config-Theme (Basis + Overrides) als `key = value`-Zeilen.
        static let customTheme = "LatexTerm.customTheme"
        static let fontFamily = "LatexTerm.fontFamily"           // leer = SF Mono
        static let fontSize = "LatexTerm.fontSize"
        static let lineSpacing = "LatexTerm.extraLineSpacing"
        static let accentColor = "LatexTerm.accentColor"         // + .red/.green/.blue/.alpha (historisch)
        static let isAdaptiveAccent = "LatexTerm.isAdaptiveAccent"
        static let focusDimming = "LatexTerm.focusDimming"
    }

    /// Name des aus `~/.config/ghostty/config` gebauten Themes (Basis-Theme + Farb-Overrides).
    static let customThemeName = "Ghostty (Config)"

    static let defaultPadding: CGFloat = 12
    static let paddingRange: ClosedRange<CGFloat> = 0...24
    /// Ghostty-Standard (Runde 27): JetBrains Mono NL in 20 pt.
    static let defaultFontSize: CGFloat = 20
    static let fontSizeRange: ClosedRange<CGFloat> = 6...48
    /// 0 wie Ghostty: Zellhöhe = Font-Metrik (JetBrains Mono bringt ~1,2 Zeilenhöhe mit).
    static let defaultLineSpacing: CGFloat = 0
    static let lineSpacingRange: ClosedRange<CGFloat> = 0...40
    static let lineSpacingStep: CGFloat = 2
    /// Neutral hell (Dark+-Vordergrund, leicht abgesenkt): Farbe = Projekt (Launcher), der Ruhezustand
    /// ohne Projekt bleibt unbunt — wie Ghostty, das Cursor/Rahmen in der Vordergrundfarbe zeichnet.
    static let defaultAccentColor = NSColor(hex: 0xc8c8c8)

    @Published private(set) var theme: TerminalTheme = .darkPlus

    /// Name des gewählten Themes (Menü/Settings binden hieran).
    var themeName: String {
        get { theme.name }
        set {
            guard newValue != theme.name, let t = Self.resolve(name: newValue) else { return }
            theme = t
            UserDefaults.standard.set(newValue, forKey: Keys.theme)
            post(.theme)
        }
    }

    /// Fetter Text in ANSI 0–7 springt auf die helle Palette (Terminal.app-Art). Ghostty: aus.
    @Published var boldIsBright: Bool = false {
        didSet { guard !loading else { return }; UserDefaults.standard.set(boldIsBright, forKey: Keys.boldIsBright); post(.appearance) }
    }

    /// Block-Cursor blinkt. Ghostty: aus.
    @Published var cursorBlink: Bool = false {
        didSet { guard !loading else { return }; UserDefaults.standard.set(cursorBlink, forKey: Keys.cursorBlink); post(.appearance) }
    }

    /// Cursor in der Theme-Cursorfarbe (Ghostty: Weiß) statt in der Projekt-/Akzentfarbe.
    @Published var cursorThemeColor: Bool = false {
        didSet { guard !loading else { return }; UserDefaults.standard.set(cursorThemeColor, forKey: Keys.cursorThemeColor); post(.appearance) }
    }

    /// macOS-Font-Smoothing („Schrift verstärken“, Ghostty `font-thicken`): Striche ~1 Subpixel dicker.
    @Published var fontThicken: Bool = false {
        didSet { guard !loading else { return }; UserDefaults.standard.set(fontThicken, forKey: Keys.fontThicken); post(.appearance) }
    }

    /// Farbige Akzentrahmen + Hüll-Tint der Kacheln (Session-Kennung). Aus = nur der Grund; Caret,
    /// HUD-Punkt und Home-Ring tragen die Projektfarbe weiter.
    @Published var paneBorders: Bool = true {
        didSet { guard !loading else { return }; UserDefaults.standard.set(paneBorders, forKey: Keys.paneBorders); post(.panes) }
    }

    /// Experimentell: getippter Text in Claude Codes Eingabe-Box (`PromptBoxLocator` findet die
    /// Box, der Fork stylt Standard-FG-Zellen dieser Zeilen).
    enum PromptTintMode: String, CaseIterable, Identifiable {
        case off, accent, custom, rainbow
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Aus"
            case .accent: return "Projektfarbe"
            case .custom: return "Eigene Farbe"
            case .rainbow: return "Regenbogen"
            }
        }
    }
    @Published var promptTintMode: PromptTintMode = .off {
        didSet { guard !loading else { return }; UserDefaults.standard.set(promptTintMode.rawValue, forKey: Keys.promptTintMode); post(.prompt) }
    }
    var promptTint: Bool { promptTintMode != .off }

    /// Glühender Prompt-Text (weicher Schein in der Textfarbe), kombinierbar mit jedem Modus.
    @Published var promptGlow: Bool = false {
        didSet { guard !loading else { return }; UserDefaults.standard.set(promptGlow, forKey: Keys.promptGlow); post(.prompt) }
    }

    /// Eigene Prompt-Farbe (Modus „Eigene Farbe“).
    @Published var promptColor: NSColor = NSColor(hex: 0x29b8db) {
        didSet { guard !loading else { return }; UserDefaults.standard.set(promptColor.ghosttyHex, forKey: Keys.promptColor); post(.prompt) }
    }

    /// Auch von Claude Code selbst gefärbten Prompt-Text (Slash-Commands, @-Erwähnungen) übersteuern.
    @Published var promptOverrideColored: Bool = false {
        didSet { guard !loading else { return }; UserDefaults.standard.set(promptOverrideColored, forKey: Keys.promptOverrideColored); post(.prompt) }
    }
    /// … dafür eine eigene Farbe statt der Prompt-Farbe nehmen.
    @Published var promptColoredOwnColor: Bool = false {
        didSet { guard !loading else { return }; UserDefaults.standard.set(promptColoredOwnColor, forKey: Keys.promptColoredOwnColor); post(.prompt) }
    }
    @Published var promptColoredColor: NSColor = NSColor(hex: 0xd670d6) {
        didSet { guard !loading else { return }; UserDefaults.standard.set(promptColoredColor.ghosttyHex, forKey: Keys.promptColoredColor); post(.prompt) }
    }

    /// Terminal-Schriftfamilie (gebündelte JetBrains Mono NL, installierte Monospace-Familie
    /// oder leer = SF Mono). Alle Kacheln, Home und Pillen folgen (`AppFonts.mono`).
    @Published var fontFamily: String = AppFonts.bundledFamily {
        didSet { guard !loading else { return }; UserDefaults.standard.set(fontFamily, forKey: Keys.fontFamily); post(.font) }
    }

    /// Schriftgröße ist global: ⌘±/0 in einer Kachel ändert sie, alle übernehmen sie.
    @Published var fontSize: CGFloat = ThemeStore.defaultFontSize {
        didSet {guard !loading else { return }; 
            let c = Self.clamp(fontSize, Self.fontSizeRange)
            if c != fontSize { fontSize = c; return }
            UserDefaults.standard.set(Double(fontSize), forKey: Keys.fontSize); post(.font)
        }
    }

    /// Zusätzlicher Zeilenabstand in px (SwiftTerm `extraLineSpacing`).
    @Published var lineSpacing: CGFloat = ThemeStore.defaultLineSpacing {
        didSet {guard !loading else { return }; 
            let c = Self.clamp(lineSpacing, Self.lineSpacingRange)
            if c != lineSpacing { lineSpacing = c; return }
            UserDefaults.standard.set(Double(lineSpacing), forKey: Keys.lineSpacing); post(.lineSpacing)
        }
    }

    /// Globale Akzentfarbe (Caret, Kachelrahmen, Home-Ring), solange keine Kachel eine eigene
    /// trägt (OSC-Override / Projektfarbe). Bei adaptivem Akzent schreibt die Kontrastanalyse hierher.
    /// Gespeichert wird nur die feste Wahl; adaptive Werte sind flüchtig, sonst klebt nach dem
    /// Abschalten die zuletzt analysierte Farbe (so kam ein Gelb in die Home-Kachel).
    @Published var accentColor: NSColor = ThemeStore.defaultAccentColor {
        didSet {
            guard !loading else { return }
            if !isAdaptiveAccent { Self.saveColor(accentColor, key: Keys.accentColor) }
            post(.accent)
        }
    }

    /// Akzentfarbe aus dem Kachelinhalt ableiten (Kontrastanalyse) statt fester Wahl.
    /// Aus → zurück auf die gespeicherte feste Farbe (oder den Default).
    @Published var isAdaptiveAccent: Bool = false {
        didSet {
            guard !loading else { return }
            UserDefaults.standard.set(isAdaptiveAccent, forKey: Keys.isAdaptiveAccent)
            if !isAdaptiveAccent { accentColor = Self.loadColor(key: Keys.accentColor, default: Self.defaultAccentColor) }
            post(.adaptiveAccent)
        }
    }

    /// Unfokussierte Kacheln abdunkeln (Alpha 0,65). Aus = alle Kacheln voll sichtbar,
    /// Fokus zeigt nur noch der Rahmen.
    @Published var focusDimming: Bool = true {
        didSet { guard !loading else { return }; UserDefaults.standard.set(focusDimming, forKey: Keys.focusDimming); post(.panes) }
    }

    /// Innenabstand Terminal-Text ↔ Kachelrand (Ghostty `window-padding` 15; hier 12, weil bei
    /// mehreren Kacheln der 8-px-Steg dazukommt).
    @Published var padding: CGFloat = ThemeStore.defaultPadding {
        didSet { guard !loading else { return }; UserDefaults.standard.set(Double(padding), forKey: Keys.padding); post(.appearance) }
    }

    /// Während `load()` schreiben/posten die Setter nicht (sonst würde z. B. die Theme-FG
    /// als „eigene“ Formelfarbe gespeichert).
    private var loading = false

    private init() { load(initial: true) }

    /// Alles aus UserDefaults (neu) lesen — beim Start und nach „Alle Einstellungen zurücksetzen“.
    /// Läuft über die normalen Setter (schreibt Defaults zurück, postet Änderungen) — bewusst, damit
    /// alle Kacheln nach einem Reset denselben Weg gehen wie bei jeder Einzeländerung.
    func load(initial: Bool = false) {
        loading = true
        defer { loading = false }
        let d = UserDefaults.standard
        let name = d.string(forKey: Keys.theme) ?? TerminalTheme.darkPlus.name
        theme = Self.resolve(name: name) ?? .darkPlus
        boldIsBright = d.object(forKey: Keys.boldIsBright) != nil ? d.bool(forKey: Keys.boldIsBright) : false
        cursorBlink = d.object(forKey: Keys.cursorBlink) != nil ? d.bool(forKey: Keys.cursorBlink) : false
        cursorThemeColor = d.object(forKey: Keys.cursorThemeColor) != nil ? d.bool(forKey: Keys.cursorThemeColor) : false
        fontThicken = d.object(forKey: Keys.fontThicken) != nil ? d.bool(forKey: Keys.fontThicken) : false
        paneBorders = d.object(forKey: Keys.paneBorders) != nil ? d.bool(forKey: Keys.paneBorders) : true
        if let raw = d.string(forKey: Keys.promptTintMode), let m = PromptTintMode(rawValue: raw) {
            promptTintMode = m
        } else {
            promptTintMode = d.bool(forKey: Keys.promptTint) ? .accent : .off   // Migration vom Bool
        }
        promptGlow = d.object(forKey: Keys.promptGlow) != nil ? d.bool(forKey: Keys.promptGlow) : false
        promptColor = d.string(forKey: Keys.promptColor).flatMap { NSColor(ghostty: $0) } ?? NSColor(hex: 0x29b8db)
        promptOverrideColored = d.object(forKey: Keys.promptOverrideColored) != nil ? d.bool(forKey: Keys.promptOverrideColored) : false
        promptColoredOwnColor = d.object(forKey: Keys.promptColoredOwnColor) != nil ? d.bool(forKey: Keys.promptColoredOwnColor) : false
        promptColoredColor = d.string(forKey: Keys.promptColoredColor).flatMap { NSColor(ghostty: $0) } ?? NSColor(hex: 0xd670d6)
        let pad = d.object(forKey: Keys.padding) != nil ? CGFloat(d.double(forKey: Keys.padding)) : Self.defaultPadding
        padding = Self.clamp(pad, Self.paddingRange)
        fontFamily = d.string(forKey: Keys.fontFamily) ?? AppFonts.bundledFamily
        let size = d.double(forKey: Keys.fontSize)
        fontSize = size > 0 ? Self.clamp(CGFloat(size), Self.fontSizeRange) : Self.defaultFontSize
        let spacing = d.object(forKey: Keys.lineSpacing) != nil ? CGFloat(d.double(forKey: Keys.lineSpacing)) : Self.defaultLineSpacing
        lineSpacing = Self.clamp(spacing, Self.lineSpacingRange)
        accentColor = Self.loadColor(key: Keys.accentColor, default: Self.defaultAccentColor)
        isAdaptiveAccent = d.object(forKey: Keys.isAdaptiveAccent) != nil ? d.bool(forKey: Keys.isAdaptiveAccent) : false
        focusDimming = d.object(forKey: Keys.focusDimming) != nil ? d.bool(forKey: Keys.focusDimming) : true
        loading = false
        guard !initial else { return }
        for c: Change in [.theme, .font, .lineSpacing, .accent, .prompt, .panes] { post(c) }
    }

    // MARK: Menü-Aktionen (Schritte wie die Tastenkürzel)

    func increaseLineSpacing() { lineSpacing += Self.lineSpacingStep }
    func decreaseLineSpacing() { lineSpacing -= Self.lineSpacingStep }
    func resetLineSpacing() { lineSpacing = Self.defaultLineSpacing }

    private func post(_ change: Change) {
        NotificationCenter.default.post(name: Self.didChange, object: self,
                                        userInfo: [Self.changeKey: change])
    }

    private static func clamp(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat {
        min(max(v, r.lowerBound), r.upperBound)
    }

    /// Farbe als vier sRGB-Komponenten unter `<key>.red/.green/.blue/.alpha` (Format der
    /// alten `FormulaSettings`, damit gespeicherte Akzentfarben unverändert weitergelten).
    static func saveColor(_ c: NSColor, key: String) {
        guard let rgb = c.usingColorSpace(.sRGB) else { return }
        let d = UserDefaults.standard
        d.set(Double(rgb.redComponent),   forKey: key + ".red")
        d.set(Double(rgb.greenComponent), forKey: key + ".green")
        d.set(Double(rgb.blueComponent),  forKey: key + ".blue")
        d.set(Double(rgb.alphaComponent), forKey: key + ".alpha")
    }

    static func loadColor(key: String, default def: NSColor) -> NSColor {
        let d = UserDefaults.standard
        guard d.object(forKey: key + ".red") != nil else { return def }
        // sRGB laden, weil in sRGB gespeichert — sonst wäre die Farbe nie komponentengleich.
        return NSColor(srgbRed: CGFloat(d.double(forKey: key + ".red")),
                       green: CGFloat(d.double(forKey: key + ".green")),
                       blue: CGFloat(d.double(forKey: key + ".blue")),
                       alpha: d.object(forKey: key + ".alpha") != nil ? CGFloat(d.double(forKey: key + ".alpha")) : 1)
    }

    // MARK: Auflösung

    /// Ghostty-Config-Theme persistieren und aktivierbar machen (`resolve` findet es unter seinem Namen).
    func installCustomTheme(_ t: TerminalTheme) {
        let text = t.ghosttyPairs.map { "\($0.0) = \($0.1)" }.joined(separator: "\n")
        UserDefaults.standard.set(text, forKey: Keys.customTheme)
        if theme.name == Self.customThemeName { theme = t; post(.theme) }
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
