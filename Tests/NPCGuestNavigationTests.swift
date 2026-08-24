import Foundation
import simd

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

@main
struct NPCGuestNavigationTests {
    static func main() {
        let floor = NPCGuestArea(center: .zero, axisU: [5, 0], axisV: [0, 5])
        let staff = NPCGuestArea(center: .zero, axisU: [1, 0], axisV: [0, 1])

        expect(NPCGuestNavigation.isValid([3, 3], inside: floor, excluding: [staff]),
               "ordinary floor point must be valid")
        expect(!NPCGuestNavigation.isValid([0, 0], inside: floor, excluding: [staff]),
               "staff area must never be a valid spawn")
        expect(!NPCGuestNavigation.isValid([6, 0], inside: floor, excluding: [staff]),
               "outside-floor point must never be a valid spawn")
        expect(!NPCGuestNavigation.isValid([.nan, 0], inside: floor, excluding: [staff]),
               "non-finite point must never be valid")

        expect(NPCGuestNavigation.isAllowedStep(from: [-3, 2], to: [3, 2],
                                                inside: floor, excluding: [staff]),
               "clear route must remain walkable")
        expect(!NPCGuestNavigation.isAllowedStep(from: [-2, 0], to: [2, 0],
                                                 inside: floor, excluding: [staff]),
               "a large frame step must not tunnel through a restricted area")
        expect(!NPCGuestNavigation.isAllowedStep(from: [4.8, 2], to: [5.2, 2],
                                                 inside: floor, excluding: [staff]),
               "movement must not leave the authored floor")
        expect(NPCGuestNavigation.isAllowedStep(from: [0, 0], to: [0.5, 0],
                                                inside: floor, excluding: [staff]),
               "an intruded NPC must be allowed to move toward the boundary")
        expect(!NPCGuestNavigation.isAllowedStep(from: [0.5, 0], to: [0.25, 0],
                                                 inside: floor, excluding: [staff]),
               "an intruded NPC must not move deeper into a restricted area")

        let fraction = NPCGuestNavigation.allowedFraction(
            from: [-2, 0], to: [2, 0], inside: floor, excluding: [staff])
        expect(fraction > 0.24 && fraction < 0.251,
               "movement must be clipped immediately before the restricted boundary")

        let diagonal = Float(1 / sqrt(2.0))
        let rotated = NPCGuestArea(center: [10, 10],
                                   axisU: [diagonal * 2, diagonal * 2],
                                   axisV: [-diagonal, diagonal])
        expect(rotated.contains([10, 10]), "rotated area must contain its center")
        expect(!rotated.contains([13, 10]), "rotated area must reject a distant point")
    }
}
