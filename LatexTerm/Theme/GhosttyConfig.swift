import AppKit

/// Liest Ghosttys Konfiguration (`~/.config/ghostty/config`, alternativ
/// `~/Library/Application Support/com.mitchellh.ghostty/config`, `config-file`-Includes eine
/// Ebene tief) und übersetzt die Darstellungs-Schlüssel in LatexTerm-Einstellungen. Nur auf
/// Knopfdruck („Aus Ghostty übernehmen“) — kein stilles Mitlesen beim Start.
struct GhosttyConfig {
    let url: URL
    let pairs: [(String, String)]

    static var candidateURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".config/ghostty/config"),
                home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config")]
    }

    /// Erste existierende Config-Datei, Includes aufgelöst.
    static func load() -> GhosttyConfig? {
        guard let url = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return GhosttyConfig(url: url, pairs: parse(url, depth: 0))
    }

    private static func parse(_ url: URL, depth: Int) -> [(String, String)] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(String, String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if key == "config-file" {
                guard depth < 1 else { continue }
                var path = value
                if path.hasPrefix("?") { path.removeFirst() }
                let inc = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                    : url.deletingLastPathComponent().appendingPathComponent(path)
                out.append(contentsOf: parse(inc, depth: depth + 1))
            } else {
                out.append((key, value))
            }
        }
        return out
    }

    /// Letzter Wert eines Schlüssels (Ghostty: später gewinnt).
    func value(_ key: String) -> String? { pairs.last(where: { $0.0 == key })?.1 }

    // MARK: Übersetzung

    /// Was der Import ändern würde — jede Zeile ein Satz für die Vorschau; `apply` setzt es um.
    struct Plan {
        var themeName: String?
        var customTheme: TerminalTheme?
        var fontFamily: String?
        var fontSize: CGFloat?
        var padding: CGFloat?
        var cursorBlink: Bool?
        var boldIsBright: Bool?
        var fontThicken: Bool?
        var notes: [String] = []

        var isEmpty: Bool {
            themeName == nil && customTheme == nil && fontFamily == nil && fontSize == nil
                && padding == nil && cursorBlink == nil && boldIsBright == nil && fontThicken == nil
        }
    }

    func plan() -> Plan {
        var p = Plan()
        let store = ThemeStore.shared

        // Theme: `Name` oder `light:X,dark:Y` → dunkle Variante (die App ist immer dunkel).
        if let raw = value("theme") {
            var name = raw
            if raw.contains(":") {
                let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                name = parts.first(where: { $0.hasPrefix("dark:") }).map { String($0.dropFirst(5)) } ?? parts[0]
                if let c = name.firstIndex(of: ":") { name = String(name[name.index(after: c)...]) }
            }
            if ThemeStore.resolve(name: name) != nil {
                if name != store.themeName { p.themeName = name }
            } else {
                p.notes.append("Theme „\(name)“ nicht gefunden — Theme bleibt \(store.themeName).")
            }
        }
        // Direkte Farb-Overrides (background/foreground/palette in der Config) → eigenes Theme.
        let colorKeys: Set<String> = ["background", "foreground", "palette", "cursor-color", "cursor-text",
                                      "selection-background", "selection-foreground"]
        let overrides = pairs.filter { colorKeys.contains($0.0) }
        if !overrides.isEmpty {
            let baseName = p.themeName ?? store.themeName
            let base = ThemeStore.resolve(name: baseName) ?? .darkPlus
            let basePairs = base.ghosttyPairs
            if let custom = TerminalTheme(ghosttyPairs: basePairs + overrides, name: ThemeStore.customThemeName) {
                p.customTheme = custom
                p.themeName = ThemeStore.customThemeName
            }
        }

        // Schrift: Familie muss installiert oder gebündelt sein; Ghosttys „JetBrains Mono“
        // (mit Ligaturen) wird auf die gebündelte NL-Variante abgebildet.
        if let fam = value("font-family"), !fam.isEmpty {
            let resolved: String?
            if AppFonts.familyExists(fam) { resolved = fam }
            else if AppFonts.familyExists(fam + " NL") { resolved = fam + " NL" }
            else { resolved = nil }
            if let r = resolved {
                if r != AppFonts.storedFamily {
                    p.fontFamily = r
                    if r != fam { p.notes.append("„\(fam)“ → „\(r)“ (ohne Ligaturen: der Renderer zeichnet zellgenau).") }
                }
            } else {
                p.notes.append("Schrift „\(fam)“ ist nicht installiert — Schrift bleibt \(AppFonts.storedFamily.isEmpty ? "SF Mono" : AppFonts.storedFamily).")
            }
        }
        if let s = value("font-size"), let size = Double(s) {
            let r = ThemeStore.fontSizeRange
            let clamped = CGFloat(min(max(size, Double(r.lowerBound)), Double(r.upperBound)))
            if clamped != store.fontSize { p.fontSize = clamped }
        }

        // Padding: Ghostty kennt x/y, LatexTerm einen Wert — Mittel, gedeckelt.
        let px = value("window-padding-x").flatMap(Double.init)
        let py = value("window-padding-y").flatMap(Double.init)
        if px != nil || py != nil {
            let avg = ((px ?? py ?? 0) + (py ?? px ?? 0)) / 2
            let pad = CGFloat(min(max(avg, Double(ThemeStore.paddingRange.lowerBound)), Double(ThemeStore.paddingRange.upperBound)))
            if pad != store.padding { p.padding = pad }
        }

        if let style = value("cursor-style"), style != "block" {
            p.notes.append("Cursor-Stil „\(style)“ wird nicht übernommen — LatexTerm zeichnet einen Block.")
        }
        if let b = value("cursor-style-blink").flatMap(Self.bool) , b != store.cursorBlink { p.cursorBlink = b }
        if let b = value("bold-is-bright").flatMap(Self.bool), b != store.boldIsBright { p.boldIsBright = b }
        if let b = value("font-thicken").flatMap(Self.bool), b != store.fontThicken { p.fontThicken = b }
        return p
    }

    private static func bool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "1", "on": return true
        case "false", "no", "0", "off": return false
        default: return nil
        }
    }

    /// Vorschau-Zeilen für den Dialog.
    static func describe(_ p: Plan) -> [String] {
        var lines: [String] = []
        if let t = p.themeName { lines.append("Theme → \(t)") }
        if let f = p.fontFamily { lines.append("Schrift → \(f)") }
        if let s = p.fontSize { lines.append("Schriftgröße → \(Int(s)) pt") }
        if let pad = p.padding { lines.append("Innenabstand → \(Int(pad)) px") }
        if let b = p.cursorBlink { lines.append("Cursor blinkt → \(b ? "an" : "aus")") }
        if let b = p.boldIsBright { lines.append("Fett als helle Farbe → \(b ? "an" : "aus")") }
        if let b = p.fontThicken { lines.append("Schrift verstärken → \(b ? "an" : "aus")") }
        if lines.isEmpty { lines.append("Alles stimmt bereits mit Ghostty überein.") }
        return lines + p.notes
    }

    /// Setzt den Plan um — über dieselben Pfade wie die Einstellungen (keine zweite Wahrheit).
    static func apply(_ p: Plan) {
        let store = ThemeStore.shared
        if let custom = p.customTheme { store.installCustomTheme(custom) }
        if let t = p.themeName { store.themeName = t }
        if let b = p.boldIsBright { store.boldIsBright = b }
        if let b = p.fontThicken { store.fontThicken = b }
        if let b = p.cursorBlink { store.cursorBlink = b }
        if let pad = p.padding { store.padding = pad }
        if let f = p.fontFamily { store.fontFamily = f }
        if let s = p.fontSize { store.fontSize = s }
    }
}

extension TerminalTheme {
    /// Rückweg ins Ghostty-Format (für Overrides auf ein Basis-Theme und die Persistenz des
    /// Config-Themes).
    var ghosttyPairs: [(String, String)] {
        var out: [(String, String)] = [("background", background.ghosttyHex), ("foreground", foreground.ghosttyHex),
                                       ("cursor-color", cursor.ghosttyHex), ("cursor-text", cursorText.ghosttyHex),
                                       ("selection-background", selectionBackground.ghosttyHex),
                                       ("selection-foreground", selectionForeground.ghosttyHex)]
        for (i, c) in ansi.enumerated() { out.append(("palette", "\(i)=\(c.ghosttyHex)")) }
        return out
    }
}

extension NSColor {
    var ghosttyHex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
