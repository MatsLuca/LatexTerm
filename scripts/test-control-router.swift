import Foundation

final class WindowFixture: ControlCommandHandler {
    var controlPanes: [PaneInfo]
    var isActiveControlWindow: Bool
    var received: [ControlRequest] = []
    init(_ ids: [String], active: Bool = false) {
        controlPanes = ids.enumerated().map { i, id in
            PaneInfo(id: id, index: i + 1, cwd: "/project", focused: false, zoomed: false, state: "none")
        }
        isActiveControlWindow = active
    }
    func handleControl(_ request: ControlRequest) -> ControlResponse {
        received.append(request)
        return ControlResponse(ok: true, pane: controlPanes.first { $0.id == request.pane })
    }
}

@main
struct RouterTests {
    static func main() throws {
        let router = ControlRouter()
        assert(!router.route(ControlRequest(cmd: "list-panes")).ok)
        let first = WindowFixture(["AAAA-1", "AAAA-2"])
        var second: WindowFixture? = WindowFixture(["BBBB-1"], active: true)
        router.register(first); router.register(second!)
        router.register(first)
        assert(router.panes.map(\.index) == [1, 2, 3])
        assert(router.route(ControlRequest(cmd: "list-panes")).panes?.count == 3)
        assert(router.route(ControlRequest(cmd: "focus", pane: "3")).ok)
        assert(second!.received.last?.pane == "BBBB-1")
        assert(router.route(ControlRequest(cmd: "focus", pane: "aaaa-2")).pane?.index == 2)
        assert(first.received.last?.pane == "AAAA-2")
        let before = first.received.count + second!.received.count
        for bad in ["AAAA", "0", "4", "", "ZZZZ", "99999999999999999999999999"] {
            assert(!router.route(ControlRequest(cmd: "send", pane: bad, text: "do not send")).ok)
        }
        assert(first.received.count + second!.received.count == before)
        assert(router.route(ControlRequest(cmd: "status", paneID: "AAAA-1", text: "ready")).ok)
        assert(first.received.last?.pane == "AAAA-1")
        assert(router.route(ControlRequest(cmd: "new-pane")).ok)
        assert(second!.received.last?.cmd == "new-pane")
        assert(router.route(ControlRequest(cmd: "new-pane", paneID: "AAAA-1")).ok)
        assert(first.received.last?.cmd == "new-pane")
        second = nil
        assert(router.panes.count == 2)
        assert(!router.route(ControlRequest(cmd: "focus", pane: "BBBB-1")).ok)
        let old = Data(#"{"ok":true,"panes":[{"id":"a","index":1,"cwd":"/project","focused":false,"zoomed":false,"state":"none"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: old)
        assert(decoded.capabilities == nil && decoded.panes?.first?.agent == nil)
        print("24 multi-window routing / compatibility cases passed")
    }
}
