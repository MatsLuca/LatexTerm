import XCTest

/// Fixture-Tests für die Eingabe-Box-Erkennung. Jede Zeile ist ein String; `cols` = Breite.
/// Zeichen-Sonderregel: `~` markiert eine Zelle mit *gefärbtem* (Nicht-Standard-) Vordergrund,
/// gefolgt vom eigentlichen Zeichen — z. B. `~─` = Trennlinie in Claude-Grau.
final class PromptBoxLocatorTests: XCTestCase {
    private let cols = 40

    private func grid(_ lines: [String], cols: Int? = nil) -> [[PromptBoxLocator.Cell]] {
        let w = cols ?? self.cols
        return lines.map { line in
            var cells: [PromptBoxLocator.Cell] = []
            var styled = false
            for ch in line {
                if ch == "~" { styled = true; continue }
                cells.append(.init(ch, defaultFg: !styled))
                styled = false
            }
            while cells.count < w { cells.append(.init(" ")) }
            return Array(cells.prefix(w))
        }
    }

    private func rule(_ styled: Bool = true, width: Int? = nil) -> String {
        let w = width ?? cols
        return String(repeating: styled ? "~─" : "─", count: w)
    }

    func testSimpleBox() {
        let rows = grid(["Claude sagt etwas", "", rule(), "❯ hallo welt", rule(), "statusline · master"])
        XCTAssertEqual(PromptBoxLocator.locate(rows: rows), .init(topRule: 2, bottomRule: 4))
    }

    func testEmptyPromptOnlyMarker() {
        let rows = grid([rule(), "❯", rule(), "ctx ███░░░ 39%"])
        XCTAssertEqual(PromptBoxLocator.locate(rows: rows)?.contentRows, 1..<2)
    }

    func testMultilineWithBlankLinesAndWraps() {
        let rows = grid([rule(), "❯ erste zeile", "", "", "  umbrochene fortsetzung", "dritte zeile ohne einzug", rule(), "status"])
        XCTAssertEqual(PromptBoxLocator.locate(rows: rows)?.contentRows, 1..<6)
    }

    func testAsciiDashesAreNotRules() {
        let rows = grid([rule(), "❯ a --> b", String(repeating: "-", count: cols), "--- und ---", rule()])
        let box = PromptBoxLocator.locate(rows: rows)
        XCTAssertEqual(box, .init(topRule: 0, bottomRule: 4))
    }

    func testUserTypedFullRuleInsideBoxIsSkipped() {
        // Nutzer tippt selbst eine ────-Zeile in die Box: darunter steht sein Text, kein Marker.
        let rows = grid([rule(), "❯ oben", rule(false), "unten", rule(), "status"])
        XCTAssertEqual(PromptBoxLocator.locate(rows: rows), .init(topRule: 0, bottomRule: 4))
    }

    func testUserTypedRuleWithStyledRequirement() {
        let rows = grid([rule(), "❯ oben", rule(false), "❯ sieht aus wie marker", rule(), "status"])
        // Ohne Farbprüfung würde die getippte Linie als obere Linie gelten (Zeile 2) —
        // mit `requireStyledRules` bleibt nur die echte (Zeile 0).
        XCTAssertEqual(PromptBoxLocator.locate(rows: rows, requireStyledRules: true), .init(topRule: 0, bottomRule: 4))
    }

    func testDialogBordersAreNotRules() {
        let inner = String(repeating: "─", count: cols - 2)
        let rows = grid(["╭" + inner + "╮", "│ Do you want to proceed?", "╰" + inner + "╯", "status"])
        XCTAssertNil(PromptBoxLocator.locate(rows: rows))
    }

    func testNoBoxWhenScrolledAway() {
        let rows = grid(["nur text", "mehr text", "", "── kurze linie ──"])
        XCTAssertNil(PromptBoxLocator.locate(rows: rows))
    }

    func testShortRuleIsNotARule() {
        let rows = grid([rule(width: cols / 2), "❯ x", rule(width: cols / 2)])
        XCTAssertNil(PromptBoxLocator.locate(rows: rows))
    }

    func testRuleMustStartAtColumnZero() {
        let rows = grid(["  " + rule(width: cols - 2), "❯ x", "  " + rule(width: cols - 2)])
        XCTAssertNil(PromptBoxLocator.locate(rows: rows))
    }

    func testBottomRuleIsLowestEvenWithOlderBoxAbove() {
        // Ältere Ausgabe enthielt eine vollständige Linie (z. B. ein früherer Prompt im Scrollback).
        let rows = grid([rule(), "❯ alt", rule(), "Antwort …", rule(), "❯ neu", rule(), "status"])
        XCTAssertEqual(PromptBoxLocator.locate(rows: rows), .init(topRule: 4, bottomRule: 6))
    }

    func testLegacyAngleMarker() {
        let rows = grid([rule(), "> hallo", rule()])
        XCTAssertNotNil(PromptBoxLocator.locate(rows: rows))
    }

    func testSuggestionsBelowBoxAreOutside() {
        let rows = grid([rule(), "❯ /co", rule(), "  /color   Set session color", "  /config  Settings"])
        XCTAssertEqual(PromptBoxLocator.locate(rows: rows)?.contentRows, 1..<2)
    }
}
