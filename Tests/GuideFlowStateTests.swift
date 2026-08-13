import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct GuideFlowStateTests {
    static func main() {
        var normal = GuideFlowState()
        expect(normal.phase, .introduction, "initial phase")
        expect(normal.isInteractionLocked, true, "introduction locks input")
        expect(normal.placement, .centerModal, "introduction is centered")

        normal.send(.confirmIntroduction)
        expect(normal.phase, .tutorial(index: 0), "intro confirmation")
        normal.send(.nextTutorial)
        normal.send(.nextTutorial)
        expect(normal.phase, .tutorial(index: 2), "third tutorial")
        normal.send(.nextTutorial)
        expect(normal.phase, .missionAnnouncement(index: 0), "tutorial starts mission one")
        normal.send(.confirmMission)
        expect(normal.phase, .missionActive(index: 0), "mission one active")
        expect(normal.isInteractionLocked, false, "active mission unlocks input")
        expect(normal.placement, .upperLeadingHUD, "active mission uses HUD placement")

        normal.send(.questAdvanced(nextIndex: 1))
        expect(normal.phase, .missionAnnouncement(index: 1), "next mission announcement")
        expect(normal.visibleMissionCount, 2, "completed plus current missions visible")
        normal.send(.confirmMission)
        normal.send(.questAdvanced(nextIndex: 2))
        normal.send(.confirmMission)
        normal.send(.questAdvanced(nextIndex: nil))
        expect(normal.phase, .completionAnnouncement, "last quest opens completion")
        normal.send(.confirmCompletion)
        expect(normal.phase, .completed, "completion acknowledgement")
        expect(normal.visibleMissionCount, 3, "all missions remain visible")

        var skipped = GuideFlowState()
        skipped.send(.skipOnboarding)
        expect(skipped.phase, .missionAnnouncement(index: 0), "skip opens mission one")

        var backward = GuideFlowState(phase: .tutorial(index: 1))
        backward.send(.previousTutorial)
        expect(backward.phase, .tutorial(index: 0), "previous tutorial")
        backward.send(.previousTutorial)
        expect(backward.phase, .tutorial(index: 0), "previous clamps at zero")

        var invalid = GuideFlowState()
        invalid.send(.questAdvanced(nextIndex: 1))
        expect(invalid.phase, .introduction, "quest event ignored outside active mission")

        var backwardAdvance = GuideFlowState(phase: .missionActive(index: 1))
        backwardAdvance.send(.questAdvanced(nextIndex: 0))
        expect(backwardAdvance.phase, .missionActive(index: 1), "backward quest advancement ignored")

        var skippedAdvance = GuideFlowState(phase: .missionActive(index: 0))
        skippedAdvance.send(.questAdvanced(nextIndex: 2))
        expect(skippedAdvance.phase, .missionActive(index: 0), "skipped quest advancement ignored")

        var earlyCompletion = GuideFlowState(phase: .missionActive(index: 1))
        earlyCompletion.send(.questAdvanced(nextIndex: nil))
        expect(earlyCompletion.phase, .missionActive(index: 1), "early completion ignored")

        var failOpen = GuideFlowState()
        failOpen.send(.failOpen(activeMissionIndex: 0))
        expect(failOpen.phase, .missionActive(index: 0), "attachment failure unlocks mission")
        expect(failOpen.isInteractionLocked, false, "fail-open is unlocked")

    }
}
