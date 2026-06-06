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
        let hits = LaTeXDetector.find(in: "$  x + y  $")
        XCTAssertEqual(hits.first?.body, "x + y")
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
}
