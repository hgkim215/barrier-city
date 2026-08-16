enum KioskAttemptSource: Equatable {
    case gazePinch
    case handReach
}

enum KioskCategory: String, CaseIterable, Hashable {
    case best, coffee, tea, ade, nonCoffee, decaf, other, all
}

enum KioskCategorySelectionResult: Equatable {
    case ignored, selected, blocked
}

struct KioskInteractionState: Equatable {
    private(set) var isIndoor = false
    private(set) var isNear = false
    private(set) var isMissionTwoActive = false
    private(set) var isGuideLocked = true
    private(set) var barrierVisible = false
    private(set) var helpRequested = false
    private(set) var selectedCategory: KioskCategory = .best
    private(set) var selectedMenuID: String?

    var menuVisible: Bool { isIndoor }

    var inputEnabled: Bool {
        isIndoor
            && isNear
            && isMissionTwoActive
            && !isGuideLocked
            && !barrierVisible
            && !helpRequested
    }

    mutating func updateContext(
        isIndoor: Bool,
        isNear: Bool,
        isMissionTwoActive: Bool,
        isGuideLocked: Bool
    ) {
        self.isIndoor = isIndoor
        self.isNear = isNear
        self.isMissionTwoActive = isMissionTwoActive
        self.isGuideLocked = isGuideLocked
    }

    @discardableResult
    mutating func attempt(_ source: KioskAttemptSource) -> Bool {
        attemptRestrictedCategory(source)
    }

    mutating func selectCategory(
        _ category: KioskCategory,
        source: KioskAttemptSource
    ) -> KioskCategorySelectionResult {
        guard inputEnabled else { return .ignored }
        if category == .other {
            barrierVisible = true
            return .blocked
        }
        selectedCategory = category
        selectedMenuID = nil
        return .selected
    }

    @discardableResult
    mutating func attemptRestrictedCategory(_ source: KioskAttemptSource) -> Bool {
        guard inputEnabled else { return false }
        barrierVisible = true
        return true
    }

    @discardableResult
    mutating func selectMenu(id: String) -> Bool {
        guard inputEnabled, selectedCategory != .other else { return false }
        selectedMenuID = id
        return true
    }

    @discardableResult
    mutating func dismissBarrier() -> Bool {
        guard barrierVisible, !helpRequested else { return false }
        barrierVisible = false
        return true
    }

    @discardableResult
    mutating func requestStaffHelp() -> Bool {
        guard barrierVisible, !helpRequested else { return false }
        barrierVisible = false
        helpRequested = true
        return true
    }

    mutating func reset() {
        self = KioskInteractionState()
    }
}
