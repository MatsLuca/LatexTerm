import AppKit

/// Baut aus einem Schnappschuss einer gerenderten Formel (transparenter Hintergrund,
/// Glyphen in Formelfarbe) ein teilbares "Chip"-Bild: dunkler, runder Hintergrund mit
/// Padding – und legt es als PNG in die Zwischenablage.
///
/// Bewusst KEIN eigener Offscreen-WKWebView: deren `takeSnapshot` liefert leer, solange
/// die View nicht wirklich on-screen gepaintet wurde. Stattdessen snapshottet der Aufrufer
/// die ohnehin sichtbare Vorschau-WebView; hier wird nur noch komponiert (volle Retina-
/// Auflösung über die Pixelgröße der Quelle).
enum FormulaImageRenderer {

    private static let pad: CGFloat = 24          // Rand zwischen Formel und Chip-Kante
    private static let corner: CGFloat = 14

    /// Komponiert das Chip-Bild. `formula` ist der WebView-Snapshot (transparent + fg-farben).
    static func makeChip(from formula: NSImage, background: NSColor) -> NSImage? {
        let logicalW = formula.size.width
        let logicalH = formula.size.height
        guard logicalW > 0, logicalH > 0,
              let tiff = formula.tiffRepresentation,
              let src = NSBitmapImageRep(data: tiff) else { return nil }

        // Retina-Faktor der Quelle übernehmen, damit der Chip scharf bleibt.
        let scale = max(1, CGFloat(src.pixelsWide) / logicalW)
        let outW = logicalW + 2 * pad
        let outH = logicalH + 2 * pad
        let pxW = Int((outW * scale).rounded())
        let pxH = Int((outH * scale).rounded())

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: outW, height: outH)   // logische Größe → Kontext skaliert auf Pixel

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        // Runder dunkler Hintergrund.
        let bgRect = NSRect(x: 0, y: 0, width: outW, height: outH)
        let path = NSBezierPath(roundedRect: bgRect, xRadius: corner, yRadius: corner)
        background.setFill()
        path.fill()

        // Formel zentriert einzeichnen.
        let drawRect = NSRect(x: pad, y: pad, width: logicalW, height: logicalH)
        formula.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: outW, height: outH))
        out.addRepresentation(rep)
        return out
    }

    /// Legt ein NSImage als PNG (+ TIFF) in die allgemeine Zwischenablage.
    @discardableResult
    static func copyToPasteboard(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)
        return pb.writeObjects([item])
    }
}
