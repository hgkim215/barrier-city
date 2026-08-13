struct SceneTransitionToken: Equatable {
    fileprivate let sessionGeneration: UInt
    fileprivate let transitionGeneration: UInt
}

struct SceneTransitionSession {
    private var sessionGeneration: UInt = 0
    private var transitionGeneration: UInt = 0
    private var activeToken: SceneTransitionToken?

    var isTransitioning: Bool { activeToken != nil }

    mutating func beginSession() {
        sessionGeneration &+= 1
        activeToken = nil
    }

    mutating func endSession() {
        sessionGeneration &+= 1
        activeToken = nil
    }

    mutating func beginTransition() -> SceneTransitionToken? {
        guard activeToken == nil else { return nil }
        transitionGeneration &+= 1
        let token = SceneTransitionToken(
            sessionGeneration: sessionGeneration,
            transitionGeneration: transitionGeneration)
        activeToken = token
        return token
    }

    func isCurrent(_ token: SceneTransitionToken) -> Bool {
        activeToken == token && token.sessionGeneration == sessionGeneration
    }

    mutating func finishTransition(_ token: SceneTransitionToken) {
        guard isCurrent(token) else { return }
        activeToken = nil
    }
}
