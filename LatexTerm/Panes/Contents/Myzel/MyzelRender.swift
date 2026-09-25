import AppKit

/// `MyzelBlock`s → NSAttributedString im Stil der App (Mono, Farben aus dem Theme). Keine festen Farben.
enum MyzelRender {
    static let bodySize: CGFloat = 12.5

    struct Palette {
        let text: NSColor
        let dim: NSColor
        let faint: NSColor
        let link: NSColor
        let code: NSColor
        let codeGround: NSColor
        let mention: NSColor

        init(theme: TerminalTheme) {
            text = theme.foreground.withAlphaComponent(LineStyle.textFocused)
            dim = theme.foreground.withAlphaComponent(LineStyle.text)
            faint = theme.foreground.withAlphaComponent(LineStyle.faint)
            link = theme.blue
            code = theme.cyan
            codeGround = theme.foreground.withAlphaComponent(LineStyle.hover)
            mention = Tone.claude.color
        }
    }

    static func attributed(_ blocks: [MyzelBlock], theme: TerminalTheme, size: CGFloat = bodySize) -> NSAttributedString {
        let palette = Palette(theme: theme)
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(render(block, palette: palette, size: size, last: i == blocks.count - 1))
        }
        return out
    }

    private static func render(_ block: MyzelBlock, palette: Palette, size: CGFloat, last: Bool) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = last ? 0 : 6
        para.lineSpacing = 1.5
        var base = size
        var weight: NSFont.Weight = .regular
        var color = palette.text
        var prefix = ""
        var ground: NSColor?

        let quoteIndent = CGFloat(block.quote) * 14
        para.firstLineHeadIndent = quoteIndent
        para.headIndent = quoteIndent
        if block.quote > 0 { color = palette.dim }

        switch block.kind {
        case .paragraph: break
        case .heading(let level):
            base = size + max(0, CGFloat(3 - level))
            weight = .bold
            para.paragraphSpacingBefore = 2
        case .code:
            ground = palette.codeGround
            color = palette.code
            para.firstLineHeadIndent += 8
            para.headIndent += 8
            para.lineSpacing = 0.5
        case .listItem(let marker, let depth):
            let indent = quoteIndent + CGFloat(depth) * 16
            prefix = marker + "\t"
            para.firstLineHeadIndent = indent
            para.headIndent = indent + 18
            para.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18)]
            para.paragraphSpacing = last ? 0 : 2
        case .tableRow(let header):
            if header { weight = .bold }
            para.paragraphSpacing = last ? 0 : 1
        case .rule:
            return NSAttributedString(string: String(repeating: "─", count: 24),
                                      attributes: [.font: AppFonts.mono(size: size), .foregroundColor: palette.faint, .paragraphStyle: para])
        }

        let text = NSMutableAttributedString()
        func attrs(_ style: MyzelSpan.Style, extra: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            var a: [NSAttributedString.Key: Any] = [
                .font: AppFonts.mono(size: base, weight: style.contains(.strong) ? .bold : weight),
                .foregroundColor: color, .paragraphStyle: para]
            if style.contains(.emphasis) { a[.obliqueness] = 0.14 }
            if style.contains(.strike) { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if style.contains(.code) { a[.foregroundColor] = palette.code; a[.backgroundColor] = palette.codeGround }
            if let ground { a[.backgroundColor] = ground }
            return a.merging(extra) { $1 }
        }
        if block.quote > 0 && prefix.isEmpty { prefix = "▎ " }
        if !prefix.isEmpty { text.append(NSAttributedString(string: prefix, attributes: attrs([], extra: [.foregroundColor: palette.dim]))) }
        for span in block.spans {
            var extra: [NSAttributedString.Key: Any] = [:]
            if let link = span.link {
                extra[.link] = link
                extra[.foregroundColor] = palette.link
                extra[.underlineStyle] = NSUnderlineStyle.single.rawValue
                extra[.toolTip] = link.absoluteString
            } else if span.mention {
                extra[.foregroundColor] = palette.mention
                extra[.font] = AppFonts.mono(size: base, weight: .bold)
            }
            text.append(NSAttributedString(string: span.text, attributes: attrs(span.style, extra: extra)))
        }
        return text
    }

    /// Kopfzeile einer Nachricht: Name fett in Tonfarbe, dahinter Zeit und Herkunft gedimmt.
    static func header(name: String, tone: NSColor, time: String, note: String?, theme: TerminalTheme) -> NSAttributedString {
        let out = NSMutableAttributedString(string: name, attributes: [
            .font: AppFonts.mono(size: 11.5, weight: .bold), .foregroundColor: tone])
        var rest = "  " + time
        if let note { rest += "  · " + note }
        out.append(NSAttributedString(string: rest, attributes: [
            .font: LineStyle.font(11, .regular), .foregroundColor: theme.foreground.withAlphaComponent(LineStyle.text)]))
        return out
    }

    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
