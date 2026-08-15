import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
@MainActor
struct InteractionFlowRegressionTests {
    static func main() {
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
