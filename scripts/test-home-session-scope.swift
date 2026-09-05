import Foundation

@main
struct HomeSessionScopeTests {
    static func main() {
        assert(HomeSessionScope.contains("/projects/a", in: "/projects/a"))
        assert(HomeSessionScope.contains("/projects/a/site", in: "/projects/a"))
        assert(!HomeSessionScope.contains("/projects/ab", in: "/projects/a"))
        assert(!HomeSessionScope.contains("/elsewhere", in: "/projects"))
        assert(HomeSessionScope.contains("/projects/a", in: "/"))
        assert(HomeSessionScope.contains("/projects/a", in: "/projects/"))
        print("6 session scope cases passed")
    }
}
