import SwiftUI
import AppKit
import SwiftTerm
import Combine

struct TerminalContainer: NSViewRepresentable {

    func makeNSView(context: Context) -> LatexTerminalView {
        let settings = FormulaSettings.shared
        let term = LatexTerminalView(frame: .zero)
        term.processDelegate = context.coordinator
        term.nativeForegroundColor = NSColor(red: 230/255.0, green: 225/255.0, blue: 225/255.0, alpha: 1.0)
        term.nativeBackgroundColor = NSColor(red: 23/255.0, green: 20/255.0, blue: 20/255.0, alpha: 1.0)
        term.caretColor = NSColor(red: 232/255.0, green: 94/255.0, blue: 62/255.0, alpha: 1.0)
        term.getTerminal().setCursorStyle(.steadyBlock)
        term.extraLineSpacing = settings.extraLineSpacing  // aus UserDefaults

        let controller = OverlayController(terminal: term)
        context.coordinator.controller = controller
        context.coordinator.terminal = term

        term.onRangeChanged = { [weak controller] in controller?.scheduleRescan() }
        term.onScrolled = { [weak controller] in controller?.scheduleReposition() }

        // Auf Zeilenabstand-Änderungen reagieren
        context.coordinator.settingsObserver = NotificationCenter.default.addObserver(
            forName: FormulaSettings.didChange,
            object: nil,
            queue: .main
        ) { [weak term] _ in
            term?.extraLineSpacing = FormulaSettings.shared.extraLineSpacing
        }

        let shell = Self.userShell()
        let shellIdiom = "-" + (shell as NSString).lastPathComponent
        FileManager.default.changeCurrentDirectoryPath(FileManager.default.homeDirectoryForCurrentUser.path)
        term.startProcess(executable: shell, execName: shellIdiom)
        return term
    }

    func updateNSView(_ nsView: LatexTerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var controller: OverlayController?
        weak var terminal: LatexTerminalView?
        var settingsObserver: NSObjectProtocol?

        deinit {
            if let obs = settingsObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            controller?.scheduleRescan()
        }
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            source.window?.title = title.isEmpty ? "LatexTerm" : title
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            (source as? NSView)?.window?.close()
        }
    }

    private static func userShell() -> String {
        let bufsize = sysconf(_SC_GETPW_R_SIZE_MAX)
        guard bufsize != -1 else { return "/bin/zsh" }
        let buffer = UnsafeMutablePointer<Int8>.allocate(capacity: bufsize)
        defer { buffer.deallocate() }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>? = UnsafeMutablePointer<passwd>.allocate(capacity: 1)
        if getpwuid_r(getuid(), &pwd, buffer, bufsize, &result) != 0 {
            return "/bin/zsh"
        }
        let s = String(cString: pwd.pw_shell)
        return s.isEmpty ? "/bin/zsh" : s
    }
}
