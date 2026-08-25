import Foundation

struct ExperienceRunTimer: Equatable {
    private var startedAt: ContinuousClock.Instant?
    private var elapsed: Duration?

    var isRunning: Bool {
        startedAt != nil && elapsed == nil
    }

    var formattedElapsed: String {
        let totalSeconds = max(0, elapsed?.components.seconds ?? 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02lld:%02lld", minutes, seconds)
    }

    mutating func start(at instant: ContinuousClock.Instant = .now) {
        startedAt = instant
        elapsed = nil
    }

    @discardableResult
    mutating func finish(at instant: ContinuousClock.Instant = .now) -> Bool {
        guard let startedAt, elapsed == nil else { return false }
        elapsed = startedAt.duration(to: instant)
        return true
    }

    mutating func reset() {
        startedAt = nil
        elapsed = nil
    }
}

struct ExperienceCelebrationState: Equatable {
    private(set) var generation = 0
    private var activeGeneration: Int?

    var isPlaying: Bool {
        activeGeneration != nil
    }

    mutating func begin() -> Int? {
        guard activeGeneration == nil else { return nil }
        generation += 1
        activeGeneration = generation
        return generation
    }

    @discardableResult
    mutating func stop() -> Bool {
        guard activeGeneration != nil else { return false }
        activeGeneration = nil
        return true
    }

    mutating func reset() {
        activeGeneration = nil
    }
}
