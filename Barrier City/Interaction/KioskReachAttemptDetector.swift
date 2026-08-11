import Foundation

enum KioskHandSide: Hashable {
    case left
    case right
}

enum KioskReachTuning {
    static let frontRange: ClosedRange<Float> = 0.08...0.65
    static let horizontalMargin: Float = 0.12
    static let minimumMovement: Float = 0.08
    static let movementWindow: TimeInterval = 0.45
    static let dwellDuration: TimeInterval = 0.20
    static let cooldownDuration: TimeInterval = 1.0
    static let staleTimeout: TimeInterval = 0.25
}

struct KioskReachAttemptDetector {
    private var origin: (position: SIMD3<Float>, time: TimeInterval)?
    private var armedAt: TimeInterval?
    private var lastSampleTime: TimeInterval?
    private var cooldownUntil: TimeInterval = -.infinity

    mutating func reset() {
        origin = nil
        armedAt = nil
        lastSampleTime = nil
        cooldownUntil = -.infinity
    }

    mutating func sample(
        position: SIMD3<Float>,
        timestamp: TimeInterval,
        isTracked: Bool,
        halfWidth: Float,
        halfHeight: Float
    ) -> Bool {
        let isStale = lastSampleTime.map {
            timestamp - $0 > KioskReachTuning.staleTimeout
        } ?? false
        if !isTracked || isStale {
            clearCandidate()
        }
        lastSampleTime = timestamp

        let isFinite = position.x.isFinite && position.y.isFinite && position.z.isFinite
            && halfWidth.isFinite && halfHeight.isFinite && timestamp.isFinite
        let isInsideAttemptVolume = isFinite
            && KioskReachTuning.frontRange.contains(position.z)
            && abs(position.x) <= halfWidth + KioskReachTuning.horizontalMargin
            && abs(position.y) <= halfHeight + KioskReachTuning.horizontalMargin

        guard isTracked, timestamp >= cooldownUntil, isInsideAttemptVolume else {
            clearCandidate()
            return false
        }

        guard let start = origin else {
            origin = (position, timestamp)
            return false
        }

        guard timestamp - start.time <= KioskReachTuning.movementWindow else {
            origin = (position, timestamp)
            armedAt = nil
            return false
        }

        let movedTowardScreen = start.position.z - position.z >= KioskReachTuning.minimumMovement
        let movedUpward = position.y - start.position.y >= KioskReachTuning.minimumMovement
        if (movedTowardScreen || movedUpward), armedAt == nil {
            armedAt = timestamp
        }

        guard let armedAt,
              timestamp - armedAt >= KioskReachTuning.dwellDuration else {
            return false
        }

        cooldownUntil = timestamp + KioskReachTuning.cooldownDuration
        clearCandidate()
        return true
    }

    private mutating func clearCandidate() {
        origin = nil
        armedAt = nil
    }
}
