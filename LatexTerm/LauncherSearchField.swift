import AppKit

/// Activate the field editor before positioning the caret. makeFirstResponder alone can
/// leave AppKit's select-all-on-entry pending, replacing a prefilled trigger on the next key.
final class LauncherSearchField: NSSearchField {
    func focusForTyping() {
        guard let window else { return }
        window.makeFirstResponder(self)
        selectText(nil)
        if let editor = currentEditor() {
            editor.selectedRange = NSRange(location: editor.string.utf16.count, length: 0)
        }
        // The containing palette is inserted while AppKit is dispatching the opening key.
        // AppKit completes that focus transaction later and selects the prefilled text again.
        // Correct only that untouched initial selection, never text the user has since edited.
        let initial = stringValue
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.currentEditor() as? NSTextView,
                  self.window?.firstResponder === editor, editor.string == initial,
                  !editor.hasMarkedText(),
                  editor.selectedRange() == NSRange(location: 0, length: initial.utf16.count) else { return }
            editor.setSelectedRange(NSRange(location: initial.utf16.count, length: 0))
        }
    }
}
