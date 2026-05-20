import SwiftUI
import AppKit
import SwiftTerm

struct TerminalContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> LatexTerminalView {
        let term = LatexTerminalView(frame: .zero)
        term.processDelegate = context.coordinator
        term.nativeForegroundColor = NSColor(white: 0.86, alpha: 1)
        term.nativeBackgroundColor = NSColor(red: 0.157, green: 0.173, blue: 0.204, alpha: 1)
        term.caretColor = .systemGreen
        term.getTerminal().setCursorStyle(.steadyBlock)
        term.extraLineSpacing = 8

        let controller = OverlayController(terminal: term)
        context.coordinator.controller = controller
        term.onRangeChanged = { [weak controller] in controller?.scheduleRescan() }

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
