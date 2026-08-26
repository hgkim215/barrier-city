import Foundation
import simd

/// 회전된 사각형 영역(월드 XZ 평면). 배회 가능 바닥과 금지 구역을 같은 기하로 다룬다.
struct NPCGuestArea {
    let center: SIMD2<Float>
    let axisU: SIMD2<Float>
    let axisV: SIMD2<Float>

    func point(u: Float, v: Float) -> SIMD2<Float> {
        center + axisU * u + axisV * v
    }

    func contains(_ point: SIMD2<Float>) -> Bool {
        guard let coordinates = localCoordinates(of: point) else { return false }
        return abs(coordinates.x) <= 1 && abs(coordinates.y) <= 1
    }

    /// 내부에서는 양수, 경계에서는 0, 외부에서는 음수다. 이미 잘못 들어간 NPC가
    /// 매 프레임 더 얕은 쪽으로만 움직이는지 판정하는 데 사용한다.
    func interiorDepth(of point: SIMD2<Float>) -> Float {
        guard let coordinates = localCoordinates(of: point) else { return -.greatestFiniteMagnitude }
        return min(1 - abs(coordinates.x), 1 - abs(coordinates.y))
    }

    /// 두 점이 모두 밖이어도 선분 중간이 금지 구역을 관통하는 경우를 잡는다.
    func intersectsSegment(from start: SIMD2<Float>, to end: SIMD2<Float>) -> Bool {
        guard let a = localCoordinates(of: start), let b = localCoordinates(of: end) else { return false }
        let delta = b - a
        var lower: Float = 0
        var upper: Float = 1

        for (origin, direction) in [(a.x, delta.x), (a.y, delta.y)] {
            if abs(direction) < 0.000001 {
                if abs(origin) <= 1 { continue }
                return false
            }
            let t1 = (-1 - origin) / direction
            let t2 = (1 - origin) / direction
            lower = max(lower, min(t1, t2))
            upper = min(upper, max(t1, t2))
            if lower > upper { return false }
        }
        return upper >= 0 && lower <= 1
    }

    /// 월드 좌표를 이 영역의 u/v(-1...1이면 내부) 좌표로 바꾼다. NPCGuestPathfinder가
    /// 격자 셀 인덱스를 계산할 때도 같은 투영을 재사용한다.
    func localCoordinates(of point: SIMD2<Float>) -> SIMD2<Float>? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let offset = point - center
        let determinant = axisU.x * axisV.y - axisU.y * axisV.x
        guard abs(determinant) > 0.000001 else { return nil }
        return SIMD2(
            (offset.x * axisV.y - offset.y * axisV.x) / determinant,
            (axisU.x * offset.y - axisU.y * offset.x) / determinant)
    }
}

/// 이동 목적에 따라 적용해야 하는 제외 구역을 한곳에서 결정한다. 일반 배회는 모든
/// 가구/키오스크 제외 구역을 피하지만, 좌석 접근과 대기줄은 목적지가 그 제외 구역 안에
/// 있을 수 있어 직원 전용 구역만 피해야 한다. 호출부가 두 배열을 개별 파라미터로 넘기면
/// 서로 뒤바뀌어도 컴파일러가 잡지 못하므로, 이동 의도를 타입으로 전달해 여기서 매핑한다.
enum NPCGuestMovementIntent {
    case roaming
    case queueing
    case seating
}

struct NPCGuestMovementContext {
    let floor: NPCGuestArea
    let roamingExclusions: [NPCGuestArea]
    let staffOnlyExclusions: [NPCGuestArea]

    func exclusions(for intent: NPCGuestMovementIntent) -> [NPCGuestArea] {
        switch intent {
        case .roaming:
            roamingExclusions
        case .queueing, .seating:
            staffOnlyExclusions
        }
    }
}

enum NPCGuestNavigation {
    /// 이미 위반 상태(바닥 밖/제외 구역 안)에서 "탈출" 판정에 쓰는 여유치. 실제
    /// 한 프레임 이동 폭(수 mm)은 이미 아주 작은데, allowedFraction이 이걸 12번
    /// 이분해 찾는 후보는 그보다 4096배 더 작아져(수 마이크로미터) Float32
    /// 정밀도 안에서 시작/끝 깊이가 아예 구분되지 않는다. 완전한 엄격 부등호만
    /// 쓰면 그 오차 때문에 탈출 이동조차 전부 거부돼 NPC가 제자리에 영원히
    /// 갇히는 문제가 실기에서 확인됐다(걷다 멈췄다를 반복하는 "지지거림"의
    /// 실제 원인 — areaFraction이 0으로 고정된 채 반복됨).
    private static let escapeTolerance: Float = 0.0005

    /// 관통(tunneling) 방지 검사(intersectsSegment)는 큰 deltaTime 한 프레임에
    /// 제외 구역 전체를 가로질러 반대편에 안착하는 극단적 경우를 막기 위한
    /// 것이다. 이동 속도가 최대 ~1m/s인 이 프로젝트에서 정상 프레임의 한 스텝은
    /// 이 문턱보다 훨씬 짧다. 스텝 길이와 무관하게 이 검사를 항상 적용하면,
    /// 테이블 경계 바로 옆을 지나가는 정상적인 배회에서도 시작점이 경계에 가깝기만
    /// 하면 매 프레임 선분이 경계에 스쳐 걸리고, 이분 탐색으로 스텝을 아무리
    /// 잘게 쪼개도 시작점 자체는 그대로라 계속 같은 이유로 걸려 areaFraction이
    /// 0으로 고정되는 문제가 실기에서 확인됐다(escapeTolerance로 해결한 "이미
    /// 구역 안" 케이스와는 다른, "구역 밖에서 경계를 스치는" 케이스).
    private static let tunnelingCheckMinimumStepLength: Float = 0.5

    static func isValid(_ point: SIMD2<Float>,
                        inside floor: NPCGuestArea,
                        excluding exclusions: [NPCGuestArea]) -> Bool {
        floor.contains(point) && !exclusions.contains(where: { $0.contains(point) })
    }

    /// 현재 위치가 정상이라면 바닥 밖/금지 구역 안으로 한 발짝도 들어가지 못하게 한다.
    /// 이미 잘못된 위치라면 위반 깊이가 나빠지지 않는(escapeTolerance만큼의 오차는
    /// 봐주는) 이동만 예외적으로 허용한다.
    static func isAllowedStep(from start: SIMD2<Float>,
                              to end: SIMD2<Float>,
                              inside floor: NPCGuestArea,
                              excluding exclusions: [NPCGuestArea]) -> Bool {
        guard end.x.isFinite, end.y.isFinite else { return false }

        let startFloorDepth = floor.interiorDepth(of: start)
        let endFloorDepth = floor.interiorDepth(of: end)
        if startFloorDepth >= 0 {
            guard endFloorDepth >= 0 else { return false }
        } else {
            guard endFloorDepth >= startFloorDepth - escapeTolerance else { return false }
        }

        for exclusion in exclusions {
            let startDepth = exclusion.interiorDepth(of: start)
            let endDepth = exclusion.interiorDepth(of: end)
            if startDepth >= 0 {
                guard endDepth <= startDepth + escapeTolerance else { return false }
            } else {
                guard endDepth < 0 else { return false }
                if simd_distance(start, end) > tunnelingCheckMinimumStepLength {
                    guard !exclusion.intersectsSegment(from: start, to: end) else { return false }
                }
            }
        }
        return true
    }

    /// 전체 이동이 불가능하면 이분 탐색으로 경계 직전까지의 안전한 비율을 구한다.
    ///
    /// 이미 위반 상태(탈출 시도)에서 전체 스텝조차 막히면 이분 탐색으로 내려가지
    /// 않는다 — 탈출 이동은 "경계 직전까지만 허용"할 개념 자체가 없고(위반 중이라
    /// 이미 경계 너머다), 절반씩 잘라 들어가는 후보는 갈수록 Float32 정밀도 밑으로
    /// 떨어져 깊이 차이가 안 잡히고 결국 0으로 수렴해버린다(escapeTolerance 도입
    /// 전 실제로 이 경로에서 NPC가 영원히 갇혔다). 대신 이번 프레임은 안 움직이고,
    /// 다음 프레임에 move()가 새로 고른 스티어링 방향으로 다시 시도한다.
    static func allowedFraction(from start: SIMD2<Float>,
                                to proposedEnd: SIMD2<Float>,
                                inside floor: NPCGuestArea,
                                excluding exclusions: [NPCGuestArea]) -> Float {
        if isAllowedStep(from: start, to: proposedEnd, inside: floor, excluding: exclusions) {
            return 1
        }
        let isEscaping = floor.interiorDepth(of: start) < 0
            || exclusions.contains { $0.interiorDepth(of: start) >= 0 }
        if isEscaping { return 0 }

        var low: Float = 0
        var high: Float = 1
        for _ in 0..<12 {
            let middle = (low + high) * 0.5
            let candidate = start + (proposedEnd - start) * middle
            if isAllowedStep(from: start, to: candidate, inside: floor, excluding: exclusions) {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }
}
