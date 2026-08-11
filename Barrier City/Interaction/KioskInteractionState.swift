enum KioskAttemptSource: Equatable {
    case gazePinch
    case handReach
}

struct KioskInteractionState: Equatable {
    private(set) var isIndoor = false
    private(set) var isNear = false
    private(set) var isMissionTwoActive = false
    private(set) var isGuideLocked = true
    private(set) var barrierVisible = false
    private(set) var helpRequested = false

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
        guard inputEnabled else { return false }
        barrierVisible = true
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
