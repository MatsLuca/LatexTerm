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

enum LaTeXDetector {
    static func find(in line: String) -> [LaTeXHit] {
        let chars = Array(line)
        var hits: [LaTeXHit] = []
        var i = 0
        while i < chars.count {
            guard let open = opener(at: i, chars: chars), !isEscaped(at: i, chars: chars) else {
                i += 1
                continue
            }
            if let closeIdx = findCloser(open.close, in: chars, from: open.contentStart) {
                let body = String(chars[open.contentStart..<closeIdx]).trimmingCharacters(in: .whitespaces)
                if !body.isEmpty {
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
            let openTrim = lines[r].trimmingCharacters(in: .whitespaces)
            let closer: String
            switch openTrim {
            case "$$":  closer = "$$"
            case "\\[": closer = "\\]"
            default:    r += 1; continue
            }
            // Passende Schlusszeile suchen (ebenfalls allein auf ihrer Zeile).
            var er = r + 1
            var found = false
            while er < lines.count, er - r <= maxBlockRows {
                if lines[er].trimmingCharacters(in: .whitespaces) == closer { found = true; break }
                er += 1
            }
            guard found else { r += 1; continue }

            let body = lines[(r + 1)..<er]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !body.isEmpty {
                let startCol = lines[r].prefix { $0 == " " }.count   // Delimiter steht meist bei 0
                blocks.append(LaTeXBlock(
                    body: body,
                    startRow: r, startCol: startCol,
                    endRow: er, endCol: lines[er].count   // ganze Schlusszeile maskieren
                ))
            }
            r = er + 1
        }
        return blocks
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

    private static func findCloser(_ delim: [Character], in chars: [Character], from: Int) -> Int? {
        var j = from
        while j + delim.count <= chars.count {
            if matches(delim, at: j, in: chars) && !isEscaped(at: j, chars: chars) {
                if delim == ["$"], j + 1 < chars.count, chars[j+1] == "$" {
                    j += 2
                    continue
                }
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
