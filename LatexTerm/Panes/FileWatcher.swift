import Foundation

/// Beobachtet EINE Datei für Kacheln, die sie zeigen (preview, web), und meldet, wenn sie sich
/// geändert hat und wieder ruhig ist. Polling per `stat` statt kqueue: übersteht atomares Ersetzen
/// (Editoren, latexmk, matplotlib schreiben eine neue Datei und benennen um), Löschen und
/// Neuanlegen, ohne Deskriptoren neu zu binden — vier `stat` pro Sekunde kosten nichts.
/// Gemeldet wird erst, wenn Größe, Zeitstempel und Inode einen Takt lang stillstehen: ein halb
/// geschriebenes PDF lädt so gar nicht erst.
final class FileWatcher {
    enum Event { case changed, missing }

    private struct Signature: Equatable {
        let size: Int64, mtime: Int64, inode: UInt64
    }

    let url: URL
    private let onEvent: (Event) -> Void
    private var timer: Timer?
    /// Stand, den die Kachel gerade zeigt (nil = nichts oder Datei fehlte).
    private var shown: Signature?
    /// Neuer Stand, der noch einen Takt Ruhe braucht.
    private var pending: Signature?
    private var missingReported = false

    /// Der Stand beim Anlegen gilt als gezeigt — der Aufrufer lädt direkt danach selbst.
    init(url: URL, interval: TimeInterval = 0.25, onEvent: @escaping (Event) -> Void) {
        self.url = url
        self.onEvent = onEvent
        shown = Self.signature(url.path)
        missingReported = shown == nil
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Laden ist trotz Ruhe gescheitert (Datei unvollständig): denselben Stand beim nächsten
    /// ruhigen Takt noch einmal melden.
    func retry() {
        shown = nil
    }

    private func tick() {
        guard let now = Self.signature(url.path) else {
            pending = nil
            shown = nil
            if !missingReported {
                missingReported = true
                onEvent(.missing)
            }
            return
        }
        guard now != shown else {
            pending = nil
            return
        }
        guard now == pending else {
            pending = now
            return
        }
        pending = nil
        shown = now
        missingReported = false
        onEvent(.changed)
    }

    private static func signature(_ path: String) -> Signature? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return Signature(size: Int64(info.st_size), mtime: mtime, inode: UInt64(info.st_ino))
    }
}
