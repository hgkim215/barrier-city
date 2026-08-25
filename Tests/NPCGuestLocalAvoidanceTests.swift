import Foundation
import simd

private func fail(_ message: String) -> Never {
    fatalError("FAIL: \(message)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

@main
struct NPCGuestLocalAvoidanceTests {
    static func main() {
        headOnApproachIsDetectedAndLateralized()
        parallelSameVelocityIsIgnored()
        divergingPairIsIgnored()
        crossingPathsAreDetectedBeforeIntersection()
        stationaryNeighborIsHandledWithoutNaN()
        closeButDivergingIsIgnoredDespiteShortDistance()
        avoidanceNeverReversesPreferredDirection()
        sidePreferenceIsDeterministicNotGeometric()
        farAwayOrSlowNeighborsProduceNoRisk()
        print("All NPCGuestLocalAvoidance tests passed.")
    }

    // MARK: - 1. 정면 충돌: A ---> <--- B

    private static func headOnApproachIsDetectedAndLateralized() {
        // 1m씩 떨어져 마주 걷는 손님 속도(1m/s)로 접근 — 남은 접근 시간(TTC≈1s)이
        // predictionHorizon(2.5s)보다 충분히 짧아야 "임박한" 위험으로 취급된다.
        let me = SIMD2<Float>(-1, 0)
        let myVelocity = SIMD2<Float>(1, 0)
        let neighbor = NPCNeighborKinematics(position: [1, 0], velocity: [-1, 0])

        guard let risk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: me, myVelocity: myVelocity, neighbor: neighbor
        ) else {
            fail("head-on approach within radius must be detected as a collision risk")
        }
        expect(risk.timeToClosestApproach > 0, "closest approach must be in the future")
        expect(risk.closestDistance < 0.05, "head-on straight-line approach must close to ~0 distance")
        expect(risk.urgency > 0.5, "an imminent head-on approach must have high urgency")

        let adjusted = NPCGuestLocalAvoidance.adjustedPreferredDirection(
            preferredDirection: [1, 0], myPosition: me, myVelocity: myVelocity,
            sidePreference: 1, neighbors: [neighbor], strengthScale: 1)
        expect(abs(adjusted.y) > 0.05, "an imminent head-on risk must introduce a lateral component")
        expect(abs(simd_length(adjusted) - 1) < 0.001, "adjusted direction must stay normalized")
    }

    // MARK: - 2. Parallel, same velocity, comfortable distance

    private static func parallelSameVelocityIsIgnored() {
        let neighbor = NPCNeighborKinematics(position: [0, 3], velocity: [1, 0])
        let risk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: [0, 0], myVelocity: [1, 0], neighbor: neighbor)
        expect(risk == nil,
               "identical relative velocity gives no closing trajectory to extrapolate from")
    }

    // MARK: - 3. 서로 멀어짐: A <----   ----> B

    private static func divergingPairIsIgnored() {
        let neighbor = NPCNeighborKinematics(position: [1, 0], velocity: [1, 0])
        let risk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: [-1, 0], myVelocity: [-1, 0], neighbor: neighbor)
        expect(risk == nil, "a pair moving apart must not be treated as a future collision")
    }

    // MARK: - 4. 교차 경로

    private static func crossingPathsAreDetectedBeforeIntersection() {
        // 나는 +X로 이동, neighbor는 위에서 -Z로 내려와 같은 교차점(원점) 근처를 지난다.
        let me = SIMD2<Float>(-3, 0)
        let myVelocity = SIMD2<Float>(1, 0)
        let neighbor = NPCNeighborKinematics(position: [0, 3], velocity: [0, -1])
        guard let risk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: me, myVelocity: myVelocity, neighbor: neighbor
        ) else {
            fail("crossing paths that meet near the same point must be flagged before intersection")
        }
        expect(risk.timeToClosestApproach > 0 && risk.timeToClosestApproach < 3.5,
               "the crossing must be predicted to happen within a reasonable horizon")
    }

    // MARK: - 5. 정지 NPC — 0으로 나누거나 NaN이 없어야 한다

    private static func stationaryNeighborIsHandledWithoutNaN() {
        let neighbor = NPCNeighborKinematics(position: [1.5, 0], velocity: .zero)
        guard let risk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: [0, 0], myVelocity: [1, 0], neighbor: neighbor
        ) else {
            fail("walking straight into a stationary neighbor must be detected")
        }
        expect(!risk.timeToClosestApproach.isNaN && !risk.closestDistance.isNaN && !risk.urgency.isNaN,
               "stationary-neighbor prediction must never produce NaN")

        // 완전히 같은 위치(상대 위치 0)에서도 나눗셈이 안전해야 한다.
        let overlapping = NPCNeighborKinematics(position: [0, 0], velocity: .zero)
        let overlapRisk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: [0, 0], myVelocity: [1, 0], neighbor: overlapping)
        if let overlapRisk {
            expect(!overlapRisk.urgency.isNaN, "exact overlap must not produce NaN urgency")
        }

        // 나 자신이 정지해 있어도(상대속도 = neighbor 속도만 남는 경우) 안전해야 한다.
        let bothStationary = NPCNeighborKinematics(position: [0.3, 0], velocity: .zero)
        let stillRisk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: [0, 0], myVelocity: .zero, neighbor: bothStationary)
        expect(stillRisk == nil,
               "two mutually stationary NPCs have zero relative speed and must be skipped, not NaN")
    }

    // MARK: - 6. 가까이 있지만 멀어지는 두 NPC — 거리만 보면 오탐하기 쉬운 케이스

    private static func closeButDivergingIsIgnoredDespiteShortDistance() {
        // 현재 거리는 0.3m(회피 반경보다 훨씬 가까움)이지만 서로 반대 방향으로 빠르게 멀어진다.
        let neighbor = NPCNeighborKinematics(position: [0.3, 0], velocity: [3, 0])
        let risk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: [0, 0], myVelocity: [-3, 0], neighbor: neighbor)
        expect(risk == nil,
               "current proximity alone must not trigger prediction when the pair is separating fast")
    }

    // MARK: - 7. Destination 유지: 회피가 걸려도 목적지 반대 방향으로 뒤집히면 안 된다

    private static func avoidanceNeverReversesPreferredDirection() {
        let me = SIMD2<Float>(0, 0)
        let myVelocity = SIMD2<Float>(1, 0)
        // 여러 이웃이 동시에 강하게 위협하는 최악의 경우를 만든다.
        let neighbors = [
            NPCNeighborKinematics(position: [0.4, 0], velocity: [-1, 0]),
            NPCNeighborKinematics(position: [0.5, 0.05], velocity: [-1, 0]),
            NPCNeighborKinematics(position: [0.45, -0.05], velocity: [-1, 0]),
        ]
        let adjusted = NPCGuestLocalAvoidance.adjustedPreferredDirection(
            preferredDirection: [1, 0], myPosition: me, myVelocity: myVelocity,
            sidePreference: 1, neighbors: neighbors, strengthScale: 1)
        expect(simd_dot(adjusted, [1, 0]) > 0,
               "predictive avoidance must steer sideways, never reverse the preferred travel direction")
    }

    // MARK: - Deterministic side preference: 기하학이 아니라 NPC 고유값으로 방향이 정해진다

    private static func sidePreferenceIsDeterministicNotGeometric() {
        let me = SIMD2<Float>(-1, 0)
        let myVelocity = SIMD2<Float>(1, 0)
        let neighbor = NPCNeighborKinematics(position: [1, 0], velocity: [-1, 0])

        let sideOne = NPCGuestLocalAvoidance.adjustedPreferredDirection(
            preferredDirection: [1, 0], myPosition: me, myVelocity: myVelocity,
            sidePreference: 1, neighbors: [neighbor], strengthScale: 1)
        let sideOther = NPCGuestLocalAvoidance.adjustedPreferredDirection(
            preferredDirection: [1, 0], myPosition: me, myVelocity: myVelocity,
            sidePreference: -1, neighbors: [neighbor], strengthScale: 1)
        expect(abs(sideOne.y) > 0.01 && abs(sideOther.y) > 0.01 && sideOne.y.sign != sideOther.y.sign,
               "flipping sidePreference must flip the lateral avoidance side, not geometry")

        // 같은 입력을 반복 호출해도 항상 같은 결과(순수 함수, 난수 없음).
        let repeated = NPCGuestLocalAvoidance.adjustedPreferredDirection(
            preferredDirection: [1, 0], myPosition: me, myVelocity: myVelocity,
            sidePreference: 1, neighbors: [neighbor], strengthScale: 1)
        expect(sideOne == repeated, "avoidance must be deterministic across repeated calls")
    }

    // MARK: - 멀리 있거나 예측 구간을 벗어나는 이웃은 무시된다

    private static func farAwayOrSlowNeighborsProduceNoRisk() {
        // predictionHorizon(2.5s)보다 훨씬 뒤에야 스칠 만큼 먼 이웃.
        let farNeighbor = NPCNeighborKinematics(position: [50, 0], velocity: [-1, 0])
        let risk = NPCGuestLocalAvoidance.predictCollision(
            myPosition: [0, 0], myVelocity: [1, 0], neighbor: farNeighbor)
        expect(risk == nil, "a neighbor that only closes in far beyond the prediction horizon must be ignored")

        let noNeighbors = NPCGuestLocalAvoidance.adjustedPreferredDirection(
            preferredDirection: [1, 0], myPosition: [0, 0], myVelocity: [1, 0],
            sidePreference: 1, neighbors: [], strengthScale: 1)
        expect(noNeighbors == SIMD2<Float>(1, 0),
               "with no neighbors the preferred direction must pass through unchanged")

        let zeroPreferred = NPCGuestLocalAvoidance.adjustedPreferredDirection(
            preferredDirection: .zero, myPosition: [0, 0], myVelocity: [1, 0],
            sidePreference: 1, neighbors: [farNeighbor], strengthScale: 1)
        expect(zeroPreferred == SIMD2<Float>.zero,
               "a degenerate zero preferred direction must be returned as-is, not NaN")
    }
}
