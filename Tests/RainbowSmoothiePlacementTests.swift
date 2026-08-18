import Foundation

private func expectNear(_ actual: Float, _ expected: Float, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) expected \(expected), got \(actual)")
    }
}

@main
struct RainbowSmoothiePlacementTests {
    static func main() {
        let position = RainbowSmoothiePlacement.counterPosition(
            minimum: SIMD3<Float>(-2, 0, -1),
            maximum: SIMD3<Float>(2, 1, 1))
        expectNear(position.x, -0.8, "30 percent from left targets empty counter")
        expectNear(position.y, 1.01, "anchor clears the counter surface")
        expectNear(position.z, 0, "anchor stays centered in counter depth")
        expectNear(
            RainbowSmoothiePlacement.uniformScale(assetHeight: 0.56),
            0.5,
            "smoothie normalizes to 28 cm height")
        expectNear(
            RainbowSmoothiePlacement.uniformScale(assetHeight: 0),
            1,
            "invalid bounds preserve authored scale")
        print("PASS: RainbowSmoothiePlacementTests")
    }
}
