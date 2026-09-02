import Foundation

struct LaTeXHit: Equatable {
    let body: String
    let startCol: Int
    let endCol: Int
    let displayMode: Bool
}

/// Ein über mehrere Grid-Zeilen reichender Display-Block (`$$..$$`, `\[..\]`),
/// dessen Öffnungs- und Schluss-Delimiter auf verschiedenen Zeilen liegen.
/// `body` ist der zeilenweise getrimmte, mit Leerzeichen verbundene Inhalt.
struct LaTeXBlock: Equatable {
    let body: String
    let startRow: Int
    let startCol: Int
    let endRow: Int
    let endCol: Int   // Spalte direkt nach dem Schluss-Delimiter (auf endRow)
}

/// Ein Treffer, der – durch weiches Zeilen-Wrapping – über eine oder mehrere
/// physische Grid-Zeilen reichen kann. Row-Indizes beziehen sich auf das an
/// `findWrapped` übergebene `rows`-Array. `endCol` ist exklusiv (Spalte direkt
/// nach dem Schluss-Delimiter) auf `endRow`.
struct LaTeXWrappedHit: Equatable {
    let body: String
    let startRow: Int
    let startCol: Int
    let endRow: Int
    let endCol: Int
    let displayMode: Bool
}

enum LaTeXDetector {
    /// `styles` (optional, eine Klasse je Spalte — bei LatexTerm die Vordergrundfarbe der Zelle):
    /// Öffner und Schließer müssen dieselbe Klasse tragen. Ein `$` in Claude Codes blau
    /// gefärbtem Code-Span (`$PATH`) paart sich so nicht mit einem `$` im Fließtext.
    static func find(in line: String, styles: [Int]? = nil) -> [LaTeXHit] {
        let chars = Array(line)
        var hits: [LaTeXHit] = []
        var i = 0
        while i < chars.count {
            guard let open = opener(at: i, chars: chars), !isEscaped(at: i, chars: chars) else {
                i += 1
                continue
            }
            if let closeIdx = findCloser(open.close, in: chars, from: open.contentStart,
                                         styles: styles, style: styles?[i]) {
                let body = repairMarkdownDamage(
                    String(chars[open.contentStart..<closeIdx]).trimmingCharacters(in: .whitespaces))
                if !body.isEmpty, !looksLikeProse(body) {
                    hits.append(LaTeXHit(
                        body: body,
                        startCol: i,
                        endCol: closeIdx + open.close.count,
                        displayMode: open.displayMode
                    ))
                }
                i = closeIdx + open.close.count
            } else {
                i += open.openLen
            }
        }
        return hits
    }

    /// Erkennt Inline-Formeln über weiche Zeilenumbrüche hinweg. `continues[i] == true`
    /// bedeutet, dass `rows[i]` die Fortsetzung von `rows[i-1]` ist (= SwiftTerms
    /// `BufferLine.isWrapped`); `continues[0]` gilt stets als `false`. Aufeinanderfolgende
    /// fortgesetzte Zeilen werden zu einer **logischen Zeile** zusammengefügt, als Ganzes
    /// gescannt und jeder Treffer auf Grid-Koordinaten `(row, col)` zurückprojiziert.
    /// Subsumiert den Einzelzeilen-Fall: eine Gruppe der Größe 1 liefert dieselben Spans
    /// wie `find(in:)`. Kein Doppeltreffer an Bruchstellen, da pro logischer Zeile genau
    /// ein `find`-Lauf erfolgt.
    static func findWrapped(rows: [String], continues: [Bool], styles: [[Int]]? = nil) -> [LaTeXWrappedHit] {
        var result: [LaTeXWrappedHit] = []
        var r = 0
        while r < rows.count {
            // Logische Gruppe: r plus alle direkt folgenden Fortsetzungszeilen.
            var groupEnd = r
            while groupEnd + 1 < rows.count, groupEnd + 1 < continues.count, continues[groupEnd + 1] {
                groupEnd += 1
            }

            if groupEnd == r {
                // Einzelne Zeile: direkter Scan, kein Mapping nötig.
                for hit in find(in: rows[r], styles: styles?[r]) {
                    result.append(LaTeXWrappedHit(
                        body: hit.body,
                        startRow: r, startCol: hit.startCol,
                        endRow: r, endCol: hit.endCol,
                        displayMode: hit.displayMode
                    ))
                }
            } else {
                // Mehrere Zeilen: konkatenieren und Index→(row,col)-Mapping mitführen.
                var logical: [Character] = []
                var logicalStyles: [Int] = []
                var map: [(row: Int, col: Int)] = []
                for gr in r...groupEnd {
                    let chars = Array(rows[gr])
                    for (col, ch) in chars.enumerated() {
                        logical.append(ch)
                        map.append((gr, col))
                        if let st = styles?[gr] { logicalStyles.append(col < st.count ? st[col] : 0) }
                    }
                }
                for hit in find(in: String(logical), styles: styles == nil ? nil : logicalStyles) {
                    // startCol/endCol sind Indizes in die logische Zeile; endCol ist exklusiv.
                    let start = map[hit.startCol]
                    let last = map[hit.endCol - 1]   // letztes Zeichen des Treffers
                    result.append(LaTeXWrappedHit(
                        body: hit.body,
                        startRow: start.row, startCol: start.col,
                        endRow: last.row, endCol: last.col + 1,
                        displayMode: hit.displayMode
                    ))
                }
            }
            r = groupEnd + 1
        }
        return result
    }

    /// Maximale Höhe eines Blocks. Begrenzt den Suchradius für den Schluss-Delimiter,
    /// damit ein verwaister `$$`-/`\[`-Delimiter keinen riesigen Block aufspannt.
    private static let maxBlockRows = 12

    /// Findet mehrzeilige Display-Blöcke (`$$..$$`, `\[..\]`) in **kanonischer Form**:
    /// Öffnungs- und Schluss-Delimiter stehen *jeweils allein auf ihrer Zeile*
    /// (`$$` bzw. `\[` … `\]`). Das ist die übliche Schreibweise und vermeidet
    /// Falschtreffer durch Prosa-`$$` (z.B. „Einzeiliges $$ …") oder die Shell-PID `$$`.
    /// Einzeilige Vorkommen (`$$x$$`) deckt `find(in:)` ab. `lines` = sichtbare
    /// Grid-Zeilen, Index = Viewport-Row.
    static func findBlocks(in lines: [String]) -> [LaTeXBlock] {
        var blocks: [LaTeXBlock] = []
        var r = 0
        while r < lines.count {
            // Öffner allein auf der Zeile — ein reiner Marker davor (Claude Codes „⏺ “,
            // Listenpunkte) ist erlaubt, Prosa nicht. `delimCol` = Spalte des Delimiters.
            guard let (opener, delimCol) = blockOpener(in: lines[r]) else { r += 1; continue }
            let closer = opener == "$$" ? "$$" : "\\]"
            // Passende Schlusszeile suchen (ebenfalls allein auf ihrer Zeile).
            var er = r + 1
            var found = false
            while er < lines.count, er - r <= maxBlockRows {
                if lines[er].trimmingCharacters(in: .whitespaces) == closer { found = true; break }
                er += 1
            }
            guard found else { r += 1; continue }

            let body = repairMarkdownDamage(lines[(r + 1)..<er]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " "))
            if !body.isEmpty {
                blocks.append(LaTeXBlock(
                    body: body,
                    startRow: r, startCol: delimCol,
                    endRow: er, endCol: lines[er].count   // ganze Schlusszeile maskieren
                ))
            }
            r = er + 1
        }
        return blocks
    }

    /// Prosa-Schutz für alle Delimiter (greift v. a. bei `$$ und das war $$` in Fließtext, wo die
    /// Pandoc-Regel nicht gilt): ein Body aus mindestens zwei Wörtern mit je ≥ 3 Buchstaben und
    /// ohne ein einziges Mathe-Zeichen (`\ ^ _ = + - * / < > ( ) [ ] { } |` oder Ziffer) ist Text.
    /// `$ab$`, `$n$`, `$\sin x$`, `$a b$` bleiben Formeln.
    static func looksLikeProse(_ body: String) -> Bool {
        let mathChars: Set<Character> = ["\\", "^", "_", "=", "+", "-", "*", "/", "<", ">", "(", ")", "[", "]", "{", "}", "|"]
        if body.contains(where: { mathChars.contains($0) || $0.isNumber }) { return false }
        let words = body.split(separator: " ").filter { $0.count >= 3 && $0.allSatisfy { $0.isLetter } }
        return words.count >= 2
    }

    /// Claude Codes Markdown-Renderer entfernt den Backslash vor ASCII-Satzzeichen (CommonMark-
    /// Escape): aus `\\` (Zeilenumbruch in Matrizen) wird `\` + Leerzeichen. Innerhalb eines
    /// `\begin{…}`-Environments ist ein nacktes `\ ` (Control Space) praktisch nie gemeint —
    /// wir stellen den Zeilenumbruch wieder her. Andere Schäden (`\,` → `,`, `\{` → `{`,
    /// `\(` → `(`) sind nicht rekonstruierbar.
    static func repairMarkdownDamage(_ body: String) -> String {
        guard body.contains("\\begin{") else { return body }
        var out: [Character] = []
        let c = Array(body)
        var i = 0
        while i < c.count {
            if c[i] == "\\", i + 1 < c.count, c[i + 1] == " ", !(i > 0 && c[i - 1] == "\\") {
                out.append(contentsOf: ["\\", "\\", " "]); i += 2; continue
            }
            out.append(c[i]); i += 1
        }
        return String(out)
    }

    /// Zeichen, die vor einem Block-Öffner stehen dürfen, ohne dass die Zeile als Prosa
    /// gilt: Claude Codes Antwort-Marker `⏺`, Listen- und Zitatzeichen.
    private static let blockMarkerChars: Set<Character> = ["⏺", "•", "·", "-", "*", ">", "⎿", "│"]

    /// Ist `line` eine Block-Öffnerzeile? Liefert den Delimiter (`$$` / `\[`) und seine Spalte.
    /// Erlaubt: nur Leerraum und Marker-Zeichen vor dem Delimiter, nichts dahinter.
    private static func blockOpener(in line: String) -> (String, Int)? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " || blockMarkerChars.contains(chars[i]) { i += 1 }
        guard i + 1 < chars.count else { return nil }
        let delim: String
        if chars[i] == "$", chars[i + 1] == "$" { delim = "$$" }
        else if chars[i] == "\\", chars[i + 1] == "[" { delim = "\\[" }
        else { return nil }
        guard chars[(i + 2)...].allSatisfy({ $0 == " " }) else { return nil }
        return (delim, i)
    }

    /// Heuristik für **harte** Umbrüche, die inhaltlich weich sind: Claude Code (und andere
    /// Markdown-Renderer) brechen lange Zeilen selbst wortweise um und schreiben harte Zeilen mit
    /// Einzug — SwiftTerms `isWrapped` bleibt dann `false`, und eine Formel über so einen Umbruch
    /// hätte auf jeder Zeile nur einen Delimiter. Erkannt wird das Paar, wenn `prev` einen
    /// unpaarigen Öffner trägt, `next` eingerückt beginnt (Fortsetzungs-Einzug) und den passenden
    /// Schließer enthält. Der Einzug ist die Schutzschwelle gegen Shell-Zeilen (`echo $PATH` über
    /// `cd $HOME` beginnt nicht mit Leerzeichen).
    static func looksLikeHardWrapContinuation(prev: String, next: String,
                                              prevStyles: [Int]? = nil, nextStyles: [Int]? = nil) -> Bool {
        let n = Array(next)
        guard let first = n.first, first == " " else { return false }
        guard let open = danglingOpener(in: Array(prev), styles: prevStyles) else { return false }
        return findCloser(open.close, in: n, from: 0, styles: nextStyles, style: open.style) != nil
    }

    /// Schließer (+ Stilklasse) des letzten Öffners in `chars`, der auf der Zeile keinen Partner
    /// mehr findet (nil = alle Öffner geschlossen bzw. keiner vorhanden). Läuft wie `find`.
    private static func danglingOpener(in chars: [Character], styles: [Int]?) -> (close: [Character], style: Int?)? {
        var i = 0
        while i < chars.count {
            guard let open = opener(at: i, chars: chars), !isEscaped(at: i, chars: chars) else { i += 1; continue }
            let style = styles?[i]
            if let closeIdx = findCloser(open.close, in: chars, from: open.contentStart, styles: styles, style: style) {
                i = closeIdx + open.close.count
            } else {
                // Unpaarig — aber nur, wenn danach noch Inhalt kommt (ein nacktes `$` am
                // Zeilenende ist eher Prosa/Prompt als eine umgebrochene Formel).
                let rest = chars[open.contentStart...]
                return rest.contains(where: { $0 != " " }) ? (open.close, style) : nil
            }
        }
        return nil
    }

    private struct Open {
        let close: [Character]
        let contentStart: Int
        let openLen: Int
        let displayMode: Bool
    }

    private static func opener(at i: Int, chars: [Character]) -> Open? {
        if i + 1 < chars.count, chars[i] == "$", chars[i+1] == "$" {
            return Open(close: ["$", "$"], contentStart: i + 2, openLen: 2, displayMode: true)
        }
        if chars[i] == "$" {
            // Pandoc-Regel (tex_math_dollars): rechts vom Öffner muss ein Nicht-Leerzeichen stehen —
            // `offenes $, unten` oder `5 $ und` sind Prosa, kein Formelanfang.
            guard i + 1 < chars.count, chars[i + 1] != " " else { return nil }
            return Open(close: ["$"], contentStart: i + 1, openLen: 1, displayMode: false)
        }
        if i + 1 < chars.count, chars[i] == "\\" {
            if chars[i+1] == "[" {
                return Open(close: ["\\", "]"], contentStart: i + 2, openLen: 2, displayMode: true)
            }
            if chars[i+1] == "(" {
                return Open(close: ["\\", ")"], contentStart: i + 2, openLen: 2, displayMode: false)
            }
        }
        return nil
    }

    /// Sucht den Schluss-Delimiter ab `from`. Führt die Tiefe nicht-escapter
    /// `{`/`}`-Gruppen mit: ein `$` innerhalb einer Gruppe (`$\text{cost: $5}$`)
    /// zählt **nicht** als Closer, sondern nur ein Delimiter auf Tiefe 0.
    /// Escapte Klammern (`\{`, `\}`) sind literale Zeichen und ändern die Tiefe
    /// nicht; die Tiefe wird bei `}`-Überschuss auf 0 geklemmt, damit ein
    /// einzelnes literales `\}` ohne `\{` den Closer nicht verschluckt.
    /// Für den einfachen `$`-Schließer gilt zusätzlich die Pandoc-Regel: links ein
    /// Nicht-Leerzeichen, rechts keine Ziffer (`mit $PATH` schließt nichts, `$5` ist ein Preis).
    /// `styles`/`style`: der Schließer muss die Stilklasse des Öffners tragen (s. `find`).
    private static func findCloser(_ delim: [Character], in chars: [Character], from: Int,
                                   styles: [Int]? = nil, style: Int? = nil) -> Int? {
        var j = from
        var depth = 0
        while j + delim.count <= chars.count {
            let c = chars[j]
            if (c == "{" || c == "}") && !isEscaped(at: j, chars: chars) {
                depth = c == "{" ? depth + 1 : max(0, depth - 1)
                j += 1
                continue
            }
            if depth == 0 && matches(delim, at: j, in: chars) && !isEscaped(at: j, chars: chars) {
                if delim == ["$"] {
                    if j + 1 < chars.count, chars[j+1] == "$" { j += 2; continue }
                    let leftOk = j > 0 && chars[j - 1] != " "
                    let rightOk = j + 1 >= chars.count || !chars[j + 1].isNumber
                    if !(leftOk && rightOk) { j += 1; continue }
                }
                if let styles, let style, j < styles.count, styles[j] != style { j += 1; continue }
                return j
            }
            j += 1
        }
        return nil
    }

    private static func matches(_ delim: [Character], at j: Int, in chars: [Character]) -> Bool {
        for k in 0..<delim.count where chars[j+k] != delim[k] { return false }
        return true
    }

    private static func isEscaped(at i: Int, chars: [Character]) -> Bool {
        var n = 0
        var k = i - 1
        while k >= 0, chars[k] == "\\" { n += 1; k -= 1 }
        return n % 2 == 1
    }
}
