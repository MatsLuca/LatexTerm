import Foundation

/// Ein Roundtrip über den Steuerkanal: JSON-Zeile hin, JSON-Zeile zurück. Wirft statt
/// `exit` — das CLI macht daraus Exit-Code 3, der MCP-Server eine Werkzeug-Fehlermeldung.
enum ControlClient {
    struct Unreachable: Error, CustomStringConvertible {
        let description: String
    }

    static func roundtrip(_ request: ControlRequest,
                          socketPath path: String = ControlProtocol.socketPath) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Unreachable(description: "Socket-Fehler: \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits = path.withCString { cstr -> Bool in
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
            guard strlen(cstr) <= maxLen else { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: cstr, count: strlen(cstr) + 1)
            }
            return true
        }
        guard fits else { throw Unreachable(description: "Socket-Pfad zu lang: \(path)") }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, size) == 0
            }
        }
        guard connected else {
            throw Unreachable(description: "LatexTerm nicht erreichbar (\(path)) — läuft die App?")
        }

        var out = try JSONEncoder().encode(request)
        out.append(UInt8(ascii: "\n"))
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 1_048_576 {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            data.append(buf, count: n)
            if buf[..<n].contains(UInt8(ascii: "\n")) { break }
        }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: data) else {
            throw Unreachable(description: "Antwort der App nicht lesbar")
        }
        return response
    }
}
