import AppKit
import PDFKit

/// Eine Stelle, die der Nutzer in der Vorschau markiert hat (Textauswahl oder ⌥-Rahmen) — für die Übergabe
/// an eine Agenten-Kachel. PDF-Rechtecke in Seitenkoordinaten (Ursprung unten links), Bild-Rechtecke in
/// Bildpunkten der Anzeige (Ursprung oben links).
nonisolated struct PreviewMark {
    enum Kind { case text, region }
    var kind: Kind
    /// 0-basierte PDF-Seite (Bild: 0).
    var page: Int
    var rect: NSRect
    /// Zeilen einer Textauswahl (Hervorhebung), sonst leer.
    var lines: [NSRect] = []
    /// Markierter Text bzw. Text im Rahmen.
    var text: String = ""
    var note: String = ""
    /// Quelltext-Stelle per SyncTeX („main.tex:235“ bzw. „:235–241“), wenn es eine gibt.
    var source: SyncTeX.Span?
}

/// SyncTeX über das CLI aus TeX Live: PDF-Stelle ↔ Quelltext-Zeile. Braucht `<stamm>.synctex.gz` neben dem PDF
/// (latexmk/pdflatex mit `-synctex=1`). Koordinaten wie SyncTeX sie will: Punkte, Ursprung oben links.
nonisolated enum SyncTeX {
    struct Location: Equatable {
        var file: String
        var line: Int
    }

    struct Span {
        var file: String
        var first: Int
        var last: Int

        /// „main.tex:235“ bzw. „main.tex:235–241“ (Pfad relativ zu `base`, sonst mit ~).
        func label(relativeTo base: URL?) -> String {
            var path = (file as NSString).abbreviatingWithTildeInPath
            if let base, file.hasPrefix(base.path + "/") { path = String(file.dropFirst(base.path.count + 1)) }
            return first == last ? "\(path):\(first)" : "\(path):\(first)–\(last)"
        }
    }

    struct Box {
        /// 1-basiert.
        var page: Int
        /// Punkte, Ursprung oben links.
        var rect: NSRect
    }

    static let binary: String? = {
        let candidates = ["/Library/TeX/texbin/synctex", "/usr/local/texlive/bin/synctex", "/opt/homebrew/bin/synctex", "/usr/local/bin/synctex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Liegt zum PDF eine SyncTeX-Datei (und das Werkzeug)?
    static func available(for pdf: URL) -> Bool {
        guard binary != nil else { return false }
        let stem = pdf.deletingPathExtension().path
        return FileManager.default.fileExists(atPath: stem + ".synctex.gz") || FileManager.default.fileExists(atPath: stem + ".synctex")
    }

    /// PDF → Quelle. `page` 1-basiert, `x`/`y` in Punkten von oben links.
    static func edit(pdf: URL, page: Int, x: CGFloat, y: CGFloat) -> Location? {
        guard let out = run(["edit", "-o", "\(page):\(Double(x)):\(Double(y)):\(pdf.path)"], in: pdf.deletingLastPathComponent()) else { return nil }
        var file: String?, line: Int?
        for row in out.split(separator: "\n") {
            if row.hasPrefix("Input:") { file = String(row.dropFirst(6)) }
            if row.hasPrefix("Line:") { line = Int(row.dropFirst(5)) }
        }
        guard var file, let line, line > 0 else { return nil }
        if !file.hasPrefix("/") { file = pdf.deletingLastPathComponent().appendingPathComponent(file).standardizedFileURL.path }
        return Location(file: file, line: line)
    }

    /// Quelltext-Spanne eines Rechtecks: oben und unten nachschlagen (gleiche Datei → Zeilenbereich).
    static func span(pdf: URL, page: Int, top: NSRect) -> Span? {
        let upper = edit(pdf: pdf, page: page, x: top.minX + min(20, top.width / 2), y: top.minY + min(4, top.height / 2))
        let lower = edit(pdf: pdf, page: page, x: top.maxX - min(20, top.width / 2), y: top.maxY - min(4, top.height / 2))
        guard let first = upper ?? lower else { return nil }
        guard let lower, lower.file == first.file else { return Span(file: first.file, first: first.line, last: first.line) }
        return Span(file: first.file, first: min(first.line, lower.line), last: max(first.line, lower.line))
    }

    /// Quelle → PDF: alle Kästen der Zeile.
    static func view(pdf: URL, source: String, line: Int) -> [Box] {
        guard let out = run(["view", "-i", "\(line):0:\(source)", "-o", pdf.path], in: pdf.deletingLastPathComponent()) else { return [] }
        var boxes: [Box] = []
        var page: Int?, h: Double?, v: Double?, w: Double?, height: Double?
        func flush() {
            if let page, let h, let v, let w, let height, w > 0 {
                boxes.append(Box(page: page, rect: NSRect(x: h, y: v - height, width: w, height: max(height, 8))))
            }
            h = nil; v = nil; w = nil; height = nil
        }
        for row in out.split(separator: "\n") {
            let parts = row.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Page": flush(); page = Int(parts[1])
            case "h": h = Double(parts[1])
            case "v": v = Double(parts[1])
            case "W": w = Double(parts[1])
            case "H": height = Double(parts[1])
            default: break
            }
        }
        flush()
        return boxes
    }

    private static func run(_ arguments: [String], in directory: URL) -> String? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + 3
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if done.wait(timeout: deadline) == .timedOut { process.terminate() }
        return String(data: data, encoding: .utf8)
    }
}

/// Bilder aus PDF-Seiten für Übergabe und `look`.
enum PreviewRender {
    /// Ausschnitt einer Seite (Seitenkoordinaten) als PNG, weißer Grund, `scale` Pixel je Punkt.
    static func crop(_ page: PDFPage, rect: NSRect, scale: CGFloat = 3) -> Data? {
        let box = page.bounds(for: .cropBox)
        let area = rect.intersection(box)
        guard area.width > 1, area.height > 1 else { return nil }
        let width = Int(area.width * scale), height = Int(area.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -(area.minX - box.minX), y: -(area.minY - box.minY))
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Ganze Seite, längste Kante `maxPixels`.
    static func page(_ page: PDFPage, maxPixels: CGFloat = 1600) -> Data? {
        let box = page.bounds(for: .cropBox)
        let scale = maxPixels / max(box.width, box.height)
        return crop(page, rect: box, scale: scale)
    }

    /// Bildausschnitt (Anzeige-Punkte, oben links) als PNG in Originalauflösung, höchstens 2400 px.
    static func crop(_ image: NSImage, pointRect: NSRect, pointSize: NSSize) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), pointSize.width > 0 else { return nil }
        let sx = CGFloat(cg.width) / pointSize.width, sy = CGFloat(cg.height) / pointSize.height
        let pixelRect = CGRect(x: pointRect.minX * sx, y: pointRect.minY * sy, width: pointRect.width * sx, height: pointRect.height * sy)
            .integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard pixelRect.width > 1, pixelRect.height > 1, let part = cg.cropping(to: pixelRect) else { return nil }
        return scaled(part, maxPixels: 2400)
    }

    static func scaled(_ cg: CGImage, maxPixels: CGFloat) -> Data? {
        let factor = min(1, maxPixels / CGFloat(max(cg.width, cg.height)))
        guard factor < 1 else { return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
        let width = Int(CGFloat(cg.width) * factor), height = Int(CGFloat(cg.height) * factor)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .png, properties: [:])
    }

    /// Schnappschuss einer View (QuickLook-Dokumente).
    static func snapshot(_ view: NSView) -> Data? {
        guard view.bounds.width > 1, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Beobachtet einen Ordner (Ordner-Modus der Vorschau): meldet, wenn sich die Liste der zeigbaren Dateien ändert.
/// Polling wie `FileWatcher` — robust gegen atomares Schreiben, Syncthing, iCloud.
final class FolderWatcher {
    let url: URL
    private var timer: Timer?
    private var last: [String] = []
    private let onChange: ([URL]) -> Void

    init(url: URL, onChange: @escaping ([URL]) -> Void) {
        self.url = url
        self.onChange = onChange
        last = Self.signature(Self.items(in: url))
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let items = Self.items(in: url)
        let signature = Self.signature(items)
        guard signature != last else { return }
        last = signature
        onChange(items)
    }

    /// PDFs und Bilder im Ordner (nicht rekursiv, ohne versteckte), neueste zuerst.
    static func items(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let shown = urls.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let type = PreviewContent.fileType(url) else { return false }
            return type == .pdf || type == .image
        }
        func date(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return shown.map { ($0, date($0)) }.sorted { $0.1 > $1.1 }.map { $0.0.standardizedFileURL }
    }

    private static func signature(_ items: [URL]) -> [String] {
        items.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return "\(url.lastPathComponent)|\(date)"
        }
    }
}
