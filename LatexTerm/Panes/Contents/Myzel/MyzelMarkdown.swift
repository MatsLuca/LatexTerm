import Foundation

/// Markdown einer Chat-Nachricht → neutrale Blöcke (Foundation-only, getestet in scripts/test-myzel-markdown.swift);
/// die Kachel färbt sie in `MyzelRender`. Sicher per Bau (PROTOKOLL §10.6): es gibt kein HTML, Bilder aus dem Text
/// werden nie geladen (nur als „🖼 alt“ gezeigt), Links nur http/https/mailto. Erwähnungen `@name` werden markiert,
/// aber nicht in Code.
struct MyzelSpan: Equatable {
    struct Style: OptionSet, Equatable {
        let rawValue: Int
        static let strong = Style(rawValue: 1)
        static let emphasis = Style(rawValue: 2)
        static let code = Style(rawValue: 4)
        static let strike = Style(rawValue: 8)
    }

    var text: String
    var style: Style = []
    var link: URL?
    var mention = false
}

struct MyzelBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case code
        case listItem(marker: String, depth: Int)
        case tableRow(header: Bool)
        case rule
    }

    var kind: Kind
    var spans: [MyzelSpan]
    /// Verschachtelung in Zitaten (0 = kein Zitat).
    var quote = 0
}

enum MyzelMarkdown {
    static func blocks(_ text: String, mentions: Set<String> = []) -> [MyzelBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return [MyzelBlock(kind: .paragraph, spans: [MyzelSpan(text: text)])]
        }
        var blocks: [MyzelBlock] = []
        var currentKey: Int?
        var currentCell: Int?
        for run in parsed.runs {
            let intent = run.presentationIntent
            let components = intent?.components ?? []
            let rowComponent = components.first { if case .tableRow = $0.kind { return true }; if case .tableHeaderRow = $0.kind { return true }; return false }
            let key = rowComponent?.identity ?? components.first?.identity ?? -1
            var span = MyzelSpan(text: String(parsed[run.range].characters))
            if let inline = run.inlinePresentationIntent {
                if inline.contains(.stronglyEmphasized) { span.style.insert(.strong) }
                if inline.contains(.emphasized) { span.style.insert(.emphasis) }
                if inline.contains(.code) { span.style.insert(.code) }
                if inline.contains(.strikethrough) { span.style.insert(.strike) }
            }
            if let link = run.link, isSafe(link) { span.link = link }
            if run.imageURL != nil { span = MyzelSpan(text: "🖼 " + span.text, style: span.style) }

            let cell = components.compactMap { c -> Int? in if case .tableCell(let column) = c.kind { return column }; return nil }.first
            if key != currentKey || blocks.isEmpty {
                blocks.append(MyzelBlock(kind: kind(of: components), spans: [], quote: components.filter { $0.kind == .blockQuote }.count))
                currentKey = key
                currentCell = cell
            } else if let cell, cell != currentCell {
                blocks[blocks.count - 1].spans.append(MyzelSpan(text: "  │  "))
                currentCell = cell
            }
            blocks[blocks.count - 1].spans.append(span)
        }
        return blocks.map { finish($0, mentions: mentions) }.filter { !$0.spans.isEmpty || $0.kind == .rule }
    }

    static func isSafe(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    /// Nur Text, ohne Auszeichnung (Antwort-Zitat, Banner): Blöcke mit Leerzeichen verbunden.
    static func plain(_ text: String) -> String {
        blocks(text).map { $0.spans.map(\.text).joined() }.joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func kind(of components: [PresentationIntent.IntentType]) -> MyzelBlock.Kind {
        for (i, c) in components.enumerated() {
            switch c.kind {
            case .codeBlock: return .code
            case .header(let level): return .heading(level)
            case .thematicBreak: return .rule
            case .tableHeaderRow: return .tableRow(header: true)
            case .tableRow: return .tableRow(header: false)
            case .listItem(let ordinal):
                let lists = components[(i + 1)...].filter { $0.kind == .orderedList || $0.kind == .unorderedList }
                let ordered = lists.first?.kind == .orderedList
                return .listItem(marker: ordered ? "\(ordinal)." : "•", depth: max(0, lists.count - 1))
            default: continue
            }
        }
        return .paragraph
    }

    /// Zeilenumbrüche am Blockende weg, nackte URLs verlinken, Erwähnungen markieren (nicht in Code).
    private static func finish(_ block: MyzelBlock, mentions: Set<String>) -> MyzelBlock {
        var block = block
        if let last = block.spans.indices.last {
            while block.spans[last].text.hasSuffix("\n") { block.spans[last].text.removeLast() }
        }
        guard block.kind != .code else { return block }
        block.spans = block.spans.flatMap { span -> [MyzelSpan] in
            guard !span.style.contains(.code), span.link == nil else { return [span] }
            return split(span, mentions: mentions)
        }
        return block
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let mentionPattern = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_@])@([\\p{L}\\p{N}_-]+)")

    private static func split(_ span: MyzelSpan, mentions: Set<String>) -> [MyzelSpan] {
        let text = span.text as NSString
        let whole = NSRange(location: 0, length: text.length)
        var marks: [(NSRange, URL?)] = []
        for m in detector?.matches(in: span.text, range: whole) ?? [] {
            if let url = m.url, isSafe(url), url.scheme?.lowercased() != "mailto" || span.text.contains("mailto:") {
                marks.append((m.range, url))
            }
        }
        for m in mentionPattern.matches(in: span.text, range: whole) where mentions.contains(text.substring(with: m.range(at: 1))) {
            if !marks.contains(where: { NSIntersectionRange($0.0, m.range).length > 0 }) { marks.append((m.range, nil)) }
        }
        guard !marks.isEmpty else { return [span] }
        var out: [MyzelSpan] = []
        var cursor = 0
        for (range, url) in marks.sorted(by: { $0.0.location < $1.0.location }) {
            if range.location > cursor {
                out.append(MyzelSpan(text: text.substring(with: NSRange(location: cursor, length: range.location - cursor)), style: span.style))
            }
            out.append(MyzelSpan(text: text.substring(with: range), style: span.style, link: url, mention: url == nil))
            cursor = range.location + range.length
        }
        if cursor < text.length { out.append(MyzelSpan(text: text.substring(from: cursor), style: span.style)) }
        return out
    }
}
