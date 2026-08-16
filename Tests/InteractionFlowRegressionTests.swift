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
        let outdoorStart = OutdoorSessionStart.positionOutsideCafe(
            doorCenter: doorCenter,
            cafeCenter: .zero,
            fallbackDoorCenter: doorCenter,
            groundHalfExtent: InteractionTuning.outdoorGroundPlaneSize / 2,
            safetyMargin: InteractionTuning.outdoorSpawnSafetyMargin)
        expectNear(outdoorStart.y, -7.5, "outdoor spawn stays inside the supported floor edge")

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
            playerX: outdoorStart.x,
            playerZ: outdoorStart.y + 0.5,
            triggers: [door],
            activeID: nil,
            dismissedID: nil)
        expect(approachedVerdict.showID, "door.enter", "half-meter approach reaches the door trigger")

        let dismissedVerdict = InteractionModel.evaluate(
            playerX: outdoorStart.x,
            playerZ: outdoorStart.y + 0.5,
            triggers: [door],
            activeID: nil,
            dismissedID: "door.enter")
        expect(dismissedVerdict.showID, nil, "dismissed door prompt stays hidden inside the trigger")

        let leftVerdict = InteractionModel.evaluate(
            playerX: doorCenter.x,
            playerZ: doorCenter.y + 2,
            triggers: [door],
            activeID: nil,
            dismissedID: "door.enter")
        expect(leftVerdict.clearDismissed, true, "leaving the door range clears dismissal")

        let reenteredVerdict = InteractionModel.evaluate(
            playerX: outdoorStart.x,
            playerZ: outdoorStart.y + 0.5,
            triggers: [door],
            activeID: nil,
            dismissedID: nil)
        expect(reenteredVerdict.showID, "door.enter", "re-entering the door range shows the prompt again")

        let doorPanelPosition = InteractionPanelPlacement.worldPosition(
            SIMD3<Float>(8, 3, 9),
            toward: SIMD3<Float>(4, 1, 2),
            kind: .yesNoPrompt)
        expectNear(doorPanelPosition.x, 0, "door prompt stays horizontally centered on the user")
        expectNear(doorPanelPosition.y, 1.45, "door prompt stays at the seated eye line")
        expectNear(doorPanelPosition.z, -1.2, "door prompt stays at a comfortable eye-front distance")

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
        expect(interactions.attemptKioskUse(.gazePinch), true, "first kiosk attempt accepted")
        expect(interactions.kioskBarrierVisible, true, "attempt opens accessibility barrier")

        expect(interactions.requestKioskStaffHelp(), true, "first help request accepted")
        expect(interactions.requestKioskStaffHelp(), false, "help request is idempotent")

        var guide = GuideFlowState(phase: .missionActive(index: 1))
        guide.send(.questAdvanced(nextIndex: 2))
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

    }
}
