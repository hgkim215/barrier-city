import Foundation

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func require(_ needle: String, in source: String, _ message: String) {
    guard source.contains(needle) else { fail(message) }
}

@main
struct NPCGuestSeatingTransitionContractTests {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fail("expected NPCGuestController.swift and NPCGuestCoordinator.swift paths")
        }
        let controller = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let coordinator = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)

        require("case sittingDown", in: controller,
                "seating must have an explicit transition state")
        require("playSitTransition(reversed: true)", in: controller,
                "sitting down must reverse Sit_to_Stand")
        require("playback.speed = -1", in: controller,
                "the seating transition must use reverse playback")
        require("playback.time = duration", in: controller,
                "reverse playback must start at the end of the clip")
        require("static let sittingDurationRange: ClosedRange<Float> = 15...20", in: controller,
                "cycler sitting duration must remain 15...20 seconds")
        require("requestNextSeatIfCycler(excluding: vacatedSeatIndex)", in: controller,
                "cycler must request its next seat immediately after vacating")
        require("excludedSeatIndices: Set<Int>", in: controller,
                "cycler seat requests must carry the complete visited-seat set")
        require("visitedSeatIndices.insert(index)", in: controller,
                "every assigned cycler seat must enter the current tour history")
        require("movementContext: NPCGuestMovementContext", in: controller,
                "movement exclusion sets must be selected through the typed context")
        require("requestCollisionSafeSeatPath(", in: controller,
                "NPC must walk only along a collision-safe path to the seat approach")
        require("NPCGuestSeatTransitionPolicy.canBeginFromBlockedApproach", in: controller,
                "a final nearby scene-geometry block must use the guarded seating policy")
        require("private func beginSittingDown(at seat: GuestSeat)", in: controller,
                "normal and near-blocked arrivals must share one seating transition")
        require("requestCollisionSafeSeatPath", in: controller,
                "seating must not fall back to a straight path when A* fails")
        require("scheduleSeatGeometryRecovery", in: controller,
                "scene geometry must attempt a local detour before vacating the seat")
        require("fallbackDirection = targetDirection", in: controller,
                "seating steering must retry the original A* direction")
        require("private func updateEscaping(", in: controller,
                "blocked movement must enter an explicit escape phase")
        require("beginEscape()", in: controller,
                "blocked seating and roaming must schedule escape")
        require("let approachPosition: SIMD2<Float>", in: coordinator,
                "every assignable seat must have a walkable approach position")
        require("maximumSeatApproachDistance", in: coordinator,
                "deep seats that require furniture traversal must be rejected")
        require("model.position.y -= modelBounds.min.y", in: coordinator,
                "dessert assets must ground their measured model bounds before placement")
        require("placementRoot.setPosition([x, surfaceY, z]", in: coordinator,
                "grounded dessert roots must be placed directly on the table surface")
        require("static let surfaceClearance: Float = 0", in: coordinator,
                "dessert bounds must touch the table instead of retaining an air gap")

        if controller.contains("reserveSeat(") || coordinator.contains("cyclerImmediateSeatChance") {
            fail("cycler must not retain probabilistic/deferred seating")
        }
        if controller.contains("avoidSceneGeometry: false")
            || controller.contains("shouldBypassSeatCollision") {
            fail("guest movement must never disable furniture collision")
        }

        let femaleCount = coordinator.components(separatedBy: "\"Guest_Female_").count - 1
        let maleCount = coordinator.components(separatedBy: "\"Guest_Male_").count - 1
        guard femaleCount + maleCount == 9 else {
            fail("guest display entity count must remain exactly 9")
        }

        guard let finishStart = controller.range(of: "    private func finishSittingDown()")?.lowerBound,
              let movementSection = controller.range(
                of: "\n    // MARK: - Movement",
                range: finishStart..<controller.endIndex)?.lowerBound else {
            fail("could not locate finishSittingDown")
        }
        let finishBody = controller[finishStart..<movementSection]
        guard let sittingLoop = finishBody.range(of: "playAnimation(.sitting)"),
              let arrivalSignal = finishBody.range(of: "pendingSeatedArrivalIndex = claimedSeatIndex"),
              sittingLoop.lowerBound < arrivalSignal.lowerBound else {
            fail("arrival must be reported only after the sitting transition completes")
        }

        print("All NPCGuestSeatingTransition contract tests passed.")
    }
}
