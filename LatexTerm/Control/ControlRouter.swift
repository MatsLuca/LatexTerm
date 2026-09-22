import Foundation

protocol ControlCommandHandler: AnyObject {
    var controlPanes: [PaneInfo] { get }
    var isActiveControlWindow: Bool { get }
    func handleControl(_ request: ControlRequest) -> ControlResponse
}

/// One directory for all windows. Indexes and UUID prefixes have exactly the same meaning
/// in list-panes and every command; ambiguous prefixes never select an arbitrary terminal.
final class ControlRouter {
    private struct Entry { weak var handler: ControlCommandHandler? }
    private var entries: [Entry] = []

    func register(_ handler: ControlCommandHandler) {
        entries.removeAll { $0.handler == nil }
        if !entries.contains(where: { $0.handler === handler }) { entries.append(Entry(handler: handler)) }
    }

    private var handlers: [ControlCommandHandler] { entries.compactMap(\.handler) }
    var panes: [PaneInfo] {
        handlers.flatMap(\.controlPanes).enumerated().map { index, pane in
            var pane = pane; pane.index = index + 1; return pane
        }
    }

    func route(_ request: ControlRequest) -> ControlResponse {
        let handlers = self.handlers
        guard !handlers.isEmpty else { return .failure("Kein Terminal-Fenster registriert") }
        if request.cmd == "list-panes" { return ControlResponse(ok: true, panes: panes) }
        let selector = request.pane ?? request.paneID
        if request.cmd == "new-pane", selector == nil {
            let target = handlers.first(where: \.isActiveControlWindow) ?? handlers[0]
            return reindex(target.handleControl(request))
        }
        guard let selector, !selector.isEmpty else { return .failure("Keine Ziel-Kachel angegeben") }
        let matches: [PaneInfo]
        if selector.allSatisfy(\.isNumber) {
            matches = Int(selector).flatMap { index in panes.first { $0.index == index } }.map { [$0] } ?? []
        } else {
            matches = panes.filter { $0.id.uppercased().hasPrefix(selector.uppercased()) }
        }
        guard matches.count == 1, let pane = matches.first,
              let target = handlers.first(where: { $0.controlPanes.contains { $0.id == pane.id } }) else {
            return .failure("Kachel nicht eindeutig gefunden: „\(selector)“ — `latexterm list-panes` zeigt Index und ID")
        }
        var routed = request
        routed.pane = pane.id
        return reindex(target.handleControl(routed))
    }

    private func reindex(_ response: ControlResponse) -> ControlResponse {
        var response = response
        if let pane = response.pane, let current = panes.first(where: { $0.id == pane.id }) { response.pane = current }
        return response
    }
}
