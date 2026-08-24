import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
@MainActor
struct InteractionFlowRegressionTests {
    static func main() {
        let doorCenter = SIMD2<Float>(0, -6)
        let outdoorStart = OutdoorSessionStart.roadMidpointPosition(
            road23Position: SIMD2<Float>(-2.7076335, 2.2008963),
            road24Position: SIMD2<Float>(1.2923665, 2.2008963),
            fallbackPosition: InteractionTuning.roadMidpointFallbackSpawnPosition)
        expectNear(outdoorStart.x, -0.7076335, "outdoor spawn is centered on X between Road_23 and Road_24")
        expectNear(outdoorStart.y, 2.2008963, "outdoor spawn is placed on the road Z")

        let door = ProximityTrigger(
            id: "door.enter",
            center: doorCenter,
            radius: InteractionTuning.doorTriggerRadius,
            prompt: "안으로 입장하시겠습니까?")
        let initialVerdict = InteractionModel.evaluate(
            playerX: outdoorStart.x,
            playerZ: outdoorStart.y,
            triggers: [door],
            activeID: nil,
            dismissedID: nil)
        expect(initialVerdict.showID, nil, "door prompt stays hidden at the outdoor spawn")

        let approachedVerdict = InteractionModel.evaluate(
            playerX: doorCenter.x,
            playerZ: doorCenter.y + 0.5,
            triggers: [door],
            activeID: nil,
            dismissedID: nil)
        expect(approachedVerdict.showID, "door.enter", "approaching within trigger radius activates the door prompt")

        let dismissedVerdict = InteractionModel.evaluate(
            playerX: doorCenter.x,
            playerZ: doorCenter.y + 0.5,
            triggers: [door],
            activeID: nil,
            dismissedID: "door.enter")
        expect(dismissedVerdict.showID, nil, "dismissed door prompt stays hidden inside the trigger")

        let leftVerdict = InteractionModel.evaluate(
            playerX: doorCenter.x,
            playerZ: doorCenter.y + 3.0,
            triggers: [door],
            activeID: nil,
            dismissedID: "door.enter")
        expect(leftVerdict.clearDismissed, true, "leaving the door range clears dismissal")

        let reenteredVerdict = InteractionModel.evaluate(
            playerX: doorCenter.x,
            playerZ: doorCenter.y + 0.5,
            triggers: [door],
            activeID: nil,
            dismissedID: nil)
        expect(reenteredVerdict.showID, "door.enter", "re-entering the door range shows the prompt again")

        let doorPanelPosition = InteractionPanelPlacement.worldPosition(
            SIMD3<Float>(8, 3, 9),
            toward: SIMD3<Float>(4, 1, 2),
            kind: .yesNoPrompt)
        expectNear(doorPanelPosition.x, 0, "door prompt stays horizontally centered on the user")
        expectNear(doorPanelPosition.y, 1.35, "door prompt stays at the seated direct-touch height")
        expectNear(doorPanelPosition.z, -0.60, "door prompt stays at a direct-touch hand distance")

        let kioskPanelPosition = InteractionPanelPlacement.worldPosition(
            SIMD3<Float>(3, 1.7, 4),
            toward: .zero,
            kind: .kioskScreen)
        expectNear(kioskPanelPosition.x, 2.52, "kiosk offset preserves its 0.8 m behavior on X")
        expectNear(kioskPanelPosition.z, 3.36, "kiosk offset preserves its 0.8 m behavior on Z")

        let kiosk = ProximityTrigger(
            id: "kiosk.order",
            center: SIMD2<Float>(1, 1),
            radius: 3,
            kind: .kioskScreen,
            prompt: "주문하기")
        let interactions = InteractionModel()
        interactions.triggers = [kiosk]
        interactions.activeTrigger = kiosk
        interactions.updateKioskContext(
            isIndoor: true,
            isNear: true,
            isMissionTwoActive: true,
            isGuideLocked: false)
        expect(interactions.kioskMenuVisible, true, "Indoor menu remains visible")
        expect(interactions.kioskInputEnabled, true, "Mission 2 proximity enables input")
        expect(interactions.selectKioskCategory(.coffee), .blocked, "category tab is blocked")
        expect(interactions.kioskSelectedCategory, .best, "category remains best")
        expect(interactions.kioskBarrierVisible, true, "category attempt opens barrier")
        _ = interactions.dismissKioskBarrier()
        expect(interactions.kioskBarrierVisible, false, "barrier dismisses")
        expect(interactions.selectKioskCategory(.other), .blocked, "other tab is also blocked")
        expect(interactions.kioskSelectedCategory, .best, "category remains best")
        expect(interactions.kioskBarrierVisible, true, "other opens barrier")

        let quest = QuestModel()
        _ = quest.advance(on: .enteredIndoor)
        var guide = GuideFlowState(phase: .missionActive(index: 1))
        var forwardedEvents: [QuestEvent] = []
        var missionThreeTransitions = 0
        let eventSink: (QuestEvent) -> Void = { event in
            forwardedEvents.append(event)
            guard case .advanced = quest.advance(on: event) else { return }
            let previousPhase = guide.phase
            guide.send(.questAdvanced(nextIndex: quest.currentIndex))
            if previousPhase != guide.phase,
               guide.phase == .missionAnnouncement(index: 2) {
                missionThreeTransitions += 1
            }
        }

        expect(
            KioskPrimaryActionCoordinator.activate(
                interactionModel: interactions,
                eventSink: eventSink),
            true,
            "first primary action is accepted")
        expect(
            KioskPrimaryActionCoordinator.activate(
                interactionModel: interactions,
                eventSink: eventSink),
            false,
            "repeated primary action is rejected")
        expect(forwardedEvents, [.kioskFailed], "primary action forwards kioskFailed exactly once")
        expect(missionThreeTransitions, 1, "primary action produces one Mission 3 transition")
        expect(guide.phase, .missionAnnouncement(index: 2), "event sink reaches Mission 3 announcement")

        guide.send(.confirmMission)
        expect(guide.phase, .missionActive(index: 2), "Mission 3 confirmation unlocks interaction")

        let verdict = InteractionModel.evaluate(
            playerX: 1,
            playerZ: 1,
            triggers: interactions.triggers,
            activeID: interactions.activeTrigger?.id,
            dismissedID: interactions.dismissedTriggerID)
        expect(verdict.showID, nil, "acknowledged kiosk stays dismissed while still in radius")
        expect(interactions.kioskBarrierVisible, false, "help closes barrier detail state")
        expect(interactions.kioskInputEnabled, false, "help locks kiosk input for the session")

        interactions.resetKioskSession()
        expect(interactions.kioskMenuVisible, false, "session reset clears kiosk visibility")
        expect(interactions.kioskBarrierVisible, false, "session reset clears barrier state")
        expect(interactions.kioskSelectedCategory, .best, "session reset restores the best category")
        expect(interactions.kioskSelectedMenuID, nil, "session reset clears selected menu")

        print("InteractionFlowRegressionTests: PASS")
    }
}
