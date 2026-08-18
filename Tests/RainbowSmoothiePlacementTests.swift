import Foundation

private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) expected \(expected), got \(actual)")
    }
}

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

@main
struct RainbowSmoothiePlacementTests {
    static func main() {
        guard let position = RainbowSmoothiePlacement.counterPosition(
            minimum: SIMD3<Float>(-2, 0, -1),
            maximum: SIMD3<Float>(2, 1, 1)) else {
            fail("finite ordered counter bounds produce a position")
        }
        expectNear(position.x, -0.8, "30 percent from left targets empty counter")
        expectNear(position.y, 1.01, "anchor clears the counter surface")
        expectNear(position.z, 0, "anchor stays centered in counter depth")
        guard RainbowSmoothiePlacement.counterPosition(
            minimum: SIMD3<Float>(-.infinity, -.infinity, -.infinity),
            maximum: SIMD3<Float>(.infinity, .infinity, .infinity)) == nil else {
            fail("empty counter bounds are rejected")
        }
        guard RainbowSmoothiePlacement.counterPosition(
            minimum: SIMD3<Float>(0, .nan, 0),
            maximum: SIMD3<Float>(1, 1, 1)) == nil else {
            fail("non-finite counter bounds are rejected")
        }
        guard RainbowSmoothiePlacement.counterPosition(
            minimum: SIMD3<Float>(1, 0, 0),
            maximum: SIMD3<Float>(0, 1, 1)) == nil else {
            fail("reversed counter bounds are rejected")
        }
        expectNear(
            RainbowSmoothiePlacement.uniformScale(assetHeight: 0.56),
            0.5,
            "smoothie normalizes to 28 cm height")
        expectNear(
            RainbowSmoothiePlacement.uniformScale(assetHeight: 0),
            1,
            "invalid bounds preserve authored scale")
        expectNear(
            RainbowSmoothiePlacement.uniformScale(assetHeight: .infinity),
            1,
            "non-finite height preserves authored scale")
        expectNear(
            RainbowSmoothiePlacement.uniformScale(assetHeight: .nan),
            1,
            "NaN height preserves authored scale")
        print("PASS: RainbowSmoothiePlacementTests")
    }
}
