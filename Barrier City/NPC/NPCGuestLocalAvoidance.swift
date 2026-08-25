import Foundation
import simd

/// 손님 한 명의 "이번 프레임 기준" 위치·속도 스냅샷. NPCGuestCoordinator.update가
/// 프레임 시작 시점에 전원을 한 번에 캡처해 이웃 배열로 넘긴다 — guest.update가
/// 순서대로 돌며 위치를 바꾸는 동안에도 예측 회피 판단은 항상 "이 프레임 시작
/// 시점" 값만 보게 해, 갱신 순서에 따라 결과가 달라지는 편향을 없앤다(positions/
/// anchors 스냅샷과 동일한 이유 — NPCGuestCoordinator.update 참고).
///
/// position/velocity는 이 코드베이스 전체가 쓰는 관례대로 바닥 평면 좌표다
/// (SIMD2의 x = 월드 X, y = 월드 Z). NPCGuestController.currentPosition,
/// NPCGuestArea 등과 동일한 평면·기저를 그대로 재사용한다 — 높이(Y)는 회피
/// 계산에 전혀 관여하지 않는다.
struct NPCNeighborKinematics {
    let position: SIMD2<Float>
    let velocity: SIMD2<Float>
}

/// 아직 떨어져 있지만 서로 다가오고 있는 두 손님을, 실제로 부딪히기 전에
/// 미리 감지해 진행 방향을 옆으로 살짝 트는 예측 회피(predictive local
/// avoidance)를 계산한다.
///
/// 기존에 이미 있던 두 안전장치와의 역할 차이:
/// - `NPCGuestController.crowdSteeredDirection`은 "지금 가까운" 이웃만 보고
///   반발력을 섞는 즉시 반응(reactive)형이다. 두 NPC가 아직 떨어져 있지만
///   정면으로 접근 중인 상황은 충분히 일찍 판단하지 못해, 부딪히기 직전에야
///   급하게 방향을 틀거나 멈추는 것처럼 보였다.
/// - `NPCObstacleAvoidance.allowedStep`의 원-원 스윕은 실제 겹침을 막는
///   마지막 하드 세이프티 넷이다. 이 레이어가 잘 작동하면 그 하드 클램프가
///   자주 걸리지 않는 게 정상이고, 놓치는 프레임이 있어도 여전히 겹침 자체는
///   막는다.
///
/// 이 레이어는 등속 직선 운동을 가정해 두 NPC가 가장 가까워지는 시점
/// (time-to-closest-approach, TTC)과 그 시점의 예상 거리를 미리 계산하고,
/// 실제로 위험할 때만 진행 방향을 보정한다. path 자체를 바꾸지 않고(A* 재계산
/// 없음), preferredDirection을 살짝 미는 정도로만 개입한다.
enum NPCGuestLocalAvoidance {

    enum Tuning {
        /// 이 시간(초) 이후의 미래는 예측하지 않는다. 너무 길면 아직 방향을
        /// 바꿀 가능성이 큰 먼 미래까지 반응해 불필요하게 자주 피하게 되고,
        /// 너무 짧으면 정면 접근을 너무 늦게 알아채 급하게 꺾이는 것처럼 보인다.
        static let predictionHorizon: Float = 2.5
        /// NPC 한 명의 예측 회피 반경(개인 공간과 별개 — crowdSteeredDirection의
        /// personalSpace는 "지금 거리", 이 값은 "미래 예상 최소 거리" 판정 기준).
        static let collisionPredictionRadius: Float = 0.45
        /// combinedRadius(양쪽 반경 합) 위에 더하는 여유. 경계에 딱 걸쳐 스치는
        /// 정도까지 위험으로 보지 않기 위한 완충.
        static let predictiveAvoidanceMargin: Float = 0.15
        /// 위험이 감지됐을 때 preferredDirection에 섞는 측면 회피 벡터의 최대 배율.
        /// urgency(0...1)에 곱해지므로 실제 세기는 위험도에 비례해 매끄럽게 커진다.
        static let avoidanceStrength: Float = 1.4
        /// 상대 속도의 크기가 이보다 작으면(나란히 같은 속도로 걷거나 둘 다 거의
        /// 정지) 등속 외삽으로 "미래에 더 가까워진다"를 판단할 근거가 없다고 보고
        /// 예측 자체를 건너뛴다 — 이미 가깝다면 즉시 반발(crowdSteeredDirection)이
        /// 처리한다.
        static let minimumRelativeSpeed: Float = 0.05
        /// 이웃 자신의 속도가 이보다 작으면(앉아있거나 배회 중 잠깐 멈춰 선 경우)
        /// 그 이웃은 예측 회피 대상에서 완전히 제외한다. TTC 기반 예측은 원래
        /// "서로 다가오는 두 이동체"를 다루기 위한 것인데, 좌석으로 걸어가는
        /// 손님에게는 목적지 바로 옆에 이미 앉아있는 손님이 항상 있다 — 그 손님을
        /// 계속 "피해야 할 미래 위험"으로 보면 정작 자기 좌석으로는 못 다가가는
        /// 교착 상태(막힘 판정을 아슬아슬하게 피하며 제자리 근처에서 서성이는
        /// 현상)에 빠진다. 이미 가까워진 뒤의 안전은 여전히 즉시 반발
        /// (crowdSteeredDirection)과 하드 세이프티 넷(NPCObstacleAvoidance)이
        /// 정지한 이웃에도 그대로 적용되므로 실제로 부딪히지는 않는다 — 여기서
        /// 빠지는 건 "아직 멀리 있을 때부터 미리 피하기"뿐이다.
        static let minimumNeighborSpeed: Float = 0.15
        /// NPCGuestController.velocity가 프레임 간 실이동량 기반으로 갱신될 때
        /// 쓰는 지수 평활 속도(초당 수렴 비율). alpha = min(1, velocitySmoothing
        /// * deltaTime) 형태로 프레임 레이트와 무관하게 동작한다.
        static let velocitySmoothing: Float = 12
    }

    /// 한 번의 예측 충돌 판정 결과.
    struct CollisionRisk {
        /// 등속 가정 하에 가장 가까워지는 시점(초, 0...predictionHorizon로 클램프됨).
        let timeToClosestApproach: Float
        /// 그 시점의 예상 거리(m).
        let closestDistance: Float
        /// 0(위험 없음 경계)...1(임박) 정규화된 위험도. TTC가 짧을수록, 예상 최소
        /// 거리가 반경 안쪽 깊이 들어올수록 1에 가까워진다.
        let urgency: Float
    }

    /// 나(내 위치·속도)와 neighbor가 등속 직선 운동을 계속한다고 가정했을 때
    /// 미래에 위험할 만큼 가까워지는지 판정한다.
    ///
    /// 반드시 nil을 반환해야 하는 경우(모두 코드 안에서 직접 처리한다 — 0으로
    /// 나누거나 NaN을 만들지 않는다):
    /// - 상대 속도가 거의 0(나란히 걷거나 둘 다 정지) → 외삽으로 판단할 근거 없음.
    /// - 가장 가까워지는 시점이 이미 과거(서로 멀어지는 중) → rawTimeToClosest ≤ 0.
    /// - 예측 구간(predictionHorizon) 안에서도 예상 최소 거리가 회피 반경보다 큼.
    ///
    /// "이미 personal space 내부"인 경우는 의도적으로 별도 분기를 두지 않는다 —
    /// 그 상황에서도 상대 속도가 여전히 발산 방향이면(rawTimeToClosest ≤ 0) 자연히
    /// nil이 되어 즉시 반발(crowdSteeredDirection) 쪽으로 책임이 넘어가고, 계속
    /// 다가오는 중이면 이 함수가 정상적으로 강한 urgency를 반환한다.
    ///
    /// neighbor.velocity가 minimumNeighborSpeed보다 느리면(앉아있거나 잠깐 멈춰
    /// 선 경우) 예측 자체를 건너뛴다 — Tuning.minimumNeighborSpeed 주석 참고.
    static func predictCollision(
        myPosition: SIMD2<Float>,
        myVelocity: SIMD2<Float>,
        neighbor: NPCNeighborKinematics
    ) -> CollisionRisk? {
        guard simd_length_squared(neighbor.velocity)
            > Tuning.minimumNeighborSpeed * Tuning.minimumNeighborSpeed else {
            return nil
        }
        let relativePosition = neighbor.position - myPosition
        let relativeVelocity = neighbor.velocity - myVelocity
        let relativeSpeedSquared = simd_length_squared(relativeVelocity)
        guard relativeSpeedSquared > Tuning.minimumRelativeSpeed * Tuning.minimumRelativeSpeed else {
            return nil
        }

        let rawTimeToClosest = -simd_dot(relativePosition, relativeVelocity) / relativeSpeedSquared
        guard rawTimeToClosest.isFinite, rawTimeToClosest > 0 else { return nil }
        let timeToClosest = min(rawTimeToClosest, Tuning.predictionHorizon)

        let futureRelativePosition = relativePosition + relativeVelocity * timeToClosest
        let closestDistance = simd_length(futureRelativePosition)
        guard closestDistance.isFinite else { return nil }

        let combinedRadius = Tuning.collisionPredictionRadius * 2 + Tuning.predictiveAvoidanceMargin
        guard closestDistance < combinedRadius else { return nil }

        // 둘 다 0...1로 정규화해 곱한다: TTC가 predictionHorizon 근처면(막 감지된
        // 상황) 거의 0에서 시작해 갑자기 방향이 튀지 않고, 반경 경계에 딱 걸치기만
        // 해도(proximityUrgency≈0) 마찬가지로 약하게 시작한다. 둘 다 임박해야
        // urgency가 1에 가까워진다.
        let ttcUrgency = 1 - min(1, timeToClosest / Tuning.predictionHorizon)
        let proximityUrgency = 1 - min(1, closestDistance / combinedRadius)
        let urgency = ttcUrgency * proximityUrgency

        return CollisionRisk(timeToClosestApproach: timeToClosest,
                             closestDistance: closestDistance,
                             urgency: urgency)
    }

    /// preferredDirection(정규화된 벡터 권장, 정규화 안 돼 있어도 내부에서
    /// 다시 정규화한다)을 예측 회피로 보정한다.
    ///
    /// 회피 방향은 매 프레임 기하학적으로 다시 계산하지 않고, 호출부가 넘긴
    /// `sidePreference`(NPCGuestController.movementProfile.separationSide,
    /// 생성 시 한 번 정해져 그 NPC가 평생 유지하는 값)만으로 결정한다. 정면으로
    /// 마주친 상황에서 좌/우 기하학적 판정은 근소한 차이로도 뒤집힐 수 있어,
    /// 프레임마다(또는 심지어 매번 새로 굴린 난수로) 다시 계산하면 "왼쪽→오른쪽
    /// →왼쪽"으로 흔들리는 진동이 생긴다. 손님마다 고정된 방향 선호를 쓰면 같은
    /// NPC는 항상 같은 쪽으로 비켜서므로 진동이 구조적으로 발생하지 않는다.
    ///
    /// 위험이 없으면 preferredDirection을 그대로(정규화만 해서) 반환한다.
    /// 결과는 아직 crowdSteeredDirection(즉시 반발)을 거치지 않은 "보정된 선호
    /// 방향"이다 — 호출부가 이어서 crowdSteeredDirection에 넘겨 최종 조향
    /// 방향을 만든다(Path Direction → Predictive Avoidance → Immediate
    /// Separation → Final Steering 순서, NPCGuestController.move 참고).
    static func adjustedPreferredDirection(
        preferredDirection: SIMD2<Float>,
        myPosition: SIMD2<Float>,
        myVelocity: SIMD2<Float>,
        sidePreference: Float,
        neighbors: [NPCNeighborKinematics],
        strengthScale: Float
    ) -> SIMD2<Float> {
        let preferredLength = simd_length(preferredDirection)
        guard preferredLength > 0.0001 else { return preferredDirection }
        let normalizedPreferred = preferredDirection / preferredLength

        var totalUrgency: Float = 0
        for neighbor in neighbors {
            guard let risk = predictCollision(
                myPosition: myPosition, myVelocity: myVelocity, neighbor: neighbor
            ) else { continue }
            totalUrgency += risk.urgency
        }
        guard totalUrgency > 0.0001 else { return normalizedPreferred }

        // 진행 방향 기준 좌/우 측면 벡터. side는 항상 이 NPC 고유의 고정값이라
        // 여러 이웃이 동시에 위험해도 방향이 뒤섞이지 않고 한쪽으로만 밀린다.
        let lateral = SIMD2(normalizedPreferred.y, -normalizedPreferred.x) * sidePreference
        let avoidance = lateral * min(totalUrgency, 1) * Tuning.avoidanceStrength * strengthScale

        let combined = normalizedPreferred + avoidance
        let combinedLength = simd_length(combined)
        return combinedLength > 0.0001 ? combined / combinedLength : normalizedPreferred
    }
}
