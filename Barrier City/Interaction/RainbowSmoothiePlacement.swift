import Foundation

enum ServingPlacementTuning {
    /// 쇼케이스와 포스기 사이의 카운터 기본 상대 위치 (포스기/쇼케이스 노드가 없을 때의 폴백)
    static let counterFractionFromMinimumX: Float = 0.689
    static let counterDepthFraction: Float = 0.174
    static let surfaceClearance: Float = 0.01
    static let targetSmoothieHeight: Float = 0.28
    /// 휠체어 탑승자 무릎 앞쪽 쟁반 로컬 위치 (X: 중앙, Y: 무릎 높이, Z: 휠체어 전방)
    ///
    /// 미션 안내 카드(QuestTuning.cardDistance)보다 반드시 더 멀고 낮아야 한다.
    /// 예전 값(0.58, -0.48)은 카드(0.60m, y≈0.75)보다 앞이라 스무디가 카드를
    /// 가렸고, 시선·핀치 히트도 스무디가 먼저 가져가 버튼이 안 눌렸다.
    ///
    /// 높이로는 못 피한다 — 카드가 y 0.61~0.89를 차지하는데 스무디 위쪽이
    /// 그 구간에 걸리므로, 컵 끝이 카드를 뚫고 나오지 않으려면 깊이로
    /// 벌려야 한다. 카드가 0.50m이므로 모델 깊이(약 ±0.07)를 감안해
    /// 0.82m까지 밀어 25cm 이상 띄운다.
    static let wheelchairTrayPosition = SIMD3<Float>(0.0, 0.56, -0.82)
}

enum RainbowSmoothiePlacement {
    /// 포스기(Payment)와 진열대(Showcase) 사이 빈 공간 테이블 위에 서빙 위치를 계산한다.
    static func counterPosition(
        barMinimum: SIMD3<Float>,
        barMaximum: SIMD3<Float>,
        posBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil,
        showcaseBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? = nil
    ) -> SIMD3<Float>? {
        guard hasFiniteOrderedBounds(minimum: barMinimum, maximum: barMaximum) else {
            return nil
        }

        let tableSurfaceY = barMaximum.y + ServingPlacementTuning.surfaceClearance

        if let pos = posBounds, let sc = showcaseBounds,
           hasFiniteOrderedBounds(minimum: pos.min, maximum: pos.max),
           hasFiniteOrderedBounds(minimum: sc.min, maximum: sc.max) {
            let midX = (sc.max.x + pos.min.x) * 0.5
            let midZ = (pos.min.z + pos.max.z + sc.min.z + sc.max.z) * 0.25
            return SIMD3(midX, tableSurfaceY, midZ)
        }

        let extent = barMaximum - barMinimum
        return SIMD3(
            barMinimum.x + extent.x * ServingPlacementTuning.counterFractionFromMinimumX,
            tableSurfaceY,
            barMinimum.z + extent.z * ServingPlacementTuning.counterDepthFraction)
    }

    static func counterPosition(
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>
    ) -> SIMD3<Float>? {
        counterPosition(barMinimum: minimum, barMaximum: maximum)
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
