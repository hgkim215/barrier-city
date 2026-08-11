import Foundation

private func expectNear(_ actual: Float?, _ expected: Float, _ message: String) {
    guard let actual, abs(actual - expected) < 0.0001 else {
        fatalError("FAIL: \(message) — expected \(expected), got \(String(describing: actual))")
    }
}

private func expectNil(_ actual: Float?, _ message: String) {
    guard actual == nil else {
        fatalError("FAIL: \(message) — expected nil, got \(actual!)")
    }
}

@main
struct KioskScreenLayoutTests {
    static func main() {
        expectNear(
            KioskScreenLayout.uniformScale(
                planeSize: [0.30, 0.52],
                attachmentSize: [0.60, 1.00],
                fill: 0.98),
            0.49,
            "height-limited 9:16 attachment")

        expectNear(
            KioskScreenLayout.uniformScale(
                planeSize: [0.30, 0.52],
                attachmentSize: [1.00, 1.00],
                fill: 0.98),
            0.294,
            "width-limited square attachment")

        expectNil(
            KioskScreenLayout.uniformScale(
                planeSize: [0, 0.52],
                attachmentSize: [0.60, 1.00],
                fill: 0.98),
            "zero plane width")
        expectNil(
            KioskScreenLayout.uniformScale(
                planeSize: [0.30, 0.52],
                attachmentSize: [0.60, 0],
                fill: 0.98),
            "zero attachment height")
        expectNil(
            KioskScreenLayout.uniformScale(
                planeSize: [.nan, 0.52],
                attachmentSize: [0.60, 1.00],
                fill: 0.98),
            "non-finite bounds")
        expectNil(
            KioskScreenLayout.uniformScale(
                planeSize: [0.30, 0.52],
                attachmentSize: [0.60, 1.00],
                fill: 0),
            "non-positive fill")

        print("KioskScreenLayoutTests: PASS")
    }
}
