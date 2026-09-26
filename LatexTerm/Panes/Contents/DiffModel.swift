import Foundation

/// Datenmodell der Kachel `diff` (26.09.2026): die Ausgabe von `git diff` als Dateien → Abschnitte → Zeilen mit
/// alten/neuen Zeilennummern, dazu die Summen für den Chip („+42 −7“). Rein (Foundation), Test `scripts/test-diff-model.swift`.
nonisolated enum DiffModel {
    enum Status: String, Codable, Equatable {
        case modified, added, deleted, renamed, untracked
    }

    enum Kind: String, Codable, Equatable {
        case context, add, del
        /// „\ No newline at end of file“ und Ähnliches — keine Zeile der Datei.
        case note
    }

    struct Line: Equatable {
        var kind: Kind
        var old: Int?
        var new: Int?
        var text: String
    }

    struct Hunk: Equatable {
        var header: String
        var lines: [Line] = []
    }

    struct File: Equatable {
        var path: String
        var oldPath: String?
        var status: Status = .modified
        var hunks: [Hunk] = []
        var added = 0
        var removed = 0
        var binary = false
        /// Mehr Zeilen als `lineLimit` — gezählt ja, gezeigt nicht.
        var truncated = false
        /// Nur Modus/Umbenennung, kein Inhalt.
        var metaOnly: Bool { hunks.isEmpty && !binary }
    }

    /// Obergrenze gezeigter Zeilen je Datei; die Summen zählen trotzdem alles.
    static let lineLimit = 3000

    /// `git diff --no-color --no-ext-diff -M` (Präfixe a/ und b/) → Dateien.
    static func parse(_ text: String, lineLimit: Int = lineLimit) -> [File] {
        var files: [File] = []
        var current: File?
        var shown = 0
        var oldLine = 0, newLine = 0
        func finish() {
            if let file = current { files.append(file) }
            current = nil
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                finish()
                current = File(path: headerPath(line) ?? "?")
                shown = 0
                continue
            }
            guard var file = current else { continue }
            defer { current = file }
            if file.hunks.isEmpty || line.hasPrefix("@@") {
                // Kopf der Datei (Metadaten) oder neuer Abschnitt.
                if line.hasPrefix("@@") {
                    let (old, new) = hunkStart(line)
                    oldLine = old; newLine = new
                    file.hunks.append(Hunk(header: line))
                    continue
                }
                if line.hasPrefix("new file mode") { file.status = .added }
                else if line.hasPrefix("deleted file mode") { file.status = .deleted }
                else if line.hasPrefix("rename from ") { file.oldPath = unquote(String(line.dropFirst(12))); file.status = .renamed }
                else if line.hasPrefix("rename to ") { file.path = unquote(String(line.dropFirst(10))); file.status = .renamed }
                else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { file.binary = true }
                else if line.hasPrefix("+++ "), let path = sidePath(String(line.dropFirst(4)), prefix: "b/") { file.path = path }
                else if line.hasPrefix("--- "), file.status == .deleted, let path = sidePath(String(line.dropFirst(4)), prefix: "a/") { file.path = path }
                continue
            }
            let kind: Kind
            switch line.first {
            case "+": kind = .add; file.added += 1
            case "-": kind = .del; file.removed += 1
            case " ": kind = .context
            case "\\": kind = .note
            case nil: continue   // Ende der Ausgabe
            default: continue
            }
            guard shown < lineLimit else { file.truncated = true; bump(kind, &oldLine, &newLine); continue }
            shown += 1
            let body = kind == .note ? String(line.dropFirst(2)) : String(line.dropFirst())
            let entry = Line(kind: kind, old: kind == .add || kind == .note ? nil : oldLine,
                             new: kind == .del || kind == .note ? nil : newLine, text: body)
            bump(kind, &oldLine, &newLine)
            file.hunks[file.hunks.count - 1].lines.append(entry)
        }
        finish()
        return files
    }

    private static func bump(_ kind: Kind, _ old: inout Int, _ new: inout Int) {
        switch kind {
        case .context: old += 1; new += 1
        case .add: new += 1
        case .del: old += 1
        case .note: break
        }
    }

    /// „@@ -12,5 +12,7 @@ …“ → (12, 12).
    static func hunkStart(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let token = parts.first(where: { $0.first == prefix && $0.count > 1 }) else { return 1 }
            return Int(token.dropFirst().split(separator: ",").first ?? "") ?? 1
        }
        return (start("-"), start("+"))
    }

    /// Neue Datei, die Git noch nicht kennt: ganz als hinzugefügt (Text), sonst binär.
    static func untracked(path: String, data: Data, lineLimit: Int = lineLimit) -> File {
        var file = File(path: path, status: .untracked)
        if data.prefix(8000).contains(0) || String(data: data, encoding: .utf8) == nil {
            file.binary = true
            return file
        }
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        file.added = lines.count
        guard !lines.isEmpty else { return file }
        var hunk = Hunk(header: "@@ -0,0 +1,\(lines.count) @@")
        for (index, text) in lines.prefix(lineLimit).enumerated() {
            hunk.lines.append(Line(kind: .add, old: nil, new: index + 1, text: text))
        }
        file.truncated = lines.count > lineLimit
        file.hunks = [hunk]
        return file
    }

    static func totals(_ files: [File]) -> (added: Int, removed: Int) {
        files.reduce((0, 0)) { ($0.0 + $1.added, $0.1 + $1.removed) }
    }

    /// „+42 −7“ (typografisches Minus, wie im Plan).
    static func label(added: Int, removed: Int) -> String { "+\(added) −\(removed)" }

    /// Für die Seite: nur Grundtypen, Texte bleiben Daten (die Seite setzt sie per textContent).
    static func payload(_ files: [File]) -> [[String: Any]] {
        files.map { file in
            var entry: [String: Any] = ["path": file.path, "status": file.status.rawValue, "added": file.added,
                                        "removed": file.removed, "binary": file.binary, "truncated": file.truncated]
            if let old = file.oldPath { entry["oldPath"] = old }
            entry["hunks"] = file.hunks.map { hunk -> [String: Any] in
                ["header": hunk.header, "lines": hunk.lines.map { line -> [Any] in
                    [line.kind.rawValue, line.old ?? NSNull(), line.new ?? NSNull(), line.text]
                }]
            }
            return entry
        }
    }

    // MARK: Pfade

    /// „diff --git a/x b/y“ → y (Anhalt, bis `+++`/`rename to` es genauer sagen).
    private static func headerPath(_ line: String) -> String? {
        let rest = String(line.dropFirst("diff --git ".count))
        if rest.hasPrefix("\"") {
            // Gequotet: zweites gequotetes Stück ist b/…
            let pieces = rest.components(separatedBy: "\" \"")
            guard let last = pieces.last else { return nil }
            return sidePath(last.hasPrefix("\"") ? last : "\"" + last, prefix: "b/")
        }
        guard let range = rest.range(of: " b/", options: .backwards) else { return nil }
        return String(rest[range.upperBound...])
    }

    /// „b/pfad“ bzw. „"b/pf\"ad"“ → pfad; „/dev/null“ → nil.
    private static func sidePath(_ raw: String, prefix: String) -> String? {
        let text = unquote(raw.trimmingCharacters(in: .whitespaces))
        guard text != "/dev/null" else { return nil }
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// Git quotet Pfade mit Sonderzeichen: "…" mit \" \\ \t \n und oktalen Bytes.
    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        var bytes: [UInt8] = []
        var chars = Array(raw.dropFirst().dropLast().utf8)[...]
        while let byte = chars.popFirst() {
            guard byte == UInt8(ascii: "\\"), let next = chars.popFirst() else { bytes.append(byte); continue }
            switch next {
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = chars.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit) else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                    chars.removeFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
