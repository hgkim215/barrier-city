import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct SceneTransitionSessionTests {
    static func main() {
        var session = SceneTransitionSession()
        session.beginSession()
        let stale = session.beginTransition()!

        session.endSession()
        session.beginSession()
        let current = session.beginTransition()!

        expect(session.isCurrent(stale), false, "exit invalidates a suspended transition")
        session.finishTransition(stale)
        expect(session.isTransitioning, true, "stale completion cannot clear a newer transition")
        expect(session.isCurrent(current), true, "new session transition remains current")

        session.finishTransition(current)
        expect(session.isTransitioning, false, "current transition can finish")

        print("SceneTransitionSessionTests: PASS")
    }
}
