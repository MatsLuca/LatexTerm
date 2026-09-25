import Foundation

/// Eingabe der Myzel-Kachel, reine Logik (Foundation-only, getestet in scripts/test-myzel-compose.swift):
/// Anhänge prüfen, @-Vervollständigung, Nachrichtenkörper.
enum MyzelCompose {
    /// Grenzen des Servers (PROTOKOLL §7): 20 MB je Datei, 5 je Nachricht.
    static let maxBytes: Int64 = 20 * 1024 * 1024
    static let maxFiles = 5

    /// Typen wie `TYPEN` der Web-Seite; alles andere nimmt der Server nicht an.
    static let types: [String: String] = ["md": "text/markdown", "markdown": "text/markdown", "txt": "text/plain",
                                          "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
                                          "webp": "image/webp", "pdf": "application/pdf"]

    static func mime(forFileName name: String) -> String? {
        types[(name as NSString).pathExtension.lowercased()]
    }

    /// Grund, warum diese Datei nicht mitgehen kann; nil = geht.
    static func problem(name: String, bytes: Int64, alreadyAttached: Int) -> String? {
        if alreadyAttached >= maxFiles { return "höchstens \(maxFiles) Anhänge je Nachricht" }
        guard mime(forFileName: name) != nil else { return "\(name): nur PNG, JPEG, WebP, PDF, TXT, MD" }
        if bytes > maxBytes { return "\(name): größer als 20 MB" }
        if bytes == 0 { return "\(name): leer" }
        return nil
    }

    /// `@teil` direkt vor dem Cursor (UTF-16-Offset wie NSTextView): Bereich des ganzen Worts samt `@` und der Teil
    /// ohne `@`. nil, wenn davor kein angefangenes @-Wort steht.
    static func mentionPrefix(in text: String, cursor: Int) -> (range: NSRange, partial: String)? {
        let ns = text as NSString
        guard cursor <= ns.length else { return nil }
        var start = cursor
        while start > 0 {
            let c = ns.character(at: start - 1)
            guard let scalar = Unicode.Scalar(c), CharacterSet.alphanumerics.contains(scalar) || c == 0x2D || c == 0x5F else { break }
            start -= 1
        }
        guard start > 0, ns.character(at: start - 1) == 0x40 else { return nil }   // "@"
        let at = start - 1
        if at > 0, let before = Unicode.Scalar(ns.character(at: at - 1)),
           CharacterSet.alphanumerics.contains(before) || before == "@" || before == "_" {
            return nil   // mail@x, @@
        }
        return (NSRange(location: at, length: cursor - at), ns.substring(with: NSRange(location: start, length: cursor - start)))
    }

    /// Passende Namen: Anfang zuerst, dann enthalten; ohne sich selbst.
    static func completions(_ partial: String, among ids: [String], excluding me: String?) -> [String] {
        let p = partial.lowercased()
        let pool = ids.filter { $0 != me }
        let starts = pool.filter { $0.lowercased().hasPrefix(p) }
        let contains = pool.filter { !$0.lowercased().hasPrefix(p) && $0.lowercased().contains(p) }
        return starts.sorted() + contains.sorted()
    }

    /// Körper für `POST /nachricht` — leere Felder weg (der Server kennt keine Extra-Schlüssel).
    static func messageBody(text: String, replyTo: String?, attachments: [String]) -> [String: Any] {
        var body: [String: Any] = ["text": text]
        if let replyTo { body["antwort_auf"] = replyTo }
        if !attachments.isEmpty { body["anhaenge"] = attachments }
        return body
    }

    /// Ist hier etwas zu senden? (Text ohne Leerraum oder mindestens ein Anhang.)
    static func canSend(text: String, attachments: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachments > 0
    }
}
