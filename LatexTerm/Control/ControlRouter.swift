import Foundation

protocol ControlCommandHandler: AnyObject {
    var controlPanes: [PaneInfo] { get }
    var isActiveControlWindow: Bool { get }
    func handleControl(_ request: ControlRequest) -> ControlResponse
    /// Anordnung dieses Fensters samt Stand-Nummer.
    func layoutReport() -> LayoutReport?
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
        if request.cmd == "list-panes" {
            // Mit Aufrufer: die Anordnung seines Fensters gleich mit (Lagebild für Agenten).
            var response = ControlResponse(ok: true, panes: panes)
            if let caller = request.paneID?.uppercased(),
               let window = handlers.first(where: { $0.controlPanes.contains { $0.id.uppercased() == caller } }) {
                response.layout = window.layoutReport()
            }
            return response
        }
        // Kachelarten sind app-weit gleich — jedes Fenster kann antworten, ein Ziel braucht es nicht.
        if request.cmd == "pane-kinds" { return handlers[0].handleControl(request) }
        let selector = request.pane ?? request.paneID
        if request.cmd == "new-pane", selector == nil {
            let target = handlers.first(where: \.isActiveControlWindow) ?? handlers[0]
            return reindex(target.handleControl(request))
        }
        guard let selector, !selector.isEmpty else { return .failure("Keine Ziel-Kachel angegeben") }
        guard let pane = resolve(selector),
              let target = handlers.first(where: { $0.controlPanes.contains { $0.id == pane.id } }) else {
            return .failure("Kachel nicht eindeutig gefunden: „\(selector)“ — `latexterm list-panes` zeigt Index und ID")
        }
        var routed = request
        routed.pane = pane.id
        // layout: die zweite Kachel ebenfalls global auflösen (Index gilt über alle Fenster).
        if let other = request.otherPane {
            guard let second = resolve(other) else {
                return .failure("Kachel nicht eindeutig gefunden: „\(other)“ — `latexterm list-panes` zeigt Index und ID")
            }
            routed.otherPane = second.id
        }
        return reindex(target.handleControl(routed))
    }

    /// Ziffern = globaler Index, sonst eindeutiges UUID-Präfix.
    private func resolve(_ selector: String) -> PaneInfo? {
        let matches: [PaneInfo]
        if selector.allSatisfy(\.isNumber) {
            matches = Int(selector).flatMap { index in panes.first { $0.index == index } }.map { [$0] } ?? []
        } else {
            matches = panes.filter { $0.id.uppercased().hasPrefix(selector.uppercased()) }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func reindex(_ response: ControlResponse) -> ControlResponse {
        var response = response
        if let pane = response.pane, let current = panes.first(where: { $0.id == pane.id }) { response.pane = current }
        return response
    }
}
