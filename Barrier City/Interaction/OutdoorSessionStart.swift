import simd

struct OutdoorStartPose: Equatable {
    let position: SIMD2<Float>
    let heading: Float
}

@MainActor
protocol OutdoorSessionResettable: AnyObject {
    var posX: Float { get set }
    var posZ: Float { get set }
    var heading: Float { get set }
    func restart()
}

enum OutdoorSessionStart {
    nonisolated static func positionOutsideCafe(
        doorCenter: SIMD2<Float>,
        cafeCenter: SIMD2<Float>,
        fallbackDoorCenter: SIMD2<Float>,
        groundHalfExtent: Float,
        safetyMargin: Float
    ) -> SIMD2<Float> {
        var outward = doorCenter - cafeCenter
        if simd_length_squared(outward) < 0.000001 {
            outward = fallbackDoorCenter - cafeCenter
        }
        if simd_length_squared(outward) < 0.000001 {
            outward = SIMD2<Float>(0, -1)
        }
        outward = simd_normalize(outward)

        let safeExtent = max(0, groundHalfExtent - max(0, safetyMargin))
        let clampedDoor = SIMD2<Float>(
            max(-safeExtent, min(safeExtent, doorCenter.x)),
            max(-safeExtent, min(safeExtent, doorCenter.y)))
        guard clampedDoor == doorCenter else { return clampedDoor }

        var exitDistance: Float?
        if abs(outward.x) > 0.000001 {
            let boundary = outward.x > 0 ? safeExtent : -safeExtent
            let candidate = (boundary - doorCenter.x) / outward.x
            if candidate >= 0 {
                exitDistance = candidate
            }
        }
        if abs(outward.y) > 0.000001 {
            let boundary = outward.y > 0 ? safeExtent : -safeExtent
            let candidate = (boundary - doorCenter.y) / outward.y
            if candidate >= 0 {
                exitDistance = min(exitDistance ?? candidate, candidate)
            }
        }
        guard let exitDistance else { return clampedDoor }
        return doorCenter + outward * exitDistance
    }

    nonisolated static func pose(
        startPosition: SIMD2<Float>,
        doorCenter: SIMD2<Float>,
        fallbackDoorCenter: SIMD2<Float>
    ) -> OutdoorStartPose {
        var direction = doorCenter - startPosition
        if simd_length_squared(direction) < 0.000001 {
            direction = fallbackDoorCenter - startPosition
        }
        if simd_length_squared(direction) < 0.000001 {
            direction = SIMD2<Float>(0, 1)
        }
        direction = simd_normalize(direction)
        let rawHeading = atan2(-direction.x, -direction.y)
        let heading = rawHeading < 0 ? rawHeading + 2 * .pi : rawHeading
        return OutdoorStartPose(
            position: startPosition,
            heading: heading)
    }

    @MainActor
    static func reset(
        _ state: any OutdoorSessionResettable,
        startPosition: SIMD2<Float>,
        doorCenter: SIMD2<Float>,
        fallbackDoorCenter: SIMD2<Float>
    ) {
        let pose = pose(
            startPosition: startPosition,
            doorCenter: doorCenter,
            fallbackDoorCenter: fallbackDoorCenter)
        state.restart()
        state.posX = pose.position.x
        state.posZ = pose.position.y
        state.heading = pose.heading
    }
}
