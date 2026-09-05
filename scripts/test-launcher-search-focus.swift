import AppKit

@main
struct LauncherSearchFocusTests {
    static func main() {
        _ = NSApplication.shared
        // No orderFront/run/activation: an off-screen window, never the running LatexTerm host.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let search = LauncherSearchField(frame: NSRect(x: 20, y: 100, width: 400, height: 30))
        window.contentView?.addSubview(search)
        for (initial, next, expected) in [("m", "oin", "moin"), ("/", "frage", "/frage"),
                                          ("", "moin", "moin"), ("👋", " hallo", "👋 hallo")] {
            window.makeFirstResponder(nil)
            search.stringValue = initial
            search.focusForTyping()
            guard let editor = search.currentEditor() as? NSTextView else { fatalError("No field editor") }
            precondition(editor.selectedRange() == NSRange(location: initial.utf16.count, length: 0))
            editor.insertText(next, replacementRange: NSRange(location: NSNotFound, length: 0))
            precondition(editor.string == expected, "Expected \(expected), got \(editor.string)")
        }
        print("4 AppKit first-character / slash / Unicode focus cases passed")
    }
}
