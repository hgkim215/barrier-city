import simd

/// 목표 지점 정의.
///
/// 충돌/지형은 더 이상 여기서 다루지 않는다(엔진 CharacterController + USDA 콜리전이 담당).
/// 목표 도달 판정에 쓰는 좌표만 남긴다. (가상 위치 공간 = 시뮬 공간 좌표)
enum Terrain {
    /// 목표 지점(추후 카페 자리로 지정).
    static let goal = SIMD2<Float>(0, -10)
    static let goalRadius: Float = 0.9
}
