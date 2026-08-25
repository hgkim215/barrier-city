import Foundation
import simd

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

@main
struct NPCGuestNavigationTests {
    static func main() {
        let floor = NPCGuestArea(center: .zero, axisU: [5, 0], axisV: [0, 5])
        let staff = NPCGuestArea(center: .zero, axisU: [1, 0], axisV: [0, 1])

        expect(NPCGuestNavigation.isValid([3, 3], inside: floor, excluding: [staff]),
               "ordinary floor point must be valid")
        expect(!NPCGuestNavigation.isValid([0, 0], inside: floor, excluding: [staff]),
               "staff area must never be a valid spawn")
        expect(!NPCGuestNavigation.isValid([6, 0], inside: floor, excluding: [staff]),
               "outside-floor point must never be a valid spawn")
        expect(!NPCGuestNavigation.isValid([.nan, 0], inside: floor, excluding: [staff]),
               "non-finite point must never be valid")

        expect(NPCGuestNavigation.isAllowedStep(from: [-3, 2], to: [3, 2],
                                                inside: floor, excluding: [staff]),
               "clear route must remain walkable")
        expect(!NPCGuestNavigation.isAllowedStep(from: [-2, 0], to: [2, 0],
                                                 inside: floor, excluding: [staff]),
               "a large frame step must not tunnel through a restricted area")
        expect(!NPCGuestNavigation.isAllowedStep(from: [4.8, 2], to: [5.2, 2],
                                                 inside: floor, excluding: [staff]),
               "movement must not leave the authored floor")
        expect(NPCGuestNavigation.isAllowedStep(from: [0, 0], to: [0.5, 0],
                                                inside: floor, excluding: [staff]),
               "an intruded NPC must be allowed to move toward the boundary")
        expect(!NPCGuestNavigation.isAllowedStep(from: [0.5, 0], to: [0.25, 0],
                                                 inside: floor, excluding: [staff]),
               "an intruded NPC must not move deeper into a restricted area")

        let fraction = NPCGuestNavigation.allowedFraction(
            from: [-2, 0], to: [2, 0], inside: floor, excluding: [staff])
        expect(fraction > 0.24 && fraction < 0.251,
               "movement must be clipped immediately before the restricted boundary")

        // 실기 재현: 이미 제외 구역 안에 있는 NPC가 아주 작은(한 프레임 크기)
        // 탈출 이동을 시도하면 전체 스텝이 허용돼야 한다. escapeTolerance 도입
        // 전에는 이분 탐색이 Float32 정밀도 밑으로 수렴해 항상 0을 반환했고,
        // 그 결과 NPC가 제자리에서 걷다 멈췄다를 반복(지지거림)했다.
        let tinyEscapeFraction = NPCGuestNavigation.allowedFraction(
            from: [0.5, 0], to: [0.5 + 0.0079, 0], inside: floor, excluding: [staff])
        expect(tinyEscapeFraction == 1,
               "a tiny escaping step out of a restricted area must not be clipped to zero")

        // 실기 재현: 두 끝점 모두 구역 밖이지만 짧은 세그먼트가 모서리를 살짝
        // 스치는 경우(테이블 경계 옆을 걷는 정상적인 한 프레임 이동). 위의 큰
        // 스텝 관통 테스트는 여전히 막혀야 하지만, 이렇게 짧은 스텝까지 관통
        // 검사에 걸려 areaFraction이 0으로 고정되던 문제가 있었다.
        expect(NPCGuestNavigation.isAllowedStep(from: [0.9596, 1.0304], to: [1.0304, 0.9596],
                                                inside: floor, excluding: [staff]),
               "a short step that only grazes a corner must not be treated as tunneling")

        let diagonal = Float(1 / sqrt(2.0))
        let rotated = NPCGuestArea(center: [10, 10],
                                   axisU: [diagonal * 2, diagonal * 2],
                                   axisV: [-diagonal, diagonal])
        expect(rotated.contains([10, 10]), "rotated area must contain its center")
        expect(!rotated.contains([13, 10]), "rotated area must reject a distant point")
    }
}
