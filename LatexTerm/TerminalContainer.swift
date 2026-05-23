import SwiftUI
import AppKit

/// Wrappt den `TerminalSplitView` (AppKit) für SwiftUI. Die gesamte Pane-/Split-Logik
/// liegt in AppKit, damit die teuren, zustandsbehafteten WKWebView-Overlays beim
/// Splitten nicht von SwiftUI-Re-Renders zerlegt werden.
struct TerminalContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalSplitView {
        TerminalSplitView(frame: .zero)
    }

    func updateNSView(_ nsView: TerminalSplitView, context: Context) {}
}
