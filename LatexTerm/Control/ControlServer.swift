import Foundation

/// Führt ein Steuerkommando aus — implementiert von `TerminalSplitView` (dort, wo
/// die Pane-Liste lebt und `private` bleiben darf). Läuft immer auf dem Main-Thread.
protocol ControlCommandHandler: AnyObject {
    func handleControl(_ request: ControlRequest) -> ControlResponse
}

/// Unix-Socket-Server des Steuerkanals (#28): nimmt JSON-Zeilen-Requests des
/// `latexterm`-CLIs an und reicht sie an die registrierte `TerminalSplitView`.
///
/// Sicherheitsmodell (siehe SECURITY.md): Text-Injection in PTYs ist Command-
/// Execution, deshalb (a) Unix-Socket statt TCP, (b) Socket-Datei 0600 im
/// User-Home, (c) getpeereid-Check — nur Prozesse desselben Users dürfen
/// verbinden. Wer diese Hürde nimmt, führt bereits Code als der User aus.
final class ControlServer {

    static let shared = ControlServer()
    private init() {}

    /// Ziel der Kommandos. Bei mehreren Fenstern gewinnt das zuletzt registrierte
    /// (v1-Vereinfachung; LatexTerm läuft praktisch mit einem Fenster).
    private weak var handler: ControlCommandHandler?

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "latexterm.control-io", qos: .utility)

    /// Startet den Listener beim ersten Aufruf; weitere Aufrufe wechseln nur das Ziel.
    func register(_ handler: ControlCommandHandler) {
        self.handler = handler
        guard listenFD < 0 else { return }
        start()
    }

    private func start() {
        let path = ControlProtocol.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        // Alten Socket wegräumen (Crash-Leiche); LaunchServices dedupliziert die
        // App über die Bundle-ID, eine konkurrierende zweite Instanz gibt es nicht.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = path.withCString { cstr -> Bool in
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
            guard strlen(cstr) <= maxLen else { return false }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: cstr, count: strlen(cstr) + 1)
            }
            return true
        }
        guard ok else { close(fd); return }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, size) == 0
            }
        }
        guard bound, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd); unlink(path); return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
        acceptSource = source
    }

    private func acceptConnection() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }

        // Nur Prozesse desselben Users: alles andere sofort trennen.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            close(client); return
        }

        ioQueue.async { [weak self] in self?.serve(client: client) }
    }

    /// Eine Verbindung = ein Request: bis zum Newline (oder EOF) lesen, auf dem
    /// Main-Thread ausführen, Antwort schreiben, schließen. Blockierendes I/O ist
    /// hier okay — kurzlebige lokale Verbindungen auf einer Utility-Queue.
    private func serve(client: Int32) {
        defer { close(client) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 1_048_576 {
            let n = read(client, &buf, buf.count)
            guard n > 0 else { break }
            data.append(buf, count: n)
            if buf[..<n].contains(UInt8(ascii: "\n")) { break }
        }
        if let nl = data.firstIndex(of: UInt8(ascii: "\n")) { data = data.prefix(upTo: nl) }

        var response: ControlResponse
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: data) {
            response = DispatchQueue.main.sync { [weak self] in
                guard let handler = self?.handler else {
                    return .failure("Kein Terminal-Fenster registriert")
                }
                return handler.handleControl(request)
            }
        } else {
            response = .failure("Request nicht lesbar (JSON-Zeile erwartet)")
        }

        if var out = try? JSONEncoder().encode(response) {
            out.append(UInt8(ascii: "\n"))
            out.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                    guard n > 0 else { break }
                    offset += n
                }
            }
        }
    }
}
