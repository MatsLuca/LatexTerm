import SwiftUI

@main
struct LatexTermApp: App {
    var body: some Scene {
        WindowGroup("LatexTerm") {
            TerminalContainer()
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}
