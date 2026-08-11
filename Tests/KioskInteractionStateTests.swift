import Foundation

private func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@main
struct KioskInteractionStateTests {
    static func main() {
        menuIsVisibleThroughoutIndoorButInputIsGated()
        bothAttemptSourcesConvergeAndDeduplicate()
        helpRequestLocksInputAndEmitsOnce()
        sessionResetClearsAllKioskState()

        print("KioskInteractionStateTests: PASS")
    }

    private static func menuIsVisibleThroughoutIndoorButInputIsGated() {
        var state = KioskInteractionState()
        expect(state.menuVisible, false, "outdoor hides kiosk menu")
        expect(state.inputEnabled, false, "initial input disabled")

        state.updateContext(
            isIndoor: true,
            isNear: false,
            isMissionTwoActive: true,
            isGuideLocked: false)
        expect(state.menuVisible, true, "Indoor keeps menu visible while far")
        expect(state.inputEnabled, false, "far kiosk is display-only")
        expect(state.attempt(.gazePinch), false, "far attempt ignored")

        state.updateContext(
            isIndoor: true,
            isNear: true,
            isMissionTwoActive: false,
            isGuideLocked: false)
        expect(state.menuVisible, true, "menu stays visible outside Mission 2")
        expect(state.inputEnabled, false, "wrong mission disables input")

        state.updateContext(
            isIndoor: true,
            isNear: true,
            isMissionTwoActive: true,
            isGuideLocked: true)
        expect(state.inputEnabled, false, "guide lock disables input")

        state.updateContext(
            isIndoor: true,
            isNear: true,
            isMissionTwoActive: true,
            isGuideLocked: false)
        expect(state.inputEnabled, true, "near unlocked Mission 2 enables input")
    }

    private static func bothAttemptSourcesConvergeAndDeduplicate() {
        var gaze = enabledState()
        expect(gaze.attempt(.gazePinch), true, "first gaze attempt accepted")
        expect(gaze.barrierVisible, true, "gaze attempt opens barrier")
        expect(gaze.inputEnabled, false, "open barrier debounces input")
        expect(gaze.attempt(.handReach), false, "hand attempt deduplicates after gaze")

        var hand = enabledState()
        expect(hand.attempt(.handReach), true, "first hand attempt accepted")
        expect(hand.barrierVisible, true, "hand attempt opens same barrier")
        expect(hand.attempt(.gazePinch), false, "gaze attempt deduplicates after hand")
    }

    private static func helpRequestLocksInputAndEmitsOnce() {
        var state = enabledState()
        expect(state.requestStaffHelp(), false, "help cannot emit before a barrier attempt")
        _ = state.attempt(.gazePinch)
        expect(state.requestStaffHelp(), true, "first help request emits")
        expect(state.barrierVisible, false, "help closes barrier card")
        expect(state.helpRequested, true, "help locks this immersive session")
        expect(state.requestStaffHelp(), false, "help request emits once")
        expect(state.inputEnabled, false, "help keeps kiosk input locked")

        state.updateContext(
            isIndoor: true,
            isNear: false,
            isMissionTwoActive: true,
            isGuideLocked: false)
        state.updateContext(
            isIndoor: true,
            isNear: true,
            isMissionTwoActive: true,
            isGuideLocked: false)
        expect(state.inputEnabled, false, "moving away and back cannot unlock after help")
    }

    private static func sessionResetClearsAllKioskState() {
        var state = enabledState()
        _ = state.attempt(.handReach)
        _ = state.requestStaffHelp()

        state.reset()

        expect(state.menuVisible, false, "reset clears Indoor visibility")
        expect(state.inputEnabled, false, "reset disables input")
        expect(state.barrierVisible, false, "reset closes barrier")
        expect(state.helpRequested, false, "reset clears session help lock")
    }

    private static func enabledState() -> KioskInteractionState {
        var state = KioskInteractionState()
        state.updateContext(
            isIndoor: true,
            isNear: true,
            isMissionTwoActive: true,
            isGuideLocked: false)
        return state
    }
}
