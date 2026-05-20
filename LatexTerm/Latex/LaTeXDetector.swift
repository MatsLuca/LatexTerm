import Foundation

struct LaTeXHit: Equatable {
    let body: String
    let startCol: Int
    let endCol: Int
    let displayMode: Bool
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
