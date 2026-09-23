import Foundation

@main
struct BoardTests {
    static func main() {
        var cases = 0
        func check(_ ok: Bool, _ what: String) { precondition(ok, what); cases += 1 }

        var list = BoardList<String>()
        list.add("a", activate: false)
        check(list.active == "a", "first board becomes active")
        list.add("b", activate: true)
        list.add("c", activate: false)
        check(list.order == ["a", "b", "c"] && list.active == "b", "new board right of the active one")
        list.activate("a"); list.add("d", activate: true)
        check(list.order == ["a", "d", "b", "c"] && list.active == "d", "insert after active, not at the end")
        check(list.neighbor(1) == "b" && list.neighbor(-1) == "a", "neighbors")
        list.activate("c")
        check(list.neighbor(1) == "a", "wraps around")
        list.remove("c")
        check(list.active == "b", "last removed → left neighbor")
        list.activate("d"); list.remove("d")
        check(list.active == "b", "removed → right neighbor")
        list.remove("a")
        check(list.order == ["b"] && list.active == "b", "removing inactive keeps active")
        check(list.neighbor(1) == nil, "single board has no neighbor")
        list.remove("b")
        check(list.active == nil && list.count == 0, "empty")
        var moving = BoardList<Int>()
        for i in 1...4 { moving.add(i, activate: true) }
        moving.move(1, to: 3)
        check(moving.order == [2, 3, 4, 1], "move to end")
        moving.move(1, to: 0)
        check(moving.order == [1, 2, 3, 4] && moving.position(of: 3) == 3, "move to front, position")
        check(moving.active == 4, "move keeps active")
        moving.add(2, activate: true)
        check(moving.order.count == 4, "no duplicates")

        let home = "/Users/x"
        check(BoardName.automatic(agentDirectories: ["/Users/x/Projekte/werkstatt"], directories: ["/tmp"], home: home, number: 1) == "werkstatt", "agent folder wins")
        check(BoardName.automatic(agentDirectories: [], directories: ["/tmp/"], home: home, number: 1) == "tmp", "trailing slash")
        check(BoardName.automatic(agentDirectories: [], directories: [home], home: home, number: 2) == "Home", "home folder")
        check(BoardName.automatic(agentDirectories: [], directories: [], home: home, number: 3) == "Brett 3", "fallback")
        check(BoardName.automatic(agentDirectories: [], directories: ["/"], home: home, number: 4) == "Brett 4", "root")
        print("board tests: \(cases) ok")
    }
}
