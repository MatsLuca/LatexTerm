import SwiftUI
import AppKit

/// Wrappt den `TerminalSplitView` (AppKit) für SwiftUI. Die gesamte Pane-/Split-Logik
/// liegt in AppKit, damit die teuren, zustandsbehafteten WKWebView-Overlays beim
/// Splitten nicht von SwiftUI-Re-Renders zerlegt werden.
struct TerminalContainer: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> TerminalSplitView {
        let open = openWindow
        WindowTabs.open = { open(id: LatexTermApp.windowGroupID) }
        return TerminalSplitView(frame: .zero)
    }

    func updateNSView(_ nsView: TerminalSplitView, context: Context) {}
}
