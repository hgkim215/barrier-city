import Foundation

private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) — expected \(expected), got \(actual)")
    }
}

@MainActor
private final class WheelchairState: OutdoorSessionResettable {
    var posX: Float = 8
    var posZ: Float = -3
    var heading: Float = 0.25
    var restartCount = 0

    func restart() {
        restartCount += 1
        posX = 0
        posZ = 0
        heading = 0
    }
}

@main
@MainActor
struct OutdoorSessionStartTests {
    static func main() {
        let outside = OutdoorSessionStart.positionOutsideCafe(
            doorCenter: SIMD2<Float>(0, -6),
            cafeCenter: .zero,
            fallbackDoorCenter: SIMD2<Float>(0, -6),
            groundMinimum: SIMD2(repeating: -8),
            groundMaximum: SIMD2(repeating: 8),
            preferredDistance: 1.5,
            safetyMargin: 0.5)
        expectNear(outside.x, 0, "safe spawn preserves centered door X")
        expectNear(outside.y, -7.5, "safe spawn stops inside the negative-Z floor edge")

        let diagonalOutside = OutdoorSessionStart.positionOutsideCafe(
            doorCenter: SIMD2<Float>(3, 4),
            cafeCenter: .zero,
            fallbackDoorCenter: SIMD2<Float>(0, -6),
            groundMinimum: SIMD2(repeating: -8),
            groundMaximum: SIMD2(repeating: 8),
            preferredDistance: 1.5,
            safetyMargin: 0.5)
        expectNear(diagonalOutside.x, 3.9, "diagonal spawn follows the door ray on X")
        expectNear(diagonalOutside.y, 5.2, "diagonal spawn keeps the preferred door distance on Z")

        let fallbackOutside = OutdoorSessionStart.positionOutsideCafe(
            doorCenter: .zero,
            cafeCenter: .zero,
            fallbackDoorCenter: SIMD2<Float>(0, -6),
            groundMinimum: SIMD2(repeating: -8),
            groundMaximum: SIMD2(repeating: 8),
            preferredDistance: 1.5,
            safetyMargin: 0.5)
        expectNear(fallbackOutside.y, -1.5, "coincident cafe and door use the fallback ray")

        let offsetGround = OutdoorSessionStart.positionOutsideCafe(
            doorCenter: SIMD2<Float>(0, 12.67),
            cafeCenter: SIMD2<Float>(0, 18.74),
            fallbackDoorCenter: SIMD2<Float>(0, -6),
            groundMinimum: SIMD2<Float>(-10, -7.68),
            groundMaximum: SIMD2<Float>(10, 12.32),
            preferredDistance: 1.5,
            safetyMargin: 0.5)
        expectNear(offsetGround.y, 11.17, "offset authored ground keeps spawn outside the cafe")

        let positiveZ = OutdoorSessionStart.pose(
            startPosition: .zero,
            doorCenter: SIMD2<Float>(0, 15),
            fallbackDoorCenter: SIMD2<Float>(0, 15))
        expectNear(positiveZ.heading, .pi, "positive-Z cafe faces 180 degrees")

        let diagonal = OutdoorSessionStart.pose(
            startPosition: .zero,
            doorCenter: SIMD2<Float>(1, 1),
            fallbackDoorCenter: SIMD2<Float>(0, 15))
        expectNear(-sin(diagonal.heading), 0.70710677, "diagonal heading faces cafe on X")
        expectNear(-cos(diagonal.heading), 0.70710677, "diagonal heading faces cafe on Z")

        let coincident = OutdoorSessionStart.pose(
            startPosition: .zero,
            doorCenter: .zero,
            fallbackDoorCenter: SIMD2<Float>(0, 15))
        expectNear(coincident.heading, .pi, "coincident marker uses cafe fallback")

        let state = WheelchairState()
        OutdoorSessionStart.reset(
            state,
            startPosition: .zero,
            doorCenter: SIMD2<Float>(0, 15),
            fallbackDoorCenter: SIMD2<Float>(0, 15))
        guard state.restartCount == 1 else {
            fatalError("FAIL: immersive entry must restart wheelchair state exactly once")
        }
        expectNear(state.posX, 0, "reset applies outdoor X")
        expectNear(state.posZ, 0, "reset applies outdoor Z")
        expectNear(state.heading, .pi, "reset applies cafe-facing heading")

        let fallbackSpawn = SIMD2<Float>(-0.7076335, 2.2008963)
        let midpointBoth = OutdoorSessionStart.roadMidpointPosition(
            road23Position: SIMD2<Float>(-2.7076335, 2.2008963),
            road24Position: SIMD2<Float>(1.2923665, 2.2008963),
            fallbackPosition: fallbackSpawn)
        expectNear(midpointBoth.x, -0.7076335, "midpoint X is centered between Road_23 and Road_24")
        expectNear(midpointBoth.y, 2.2008963, "midpoint Z is preserved")

        let midpointOnly23 = OutdoorSessionStart.roadMidpointPosition(
            road23Position: SIMD2<Float>(-2.7076335, 2.2008963),
            road24Position: nil,
            fallbackPosition: fallbackSpawn)
        expectNear(midpointOnly23.x, -2.7076335, "single Road_23 is used when Road_24 missing")

        let midpointOnly24 = OutdoorSessionStart.roadMidpointPosition(
            road23Position: nil,
            road24Position: SIMD2<Float>(1.2923665, 2.2008963),
            fallbackPosition: fallbackSpawn)
        expectNear(midpointOnly24.x, 1.2923665, "single Road_24 is used when Road_23 missing")

        let midpointFallback = OutdoorSessionStart.roadMidpointPosition(
            road23Position: nil,
            road24Position: nil,
            fallbackPosition: fallbackSpawn)
        expectNear(midpointFallback.x, -0.7076335, "fallback X applied when both missing")
        expectNear(midpointFallback.y, 2.2008963, "fallback Z applied when both missing")

        let roadPose = OutdoorSessionStart.pose(
            startPosition: fallbackSpawn,
            doorCenter: SIMD2<Float>(-0.16957682, -5.889111),
            fallbackDoorCenter: SIMD2<Float>(-0.16957682, -5.889111))
        // direction is towards negative Z, so heading is nearly 0 / 2pi (facing -Z)
        expectNear(-cos(roadPose.heading), -0.997793, "road spawn heading faces negative Z (cafe door)")

        print("OutdoorSessionStartTests: PASS")
    }
}
