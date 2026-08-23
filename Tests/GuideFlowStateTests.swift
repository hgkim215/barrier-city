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
        expect(normal.allowsNPCConversation, false, "mission one blocks NPC conversation")
        expect(normal.allowsNPCOrderConversation, false, "mission one blocks NPC ordering")

        normal.send(.questAdvanced(nextIndex: 1))
        expect(normal.phase, .missionAnnouncement(index: 1), "next mission announcement")
        expect(normal.visibleMissionCount, 2, "completed plus current missions visible")
        normal.send(.confirmMission)
        normal.send(.questAdvanced(nextIndex: 2))
        normal.send(.confirmMission)
        expect(normal.allowsNPCConversation, true, "mission three enables NPC conversation")
        expect(normal.allowsNPCOrderConversation, true, "mission three enables NPC ordering")

        normal.send(.questAdvanced(nextIndex: 3))
        expect(normal.phase, .missionAnnouncement(index: 3), "NPC order enters mission 4 announcement")
        expect(normal.visibleMissionCount, 4, "drink waiting step is visible in announcement")
        normal.send(.confirmMission)
        expect(normal.phase, .missionActive(index: 3), "mission 4 active")
        expect(normal.allowsNPCConversation, true, "drink wait keeps NPC follow-up conversation open")
        expect(normal.allowsNPCOrderConversation, false, "drink wait closes NPC ordering")

        normal.send(.questAdvanced(nextIndex: 4))
        expect(normal.phase, .missionAnnouncement(index: 4), "drink ready advances to pickup announcement")
        expect(normal.visibleMissionCount, 5, "pickup step is visible")
        normal.send(.confirmMission)
        expect(normal.phase, .missionActive(index: 4), "mission 5 active")

        normal.send(.questAdvanced(nextIndex: 5))
        expect(normal.phase, .missionAnnouncement(index: 5), "pickup advances to seating announcement")
        expect(normal.visibleMissionCount, 6, "seating step is visible")
        normal.send(.confirmMission)
        expect(normal.phase, .missionActive(index: 5), "mission 6 active")

        normal.send(.questAdvanced(nextIndex: nil))
        expect(normal.phase, .completionAnnouncement, "seating opens completion")
        normal.send(.confirmCompletion)
        expect(normal.phase, .completed, "completion acknowledgement")
        expect(normal.visibleMissionCount, 6, "all missions remain visible")

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

        var npcOnly = GuideFlowState(phase: .missionActive(index: 2))
        npcOnly.send(.questAdvanced(nextIndex: 3))
        expect(npcOnly.phase, .missionAnnouncement(index: 3),
               "NPC completion must not complete the experience")

        var failOpen = GuideFlowState()
        failOpen.send(.failOpen(activeMissionIndex: 0))
        expect(failOpen.phase, .missionActive(index: 0), "attachment failure unlocks mission")
        expect(failOpen.isInteractionLocked, false, "fail-open is unlocked")

    }
}
