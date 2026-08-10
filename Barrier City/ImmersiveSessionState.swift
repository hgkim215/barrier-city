enum ImmersiveSessionPhase: Equatable {
    case closed
    case opening
    case open
    case closing
}

struct ImmersiveSessionState: Equatable {
    private(set) var phase: ImmersiveSessionPhase = .closed
    private(set) var generation = 0

    var isImmersive: Bool {
        phase == .open || phase == .closing
    }

    var isTransitioning: Bool {
        phase == .opening || phase == .closing
    }

    var controlTitle: String {
        switch phase {
        case .closed: "체험 시작"
        case .opening: "여는 중…"
        case .open: "체험 종료"
        case .closing: "종료 중…"
        }
    }

    mutating func beginOpen() -> Int? {
        guard phase == .closed else { return nil }
        generation += 1
        phase = .opening
        return generation
    }

    @discardableResult
    mutating func completeOpen(generation: Int, succeeded: Bool) -> Bool {
        guard generation == self.generation, phase == .opening else { return false }
        phase = succeeded ? .open : .closed
        return true
    }

    mutating func beginClose() -> Int? {
        guard phase == .open else { return nil }
        phase = .closing
        return generation
    }

    @discardableResult
    mutating func completeClose(generation: Int) -> Bool {
        guard generation == self.generation, phase == .closing else { return false }
        phase = .closed
        return true
    }

    /// 현재 몰입 뷰가 소유할 세대 번호를 반환한다.
    mutating func appeared() -> Int? {
        guard generation > 0 else { return nil }
        if phase == .opening {
            phase = .open
        }
        return generation
    }

    /// 해당 뷰가 여전히 최신 세션일 때만 상태 변경과 외부 정리를 허용한다.
    mutating func disappeared(generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        phase = .closed
        return true
    }
}
