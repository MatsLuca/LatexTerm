import AppKit

// Minimal presentation dependencies; the palette and search field themselves are production code.
enum AppFonts {
    static func mono(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }
}
final class ThemeStore {
    static let shared = ThemeStore()
    static let didChange = Notification.Name("ThemeStoreDidChange")
    let theme = TerminalTheme()
    let accentColor = NSColor.controlAccentColor
}
struct TerminalTheme {
    let background = NSColor.windowBackgroundColor, foreground = NSColor.labelColor
    let dim = NSColor.secondaryLabelColor, faint = NSColor.tertiaryLabelColor
    let red = NSColor.systemRed, green = NSColor.systemGreen, yellow = NSColor.systemYellow
    let blue = NSColor.systemBlue, violet = NSColor.systemPurple, cyan = NSColor.systemTeal
    let roles: [String: NSColor] = [:]
}
extension NSColor {
    func lightened(by amount: CGFloat) -> NSColor { blended(withFraction: amount, of: .white) ?? self }
}
enum HomePaneView {
    static let cyan = NSColor.systemTeal, orange = NSColor.systemOrange
    static let yellow = NSColor.systemYellow, green = NSColor.systemGreen
}
struct LoaderError: Error { var message: String }

final class TriggerView: NSView {
    var palette: LauncherPalette?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        let palette = LauncherPalette(frame: bounds, catalog: .init(home: [], searchable: []), query: event.characters ?? "")
        self.palette = palette
        addSubview(palette)
        palette.focus()
    }
}

@main
struct PaletteInputTests {
    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let trigger = TriggerView(frame: window.contentView!.bounds)
        window.contentView!.addSubview(trigger)
        var failures = 0
        for (initial, rest, expected) in [("m", "oin", "moin"), ("/", "frage", "/frage")] {
            trigger.palette?.removeFromSuperview(); trigger.palette = nil
            window.makeFirstResponder(trigger)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                        windowNumber: window.windowNumber, context: nil, characters: initial,
                                        charactersIgnoringModifiers: initial, isARepeat: false, keyCode: 46)!
            window.sendEvent(event)
            window.contentView!.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
            guard let editor = window.firstResponder as? NSTextView else { fatalError("No active editor") }
            print("after opening: \(editor.string.debugDescription), selection \(editor.selectedRange())")
            for char in rest {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: String(char),
                                            charactersIgnoringModifiers: String(char), isARepeat: false, keyCode: 31)!
                window.sendEvent(event)
            }
            if editor.string != expected { print("FAIL: expected \(expected), got \(editor.string)"); failures += 1 }
        }
        if failures > 0 { exit(1) }
        print("2 full palette key-event paths passed")
    }
}
