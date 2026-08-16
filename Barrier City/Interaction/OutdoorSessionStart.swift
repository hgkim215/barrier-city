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
        distanceFromDoor: Float
    ) -> SIMD2<Float> {
        var outward = doorCenter - cafeCenter
        if simd_length_squared(outward) < 0.000001 {
            outward = fallbackDoorCenter - cafeCenter
        }
        if simd_length_squared(outward) < 0.000001 {
            outward = SIMD2<Float>(0, -1)
        }
        return doorCenter
            + simd_normalize(outward) * max(0, distanceFromDoor)
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
