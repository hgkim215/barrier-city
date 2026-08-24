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

    private func localCoordinates(of point: SIMD2<Float>) -> SIMD2<Float>? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let offset = point - center
        let determinant = axisU.x * axisV.y - axisU.y * axisV.x
        guard abs(determinant) > 0.000001 else { return nil }
        return SIMD2(
            (offset.x * axisV.y - offset.y * axisV.x) / determinant,
            (axisU.x * offset.y - axisU.y * offset.x) / determinant)
    }
}

enum NPCGuestNavigation {
    static func isValid(_ point: SIMD2<Float>,
                        inside floor: NPCGuestArea,
                        excluding exclusions: [NPCGuestArea]) -> Bool {
        floor.contains(point) && !exclusions.contains(where: { $0.contains(point) })
    }

    /// 현재 위치가 정상이라면 바닥 밖/금지 구역 안으로 한 발짝도 들어가지 못하게 한다.
    /// 이미 잘못된 위치라면 위반 깊이가 감소하는 탈출 이동만 예외적으로 허용한다.
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
            guard endFloorDepth > startFloorDepth else { return false }
        }

        for exclusion in exclusions {
            let startDepth = exclusion.interiorDepth(of: start)
            let endDepth = exclusion.interiorDepth(of: end)
            if startDepth >= 0 {
                guard endDepth < startDepth else { return false }
            } else {
                guard endDepth < 0,
                      !exclusion.intersectsSegment(from: start, to: end) else { return false }
            }
        }
        return true
    }

    /// 전체 이동이 불가능하면 이분 탐색으로 경계 직전까지의 안전한 비율을 구한다.
    static func allowedFraction(from start: SIMD2<Float>,
                                to proposedEnd: SIMD2<Float>,
                                inside floor: NPCGuestArea,
                                excluding exclusions: [NPCGuestArea]) -> Float {
        if isAllowedStep(from: start, to: proposedEnd, inside: floor, excluding: exclusions) {
            return 1
        }
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
