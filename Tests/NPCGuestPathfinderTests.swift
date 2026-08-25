import Foundation
import simd

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

private func approximatelyEqual(
    _ lhs: SIMD2<Float>,
    _ rhs: SIMD2<Float>,
    tolerance: Float = 0.001
) -> Bool {
    simd_distance(lhs, rhs) <= tolerance
}

@main
struct NPCGuestPathfinderTests {
    static func main() {
        let floor = NPCGuestArea(center: .zero, axisU: [3, 0], axisV: [0, 3])
        let grid = NPCGuestPathfinder.buildGrid(area: floor, cellSize: 1) { point in
            abs(point.x) > 0.4
        }
        let seat = SIMD2<Float>(0, 0)
        guard let approach = grid.bestApproachPosition(
            to: seat,
            preferredDirection: [-1, 0],
            maximumDistance: 1.1)
        else { fail("a walkable seat approach behind the seat must exist") }
        expect(approximatelyEqual(approach, [-1, 0]),
               "seat approach must choose the preferred back side, not cross the furniture")
        expect(
            grid.bestApproachPosition(
                to: seat,
                preferredDirection: [-1, 0],
                maximumDistance: 0.5) == nil,
            "a seat deeper than the transition limit must be rejected")

        guard let path = NPCGuestPathfinder.findPath(from: [-3, 0], to: approach, in: grid)
        else { fail("a path to the safe seat approach must exist") }
        expect(approximatelyEqual(path.last ?? [999, 999], approach),
               "walking must stop at the safe approach instead of entering the blocked seat")

        print("All NPCGuestPathfinder tests passed.")
    }
}
