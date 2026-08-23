import Foundation

enum CafeOrderPhase: String, Equatable, Sendable {
    case notOrdered
    case preparing
    case readyAtCounter
    case failed
}

@MainActor
final class CafeOrderSession {
    private(set) var phase: CafeOrderPhase = .notOrdered
    private(set) var generation = 0

    @discardableResult
    func beginIndoorSession() -> Int {
        generation &+= 1
        phase = .notOrdered
        return generation
    }

    func acceptOrder() -> Int? {
        guard phase == .notOrdered else { return nil }
        phase = .preparing
        return generation
    }

    @discardableResult
    func markReady(generation: Int) -> Bool {
        guard generation == self.generation, phase == .preparing else { return false }
        phase = .readyAtCounter
        return true
    }

    @discardableResult
    func markFailed(generation: Int) -> Bool {
        guard generation == self.generation,
              phase == .notOrdered || phase == .preparing else { return false }
        phase = .failed
        return true
    }

    func resetForOutdoor() {
        generation &+= 1
        phase = .notOrdered
    }
}
