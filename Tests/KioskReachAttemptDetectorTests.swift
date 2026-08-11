import Foundation

private func expect(_ actual: Bool, _ expected: Bool, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

private let halfWidth: Float = 0.15
private let halfHeight: Float = 0.26

private func sample(
    _ detector: inout KioskReachAttemptDetector,
    _ position: SIMD3<Float>,
    at time: TimeInterval,
    tracked: Bool = true
) -> Bool {
    detector.sample(
        position: position,
        timestamp: time,
        isTracked: tracked,
        halfWidth: halfWidth,
        halfHeight: halfHeight)
}

@main
struct KioskReachAttemptDetectorTests {
    static func main() {
        approachTowardScreenFiresAfterDwell()
        upwardReachFiresAfterDwell()
        invalidRegionsAndStationaryHandsDoNotFire()
        staleOrUntrackedSamplesResetCandidate()
        cooldownDeduplicatesThenAllowsAnotherAttempt()

        print("KioskReachAttemptDetectorTests: PASS")
    }

    private static func approachTowardScreenFiresAfterDwell() {
        var detector = KioskReachAttemptDetector()
        expect(sample(&detector, [0, 0, 0.55], at: 0.00), false, "approach origin does not fire")
        expect(sample(&detector, [0, 0, 0.46], at: 0.18), false, "approach movement only arms")
        expect(sample(&detector, [0, 0, 0.44], at: 0.39), true, "approach dwell fires once")
    }

    private static func upwardReachFiresAfterDwell() {
        var detector = KioskReachAttemptDetector()
        expect(sample(&detector, [0, -0.12, 0.40], at: 1.00), false, "upward origin does not fire")
        expect(sample(&detector, [0, -0.03, 0.40], at: 1.15), false, "upward movement only arms")
        expect(sample(&detector, [0, 0.00, 0.39], at: 1.36), true, "upward dwell fires")
    }

    private static func invalidRegionsAndStationaryHandsDoNotFire() {
        var outsideX = KioskReachAttemptDetector()
        expect(sample(&outsideX, [0.28, 0, 0.50], at: 2.00), false, "outside horizontal margin ignored")
        expect(sample(&outsideX, [0.28, 0.10, 0.39], at: 2.20), false, "outside horizontal movement ignored")
        expect(sample(&outsideX, [0.28, 0.10, 0.38], at: 2.42), false, "outside horizontal dwell ignored")

        var behind = KioskReachAttemptDetector()
        expect(sample(&behind, [0, 0, 0.70], at: 3.00), false, "too far sample ignored")
        expect(sample(&behind, [0, 0.10, 0.59], at: 3.20), false, "entering from invalid origin starts new candidate")
        expect(sample(&behind, [0, 0.10, 0.58], at: 3.42), false, "new stationary candidate does not fire")

        var lowWheel = KioskReachAttemptDetector()
        expect(sample(&lowWheel, [0, -0.45, 0.50], at: 4.00), false, "wheel-height sample ignored")
        expect(sample(&lowWheel, [0, -0.34, 0.39], at: 4.20), false, "wheel-height movement ignored")
        expect(sample(&lowWheel, [0, -0.33, 0.38], at: 4.42), false, "wheel-height dwell ignored")

        var stationary = KioskReachAttemptDetector()
        expect(sample(&stationary, [0, 0, 0.40], at: 5.00), false, "stationary origin")
        expect(sample(&stationary, [0.01, 0.01, 0.39], at: 5.20), false, "small jitter ignored")
        expect(sample(&stationary, [0.01, 0.01, 0.39], at: 5.42), false, "stationary dwell ignored")
    }

    private static func staleOrUntrackedSamplesResetCandidate() {
        var stale = KioskReachAttemptDetector()
        expect(sample(&stale, [0, 0, 0.55], at: 6.00), false, "stale origin")
        expect(sample(&stale, [0, 0, 0.45], at: 6.15), false, "stale movement arms")
        expect(sample(&stale, [0, 0, 0.44], at: 6.41), false, "stale gap resets before dwell")

        var lost = KioskReachAttemptDetector()
        expect(sample(&lost, [0, 0, 0.55], at: 7.00), false, "tracked origin")
        expect(sample(&lost, [0, 0, 0.45], at: 7.15), false, "tracked movement arms")
        expect(sample(&lost, [0, 0, 0.44], at: 7.20, tracked: false), false, "tracking loss resets")
        expect(sample(&lost, [0, 0, 0.43], at: 7.38), false, "post-loss sample is a new origin")
    }

    private static func cooldownDeduplicatesThenAllowsAnotherAttempt() {
        var detector = KioskReachAttemptDetector()
        _ = sample(&detector, [0, 0, 0.55], at: 8.00)
        _ = sample(&detector, [0, 0, 0.45], at: 8.15)
        expect(sample(&detector, [0, 0, 0.44], at: 8.36), true, "first attempt fires")
        expect(sample(&detector, [0, 0.10, 0.30], at: 8.50), false, "cooldown suppresses movement")
        expect(sample(&detector, [0, 0.20, 0.20], at: 8.75), false, "cooldown suppresses dwell")

        expect(sample(&detector, [0, -0.10, 0.55], at: 9.40), false, "post-cooldown new origin")
        expect(sample(&detector, [0, 0.00, 0.50], at: 9.55), false, "post-cooldown movement arms")
        expect(sample(&detector, [0, 0.02, 0.48], at: 9.76), true, "post-cooldown attempt fires")
    }
}
