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

        // Akzente/Stile: Dekoration fällt weg, Inhalt bleibt
        ("\\vec{x}",            "x"),
        ("\\mathbf{A}",         "A"),

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
}
