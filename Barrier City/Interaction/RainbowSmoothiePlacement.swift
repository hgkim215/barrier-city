import Foundation

enum ServingPlacementTuning {
    static let counterFractionFromMinimumX: Float = 0.30
    static let counterDepthFraction: Float = 0.50
    static let surfaceClearance: Float = 0.01
    static let targetSmoothieHeight: Float = 0.28
}

enum RainbowSmoothiePlacement {
    static func counterPosition(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) -> SIMD3<Float>? {
        guard hasFiniteOrderedBounds(minimum: minimum, maximum: maximum) else {
            return nil
        }
        let extent = maximum - minimum
        return SIMD3(
            minimum.x + extent.x * ServingPlacementTuning.counterFractionFromMinimumX,
            maximum.y + ServingPlacementTuning.surfaceClearance,
            minimum.z + extent.z * ServingPlacementTuning.counterDepthFraction)
    }

    static func uniformScale(assetHeight: Float) -> Float {
        guard assetHeight.isFinite, assetHeight > 0.0001 else { return 1 }
        return ServingPlacementTuning.targetSmoothieHeight / assetHeight
    }

    static func hasFiniteOrderedBounds(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) -> Bool {
        minimum.x.isFinite && minimum.y.isFinite && minimum.z.isFinite
            && maximum.x.isFinite && maximum.y.isFinite && maximum.z.isFinite
            && minimum.x <= maximum.x
            && minimum.y <= maximum.y
            && minimum.z <= maximum.z
    }
}
