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
    nonisolated static func roadMidpointPosition(
        road23Position: SIMD2<Float>?,
        road24Position: SIMD2<Float>?,
        fallbackPosition: SIMD2<Float>
    ) -> SIMD2<Float> {
        if let r23 = road23Position, let r24 = road24Position {
            return (r23 + r24) * 0.5
        } else if let r23 = road23Position {
            return r23
        } else if let r24 = road24Position {
            return r24
        }
        return fallbackPosition
    }

    nonisolated static func positionOutsideCafe(
        doorCenter: SIMD2<Float>,
        cafeCenter: SIMD2<Float>,
        fallbackDoorCenter: SIMD2<Float>,
        groundMinimum: SIMD2<Float>,
        groundMaximum: SIMD2<Float>,
        preferredDistance: Float,
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

        let margin = max(0, safetyMargin)
        let safeMinimum = groundMinimum + margin
        let safeMaximum = groundMaximum - margin
        let target = doorCenter + outward * max(0, preferredDistance)
        return SIMD2<Float>(
            max(safeMinimum.x, min(safeMaximum.x, target.x)),
            max(safeMinimum.y, min(safeMaximum.y, target.y)))
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
