import Foundation

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

@main
struct NPCGuestSeatingPolicyTests {
    static func main() {
        let occupants: [Int?] = [10, nil, nil, 20]
        expect(
            NPCGuestSeatingPolicy.freeSeatIndices(occupants: occupants, avoiding: []) == [1, 2],
            "all unoccupied seats must be candidates without an exclusion")
        expect(
            NPCGuestSeatingPolicy.freeSeatIndices(occupants: occupants, avoiding: [1]) == [2],
            "cycler must prefer a different free seat")
        expect(
            NPCGuestSeatingPolicy.freeSeatIndices(
                occupants: [nil, nil, nil, nil],
                avoiding: [0, 1]) == [2, 3],
            "cycler must exclude every seat already visited in the current tour")

        let onlyVisitedSeatsFree: [Int?] = [10, nil, nil, 20]
        expect(
            NPCGuestSeatingPolicy.freeSeatIndices(
                occupants: onlyVisitedSeatsFree,
                avoiding: [1, 2]) == [1, 2],
            "visited seats must become fallbacks after all currently free seats were visited")
        expect(
            NPCGuestSeatingPolicy.freeSeatIndices(
                occupants: [10, 20],
                avoiding: [1]).isEmpty,
            "a full room must produce no seat candidate")

        let seat = SIMD2<Float>(0, 0)
        let approach = SIMD2<Float>(-0.5, 0)
        expect(
            NPCGuestSeatTransitionPolicy.canBeginFromBlockedApproach(
                currentPosition: [-0.62, 0],
                seatPosition: seat,
                approachPosition: approach,
                seatFacing: [1, 0],
                isFinalWaypoint: true,
                isSceneGeometryBlock: true),
            "scene geometry at the final nearby back-side approach must begin seating")
        expect(
            !NPCGuestSeatTransitionPolicy.canBeginFromBlockedApproach(
                currentPosition: [-0.62, 0],
                seatPosition: seat,
                approachPosition: approach,
                seatFacing: [1, 0],
                isFinalWaypoint: false,
                isSceneGeometryBlock: true),
            "an intermediate waypoint block must never teleport the guest into the seat")
        expect(
            !NPCGuestSeatTransitionPolicy.canBeginFromBlockedApproach(
                currentPosition: [-0.62, 0],
                seatPosition: seat,
                approachPosition: approach,
                seatFacing: [1, 0],
                isFinalWaypoint: true,
                isSceneGeometryBlock: false),
            "player and neighboring NPC blocks must not be bypassed")
        expect(
            !NPCGuestSeatTransitionPolicy.canBeginFromBlockedApproach(
                currentPosition: [0.02, 0],
                seatPosition: seat,
                approachPosition: [-0.3, 0],
                seatFacing: [1, 0],
                isFinalWaypoint: true,
                isSceneGeometryBlock: true),
            "a guest on the opposite side of the seat must not cross the table to sit")
        expect(
            !NPCGuestSeatTransitionPolicy.canBeginFromBlockedApproach(
                currentPosition: [-0.8, 0],
                seatPosition: seat,
                approachPosition: approach,
                seatFacing: [1, 0],
                isFinalWaypoint: true,
                isSceneGeometryBlock: true),
            "the seating transition must not slide farther than its authored movement range")

        print("All NPCGuestSeatingPolicy tests passed.")
    }
}
