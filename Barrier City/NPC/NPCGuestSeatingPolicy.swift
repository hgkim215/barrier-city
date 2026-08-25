import Foundation
import simd

/// RealityKit과 무관한 좌석 후보 정책. cycler가 현재 순회에서 이미 배정받은 좌석을
/// 다시 고르지 않되, 미방문 빈 좌석을 모두 소진했으면 순환 자체가 멈추지 않도록
/// 전체 빈 좌석으로 폴백한다.
enum NPCGuestSeatingPolicy {
    static func freeSeatIndices(
        occupants: [Int?],
        avoiding excludedSeatIndices: Set<Int>
    ) -> Set<Int> {
        let allFreeIndices = Set(occupants.indices.filter { occupants[$0] == nil })
        let preferred = allFreeIndices.subtracting(excludedSeatIndices)
        return preferred.isEmpty ? allFreeIndices : preferred
    }
}

/// 좌석 바로 뒤까지 도착했지만 몸통 폭 레이가 의자/테이블 collision proxy에 먼저
/// 닿은 경우, 좌석을 포기하지 않고 착석 전환을 시작해도 되는지 판정한다. RealityKit
/// 상태와 분리해 경계값과 잘못된 접근 방향을 단위 테스트로 고정한다.
enum NPCGuestSeatTransitionPolicy {
    /// 정상 도착 반경(0.12m) 바깥에서도 몸통 반폭+격자 오차 때문에 collision proxy에
    /// 걸릴 수 있다. 접근점에서 이 거리 안이면 "사실상 도착"으로 볼 수 있다.
    static let blockedApproachTolerance: Float = 0.35
    /// 이보다 먼 위치에서 좌석까지 루트 위치를 보간하면 앉는 동작이 아니라 가구를
    /// 통과하는 슬라이드로 보인다. authored 접근점 최대 거리(0.65m)에 작은 오차만 둔다.
    static let maximumTransitionDistance: Float = 0.75

    static func canBeginFromBlockedApproach(
        currentPosition: SIMD2<Float>,
        seatPosition: SIMD2<Float>,
        approachPosition: SIMD2<Float>,
        seatFacing: SIMD2<Float>,
        isFinalWaypoint: Bool,
        isSceneGeometryBlock: Bool
    ) -> Bool {
        guard isFinalWaypoint, isSceneGeometryBlock,
              currentPosition.x.isFinite, currentPosition.y.isFinite,
              simd_distance(currentPosition, approachPosition) <= blockedApproachTolerance,
              simd_distance(currentPosition, seatPosition) <= maximumTransitionDistance
        else { return false }

        // 접근점이 좌석과 충분히 떨어져 있으면 authored 결과인 seat→approach 방향을
        // 신뢰한다. 둘이 거의 겹치면 좌석 정면의 반대(-facing)를 뒤쪽으로 사용한다.
        let seatToApproach = approachPosition - seatPosition
        let expectedBackDirection: SIMD2<Float>?
        if simd_length(seatToApproach) > 0.05 {
            expectedBackDirection = simd_normalize(seatToApproach)
        } else if simd_length(seatFacing) > 0.001 {
            expectedBackDirection = -simd_normalize(seatFacing)
        } else {
            expectedBackDirection = nil
        }

        // 이미 좌석 중심에 도달했거나 방향 정보를 만들 수 없는 비정상 authoring은
        // 거리 조건까지만 적용한다. 그 외에는 반드시 접근점과 같은 뒤쪽 반평면이어야
        // 하므로 테이블 반대편에서 좌석으로 순간이동하는 경로를 허용하지 않는다.
        let seatToCurrent = currentPosition - seatPosition
        guard simd_length(seatToCurrent) > 0.001,
              let expectedBackDirection else { return true }
        return simd_dot(simd_normalize(seatToCurrent), expectedBackDirection) >= 0
    }
}
