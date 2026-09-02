import XCTest

/// Fixture-getriebene Tests für `LaTeXDetector`.
///
/// `LaTeXDetector`/`LaTeXHit`/`LaTeXBlock` sind reine Foundation-Logik und werden
/// direkt ins Test-Target kompiliert (kein App-Host, kein `@testable import`).
final class LaTeXDetectorTests: XCTestCase {

    // MARK: - find(in:) — einzeilige Treffer

    func testInlineDollar() {
        let hits = LaTeXDetector.find(in: "vorher $E=mc^2$ nachher")
        XCTAssertEqual(hits, [
            LaTeXHit(body: "E=mc^2", startCol: 7, endCol: 15, displayMode: false)
        ])
    }

    func testInlineParenDelimiter() {
        let hits = LaTeXDetector.find(in: "\\(a+b\\)")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.body, "a+b")
        XCTAssertEqual(hits.first?.displayMode, false)
    }

    func testSingleLineDisplayDollarDollar() {
        let hits = LaTeXDetector.find(in: "$$x^2$$")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.body, "x^2")
        XCTAssertEqual(hits.first?.displayMode, true)
    }

    func testSingleLineDisplayBracket() {
        let hits = LaTeXDetector.find(in: "\\[a=b\\]")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.body, "a=b")
        XCTAssertEqual(hits.first?.displayMode, true)
    }

    func testMultipleHitsInOneLine() {
        let hits = LaTeXDetector.find(in: "$a$ und $b$")
        XCTAssertEqual(hits.map(\.body), ["a", "b"])
        XCTAssertEqual(hits.map(\.startCol), [0, 8])
    }

    func testBodyIsTrimmed() {
        // Innen-Leerraum wird getrimmt; bei `$` verbietet die Pandoc-Regel Leerzeichen direkt am
        // Delimiter (Prosa-Schutz), bei `\(…\)` und `$$…$$` nicht.
        XCTAssertEqual(LaTeXDetector.find(in: "\\(  x + y  \\)").first?.body, "x + y")
        XCTAssertEqual(LaTeXDetector.find(in: "$$  x + y  $$").first?.body, "x + y")
        XCTAssertTrue(LaTeXDetector.find(in: "$  x + y  $").isEmpty)
    }

    // MARK: - Escaping & Negativfälle

    func testEscapedDollarIsNotADelimiter() {
        // \$5 und \$10 sind maskiert → keine Formel.
        XCTAssertTrue(LaTeXDetector.find(in: "Preis \\$5 bis \\$10").isEmpty)
    }

    func testEmptyBodyIsSkipped() {
        XCTAssertTrue(LaTeXDetector.find(in: "$$").isEmpty)
        XCTAssertTrue(LaTeXDetector.find(in: "$$$$").isEmpty)
    }

    func testUnclosedDelimiterYieldsNoHit() {
        XCTAssertTrue(LaTeXDetector.find(in: "offen $x+y").isEmpty)
    }

    func testStartAndEndColumns() {
        // "ab $x$ cd": $ bei 3, Schluss-$ bei 5 → endCol = 6
        let hit = LaTeXDetector.find(in: "ab $x$ cd").first
        XCTAssertEqual(hit?.startCol, 3)
        XCTAssertEqual(hit?.endCol, 6)
    }

    // MARK: - Brace-Awareness & Shell-Robustheit (#3)

    func testInnerDollarInBraceDoesNotCloseEarly() {
        // Das $ in "cost: $5" steht innerhalb einer {…}-Gruppe und darf den
        // Schluss-Delimiter nicht vorziehen → genau EINE Formel.
        let hits = LaTeXDetector.find(in: "$\\text{cost: $5}$")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.body, "\\text{cost: $5}")
        XCTAssertEqual(hits.first?.startCol, 0)
        XCTAssertEqual(hits.first?.endCol, 17)
    }

    func testSubscriptBraceStillCloses() {
        // Regress: ausgeglichene Gruppe darf den Closer nicht verschlucken.
        XCTAssertEqual(LaTeXDetector.find(in: "$a_{i}$").first?.body, "a_{i}")
        XCTAssertEqual(LaTeXDetector.find(in: "$\\frac{1}{2}$").first?.body, "\\frac{1}{2}")
    }

    func testEscapedBracesAreLiteralAndCloserSurvives() {
        // \{ \} sind literale Zeichen, nicht Gruppen → Closer wird erkannt.
        XCTAssertEqual(LaTeXDetector.find(in: "$\\{a\\}$").first?.body, "\\{a\\}")
    }

    func testUnbalancedLiteralCloseBraceDoesNotEatCloser() {
        // Einzelnes literales \} (ohne \{) klemmt die Tiefe auf 0 → Closer bleibt gültig.
        XCTAssertEqual(LaTeXDetector.find(in: "$\\}$").first?.body, "\\}")
    }

    func testShellArtifactsWithoutCloserYieldNoHits() {
        // $$, $PATH, $(…) ohne schließendes $ erzeugen keine Overlays.
        XCTAssertTrue(LaTeXDetector.find(in: "PID ist $$ heute").isEmpty)
        XCTAssertTrue(LaTeXDetector.find(in: "echo $PATH ende").isEmpty)
        XCTAssertTrue(LaTeXDetector.find(in: "echo $((1+2)) ende").isEmpty)
        XCTAssertTrue(LaTeXDetector.find(in: "Betrag $5 ohne close").isEmpty)
    }

    func testLiteralBackslashThenDollarYieldsNoHit() {
        // \\$5 = literaler Backslash + $ ohne Closer → keine Formel.
        XCTAssertTrue(LaTeXDetector.find(in: "Preis \\\\$5").isEmpty)
    }

    // MARK: - findWrapped(rows:continues:) — über Zeilenumbrüche (#1)

    func testWrappedAcrossTwoRows() {
        // Formel beginnt auf Zeile 0, läuft via Soft-Wrap auf Zeile 1 weiter.
        let hits = LaTeXDetector.findWrapped(
            rows: ["abc $\\frac{n}", "{2}$ def"],
            continues: [false, true]
        )
        XCTAssertEqual(hits, [
            LaTeXWrappedHit(body: "\\frac{n}{2}", startRow: 0, startCol: 4,
                            endRow: 1, endCol: 4, displayMode: false)
        ])
    }

    func testWrappedAcrossThreeRows() {
        let hits = LaTeXDetector.findWrapped(
            rows: ["$\\frac{a+", "b+c}{d+", "e}$"],
            continues: [false, true, true]
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.body, "\\frac{a+b+c}{d+e}")
        XCTAssertEqual(hits.first?.startRow, 0)
        XCTAssertEqual(hits.first?.endRow, 2)
    }

    func testWrappedSubsumesSingleLine() {
        // continues alle false → identisches Ergebnis wie find(in:) pro Zeile.
        let hits = LaTeXDetector.findWrapped(
            rows: ["$a$ und $b$", "plain"],
            continues: [false, false]
        )
        XCTAssertEqual(hits.map(\.body), ["a", "b"])
        XCTAssertTrue(hits.allSatisfy { $0.startRow == $0.endRow && $0.startRow == 0 })
        XCTAssertEqual(hits.map(\.startCol), [0, 8])
    }

    func testHitFullyWithinOneRowInsideWrapGroup() {
        // In einer Wrap-Gruppe, aber der Treffer liegt komplett auf einer Row.
        let hits = LaTeXDetector.findWrapped(
            rows: ["x $a$ yyyy", "yyy $b$"],
            continues: [false, true]
        )
        XCTAssertEqual(hits, [
            LaTeXWrappedHit(body: "a", startRow: 0, startCol: 2, endRow: 0, endCol: 5, displayMode: false),
            LaTeXWrappedHit(body: "b", startRow: 1, startCol: 4, endRow: 1, endCol: 7, displayMode: false)
        ])
    }

    func testWrapGroupWithoutCloserYieldsNoHit() {
        // Formel öffnet, schließt aber nirgends in der (sichtbaren) Gruppe.
        XCTAssertTrue(LaTeXDetector.findWrapped(
            rows: ["text $x+y", "z+w more"],
            continues: [false, true]
        ).isEmpty)
    }

    // MARK: - findBlocks(in:) — mehrzeilige Display-Blöcke

    func testCanonicalMultiLineBlock() {
        let lines = [
            "vorher",
            "$$",
            "a + b",
            "= c",
            "$$",
            "nachher"
        ]
        let blocks = LaTeXDetector.findBlocks(in: lines)
        XCTAssertEqual(blocks.count, 1)
        let b = blocks[0]
        XCTAssertEqual(b.body, "a + b = c")
        XCTAssertEqual(b.startRow, 1)
        XCTAssertEqual(b.endRow, 4)
    }

    func testBracketBlock() {
        let lines = ["\\[", "x = y", "\\]"]
        let blocks = LaTeXDetector.findBlocks(in: lines)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].body, "x = y")
    }

    func testBlockRequiresDelimiterAloneOnLine() {
        // "$$" steckt in Prosa → kein Block (vermeidet Falschtreffer & Shell-PID $$).
        let lines = ["Text mit $$ mittendrin", "noch was"]
        XCTAssertTrue(LaTeXDetector.findBlocks(in: lines).isEmpty)
    }

    func testBlockWithoutCloserIsIgnored() {
        let lines = ["$$", "a", "b"]
        XCTAssertTrue(LaTeXDetector.findBlocks(in: lines).isEmpty)
    }

    func testBlockBeyondMaxRowsIsIgnored() {
        // 13 Inhaltszeilen zwischen den Delimitern > maxBlockRows (12) → kein Block.
        var lines = ["$$"]
        lines += Array(repeating: "x", count: 13)
        lines += ["$$"]
        XCTAssertTrue(LaTeXDetector.findBlocks(in: lines).isEmpty)
    }

    func testBlockOpenerWithClaudeMarkerPrefix() {
        // Claude Code stellt der ersten Absatzzeile „⏺ " voran — der Block gilt trotzdem,
        // startCol zeigt auf den Delimiter (der Marker bleibt sichtbar).
        let lines = ["⏺ $$", "  a = b", "  $$", ""]
        let blocks = LaTeXDetector.findBlocks(in: lines)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].body, "a = b")
        XCTAssertEqual(blocks[0].startCol, 2)
        XCTAssertEqual(blocks[0].endRow, 2)
    }

    func testBlockOpenerWithProseIsNotABlock() {
        let lines = ["Kosten $$", "a", "$$"]
        XCTAssertTrue(LaTeXDetector.findBlocks(in: lines).isEmpty)
    }

    // MARK: - looksLikeHardWrapContinuation — Claude Codes eigener Wortumbruch

    func testHardWrapContinuationClaudeStyle() {
        XCTAssertTrue(LaTeXDetector.looksLikeHardWrapContinuation(
            prev: "⏺ Die Lösung ist $x = \\frac{-b \\pm",
            next: "  \\sqrt{b^2-4ac}}{2a}$ und damit eindeutig."))
    }

    func testHardWrapContinuationParenDelimiter() {
        XCTAssertTrue(LaTeXDetector.looksLikeHardWrapContinuation(
            prev: "  also \\(a +", next: "  b\\) ist"))
    }

    func testHardWrapRejectsShellVariablesWithoutIndent() {
        // Zwei Shell-Zeilen: kein Einzug → kein Join (sonst würde `$PATH … $HOME` zur Formel).
        XCTAssertFalse(LaTeXDetector.looksLikeHardWrapContinuation(
            prev: "echo $PATH", next: "cd $HOME"))
    }

    func testHardWrapRejectsWhenPrevIsBalanced() {
        XCTAssertFalse(LaTeXDetector.looksLikeHardWrapContinuation(
            prev: "  $a$ fertig", next: "  $b$ neu"))
    }

    func testHardWrapRejectsWhenNextHasNoCloser() {
        XCTAssertFalse(LaTeXDetector.looksLikeHardWrapContinuation(
            prev: "  ist $x +", next: "  y ohne Ende"))
    }

    func testHardWrapRejectsBareDollarAtLineEnd() {
        // Nacktes `$` am Zeilenende (Prompt, Preis-Prosa) ist kein Öffner einer Formel.
        XCTAssertFalse(LaTeXDetector.looksLikeHardWrapContinuation(
            prev: "Preis in $", next: "  5$ Dollar"))
    }

    // MARK: - Prosa-Schutz: Pandoc-Regel + Stilklassen

    func testPandocRuleShellVariablesOnOneLine() {
        // `$PATH and $HOME`: das zweite `$` hat links ein Leerzeichen → kein Schließer.
        XCTAssertTrue(LaTeXDetector.find(in: "echo $PATH and $HOME").isEmpty)
    }

    func testPandocRuleOpenerNeedsNonSpaceRight() {
        XCTAssertTrue(LaTeXDetector.find(in: "kostet 5 $ und 7 $ hier").isEmpty)
        XCTAssertTrue(LaTeXDetector.find(in: "offenes $, dann $x$").count == 1)
    }

    func testPandocRuleCloserNotBeforeDigit() {
        // `$5` als Preis: das `$` direkt vor einer Ziffer schließt nichts.
        XCTAssertTrue(LaTeXDetector.find(in: "von $a bis $5 Dollar").isEmpty)
        XCTAssertEqual(LaTeXDetector.find(in: "$x_1$ und $y$").count, 2)
    }

    func testPandocRuleKeepsLegitMath() {
        XCTAssertEqual(LaTeXDetector.find(in: "$(a+b)$ und $n$th und $X$ … $Y$").count, 4)
    }

    func testStyleClassMustMatch() {
        // "mit $PATH" in Code-Farbe (Klasse 1), das `$` davor im Fließtext (Klasse 0): kein Paar.
        let line = "ein $x, mit $PATH ok"
        var styles = [Int](repeating: 0, count: line.count)
        for i in 12..<17 { styles[i] = 1 }
        XCTAssertTrue(LaTeXDetector.find(in: line, styles: styles).isEmpty)
        // Ohne Stilinfo greift nur die Pandoc-Regel: `$PATH`s `$` hat links ein Leerzeichen → ebenfalls leer.
        XCTAssertTrue(LaTeXDetector.find(in: line).isEmpty)
        // Gleiche Klasse überall → normale Paarung.
        XCTAssertEqual(LaTeXDetector.find(in: "ein $x$ ok", styles: [Int](repeating: 3, count: 10)).count, 1)
    }

    func testHardWrapRejectsProseWithCodeColoredDollar() {
        // Der Fall aus Mats' Screenshot: „offenes $,“ oben, „mit $PATH“ (Code-Farbe) unten.
        let prev = "  Regel: oben ein offenes $, unten"
        let next = "  eine Zeile mit $PATH und $HOME getrennt."
        XCTAssertFalse(LaTeXDetector.looksLikeHardWrapContinuation(prev: prev, next: next))
    }

    // MARK: - Prosa-Body + Markdown-Schaden

    func testProseBodyInDoubleDollarIsRejected() {
        XCTAssertTrue(LaTeXDetector.find(in: "die PID ist $$ und das war $$ kein Block").isEmpty)
        XCTAssertTrue(LaTeXDetector.looksLikeProse("und das war"))
        XCTAssertFalse(LaTeXDetector.looksLikeProse("a b"))
        XCTAssertFalse(LaTeXDetector.looksLikeProse("\\sin x"))
        XCTAssertFalse(LaTeXDetector.looksLikeProse("abc"))
        XCTAssertEqual(LaTeXDetector.find(in: "$$x^2 + y^2$$").count, 1)
    }

    func testRepairMatrixRowBreaksEatenByMarkdown() {
        // CC macht aus `1 & 2 \\\\ 3 & 4` ein `1 & 2 \\ 3 & 4` — im Environment zurück zu `\\\\`.
        let damaged = "\\begin{pmatrix} 1 & 2 \\ 3 & 4 \\end{pmatrix}"
        XCTAssertEqual(LaTeXDetector.repairMarkdownDamage(damaged),
                       "\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}")
        // Ohne Environment bleibt `\\ ` (Control Space) unangetastet.
        XCTAssertEqual(LaTeXDetector.repairMarkdownDamage("a\\ b"), "a\\ b")
        // Ein echtes `\\\\ ` wird nicht verdoppelt.
        let ok = "\\begin{cases} a \\\\ b \\end{cases}"
        XCTAssertEqual(LaTeXDetector.repairMarkdownDamage(ok), ok)
    }
}
