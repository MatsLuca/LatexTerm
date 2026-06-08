import XCTest

/// Fixture-getriebene Tests für den Offline-Konverter `LaTeXReadable`.
final class LaTeXReadableTests: XCTestCase {

    /// Erwartung-Tabelle: LaTeX-Eingabe → lesbare Unicode-Math-Ausgabe.
    private let cases: [(input: String, expected: String)] = [
        // Brüche
        ("\\frac{a}{b}",        "a/b"),
        ("\\frac{a+b}{c}",      "(a+b)/c"),
        ("\\frac12",            "1/2"),               // einzelne Zeichen als Argument

        // Wurzeln
        ("\\sqrt{x}",           "√x"),
        ("\\sqrt{x+1}",         "√(x+1)"),
        ("\\sqrt[3]{x}",        "³√x"),               // n-te Wurzel

        // Hoch-/Tiefstellung
        ("x^2",                 "x²"),
        ("a_1",                 "a₁"),
        ("x^{n+1}",             "xⁿ⁺¹"),              // alle mapbar → Unicode-Superscript
        ("x^{qy}",              "x^(qy)"),            // 'q' nicht mapbar → Fallback ^(…)

        // Griechisch & Operatoren
        ("\\alpha + \\beta",    "α + β"),
        ("a \\times b",         "a × b"),
        ("x \\leq y",           "x ≤ y"),

        // Blackboard-Mengen
        ("\\mathbb{R}",         "ℝ"),
        ("\\mathbb{N}",         "ℕ"),

        // Text / Funktionen bleiben aufrecht
        ("\\text{hallo}",       "hallo"),
        ("\\sin x",             "sin x"),

        // Stile: Dekoration fällt weg, Inhalt bleibt
        ("\\mathbf{A}",         "A"),
        ("\\mathcal{L}",        "L"),

        // Akzente: als Unicode-Combining-Mark sichtbar (#6)
        ("\\vec{x}",            "x\u{20D7}"),
        ("\\hat{x}",            "x\u{0302}"),
        ("\\tilde{x}",          "x\u{0303}"),
        ("\\bar{x}",            "x\u{0304}"),
        ("\\dot{x}",            "x\u{0307}"),

        // Griechisch in Hoch-/Tiefstellung (#6: vervollständigte Maps)
        ("x^\\alpha",           "xᵅ"),
        ("a_\\beta",            "aᵦ"),

        // Das Doc-Beispiel: Mitternachtsformel
        ("\\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}", "(-b ± √(b²-4ac))/(2a)"),
    ]

    func testReadableFixtures() {
        for (input, expected) in cases {
            XCTAssertEqual(
                LaTeXReadable.readable(input), expected,
                "readable(\(input.debugDescription)) sollte \(expected.debugDescription) sein"
            )
        }
    }

    func testWhitespaceIsCollapsedAndTrimmed() {
        XCTAssertEqual(LaTeXReadable.readable("  a \\quad b  "), "a b")
    }

    func testUnknownCommandKeepsItsName() {
        // Unbekanntes Kommando: Name bleibt erhalten (informativ statt Absturz).
        XCTAssertEqual(LaTeXReadable.readable("\\foobar"), "foobar")
    }

    // MARK: - Environments (#6)

    func testPmatrixRendersAs2DWithParens() {
        let out = LaTeXReadable.readable("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}")
        XCTAssertEqual(out, "⎛a  b⎞\n⎝c  d⎠")
    }

    func testBmatrixRendersAs2DWithBrackets() {
        let out = LaTeXReadable.readable("\\begin{bmatrix}1 & 2 \\\\ 3 & 4\\end{bmatrix}")
        XCTAssertEqual(out, "⎡1  2⎤\n⎣3  4⎦")
    }

    func testMatrixAlignsUnequalColumnWidths() {
        let out = LaTeXReadable.readable("\\begin{pmatrix}10 & 2 \\\\ 3 & 40\\end{pmatrix}")
        XCTAssertEqual(out, "⎛10  2 ⎞\n⎝3   40⎠")
    }

    func testCasesRendersWithLeftBrace() {
        let out = LaTeXReadable.readable("\\begin{cases} a & x>0 \\\\ b & x<0 \\end{cases}")
        XCTAssertEqual(out, "⎧ a, x>0\n⎩ b, x<0")
    }

    func testEnvironmentDoesNotCollapseToEmpty() {
        // Akzeptanzkriterium: keine Leerstring-Ausgabe mehr für strukturierte Envs.
        XCTAssertFalse(LaTeXReadable.readable("\\begin{matrix}a&b\\\\c&d\\end{matrix}").isEmpty)
    }
}
