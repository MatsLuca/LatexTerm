import AppKit

/// Tabs (22.09.2026): jedes LatexTerm-Fenster ist ein Tab der nativen macOS-Tab-Leiste, die
/// Leiste ist von Anfang an sichtbar (auch mit einem Tab). Ein Tab = ein `TerminalSplitView` mit
/// eigenen Kacheln; ⌥⌘R/⌥⌘Q merken Tab-Gruppen und Reihenfolge (`SessionSnapshot.Window.tabGroup`).
/// Neue Tabs: „+“ in der Leiste, Menü „Kachel → Neuer Tab“ (⇧⌘T) — ⌘T bleibt die Terminal-Kachel.
enum WindowTabs {
    static let identifier = "LatexTerm"

    /// Öffnet ein neues Fenster der WindowGroup (von `TerminalContainer` aus der SwiftUI-Umgebung
    /// gesetzt). Zum Tab wird es erst in `prepare` — von selbst hängt SwiftUI es nicht an die Leiste
    /// (Live-Befund 22.09.: nach ⌥⌘R standen alle Tabs in getrennten Fenstern).
    static var open: (() -> Void)?

    /// `anchor` = Fenster, neben das der neue Tab gehört; nil = steht allein (erstes Fenster, eigene
    /// Leiste beim Wiederherstellen).
    static func prepare(_ window: NSWindow, anchor: NSWindow?) {
        window.tabbingIdentifier = identifier
        window.tabbingMode = .preferred
        DispatchQueue.main.async {
            if let anchor, anchor !== window, anchor.isVisible,
               !(anchor.tabGroup?.windows.contains(window) ?? false) {
                anchor.addTabbedWindow(window, ordered: .above)
                window.makeKeyAndOrderFront(nil)
            }
            // Nur ein allein stehendes Fenster bekommt die Leiste — hat Mats sie in einer Gruppe
            // ausgeblendet, bleibt sie das auch für neue Tabs dieser Gruppe.
            guard let group = window.tabGroup, group.windows.count <= 1, !group.isTabBarVisible else { return }
            window.toggleTabBar(nil)
        }
    }

    /// Anker für einen neuen Tab („+“, ⇧⌘T): das vorderste andere LatexTerm-Fenster.
    static func frontmost(excluding window: NSWindow) -> NSWindow? {
        NSApp.orderedWindows.first { $0 !== window && $0.tabbingIdentifier == identifier && $0.isVisible }
    }

    /// 1-basierte Position des Fensters in seiner Tab-Leiste; nil, solange es allein steht.
    static func position(of window: NSWindow?) -> Int? {
        guard let window, let tabs = window.tabGroup?.windows, tabs.count > 1,
              let index = tabs.firstIndex(of: window) else { return nil }
        return index + 1
    }
}
