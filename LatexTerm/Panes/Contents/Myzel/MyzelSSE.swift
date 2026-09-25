import Foundation

/// Server-Sent Events, so wie der Myzel-Server sie schickt: `id: <id>` + `data: <json>` + Leerzeile, dazwischen
/// `: puls` (Kommentar, alle 25 s). Keine Ereignisnamen. Nimmt Bytes in beliebigen Stücken (auch mitten in einem
/// UTF-8-Zeichen oder vor `\n` getrenntem `\r`) und gibt fertige Frames heraus. Foundation-only, getestet in
/// scripts/test-myzel-sse.swift.
struct MyzelSSEParser {
    struct Frame: Equatable {
        var id: String?
        var data: String
    }

    private var pending = Data()
    private var dataLines: [String] = []
    private var frameID: String?
    /// Zeitpunkt des letzten Lebenszeichens (auch `: puls`) — für die Hänger-Erkennung.
    private(set) var lastActivity = Date()

    mutating func feed(_ bytes: Data) -> [Frame] {
        guard !bytes.isEmpty else { return [] }
        lastActivity = Date()
        pending.append(bytes)
        var frames: [Frame] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            var lineData = pending[pending.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            pending.removeSubrange(pending.startIndex...newline)
            if let frame = line(String(decoding: lineData, as: UTF8.self)) { frames.append(frame) }
        }
        return frames
    }

    /// Eine Zeile verarbeiten; Leerzeile schließt den Frame ab.
    private mutating func line(_ line: String) -> Frame? {
        if line.isEmpty {
            defer { dataLines = []; frameID = nil }
            guard !dataLines.isEmpty else { return nil }
            return Frame(id: frameID, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "id": frameID = String(value)
        default: break   // event, retry: schickt der Server nicht
        }
        return nil
    }
}

/// Wie lange bis zum nächsten Verbindungsversuch: 2 s wie die Web-Seite, danach verdoppelt bis 30 s.
enum MyzelBackoff {
    static func delay(attempt: Int) -> TimeInterval {
        min(30, 2 * pow(2, Double(max(0, attempt - 1))))
    }
}
