import Foundation
import simd

private func expect(_ actual: Bool, _ expected: Bool, _ message: String) {
    guard actual == expected else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

private let halfWidth: Float = 0.15
private let halfHeight: Float = 0.26

private func sample(
    _ detector: inout KioskReachAttemptDetector,
    _ position: SIMD3<Float>,
    at time: TimeInterval,
    tracked: Bool = true,
    halfSize: SIMD2<Float> = [halfWidth, halfHeight]
) -> Bool {
    detector.sample(
        position: position,
        timestamp: time,
        isTracked: tracked,
        halfWidth: halfSize.x,
        halfHeight: halfSize.y)
}

@main
struct KioskReachAttemptDetectorTests {
    static func main() {
        authoredScreenTransformMapsIntoScreenAlignedWorldMeters()
        authoredScreenTransformDetectsPhysicalUpwardReach()
        authoredScreenTransformRejectsFarAndWheelHeightSamples()
        approachTowardScreenFiresAfterDwell()
        upwardReachFiresAfterDwell()
        invalidRegionsAndStationaryHandsDoNotFire()
        staleOrUntrackedSamplesResetCandidate()
        cooldownDeduplicatesThenAllowsAnotherAttempt()

        print("KioskReachAttemptDetectorTests: PASS")
    }

    /// Fixture axes before face correction:
    /// local +X -> world -Z, local +Y -> world +Y, local +Z -> world +X.
    /// Every authored axis carries the Indoor kiosk's 1.7 scale.
    private static let authoredPlaneTransform = simd_float4x4(columns: (
        SIMD4<Float>(0, 0, -1.7, 0),
        SIMD4<Float>(0, 1.7, 0, 0),
        SIMD4<Float>(1.7, 0, 0, 0),
        SIMD4<Float>(2, 1, -3, 1)
    ))

    private static func authoredScreenFrame() -> KioskScreenCoordinateFrame {
        guard let frame = KioskScreenCoordinateFrame(
            planeWorldTransform: authoredPlaneTransform,
            localSurfaceCenter: .zero,
            localHalfSize: [0.15, 0.18],
            faceRotationRadians: .pi) else {
            fatalError("FAIL: valid authored screen fixture must create a frame")
        }
        return frame
    }

    private static func authoredScreenTransformMapsIntoScreenAlignedWorldMeters() {
        let frame = authoredScreenFrame()
        let mapped = frame.screenPosition(for: [2.5, 0.9, -2.9])

        expectNear(mapped.x, 0.10, "pi correction maps world +Z to screen-right")
        expectNear(mapped.y, 0.10, "pi correction maps physical world -Y to screen-up")
        expectNear(mapped.z, 0.50, "authored 1.7 scale does not shrink front meters")
        expectNear(frame.halfSizeMeters.x, 0.255, "authored scale expands physical half-width")
        expectNear(frame.halfSizeMeters.y, 0.306, "authored scale expands physical half-height")
    }

    private static func authoredScreenTransformDetectsPhysicalUpwardReach() {
        let frame = authoredScreenFrame()
        var detector = KioskReachAttemptDetector()

        expect(
            sample(&detector, frame.screenPosition(for: [2.40, 1.12, -3.00]), at: 10.00,
                   halfSize: frame.halfSizeMeters),
            false,
            "world-space origin does not fire")
        expect(
            sample(&detector, frame.screenPosition(for: [2.40, 1.03, -3.00]), at: 10.15,
                   halfSize: frame.halfSizeMeters),
            false,
            "physical upward movement arms after face correction")
        expect(
            sample(&detector, frame.screenPosition(for: [2.39, 1.00, -3.00]), at: 10.36,
                   halfSize: frame.halfSizeMeters),
            true,
            "physical upward dwell fires once")
    }

    private static func authoredScreenTransformRejectsFarAndWheelHeightSamples() {
        let frame = authoredScreenFrame()

        var tooFar = KioskReachAttemptDetector()
        expect(
            sample(&tooFar, frame.screenPosition(for: [2.80, 1.00, -3.00]), at: 11.00,
                   halfSize: frame.halfSizeMeters),
            false,
            "0.80 world meters in front is outside the reach volume")
        expect(
            sample(&tooFar, frame.screenPosition(for: [2.69, 0.89, -3.00]), at: 11.15,
                   halfSize: frame.halfSizeMeters),
            false,
            "far movement cannot arm after authored scale normalization")
        expect(
            sample(&tooFar, frame.screenPosition(for: [2.68, 0.88, -3.00]), at: 11.36,
                   halfSize: frame.halfSizeMeters),
            false,
            "far dwell remains rejected")

        var wheelHeight = KioskReachAttemptDetector()
        expect(
            sample(&wheelHeight, frame.screenPosition(for: [2.50, 1.55, -3.00]), at: 12.00,
                   halfSize: frame.halfSizeMeters),
            false,
            "wheel-height origin is outside the physical screen volume")
        expect(
            sample(&wheelHeight, frame.screenPosition(for: [2.39, 1.44, -3.00]), at: 12.15,
                   halfSize: frame.halfSizeMeters),
            false,
            "wheel-height movement cannot arm")
        expect(
            sample(&wheelHeight, frame.screenPosition(for: [2.38, 1.43, -3.00]), at: 12.36,
                   halfSize: frame.halfSizeMeters),
            false,
            "wheel-height dwell remains rejected")
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
