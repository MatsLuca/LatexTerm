import SwiftUI
import AppKit

/// Beschriftung · Farbwähler; bridgt `NSColor` (Stores) ↔ `Color` (SwiftUI) und liefert die
/// Wahl in sRGB zurück, damit gespeicherte und geladene Werte komponentengleich sind.
struct ColorRow: View {
    let title: String
    @Binding var color: NSColor

    var body: some View {
        ColorPicker(title, selection: bridged, supportsOpacity: false)
    }

    private var bridged: Binding<Color> {
        Binding(get: { Color(nsColor: color) },
                set: { color = NSColor($0).usingColorSpace(.sRGB) ?? NSColor($0) })
    }
}
