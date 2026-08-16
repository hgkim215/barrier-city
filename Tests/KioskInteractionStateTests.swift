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
        generalCategoriesSwitchAndMenusSelect()
        otherCategoryBlocksWithoutSelecting()
        dismissKeepsMissionRetryable()
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
        expect(state.attemptRestrictedCategory(.gazePinch), false, "far restricted-category attempt ignored")

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

    private static func generalCategoriesSwitchAndMenusSelect() {
        var state = enabledState()
        expect(state.selectedCategory, .best, "best is selected initially")
        expect(state.selectCategory(.coffee, source: .gazePinch), .selected, "coffee switches")
        expect(state.selectedCategory, .coffee, "coffee remains selected")
        expect(state.barrierVisible, false, "general category stays usable")
        expect(state.selectMenu(id: "cafe-latte"), true, "menu can be selected")
        expect(state.selectedMenuID, "cafe-latte", "menu id is stored")
    }

    private static func otherCategoryBlocksWithoutSelecting() {
        var state = enabledState()
        _ = state.selectCategory(.coffee, source: .gazePinch)
        expect(state.selectCategory(.other, source: .gazePinch), .blocked, "other is blocked")
        expect(state.selectedCategory, .coffee, "previous category remains")
        expect(state.barrierVisible, true, "barrier opens")
        expect(state.attemptRestrictedCategory(.handReach), false, "second source deduplicates")
    }

    private static func dismissKeepsMissionRetryable() {
        var state = enabledState()
        _ = state.selectCategory(.other, source: .gazePinch)
        expect(state.dismissBarrier(), true, "barrier closes")
        expect(state.helpRequested, false, "dismiss does not request help")
        expect(state.inputEnabled, true, "retry is enabled")
    }

    private static func helpRequestLocksInputAndEmitsOnce() {
        var state = enabledState()
        expect(state.requestStaffHelp(), false, "help cannot emit before a barrier attempt")
        _ = state.selectCategory(.other, source: .gazePinch)
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
        _ = state.selectCategory(.coffee, source: .gazePinch)
        _ = state.selectMenu(id: "cafe-latte")
        _ = state.selectCategory(.other, source: .handReach)
        _ = state.requestStaffHelp()

        state.reset()

        expect(state.menuVisible, false, "reset clears Indoor visibility")
        expect(state.inputEnabled, false, "reset disables input")
        expect(state.barrierVisible, false, "reset closes barrier")
        expect(state.helpRequested, false, "reset clears session help lock")
        expect(state.selectedCategory, .best, "reset restores the best category")
        expect(state.selectedMenuID, nil, "reset clears selected menu")
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
