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
        let r = convert(latex)
        let collapsed = r.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

        // Akzente/Stile: Inhalt konvertieren, Dekoration weglassen
        case "mathbf", "boldsymbol", "bm", "mathit", "mathcal", "mathfrak",
             "vec", "hat", "bar", "tilde", "dot", "ddot", "overline", "underline",
             "overrightarrow", "widehat", "widetilde":
            let (a, n1) = readArg(chars, i); i = n1
            return convert(a)

        case "left", "right":
            var j = i
            while j < chars.count, chars[j] == " " { j += 1 }
            if j < chars.count, chars[j] == "." { i = j + 1 }   // unsichtbarer Delimiter
            return ""

        case "begin", "end":
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

    // MARK: - Tabellen

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
        "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ"
    ]

    private static let subMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ",
        "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ",
        "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
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
        "leftarrow ": "←", "cdotp": "·",
        // Wörter, die als Symbol gemeint sind
        "quad": " ", "qquad": "  "
    ]
}
