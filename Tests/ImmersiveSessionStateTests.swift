import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct ImmersiveSessionStateTests {
    static func main() {
        var normal = ImmersiveSessionState()
        expect(normal.phase, .closed, "initial phase")
        expect(normal.controlTitle, "체험 시작", "closed title")
        expect(normal.isTransitioning, false, "closed controls enabled")

        let firstGeneration = normal.beginOpen()
        expect(firstGeneration, 1, "first session generation")
        expect(normal.phase, .opening, "begin open")
        expect(normal.controlTitle, "여는 중…", "opening title")
        expect(normal.isTransitioning, true, "opening controls disabled")
        normal.completeOpen(generation: firstGeneration!, succeeded: true)
        expect(normal.phase, .open, "open succeeds")
        expect(normal.controlTitle, "체험 종료", "open title")
        expect(normal.isImmersive, true, "open is immersive")

        let closingGeneration = normal.beginClose()
        expect(closingGeneration, firstGeneration, "close owns first session")
        expect(normal.phase, .closing, "begin close")
        expect(normal.controlTitle, "종료 중…", "closing title")
        expect(normal.isTransitioning, true, "closing controls disabled")
        normal.completeClose(generation: closingGeneration!)
        expect(normal.phase, .closed, "close returns to start")
        expect(normal.controlTitle, "체험 시작", "close restores start title")
        expect(normal.isImmersive, false, "closed is not immersive")

        let secondGeneration = normal.beginOpen()
        expect(secondGeneration, 2, "second session generation")
        normal.completeOpen(generation: secondGeneration!, succeeded: true)
        expect(normal.phase, .open, "second experience can open")

        var cancelled = ImmersiveSessionState()
        let cancelledGeneration = cancelled.beginOpen()!
        cancelled.completeOpen(generation: cancelledGeneration, succeeded: false)
        expect(cancelled.phase, .closed, "cancelled open returns to start")

        var systemDriven = ImmersiveSessionState()
        let systemGeneration = systemDriven.beginOpen()!
        expect(systemDriven.appeared(), systemGeneration, "appearance claims current session")
        expect(systemDriven.phase, .open, "appearance reconciles external open")
        expect(systemDriven.disappeared(generation: systemGeneration), true,
               "current disappearance owns teardown")
        expect(systemDriven.phase, .closed, "disappearance reconciles external close")

        var staleCallbacks = ImmersiveSessionState()
        let staleGeneration = staleCallbacks.beginOpen()!
        staleCallbacks.completeOpen(generation: staleGeneration, succeeded: true)
        let staleClosingGeneration = staleCallbacks.beginClose()!
        staleCallbacks.completeClose(generation: staleClosingGeneration)

        let replacementGeneration = staleCallbacks.beginOpen()!
        expect(staleCallbacks.appeared(), replacementGeneration,
               "replacement appearance claims replacement session")
        expect(staleCallbacks.phase, .open, "replacement session is open")

        expect(staleCallbacks.disappeared(generation: staleGeneration), false,
               "stale disappearance cannot own replacement teardown")
        expect(staleCallbacks.phase, .open, "stale disappearance cannot close replacement")

        expect(staleCallbacks.completeOpen(generation: staleGeneration, succeeded: false), false,
               "stale open result is rejected")
        expect(staleCallbacks.phase, .open, "stale open result cannot close replacement")

        expect(staleCallbacks.disappeared(generation: replacementGeneration), true,
               "replacement disappearance owns its teardown")
        expect(staleCallbacks.phase, .closed, "replacement disappearance closes session")

    }
}
