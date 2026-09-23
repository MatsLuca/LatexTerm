import SwiftUI
import AppKit

/// Wrappt die `BoardHostView` (AppKit: Bretter mit je einem `TerminalSplitView`) für SwiftUI. Die gesamte
/// Pane-/Split-Logik liegt in AppKit, damit die teuren, zustandsbehafteten WKWebView-Overlays beim
/// Splitten nicht von SwiftUI-Re-Renders zerlegt werden.
struct TerminalContainer: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> BoardHostView {
        let open = openWindow
        BoardHostView.openWindow = { open(id: LatexTermApp.windowGroupID) }
        return BoardHostView()
    }

    func updateNSView(_ nsView: BoardHostView, context: Context) {}
}
