import Foundation

/// Findet Claude Codes Eingabe-Box im unteren Bildschirmbereich: zwei volle Trennlinien aus
/// `─` (U+2500) mit dem Prompt-Marker (`❯`/`>`) in der ersten Zeile dazwischen.
///
/// Reine Foundation-Logik über einem Zellraster (Zeichen + „Standard-Vordergrund?“), damit sie
/// im Logic-Test-Target gegen Fixture-Tabellen läuft. Bewusst strukturell, keine Semantik:
///
/// - **Trennlinie** = Zeile, deren Nicht-Leerzeichen ausschließlich `─` sind, ≥ 90 % der Spalten
///   belegen und in Spalte 0 beginnen. ASCII-Bindestriche (`--`, `-->`, `---`) sind U+002D und
///   zählen nie; Rahmen von Dialogen (`╭──╮`, `╰──╯`) enthalten Ecken ≠ `─` und fallen raus.
/// - **Untere Linie** = die unterste Trennlinie im Fenster (Statusline darunter enthält keine).
/// - **Obere Linie** = die nächste Trennlinie darüber, unter der eine Zeile mit dem Marker als erstem
///   Nicht-Leerzeichen liegt. Eine vom Nutzer *in* die Box getippte `────`-Zeile hat darunter
///   seinen Text, nicht den Marker → sie wird übersprungen, die Suche läuft weiter nach oben.
///   Zusatzsicherung: Nutzer-Text steht in Standard-Vordergrundfarbe, Claudes Linien nicht —
///   eine Linie in Standard-FG gilt nur, wenn `requireStyledRules == false`.
/// - **Inhalt** = alle Zeilen dazwischen (auch Leerzeilen und umbrochene Fortsetzungen), egal wie
///   hoch die Box wächst (bis `maxBoxRows`).
enum PromptBoxLocator {
    struct Cell {
        let char: Character
        /// Zelle nutzt die Standard-Vordergrundfarbe (kein SGR-Farbcode).
        let isDefaultFg: Bool
        init(_ char: Character, defaultFg: Bool = true) { self.char = char; self.isDefaultFg = defaultFg }
    }

    struct Box: Equatable {
        /// Zeilenindizes im übergebenen Raster.
        let topRule: Int
        let bottomRule: Int
        var contentRows: Range<Int> { (topRule + 1)..<bottomRule }
    }

    static let rule: Character = "─"
    static let markers: Set<Character> = ["❯", ">"]
    static let minCoverage = 0.9
    static let maxBoxRows = 60

    /// `rows`: Zeilen von oben nach unten (typisch die unteren N Live-Zeilen), jede `cols` Zellen.
    /// `requireStyledRules`: Linien müssen (mehrheitlich) eine Nicht-Standard-Farbe tragen.
    static func locate(rows: [[Cell]], requireStyledRules: Bool = false) -> Box? {
        guard let cols = rows.first?.count, cols >= 8 else { return nil }
        let ruleRows = rows.indices.filter { isRule(rows[$0], cols: cols, requireStyled: requireStyledRules) }
        guard let bottom = ruleRows.last else { return nil }
        for top in ruleRows.reversed() where top < bottom {
            guard bottom - top - 1 <= maxBoxRows else { break }
            if hasMarker(rows[top + 1]) { return Box(topRule: top, bottomRule: bottom) }
        }
        return nil
    }

    static func isRule(_ row: [Cell], cols: Int, requireStyled: Bool) -> Bool {
        var ruleCells = 0, styled = 0
        for (i, c) in row.enumerated() {
            if c.char == rule {
                ruleCells += 1
                if !c.isDefaultFg { styled += 1 }
            } else if c.char != " " && c.char != "\u{0}" {
                return false
            } else if i == 0 {
                return false   // Linie beginnt in Spalte 0
            }
        }
        guard Double(ruleCells) >= Double(cols) * minCoverage else { return false }
        if requireStyled, Double(styled) < Double(ruleCells) * 0.5 { return false }
        return true
    }

    static func hasMarker(_ row: [Cell]) -> Bool {
        guard let first = row.first(where: { $0.char != " " && $0.char != "\u{0}" }) else { return false }
        return markers.contains(first.char)
    }
}
