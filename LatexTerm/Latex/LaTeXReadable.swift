import Foundation

/// Wandelt einen LaTeX-Ausdruck in eine gut lesbare Unicode-Math-Form um.
///
/// Beispiel:
///   `\frac{-b \pm \sqrt{b^2-4ac}}{2a}`  →  `(-b ± √(b²-4ac))/(2a)`
///
/// Das ist bewusst ein Heuristik-Konverter: gängige Vorlesungs-Formeln
/// (Brüche, Wurzeln, Hoch-/Tiefstellungen, Griechisch, Operatoren) werden
/// schön umgesetzt; exotische Konstrukte (Matrizen, cases, …) degradieren
/// lesbar, statt zu scheitern.
enum LaTeXReadable {

    /// Öffentlicher Einstieg: konvertiert und räumt Whitespace auf.
    static func readable(_ latex: String) -> String {
        cacheLock.lock()
        if let hit = cache[latex] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let r = convert(latex)
        // Mehrzeilige Ausgaben (Matrizen, cases) behalten ihre Ausricht-Spaces;
        // einzeilige Formeln werden von Spacing-Artefakten befreit.
        let cleaned = r.contains("\n")
            ? r
            : r.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        let result = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        cacheLock.lock(); cache[latex] = result; cacheLock.unlock()
        return result
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: String] = [:]

    // MARK: - Rekursiver Parser

    private static func convert(_ s: String) -> String {
        let chars = Array(s)
        var i = 0
        var out = ""
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\\":
                let (cmd, next) = readCommand(chars, i)
                i = next
                out += handleCommand(cmd, chars, &i)
            case "{":
                let (grp, next) = readBalanced(chars, i)
                i = next
                out += convert(grp)
            case "}":
                i += 1
            case "^":
                let (arg, next) = readArg(chars, i + 1)
                i = next
                out += superscript(convert(arg))
            case "_":
                let (arg, next) = readArg(chars, i + 1)
                i = next
                out += subscriptText(convert(arg))
            case "$":
                i += 1
            case "~":
                out += " "; i += 1
            case "'":
                out += "′"; i += 1
            default:
                out.append(c); i += 1
            }
        }
        return out
    }

    private static func handleCommand(_ cmd: String, _ chars: [Character], _ i: inout Int) -> String {
        switch cmd {
        case "frac", "dfrac", "tfrac", "cfrac":
            let (a, n1) = readArg(chars, i); i = n1
            let (b, n2) = readArg(chars, i); i = n2
            return paren(convert(a)) + "/" + paren(convert(b))

        case "sqrt":
            var root = ""
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            if j < chars.count, chars[j] == "[" {
                var inner = ""; j += 1
                while j < chars.count, chars[j] != "]" { inner.append(chars[j]); j += 1 }
                if j < chars.count { j += 1 }   // ] überspringen
                root = superscript(convert(inner))
                i = j
            }
            let (a, n1) = readArg(chars, i); i = n1
            return root + "√" + paren(convert(a))

        case "mathbb":
            let (a, n1) = readArg(chars, i); i = n1
            let inner = a.trimmingCharacters(in: .whitespaces)
            return blackboard[inner] ?? convert(a)

        // Inhalt 1:1 (Text/aufrechte Schrift)
        case "text", "operatorname", "mathrm", "textrm", "mathtt", "texttt", "mathsf", "textsf":
            let (a, n1) = readArg(chars, i); i = n1
            return a

        // Stile: Inhalt konvertieren, Dekoration weglassen
        case "mathbf", "boldsymbol", "bm", "mathit", "mathcal", "mathfrak", "mathscr":
            let (a, n1) = readArg(chars, i); i = n1
            return convert(a)

        // Akzente: als Unicode-Combining-Mark auf das konvertierte Argument
        case let c where accents[c] != nil:
            let (a, n1) = readArg(chars, i); i = n1
            return accent(convert(a), accents[c]!)

        case "left", "right":
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            if j < chars.count, chars[j] == "." { i = j + 1 }   // unsichtbarer Delimiter
            return ""

        case "begin":
            let (env, n1) = readArg(chars, i); i = n1
            let envName = env.trimmingCharacters(in: .whitespaces)
            if envName == "array" {            // Spaltenspezifikation {cc} überspringen
                var j = i
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, chars[j] == "{" {
                    let (_, n2) = readBalanced(chars, j); i = n2
                }
            }
            let (body, next) = readEnvBody(chars, i, envName)
            i = next
            return formatEnv(envName, body)

        case "end":   // nur erreichbar, wenn \end ohne passendes \begin auftaucht
            let (_, n1) = readArg(chars, i); i = n1
            return ""

        case ",", ";", ":", " ", "quad", "qquad", "enspace", "thinspace":
            return " "
        case "!", "negthinspace":
            return ""
        case "\\":
            return " "      // Zeilenumbruch in mehrzeiligen Ausdrücken
        case "{": return "{"
        case "}": return "}"
        case "%": return "%"
        case "#": return "#"
        case "&": return " "

        default:
            if let sym = symbols[cmd] { return sym }
            if functions.contains(cmd) { return cmd }
            return cmd      // unbekannt: Name behalten (selten, aber informativ)
        }
    }

    // MARK: - Lese-Helfer

    /// `start` zeigt auf `\`. Liefert den Befehlsnamen (ohne Backslash) und den Index dahinter.
    private static func readCommand(_ chars: [Character], _ start: Int) -> (String, Int) {
        var i = start + 1
        guard i < chars.count else { return ("\\", i) }
        if chars[i].isLetter {
            var name = ""
            while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
            return (name, i)
        }
        let ch = chars[i]; i += 1
        return (String(ch), i)   // einzelnes Nicht-Buchstaben-Kommando: \, \{ \\ …
    }

    /// Liest das nächste Argument: `{…}`-Gruppe, `\befehl`, oder ein einzelnes Zeichen.
    private static func readArg(_ chars: [Character], _ start: Int) -> (String, Int) {
        var i = start
        while i < chars.count, chars[i] == " " { i += 1 }
        guard i < chars.count else { return ("", i) }
        if chars[i] == "{" { return readBalanced(chars, i) }
        if chars[i] == "\\" {
            let (cmd, next) = readCommand(chars, i)
            return ("\\" + cmd, next)   // Backslash erhalten → convert parst es als Kommando
        }
        return (String(chars[i]), i + 1)
    }

    /// `start` zeigt auf `{`. Liefert den Inhalt (ohne äußere Klammern) und Index nach `}`.
    private static func readBalanced(_ chars: [Character], _ start: Int) -> (String, Int) {
        var depth = 0
        var i = start
        var inner = ""
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                depth += 1
                if depth == 1 { i += 1; continue }
            } else if c == "}" {
                depth -= 1
                if depth == 0 { i += 1; break }
            }
            inner.append(c); i += 1
        }
        return (inner, i)
    }

    // MARK: - Hoch-/Tiefstellung

    private static func superscript(_ s: String) -> String {
        if s.isEmpty { return "" }
        var mapped = ""
        for ch in s {
            guard let m = superMap[ch] else {
                return s.count == 1 ? "^" + s : "^(" + s + ")"
            }
            mapped.append(m)
        }
        return mapped
    }

    private static func subscriptText(_ s: String) -> String {
        if s.isEmpty { return "" }
        var mapped = ""
        for ch in s {
            guard let m = subMap[ch] else {
                return s.count == 1 ? "_" + s : "_(" + s + ")"
            }
            mapped.append(m)
        }
        return mapped
    }

    private static func paren(_ s: String) -> String {
        s.count <= 1 ? s : "(" + s + ")"
    }

    /// Setzt eine Combining-Mark hinter das erste Zeichen des Inhalts (`x` + ̃ → `x̃`).
    private static func accent(_ s: String, _ mark: Character) -> String {
        guard let first = s.first else { return "" }
        return String(first) + String(mark) + String(s.dropFirst())
    }

    // MARK: - Environments (Matrizen, cases)

    /// Liest den Rumpf zwischen `\begin{name}` und dem passenden `\end{name}`
    /// (balanciert über verschachtelte Environments) und liefert den Index dahinter.
    private static func readEnvBody(_ chars: [Character], _ start: Int, _ name: String) -> (String, Int) {
        var i = start
        var depth = 1
        var body = ""
        while i < chars.count {
            if chars[i] == "\\" {
                let (cmd, after) = readCommand(chars, i)
                if cmd == "begin" {
                    depth += 1
                    body += String(chars[i..<after]); i = after; continue
                }
                if cmd == "end" {
                    depth -= 1
                    if depth == 0 {
                        let (_, a2) = readArg(chars, after)   // \end{name} schlucken
                        return (body, a2)
                    }
                    body += String(chars[i..<after]); i = after; continue
                }
                body += String(chars[i..<after]); i = after; continue
            }
            body.append(chars[i]); i += 1
        }
        return (body, i)
    }

    /// Zerlegt einen Environment-Rumpf in Zeilen (`\\`) und Spalten (`&`),
    /// wobei Inhalte in `{…}` und verschachtelten Environments unangetastet bleiben.
    private static func parseGrid(_ s: String) -> [[String]] {
        let chars = Array(s)
        var rows: [[String]] = []
        var cols: [String] = []
        var cur = ""
        var brace = 0
        var env = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" { brace += 1; cur.append(c); i += 1; continue }
            if c == "}" { brace -= 1; cur.append(c); i += 1; continue }
            if c == "&", brace == 0, env == 0 {
                cols.append(cur); cur = ""; i += 1; continue
            }
            if c == "\\" {
                let (cmd, after) = readCommand(chars, i)
                if cmd == "\\", brace == 0, env == 0 {          // Zeilenumbruch
                    cols.append(cur); cur = ""
                    rows.append(cols); cols = []
                    i = after; continue
                }
                if cmd == "begin" { env += 1 }
                else if cmd == "end" { env = max(0, env - 1) }
                cur += String(chars[i..<after]); i = after; continue
            }
            cur.append(c); i += 1
        }
        cols.append(cur); rows.append(cols)
        return rows
    }

    /// Konvertiert die Zellen und wählt das passende Layout (Matrix-Klammern vs. cases).
    private static func formatEnv(_ name: String, _ body: String) -> String {
        let base = name.hasSuffix("*") ? String(name.dropLast()) : name
        var grid = parseGrid(body).map { row in
            row.map { convert($0).trimmingCharacters(in: .whitespaces) }
        }
        while let last = grid.last, last.allSatisfy({ $0.isEmpty }) { grid.removeLast() }
        if grid.isEmpty { return "" }
        if base == "cases" { return formatCases(grid) }
        return formatMatrix(grid, delim: delimKind(for: base))
    }

    /// Spaltenbündige 2D-Darstellung mit (optionalen) Klammer-Glyphen.
    private static func formatMatrix(_ grid: [[String]], delim: DelimKind) -> String {
        let nCols = grid.map(\.count).max() ?? 0
        var widths = [Int](repeating: 0, count: nCols)
        for row in grid {
            for (c, cell) in row.enumerated() { widths[c] = max(widths[c], cell.count) }
        }
        let lines: [String] = grid.map { row in
            var parts: [String] = []
            for c in 0..<nCols {
                let cell = c < row.count ? row[c] : ""
                // Letzte Spalte nur padden, wenn rechts ein Delimiter folgt.
                if c == nCols - 1, !delim.hasRight { parts.append(cell) }
                else { parts.append(pad(cell, widths[c])) }
            }
            return parts.joined(separator: "  ")
        }
        return wrap(lines, delim)
    }

    /// `cases`: nur linke geschweifte Klammer, Spalten mit ", " verbunden.
    private static func formatCases(_ grid: [[String]]) -> String {
        let lines = grid.map { $0.filter { !$0.isEmpty }.joined(separator: ", ") }
        if lines.count == 1 { return "{ " + lines[0] }
        let L = braceColumn("⎧", "⎪", "⎨", "⎩", lines.count)
        return (0..<lines.count).map { L[$0] + " " + lines[$0] }.joined(separator: "\n")
    }

    // MARK: - Klammer-Glyphen

    private enum DelimKind {
        case none, paren, bracket, brace, vert, vvert
        var hasRight: Bool { self != .none }
    }

    private static func delimKind(for base: String) -> DelimKind {
        switch base {
        case "pmatrix": return .paren
        case "bmatrix": return .bracket
        case "Bmatrix": return .brace
        case "vmatrix": return .vert
        case "Vmatrix": return .vvert
        default:        return .none   // matrix, smallmatrix, array, aligned, gather, …
        }
    }

    private static func wrap(_ lines: [String], _ d: DelimKind) -> String {
        if d == .none { return lines.map(rstrip).joined(separator: "\n") }
        let n = lines.count
        if n == 1 {
            let (l, r) = simpleDelims(d)
            return l + lines[0] + r
        }
        let L = sideGlyphs(d, n, left: true)
        let R = sideGlyphs(d, n, left: false)
        return (0..<n).map { L[$0] + lines[$0] + R[$0] }.joined(separator: "\n")
    }

    private static func simpleDelims(_ d: DelimKind) -> (String, String) {
        switch d {
        case .paren:   return ("(", ")")
        case .bracket: return ("[", "]")
        case .brace:   return ("{", "}")
        case .vert:    return ("|", "|")
        case .vvert:   return ("‖", "‖")
        case .none:    return ("", "")
        }
    }

    private static func sideGlyphs(_ d: DelimKind, _ n: Int, left: Bool) -> [String] {
        switch d {
        case .paren:   return left ? column("⎛", "⎜", "⎝", n) : column("⎞", "⎟", "⎠", n)
        case .bracket: return left ? column("⎡", "⎢", "⎣", n) : column("⎤", "⎥", "⎦", n)
        case .brace:   return left ? braceColumn("⎧", "⎪", "⎨", "⎩", n)
                                   : braceColumn("⎫", "⎪", "⎬", "⎭", n)
        case .vert:    return column("│", "│", "│", n)
        case .vvert:   return column("‖", "‖", "‖", n)
        case .none:    return Array(repeating: "", count: n)
        }
    }

    /// Klammer-Spalte: oben/Mitte/unten.
    private static func column(_ top: String, _ mid: String, _ bottom: String, _ n: Int) -> [String] {
        if n == 1 { return [mid] }
        return (0..<n).map { $0 == 0 ? top : ($0 == n - 1 ? bottom : mid) }
    }

    /// Geschweifte Klammer mit Mittel-Glyph (`⎨`/`⎬`) in der vertikalen Mitte.
    private static func braceColumn(_ top: String, _ ext: String, _ mid: String, _ bottom: String, _ n: Int) -> [String] {
        if n == 1 { return [mid] }
        let center = (n - 1) / 2
        return (0..<n).map {
            $0 == 0 ? top : ($0 == n - 1 ? bottom : ($0 == center ? mid : ext))
        }
    }

    private static func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }

    private static func rstrip(_ s: String) -> String {
        var t = s
        while t.hasSuffix(" ") { t.removeLast() }
        return t
    }

    // MARK: - Tabellen

    /// Akzent-Kommando → Unicode-Combining-Mark.
    private static let accents: [String: Character] = [
        "hat": "\u{0302}", "widehat": "\u{0302}",
        "tilde": "\u{0303}", "widetilde": "\u{0303}",
        "bar": "\u{0304}", "overline": "\u{0304}",
        "vec": "\u{20D7}", "overrightarrow": "\u{20D7}",
        "dot": "\u{0307}", "ddot": "\u{0308}",
        "check": "\u{030C}", "breve": "\u{0306}",
        "acute": "\u{0301}", "grave": "\u{0300}",
        "mathring": "\u{030A}", "underline": "\u{0332}"
    ]

    private static let blackboard: [String: String] = [
        "R": "ℝ", "N": "ℕ", "Z": "ℤ", "Q": "ℚ", "C": "ℂ",
        "H": "ℍ", "P": "ℙ", "E": "𝔼", "F": "𝔽", "K": "𝕂"
    ]

    private static let superMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ",
        "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ",
        "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
        "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
        // Griechisch (bereits zu Unicode konvertiert, bevor superscript() greift)
        "α": "ᵅ", "β": "ᵝ", "γ": "ᵞ", "δ": "ᵟ", "φ": "ᵠ", "χ": "ᵡ", "θ": "ᶿ"
    ]

    private static let subMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ",
        "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
        // Griechisch
        "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ"
    ]

    private static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc",
        "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp",
        "lim", "limsup", "liminf", "max", "min", "sup", "inf",
        "det", "dim", "ker", "deg", "gcd", "arg", "Pr", "hom",
        "arcsin", "arccos", "arctan", "mod"
    ]

    private static let symbols: [String: String] = [
        // Griechisch klein
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
        "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο",
        "pi": "π", "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ",
        "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Griechisch groß
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operatoren / Relationen
        "times": "×", "cdot": "·", "div": "÷", "ast": "∗", "star": "⋆",
        "pm": "±", "mp": "∓", "oplus": "⊕", "ominus": "⊖", "otimes": "⊗",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
        "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "cong": "≅",
        "sim": "∼", "simeq": "≃", "propto": "∝", "ll": "≪", "gg": "≫",
        "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱",
        // Mengen / Logik
        "in": "∈", "notin": "∉", "ni": "∋",
        "subset": "⊂", "subseteq": "⊆", "supset": "⊃", "supseteq": "⊇",
        "cup": "∪", "cap": "∩", "setminus": "∖", "emptyset": "∅", "varnothing": "∅",
        "forall": "∀", "exists": "∃", "nexists": "∄",
        "neg": "¬", "lnot": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
        "implies": "⇒", "iff": "⇔",
        // Pfeile
        "rightarrow": "→", "to": "→", "leftarrow": "←", "gets": "←",
        "leftrightarrow": "↔", "Rightarrow": "⇒", "Leftarrow": "⇐",
        "Leftrightarrow": "⇔", "mapsto": "↦", "uparrow": "↑", "downarrow": "↓",
        "longrightarrow": "⟶", "longleftarrow": "⟵",
        // Große Operatoren
        "sum": "∑", "prod": "∏", "coprod": "∐",
        "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂",
        // Sonstiges
        "infty": "∞", "partial": "∂", "nabla": "∇", "hbar": "ℏ", "ell": "ℓ",
        "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘",
        "angle": "∠", "perp": "⊥", "parallel": "∥", "mid": "|", "|": "‖",
        "circ": "∘", "bullet": "•", "degree": "°", "prime": "′",
        "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉",
        "lfloor": "⌊", "rfloor": "⌋", "backslash": "\\",
        "cdotp": "·",
        // Wörter, die als Symbol gemeint sind
        "quad": " ", "qquad": "  "
    ]
}
