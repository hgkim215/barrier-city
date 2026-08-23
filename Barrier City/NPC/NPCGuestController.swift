import Foundation
import RealityKit
import simd

/// Indoor.usda의 Guest_* AnimationLibrary에 등록된 애니메이션 키.
/// Idle은 Barista와 동일하게 *Idle.usdz의 default subtree animation을 그대로 쓴다.
/// "Sit_to_Stand"는 AnimationLibrary def 블록 이름을 그대로 쓴 것으로, authored된
/// "Sit to Stand"라는 표시용 name과는 다르다(라이브러리 조회는 def 이름 기준).
enum NPCGuestAnimationCue: String {
    case idle = "Idle"
    case walk = "Walk"
    case sitting = "Sitting"
    case sitToStand = "Sit_to_Stand"
    case angry = "Angry"

    var repeats: Bool {
        switch self {
        case .idle, .walk, .sitting, .angry: true
        case .sitToStand: false
        }
    }
}

/// 손님 한 명이 대기줄/착석 행동에 참여하는 방식. 세 역할은 서로 섞이지 않는
/// 고정된 카테고리다.
enum NPCGuestRole {
    /// 절대 앉지 않고 계속 배회한다. 대기줄 후보.
    case alwaysWandering
    /// 배회↔착석↔기립을 랜덤한 타이밍(손님마다 다른 확률·지속시간)으로 반복한다.
    /// 배회 중일 때만 대기줄 후보.
    case cycler
    /// 입장 시 가능하면 이미 앉은 채로 시작하고, 한 번 앉으면 다시 일어나지 않는
    /// "그냥 앉아만 있는" 손님이다. 좌석이 부족해 배회로 시작하더라도 자리를
    /// 잡으면 그 뒤로는 영구히 앉아있는다. 대기줄 후보에서는 항상 제외된다.
    case seatedPool
}

/// 성별에 따라 재생할 한숨(sigh) 효과음 리소스가 갈린다.
enum NPCGuestGender {
    case male
    case female

    var sighResourceName: String {
        switch self {
        case .male: "male_sigh"
        case .female: "female_sigh"
        }
    }
}

/// 손님 NPC 한 명의 배치·이동·애니메이션을 담당한다. 대화·근접 감지는 다루지 않는
/// 순수 동선 담당 컨트롤러로, 대화까지 책임지는 NPCClerkController와 역할을 분리한다.
@MainActor
final class NPCGuestController {
    enum NPCGuestTuning {
        static let turnResponse: Float = 6
        static let arrivalDistance: Float = 0.05
        static let queueArrivalDistance: Float = 0.12
        static let minimumRoamDistance: Float = 0.8
        /// Blender/RealityKit 축 변환 보정용. 모델의 정면이 다르면 이 값을 조정한다.
        static let forwardYawOffset: Float = .pi
        /// 가구 회피 레이 폭 방향 샘플 간격(콜리전 박스 절반 폭과 대략 맞춘다).
        static let bodyHalfWidth: Float = 0.2
        /// 원하는 이동 폭 대비 실제로 이동 가능한 폭이 이 비율보다 작으면 "막혔다"로
        /// 보고 현재 목적지를 버려 벽/가구 앞에서 제자리걸음하지 않게 한다.
        static let blockedStepFraction: Float = 0.15
        /// 자유 배회 목적지끼리 이 정도 간격을 우선 확보한다.
        static let preferredTargetSeparation: Float = 1.35
        /// 좌석 도착 판정 거리.
        static let seatArrivalDistance: Float = 0.08
        /// "Sit to Stand" 클립 재생으로 간주하는 시간(초). 애니메이션 완료 콜백 대신
        /// 다른 NPC 상태 전환과 동일하게 타이머 기반으로 처리한다.
        static let standingUpDuration: Float = 1.2
        /// 이 시간 동안 배회 목적지에 도착하지 못하면(가구를 완전히 막힌 채 스치듯
        /// 지나가는 등, 매 프레임 "막혔다" 판정까지는 안 걸리지만 실제로는 못 가는
        /// 경우) 포기하고 다음 프레임에 새 목적지를 고른다.
        static let wanderStuckTimeout: Float = 6.0
        /// 좌석으로 이동 중 이 시간 동안 도착하지 못하면 그 좌석을 포기하고
        /// 배회로 돌아간다(좌석은 코디네이터가 다른 손님에게 다시 배정할 수 있게 반환).
        static let seatApproachStuckTimeout: Float = 8.0
    }

    private enum SeatState {
        case none
        case movingToSeat
        case sitting
        case standingUp
    }

    /// 전원이 같은 속도와 정지 주기로 움직이면 군무처럼 보인다. 손님마다 생성 시 한 번
    /// 서로 다른 보행 성향을 부여해 이후 프레임에서는 안정적으로 유지한다.
    private struct MovementProfile {
        let moveSpeed: Float
        let pauseRange: ClosedRange<Float>
        let personalSpace: Float
        let separationStrength: Float
        let separationSide: Float
        /// 배회 목적지에 도착할 때마다 착석을 시도할 확률(cycler 개인차). 전원이 같은
        /// 확률로 앉으면 기계적으로 보여, 손님마다 성향을 다르게 둔다.
        let sitDesireChance: Float
        /// 한 번 앉으면 머무는 시간(cycler 개인차).
        let sittingDurationRange: ClosedRange<Float>

        static func random() -> MovementProfile {
            let pauseMinimum = Float.random(in: 0.7...2.2)
            let sittingMinimum = Float.random(in: 5...12)
            return MovementProfile(
                moveSpeed: Float.random(in: 0.68...1.02),
                pauseRange: pauseMinimum...Float.random(in: 3.8...7.0),
                personalSpace: Float.random(in: 0.62...0.82),
                separationStrength: Float.random(in: 0.85...1.25),
                separationSide: Bool.random() ? 1 : -1,
                sitDesireChance: Float.random(in: 0.2...0.55),
                sittingDurationRange: sittingMinimum...Float.random(in: 16...30))
        }
    }

    private(set) var name: String
    let role: NPCGuestRole
    let gender: NPCGuestGender
    private var locomotionRoot: Entity?
    private var modelEntity: Entity?
    private var animationPlayback: AnimationPlaybackController?
    private var currentCue: NPCGuestAnimationCue?
    private var wanderTarget: SIMD2<Float>?
    private var pauseRemaining: Float = 0
    private let movementProfile: MovementProfile
    /// 지금 쫓고 있는 목적지(배회 목적지든 좌석이든)를 얼마나 오래 쫓고 있는지.
    /// 두 상태가 동시에 벌어지지 않아 하나의 타이머를 공유한다. 새 목적지를
    /// 잡거나 도착/포기할 때마다 0으로 되돌린다.
    private var pursuitElapsed: Float = 0

    private var seatState: SeatState = .none
    private var claimedSeatIndex: Int?
    private var claimedSeat: GuestSeat?
    private var seatTimeRemaining: Float = 0
    /// 코디네이터가 다음 프레임에 한 번만 소비하는 원샷 신호. 착석을 원한다는 요청과,
    /// 방금 자리를 비웠다는 통지에 쓴다(takeSeatRequest/takeVacatedSeatIndex 참고).
    private var pendingSeatRequest = false
    private var pendingVacatedSeatIndex: Int?
    /// 대기줄 자리에 막 도착한 프레임에 한 번만 서는 원샷 신호(takeQueueArrivalSignal).
    private var pendingQueueArrival = false
    /// pendingQueueArrival을 한 번만 세우기 위한 상태 추적(도착해 있는 동안 매 프레임
    /// 다시 세우지 않도록).
    private var hasReportedQueueArrival = false
    private static var cachedSighResources: [NPCGuestGender: AudioFileResource] = [:]

    init(name: String, role: NPCGuestRole = .cycler, gender: NPCGuestGender = .female) {
        self.name = name
        self.role = role
        self.gender = gender
        movementProfile = .random()
    }

    /// 대기줄 후보 자격: 착석 지향(seatedPool) 역할이 아니고, 지금 이동/착석/기립
    /// 중이 아닐 때만(= 배회 중일 때만) 후보가 된다.
    var isQueueEligible: Bool {
        role != .seatedPool && seatState == .none
    }

    /// 코디네이터가 이번 프레임에 착석을 원하는지 확인할 때 한 번만 읽고 소비한다.
    func takeSeatRequest() -> Bool {
        defer { pendingSeatRequest = false }
        return pendingSeatRequest
    }

    /// 코디네이터가 빈 좌석을 찾아 배정할 때 호출한다.
    func grantSeat(index: Int, seat: GuestSeat) {
        claimedSeatIndex = index
        claimedSeat = seat
        seatState = .movingToSeat
        wanderTarget = nil
        pauseRemaining = 0
        pursuitElapsed = 0
    }

    /// 방금 자리를 비웠으면 그 좌석 인덱스를 반환하고 소비한다. 코디네이터가 이걸로
    /// seatOccupants를 비운다.
    func takeVacatedSeatIndex() -> Int? {
        defer { pendingVacatedSeatIndex = nil }
        return pendingVacatedSeatIndex
    }

    /// 대기줄 자리에 막 도착했으면(이번 대기 세션 중 처음 한 번만) true를 반환하고
    /// 소비한다.
    func takeQueueArrivalSignal() -> Bool {
        defer { pendingQueueArrival = false }
        return pendingQueueArrival
    }

    /// 성별에 맞는 한숨 소리를 자신의 위치에서 한 번 재생한다(공간 음향이라 유저
    /// 뒤에서 나는 것처럼 들린다). 리소스는 타입 전체가 공유하는 캐시에 한 번만
    /// 로드해 재사용한다.
    func playSigh() {
        guard let root = locomotionRoot else { return }
        let gender = self.gender
        Task { @MainActor in
            let resource: AudioFileResource
            if let cached = Self.cachedSighResources[gender] {
                resource = cached
            } else {
                guard let url = Bundle.main.url(forResource: gender.sighResourceName, withExtension: "mp3"),
                      let loaded = try? await AudioFileResource(
                        contentsOf: url, configuration: .init(shouldLoop: false)) else { return }
                resource = loaded
                Self.cachedSighResources[gender] = loaded
            }
            root.playAudio(resource)
        }
    }

    /// locomotion wrapper 생성과 발 기준 정렬을 공통화한다(place/placeSeated 공용).
    private func setUpLocomotionRoot(entity: Entity, worldRoot: Entity, at position: SIMD2<Float>) {
        entity.removeFromParent()

        let locomotion = Entity()
        locomotion.name = "\(name)LocomotionRoot"
        locomotion.position = [position.x, 0, position.y]

        let modelAlignment = Entity()
        modelAlignment.name = "\(name)ModelAlignment"
        modelAlignment.addChild(entity)
        locomotion.addChild(modelAlignment)
        let bounds = entity.visualBounds(relativeTo: modelAlignment)
        modelAlignment.position = [-bounds.center.x, -bounds.min.y, -bounds.center.z]

        entity.applyNPCBodyCollision(group: AppModel.npcGroup)

        worldRoot.addChild(locomotion)
        locomotionRoot = locomotion
        modelEntity = entity
        wanderTarget = nil
    }

    /// Indoor.usda에서 찾은 손님 엔티티를 이동 wrapper로 감싸 worldRoot에 배치한다.
    /// Barista 배치(NPCClerkController.enterIndoor)와 동일한 발 기준 정렬 방식을 쓴다.
    func place(entity: Entity, worldRoot: Entity, at position: SIMD2<Float>) {
        setUpLocomotionRoot(entity: entity, worldRoot: worldRoot, at: position)
        // 진입 직후 전원이 동시에 걷기 시작하지 않도록 첫 출발 시점을 넓게 흩뜨린다.
        pauseRemaining = Float.random(in: 0...4.5)
        playAnimation(.idle)
    }

    /// 입장 시점부터 이미 지정된 좌석에 앉아있는 상태로 배치한다(seatedPool 역할용).
    /// 걸어가는 과정 없이 좌석 위치/방향으로 바로 배치한다. seatedPool은 계속 앉아만
    /// 있어야 하므로(updateSitting 참고) seatTimeRemaining은 쓰이지 않는다.
    func placeSeated(entity: Entity, worldRoot: Entity, seatIndex: Int, seat: GuestSeat) {
        setUpLocomotionRoot(entity: entity, worldRoot: worldRoot, at: seat.position)
        pauseRemaining = 0
        claimedSeatIndex = seatIndex
        claimedSeat = seat
        seatState = .sitting
        face(direction: seat.facing, deltaTime: 999)
        playAnimation(.sitting)
    }

    func teardown() {
        animationPlayback?.stop()
        animationPlayback = nil
        locomotionRoot?.removeFromParent()
        locomotionRoot = nil
        modelEntity = nil
        currentCue = nil
        wanderTarget = nil
        seatState = .none
        claimedSeatIndex = nil
        claimedSeat = nil
        pendingSeatRequest = false
        pendingVacatedSeatIndex = nil
        pendingQueueArrival = false
        hasReportedQueueArrival = false
    }

    var currentPosition: SIMD2<Float> {
        guard let root = locomotionRoot else { return .zero }
        return SIMD2(root.position.x, root.position.z)
    }

    /// 다른 손님이 다음 목적지를 고를 때 현재 위치뿐 아니라 이미 선택된 목적지도 피한다.
    var crowdAnchor: SIMD2<Float> { wanderTarget ?? currentPosition }

    /// queueSlot이 있으면 그 지점으로 이동해 대기하고, 없으면 wanderArea 안에서
    /// exclusions(직원 구역 등)를 피해 자유롭게 걸어 다닌다.
    func update(deltaTime: Float,
               wanderArea: NPCGuestArea,
               exclusions: [NPCGuestArea],
               queueSlot: SIMD2<Float>?,
               facing facingTarget: SIMD2<Float>?,
               playerPosition: SIMD2<Float>,
               neighboringPositions: [SIMD2<Float>],
               occupiedAnchors: [SIMD2<Float>]) {
        guard locomotionRoot != nil else { return }

        switch seatState {
        case .movingToSeat:
            updateMovingToSeat(deltaTime: deltaTime,
                               playerPosition: playerPosition,
                               neighboringPositions: neighboringPositions,
                               exclusions: exclusions)
            return
        case .sitting:
            updateSitting(deltaTime: deltaTime)
            return
        case .standingUp:
            updateStandingUp(deltaTime: deltaTime)
            return
        case .none:
            break
        }

        if let queueSlot {
            // 대기줄은 의도적으로 유저 바로 뒤까지 다가가야 하므로, 평소 배회에서
            // 유저 몸에 안 걸어 들어가게 막는 반경 회피는 여기서만 끈다.
            let outcome = move(toward: queueSlot, deltaTime: deltaTime,
                               arrivalDistance: NPCGuestTuning.queueArrivalDistance,
                               playerPosition: playerPosition,
                               neighboringPositions: neighboringPositions,
                               separationScale: 0.35,
                               exclusions: exclusions,
                               avoidPlayer: false)
            if outcome.arrived {
                // 대기줄에 서서 기다리는 동안은 살짝 짜증난 티를 낸다(Idle 대신 Angry 루프).
                playAnimation(.angry)
                if let facingTarget { face(point: facingTarget, deltaTime: deltaTime) }
                if !hasReportedQueueArrival {
                    hasReportedQueueArrival = true
                    pendingQueueArrival = true
                }
            } else {
                playAnimation(outcome.moved ? .walk : .idle)
            }
            return
        }
        hasReportedQueueArrival = false

        if pauseRemaining > 0 {
            pauseRemaining = max(0, pauseRemaining - deltaTime)
            playAnimation(.idle)
            return
        }
        if wanderTarget == nil {
            wanderTarget = randomWanderTarget(
                in: wanderArea,
                excluding: exclusions,
                awayFrom: currentPosition,
                avoiding: occupiedAnchors)
            pursuitElapsed = 0
        }
        guard let target = wanderTarget else {
            playAnimation(.idle)
            return
        }
        // 매 프레임 "막혔다" 판정(move() 내부)까지는 안 걸리더라도, 가구를 스치듯
        // 지나가며 아주 조금씩만 전진하는 경우 목적지에 영영 못 닿을 수 있다. 한
        // 목적지를 너무 오래 쫓고 있으면 포기하고 다음 프레임에 새 목적지를 고른다.
        pursuitElapsed += deltaTime
        if pursuitElapsed > NPCGuestTuning.wanderStuckTimeout {
            wanderTarget = nil
            pursuitElapsed = 0
            pauseRemaining = Float.random(in: 0.2...0.6)
            playAnimation(.idle)
            return
        }
        let outcome = move(toward: target, deltaTime: deltaTime,
                           arrivalDistance: NPCGuestTuning.arrivalDistance,
                           playerPosition: playerPosition,
                           neighboringPositions: neighboringPositions,
                           separationScale: 1,
                           exclusions: exclusions)
        if outcome.arrived {
            wanderTarget = nil
            pursuitElapsed = 0
            pauseRemaining = Float.random(in: movementProfile.pauseRange)
            playAnimation(.idle)
            // 목적지 도착이라는 자연스러운 결정 지점에서만 착석 여부를 굴린다.
            // alwaysWandering 역할은 절대 앉지 않는다. 확률은 손님마다 달라(개인차) 전원이
            // 기계적으로 같은 타이밍에 앉지 않게 한다.
            if role != .alwaysWandering, Float.random(in: 0...1) < movementProfile.sitDesireChance {
                pendingSeatRequest = true
            }
        } else {
            // 실제로 위치가 움직인 프레임에만 Walk를 재생한다. 장애물에 막혀 제자리인
            // 프레임까지 Walk를 계속 재생하면 제자리걸음처럼 보인다.
            playAnimation(outcome.moved ? .walk : .idle)
        }
    }

    // MARK: - Seating

    private func updateMovingToSeat(deltaTime: Float,
                                    playerPosition: SIMD2<Float>,
                                    neighboringPositions: [SIMD2<Float>],
                                    exclusions: [NPCGuestArea]) {
        guard let seat = claimedSeat else { seatState = .none; return }
        pursuitElapsed += deltaTime
        if pursuitElapsed > NPCGuestTuning.seatApproachStuckTimeout {
            // 좌석까지 너무 오래 못 가면 포기하고 자리를 반납한다(코디네이터가
            // seatOccupants를 비워 다른 손님에게 다시 배정할 수 있게 한다).
            pendingVacatedSeatIndex = claimedSeatIndex
            claimedSeatIndex = nil
            claimedSeat = nil
            seatState = .none
            pursuitElapsed = 0
            pauseRemaining = Float.random(in: 0.3...1.0)
            playAnimation(.idle)
            return
        }
        let outcome = move(toward: seat.position, deltaTime: deltaTime,
                           arrivalDistance: NPCGuestTuning.seatArrivalDistance,
                           playerPosition: playerPosition,
                           neighboringPositions: neighboringPositions,
                           separationScale: 0.5,
                           exclusions: exclusions)
        if outcome.arrived {
            seatState = .sitting
            pursuitElapsed = 0
            seatTimeRemaining = Float.random(in: movementProfile.sittingDurationRange)
            face(direction: seat.facing, deltaTime: 999)
            playAnimation(.sitting)
        } else {
            playAnimation(outcome.moved ? .walk : .idle)
        }
    }

    private func updateSitting(deltaTime: Float) {
        // seatedPool은 한 번 앉으면 계속 앉아있는 "고정 착석" 손님이다. cycler만
        // 시간이 지나면 일어나 다시 배회한다.
        guard role != .seatedPool else { return }
        seatTimeRemaining -= deltaTime
        guard seatTimeRemaining <= 0 else { return }
        seatState = .standingUp
        seatTimeRemaining = NPCGuestTuning.standingUpDuration
        playAnimation(.sitToStand)
    }

    private func updateStandingUp(deltaTime: Float) {
        seatTimeRemaining -= deltaTime
        guard seatTimeRemaining <= 0 else { return }
        pendingVacatedSeatIndex = claimedSeatIndex
        claimedSeatIndex = nil
        claimedSeat = nil
        seatState = .none
        pauseRemaining = Float.random(in: 0.3...1.2)
        playAnimation(.idle)
    }

    // MARK: - Movement

    /// arrived: 목적지에 도착(또는 이미 도착해 있었음). moved: 이번 프레임에 실제로
    /// 위치가 바뀌었는지 — 장애물에 완전히 막히면 arrived가 false여도 moved는
    /// false일 수 있다. 호출부는 moved를 보고서만 Walk를 재생해야 제자리걸음처럼
    /// 보이지 않는다.
    private struct MoveOutcome {
        let arrived: Bool
        let moved: Bool
    }

    private func move(toward target: SIMD2<Float>, deltaTime: Float,
                      arrivalDistance: Float, playerPosition: SIMD2<Float>,
                      neighboringPositions: [SIMD2<Float>],
                      separationScale: Float,
                      exclusions: [NPCGuestArea] = [],
                      avoidPlayer: Bool = true) -> MoveOutcome {
        guard let root = locomotionRoot else { return MoveOutcome(arrived: false, moved: false) }
        let current = SIMD2<Float>(root.position.x, root.position.z)
        let delta = target - current
        let distance = simd_length(delta)
        guard distance > arrivalDistance else { return MoveOutcome(arrived: true, moved: false) }

        let targetDirection = delta / distance
        var direction = crowdSteeredDirection(
            targetDirection: targetDirection,
            from: current,
            neighbors: neighboringPositions,
            scale: separationScale)
        // 목적지 자체는 제외 구역을 피해 골랐어도 직선 경로가 AreaK/AreaB를 가로지를
        // 수 있다. 지금 그 구역 안에 있다면 중심에서 바깥으로 강하게 밀어내 서성이지
        // 않고 빠르게 빠져나가게 한다.
        if let intruded = exclusions.first(where: { $0.contains(current) }) {
            let away = current - intruded.center
            if simd_length(away) > 0.001 {
                direction = simd_normalize(direction + simd_normalize(away) * 1.5)
            }
        }
        let desiredStep = min(distance, movementProfile.moveSpeed * deltaTime)
        var step = desiredStep
        if let scene = root.scene {
            step = NPCObstacleAvoidance.allowedStep(
                scene: scene,
                from: SIMD3(current.x, 0, current.y),
                direction: SIMD3(direction.x, 0, direction.y),
                desiredStep: desiredStep,
                halfWidth: NPCGuestTuning.bodyHalfWidth,
                playerPosition: playerPosition,
                avoidPlayer: avoidPlayer)
        }
        root.position.x += direction.x * step
        root.position.z += direction.y * step
        // 장애물에 거의 다 막혀 한 프레임에 1mm 안팎만 겨우 밀리는 경우까지 "이동
        // 중"으로 치면, 실제로는 제자리에 멈춰 있는데도 Walk 애니메이션이 계속
        // 재생되는 것처럼 보인다. blockedStepFraction과 같은 기준으로 "사실상
        // 막혔다"를 판정해 그 경우엔 이동도 애니메이션도 멈춘 것으로 취급한다.
        let isBlocked = step < desiredStep * NPCGuestTuning.blockedStepFraction
        let moved = !isBlocked && step > 0.0005
        if moved {
            face(direction: direction, deltaTime: deltaTime)
        }
        if isBlocked {
            wanderTarget = nil
            // 같은 장애물에 도달한 NPC들이 같은 프레임에 즉시 재탐색하지 않도록 짧고
            // 서로 다른 숨 고르기를 둔다.
            pauseRemaining = max(pauseRemaining, Float.random(in: 0.15...0.9))
        }
        return MoveOutcome(arrived: step >= distance, moved: moved)
    }

    /// 목표 방향에 개인 공간 반발력을 섞는다. 완전 정면 충돌 시에는 손님별 좌/우
    /// 성향을 사용해 둘이 같은 자리에서 영원히 마주 보는 대칭 교착을 깬다.
    private func crowdSteeredDirection(targetDirection: SIMD2<Float>,
                                       from current: SIMD2<Float>,
                                       neighbors: [SIMD2<Float>],
                                       scale: Float) -> SIMD2<Float> {
        var steering = targetDirection
        for neighbor in neighbors {
            var away = current - neighbor
            var distance = simd_length(away)
            guard distance < movementProfile.personalSpace else { continue }
            if distance < 0.001 {
                away = SIMD2(movementProfile.separationSide, 0)
                distance = 0.001
            }
            let proximity = 1 - distance / movementProfile.personalSpace
            steering += (away / distance) * proximity
                * movementProfile.separationStrength * scale
        }

        // 반발력이 정확히 상쇄되거나 뒤로 향하면 선호 측면으로 살짝 비켜 교착을 푼다.
        if simd_length_squared(steering) < 0.01 || simd_dot(steering, targetDirection) < 0.05 {
            let side = SIMD2(targetDirection.y, -targetDirection.x)
                * movementProfile.separationSide
            steering = targetDirection * 0.35 + side * 0.65
        }
        return simd_normalize(steering)
    }

    private func face(point: SIMD2<Float>, deltaTime: Float) {
        let delta = point - currentPosition
        guard simd_length(delta) > 0.001 else { return }
        face(direction: simd_normalize(delta), deltaTime: deltaTime)
    }

    private func face(direction: SIMD2<Float>, deltaTime: Float) {
        guard let root = locomotionRoot else { return }
        let yaw = atan2(-direction.x, -direction.y) + NPCGuestTuning.forwardYawOffset
        let target = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let amount = min(1, NPCGuestTuning.turnResponse * deltaTime)
        root.orientation = simd_slerp(root.orientation, target, amount)
    }

    private func randomWanderTarget(in area: NPCGuestArea,
                                    excluding exclusions: [NPCGuestArea],
                                    awayFrom current: SIMD2<Float>,
                                    avoiding occupiedAnchors: [SIMD2<Float>]) -> SIMD2<Float>? {
        var fallback: SIMD2<Float>?
        var bestSeparation: Float = -1
        for _ in 0..<40 {
            let candidate = area.point(u: Float.random(in: -1...1), v: Float.random(in: -1...1))
            if exclusions.contains(where: { $0.contains(candidate) }) { continue }
            // 후보 자체는 제외 구역 밖이어도, 지금 위치에서 거기까지 가는 직선 경로가
            // AreaK 등을 가로지르면 이동 중 반발력에 계속 밀려나 목적지에 못 닿고
            // 경계 근처를 맴돌며 Walk 애니메이션만 재생되는 문제가 있었다. 그런
            // 후보는 애초에 고르지 않는다.
            if pathCrosses(exclusions, from: current, to: candidate) { continue }
            guard simd_distance(candidate, current) >= NPCGuestTuning.minimumRoamDistance else { continue }
            let separation = occupiedAnchors
                .map { simd_distance(candidate, $0) }
                .min() ?? .greatestFiniteMagnitude
            if separation > bestSeparation {
                bestSeparation = separation
                fallback = candidate
            }
            if separation >= NPCGuestTuning.preferredTargetSeparation {
                return candidate
            }
        }
        return fallback
    }

    /// start→end 직선 경로 위 몇 지점을 샘플링해 제외 구역을 가로지르는지 대략
    /// 판정한다(정확한 선분-사각형 교차 계산 대신 충분히 촘촘한 샘플링으로 근사).
    private func pathCrosses(_ exclusions: [NPCGuestArea], from start: SIMD2<Float>, to end: SIMD2<Float>) -> Bool {
        guard !exclusions.isEmpty else { return false }
        let sampleCount = 6
        for step in 1..<sampleCount {
            let t = Float(step) / Float(sampleCount)
            let point = start + (end - start) * t
            if exclusions.contains(where: { $0.contains(point) }) { return true }
        }
        return false
    }

    // MARK: - Animation

    private func playAnimation(_ cue: NPCGuestAnimationCue) {
        guard currentCue != cue, let model = modelEntity else { return }

        let match = cue == .idle
            ? findDefaultSubtreeAnimation(in: model)
            : findAnimation(named: cue.rawValue, in: model)
        guard let match else { return }

        animationPlayback?.stop(blendOutDuration: 0.15)
        let resource = cue.repeats ? match.resource.repeat() : match.resource
        animationPlayback = match.entity.playAnimation(resource, transitionDuration: 0.2)
        if cue.repeats {
            // 여러 손님이 같은 클립을 동시에 재생하면 완전히 같은 위상으로 움직여
            // 기계적으로 보인다. 반복 재생 cue는 시작 지점을 무작위로 어긋나게 한다
            // (원샷인 sitToStand는 처음부터 재생돼야 하므로 건드리지 않는다).
            animationPlayback?.time = TimeInterval.random(in: 0..<4)
        }
        currentCue = cue
    }

    private func findAnimation(named animationName: String,
                               in entity: Entity) -> (entity: Entity, resource: AnimationResource)? {
        if let library = entity.components[AnimationLibraryComponent.self],
           let resource = library.animations[animationName] {
            return (entity, resource)
        }
        for child in entity.children {
            if let match = findAnimation(named: animationName, in: child) { return match }
        }
        return nil
    }

    /// Indoor.usda의 Guest AnimationLibrary에 이름으로 등록된 클립. 이 이름과 겹치지
    /// 않는 첫 애니메이션이 *Idle.usdz 임포트 시 RealityKit이 모델 자체의 스켈레톤
    /// 액션으로부터 자동 생성하는 "default subtree animation"(idle 루프)이다.
    /// Sitting/Sit_to_Stand/Angry도 라이브러리에 등록돼 있어 "Walk"만 제외하면
    /// idle 판정이 그중 하나로 잘못 걸릴 수 있다(NPCClerkController의 동일 패턴 참고).
    private static let libraryAnimationNames: Set<String> = ["Walk", "Sitting", "Sit_to_Stand", "Angry"]

    /// availableAnimations는 이미 서브트리 전체를 포함하므로, 라이브러리에 등록된
    /// 이름과 겹치지 않는 첫 항목을 idle 애니메이션으로 사용한다.
    private func findDefaultSubtreeAnimation(in entity: Entity) -> (entity: Entity, resource: AnimationResource)? {
        guard let resource = entity.availableAnimations.first(where: { animation in
            guard let name = animation.name else { return true }
            return !Self.libraryAnimationNames.contains(name)
        }) else { return nil }
        return (entity, resource)
    }
}
