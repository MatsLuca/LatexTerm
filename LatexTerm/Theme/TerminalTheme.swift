import AppKit
import SwiftTerm

/// Ein Farbschema fürs ganze Fenster: Terminal-Grund, 16 ANSI-Farben, Cursor, Auswahl —
/// und daraus abgeleitet die Flächen drumherum (Steg, Tastenhilfe, Dimmstufen). Es gibt
/// genau eine Wahrheit (`ThemeStore.shared.theme`); nirgends sonst stehen Hex-Werte für
/// den Hintergrund.
///
/// Format = Ghostty-Theme-Datei (`palette = N=#rrggbb`, `background`, `foreground`,
/// `cursor-color`, `cursor-text`, `selection-background`, `selection-foreground`), damit
/// jedes der ~460 Ghostty-Themes 1:1 übernommen werden kann und LatexTerm neben Ghostty
/// identisch aussieht.
struct TerminalTheme: Equatable {
    let name: String
    let background: NSColor
    let foreground: NSColor
    /// 16 ANSI-Farben (0–7 normal, 8–15 hell).
    let ansi: [NSColor]
    let cursor: NSColor
    let cursorText: NSColor
    let selectionBackground: NSColor
    let selectionForeground: NSColor

    // MARK: Abgeleitete Flächen

    /// Steg zwischen Kacheln: Grund leicht aufgehellt, transluzent, damit die Vibrancy durchschimmert.
    var gap: NSColor { background.lightened(by: 0.10).withAlphaComponent(0.35) }
    /// Tastenhilfe-Overlay der Home-Kachel.
    var keyHelpBackground: NSColor { background.lightened(by: 0.04).withAlphaComponent(0.97) }
    /// Status-Pille in der Kachel.
    var badgeBackground: NSColor { background.lightened(by: 0.03).withAlphaComponent(0.85) }
    var dim: NSColor { foreground.withAlphaComponent(0.45) }
    var faint: NSColor { foreground.withAlphaComponent(0.22) }

    // Semantische Farben der eigenen UIs (Home-Kachel, Hinweise, Badges): die hellen ANSI-Farben
    // des Themes, damit Baum und Terminal-Inhalt aus derselben Palette kommen.
    var red: NSColor { ansi[9] }
    var green: NSColor { ansi[10] }
    var yellow: NSColor { ansi[11] }
    var blue: NSColor { ansi[12] }
    var violet: NSColor { ansi[13] }
    var cyan: NSColor { ansi[14] }

    /// Kandidaten der adaptiven Akzenterkennung (Kacheln ohne Launcher-Farbe): die sechs bunten
    /// hellen ANSI-Farben plus der Vordergrund — der letzte Eintrag ist die „weiße“ Option, die
    /// bei hellem Text übersprungen wird.
    var contrastCandidates: [NSColor] { [ansi[9], ansi[10], ansi[11], ansi[12], ansi[13], ansi[14], foreground] }

    /// Hintergrund als sRGB-Komponenten (für Pixel-Vergleiche in der Kontrastanalyse).
    var backgroundRGB: (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = background.usingColorSpace(.sRGB) ?? background
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    /// Die 16 ANSI-Farben im SwiftTerm-Format (16 Bit je Kanal).
    var swiftTermPalette: [SwiftTerm.Color] {
        ansi.map { c in
            let s = c.usingColorSpace(.sRGB) ?? c
            return SwiftTerm.Color(red: UInt16(s.redComponent * 65535),
                                   green: UInt16(s.greenComponent * 65535),
                                   blue: UInt16(s.blueComponent * 65535))
        }
    }

    // MARK: Eingebaute Themes

    /// VS Code „Dark+“ — Kopie des Ghostty-Themes, damit es auch ohne Ghostty da ist.
    static let darkPlus = TerminalTheme(
        name: "Dark+",
        background: NSColor(hex: 0x1e1e1e), foreground: NSColor(hex: 0xcccccc),
        ansi: [0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
               0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xe5e5e5].map(NSColor.init(hex:)),
        cursor: NSColor(hex: 0xffffff), cursorText: NSColor(hex: 0x000000),
        selectionBackground: NSColor(hex: 0x3a3d41), selectionForeground: NSColor(hex: 0xe0e0e0))

    /// LatexTerms bisheriges warmes Rotschwarz mit der Terminal.app-Palette (Runden 1–25).
    static let ember = TerminalTheme(
        name: "Ember",
        background: NSColor(hex: 0x171414), foreground: NSColor(hex: 0xe6e1e1),
        ansi: [0x000000, 0xc23621, 0x25bc24, 0xadad27, 0x492ee1, 0xd338d3, 0x33bbc8, 0xcbcccd,
               0x818383, 0xfc391f, 0x31e722, 0xeaec23, 0x5833ff, 0xf935f8, 0x14f0f0, 0xe9ebeb].map(NSColor.init(hex:)),
        cursor: NSColor(hex: 0xe6e1e1), cursorText: NSColor(hex: 0x171414),
        selectionBackground: NSColor(hex: 0x3a3535), selectionForeground: NSColor(hex: 0xe6e1e1))

    static let builtIn: [TerminalTheme] = [darkPlus, ember]

    // MARK: Ghostty-Theme-Datei

    /// Liest eine Ghostty-Theme-Datei. Fehlende Schlüssel fallen auf Dark+ zurück;
    /// eine Datei ohne `background` gilt als kein Theme (nil).
    init?(ghosttyFile url: URL, name: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var pairs: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            pairs.append((key, value))
        }
        self.init(ghosttyPairs: pairs, name: name)
    }

    /// Baut ein Theme aus `key = value`-Paaren im Ghostty-Format (auch der Import aus
    /// `~/.config/ghostty/config` läuft hierüber). `background` ist Pflicht.
    init?(ghosttyPairs pairs: [(String, String)], name: String) {
        var bg: NSColor?, fg: NSColor?, cursor: NSColor?, cursorText: NSColor?, selBg: NSColor?, selFg: NSColor?
        var palette = TerminalTheme.darkPlus.ansi
        for (key, value) in pairs {
            switch key {
            case "background": bg = NSColor(ghostty: value)
            case "foreground": fg = NSColor(ghostty: value)
            case "cursor-color": cursor = NSColor(ghostty: value)
            case "cursor-text": cursorText = NSColor(ghostty: value)
            case "selection-background": selBg = NSColor(ghostty: value)
            case "selection-foreground": selFg = NSColor(ghostty: value)
            case "palette":
                // `N=#rrggbb`
                guard let eq = value.firstIndex(of: "="),
                      let idx = Int(value[..<eq].trimmingCharacters(in: .whitespaces)), (0..<16).contains(idx),
                      let c = NSColor(ghostty: String(value[value.index(after: eq)...])) else { continue }
                palette[idx] = c
            default: continue
            }
        }
        guard let background = bg else { return nil }
        let foreground = fg ?? TerminalTheme.darkPlus.foreground
        self.init(name: name, background: background, foreground: foreground, ansi: palette,
                  cursor: cursor ?? foreground, cursorText: cursorText ?? background,
                  selectionBackground: selBg ?? background.lightened(by: 0.12),
                  selectionForeground: selFg ?? foreground)
    }

    init(name: String, background: NSColor, foreground: NSColor, ansi: [NSColor],
         cursor: NSColor, cursorText: NSColor, selectionBackground: NSColor, selectionForeground: NSColor) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.ansi = ansi.count == 16 ? ansi : TerminalTheme.darkPlus.ansi
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    /// Ghostty-Farbwert: `#rrggbb`, `rrggbb` oder `rgb` (Kurzform).
    convenience init?(ghostty raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    /// Mischt Richtung Weiß (`amount` 0…1) — für Stege, Pillen, Overlays auf dem Grund.
    func lightened(by amount: CGFloat) -> NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        return NSColor(srgbRed: c.redComponent + (1 - c.redComponent) * amount,
                       green: c.greenComponent + (1 - c.greenComponent) * amount,
                       blue: c.blueComponent + (1 - c.blueComponent) * amount,
                       alpha: c.alphaComponent)
    }
}
