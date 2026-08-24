import Foundation
import RealityKit
import simd

/// Indoor.usda의 Guest_* AnimationLibrary에 등록된 애니메이션 키.
/// Idle은 Barista와 동일하게 *Idle.usdz의 default subtree animation을 그대로 쓴다.
enum NPCGuestAnimationCue: String {
    case idle = "Idle"
    case walk = "Walk"
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
    }

    /// 전원이 같은 속도와 정지 주기로 움직이면 군무처럼 보인다. 손님마다 생성 시 한 번
    /// 서로 다른 보행 성향을 부여해 이후 프레임에서는 안정적으로 유지한다.
    private struct MovementProfile {
        let moveSpeed: Float
        let pauseRange: ClosedRange<Float>
        let personalSpace: Float
        let separationStrength: Float
        let separationSide: Float

        static func random() -> MovementProfile {
            let pauseMinimum = Float.random(in: 0.7...2.2)
            return MovementProfile(
                moveSpeed: Float.random(in: 0.68...1.02),
                pauseRange: pauseMinimum...Float.random(in: 3.8...7.0),
                personalSpace: Float.random(in: 0.62...0.82),
                separationStrength: Float.random(in: 0.85...1.25),
                separationSide: Bool.random() ? 1 : -1)
        }
    }

    private(set) var name: String
    private var locomotionRoot: Entity?
    private var modelEntity: Entity?
    private var animationPlayback: AnimationPlaybackController?
    private var currentCue: NPCGuestAnimationCue?
    private var wanderTarget: SIMD2<Float>?
    private var pauseRemaining: Float = 0
    private let movementProfile: MovementProfile

    init(name: String) {
        self.name = name
        movementProfile = .random()
    }

    /// Indoor.usda에서 찾은 손님 엔티티를 이동 wrapper로 감싸 worldRoot에 배치한다.
    /// Barista 배치(NPCClerkController.enterIndoor)와 동일한 발 기준 정렬 방식을 쓴다.
    func place(entity: Entity, worldRoot: Entity, at position: SIMD2<Float>) {
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
        // 진입 직후 전원이 동시에 걷기 시작하지 않도록 첫 출발 시점을 넓게 흩뜨린다.
        pauseRemaining = Float.random(in: 0...4.5)
        playAnimation(.idle)
    }

    func teardown() {
        animationPlayback?.stop()
        animationPlayback = nil
        locomotionRoot?.removeFromParent()
        locomotionRoot = nil
        modelEntity = nil
        currentCue = nil
        wanderTarget = nil
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

        if let queueSlot {
            if move(toward: queueSlot, deltaTime: deltaTime,
                    arrivalDistance: NPCGuestTuning.queueArrivalDistance,
                    playerPosition: playerPosition,
                    neighboringPositions: neighboringPositions,
                    separationScale: 0.35) {
                playAnimation(.idle)
                if let facingTarget { face(point: facingTarget, deltaTime: deltaTime) }
            }
            return
        }

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
        }
        guard let target = wanderTarget else {
            playAnimation(.idle)
            return
        }
        playAnimation(.walk)
        if move(toward: target, deltaTime: deltaTime,
                arrivalDistance: NPCGuestTuning.arrivalDistance,
                playerPosition: playerPosition,
                neighboringPositions: neighboringPositions,
                separationScale: 1) {
            wanderTarget = nil
            pauseRemaining = Float.random(in: movementProfile.pauseRange)
            playAnimation(.idle)
        }
    }

    // MARK: - Movement

    @discardableResult
    private func move(toward target: SIMD2<Float>, deltaTime: Float,
                      arrivalDistance: Float, playerPosition: SIMD2<Float>,
                      neighboringPositions: [SIMD2<Float>],
                      separationScale: Float) -> Bool {
        guard let root = locomotionRoot else { return false }
        let current = SIMD2<Float>(root.position.x, root.position.z)
        let delta = target - current
        let distance = simd_length(delta)
        guard distance > arrivalDistance else { return true }

        let targetDirection = delta / distance
        let direction = crowdSteeredDirection(
            targetDirection: targetDirection,
            from: current,
            neighbors: neighboringPositions,
            scale: separationScale)
        let desiredStep = min(distance, movementProfile.moveSpeed * deltaTime)
        var step = desiredStep
        if let scene = root.scene {
            step = NPCObstacleAvoidance.allowedStep(
                scene: scene,
                from: SIMD3(current.x, 0, current.y),
                direction: SIMD3(direction.x, 0, direction.y),
                desiredStep: desiredStep,
                halfWidth: NPCGuestTuning.bodyHalfWidth,
                playerPosition: playerPosition)
        }
        root.position.x += direction.x * step
        root.position.z += direction.y * step
        face(direction: direction, deltaTime: deltaTime)
        if step < desiredStep * NPCGuestTuning.blockedStepFraction {
            wanderTarget = nil
            // 같은 장애물에 도달한 NPC들이 같은 프레임에 즉시 재탐색하지 않도록 짧고
            // 서로 다른 숨 고르기를 둔다.
            pauseRemaining = max(pauseRemaining, Float.random(in: 0.15...0.9))
        }
        return step >= distance
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
        let len = simd_length(steering)
        return len > 0.001 ? steering / len : targetDirection
    }

    private func face(point: SIMD2<Float>, deltaTime: Float) {
        let delta = point - currentPosition
        guard simd_length(delta) > 0.001, !delta.x.isNaN, !delta.y.isNaN else { return }
        face(direction: simd_normalize(delta), deltaTime: deltaTime)
    }

    private func face(direction: SIMD2<Float>, deltaTime: Float) {
        guard let root = locomotionRoot,
              !direction.x.isNaN, !direction.y.isNaN,
              simd_length(direction) > 0.001 else { return }
        let yaw = atan2(-direction.x, -direction.y) + NPCGuestTuning.forwardYawOffset
        guard !yaw.isNaN else { return }
        let target = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let amount = min(1, max(0, NPCGuestTuning.turnResponse * deltaTime))
        let currentOri = root.orientation
        if simd_length(currentOri.vector) > 0.001 && !currentOri.vector.x.isNaN {
            let nextOri = simd_slerp(simd_normalize(currentOri), target, amount)
            if !nextOri.vector.x.isNaN {
                root.orientation = nextOri
            }
        } else {
            root.orientation = target
        }
    }

    private func randomWanderTarget(in area: NPCGuestArea,
                                    excluding exclusions: [NPCGuestArea],
                                    awayFrom current: SIMD2<Float>,
                                    avoiding occupiedAnchors: [SIMD2<Float>]) -> SIMD2<Float>? {
        var fallback: SIMD2<Float>?
        var bestSeparation: Float = -1
        for _ in 0..<28 {
            let candidate = area.point(u: Float.random(in: -1...1), v: Float.random(in: -1...1))
            if exclusions.contains(where: { $0.contains(candidate) }) { continue }
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

    // MARK: - Animation

    private func playAnimation(_ cue: NPCGuestAnimationCue) {
        guard currentCue != cue, let model = modelEntity else { return }

        let match = cue == .idle
            ? findDefaultSubtreeAnimation(in: model)
            : findAnimation(named: cue.rawValue, in: model)
        guard let match else { return }

        animationPlayback?.stop(blendOutDuration: 0.15)
        animationPlayback = match.entity.playAnimation(match.resource.repeat(), transitionDuration: 0.2)
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

    /// Idle*.usdz 임포트 시 RealityKit이 모델 스켈레톤에서 자동 생성하는 기본 서브트리
    /// 애니메이션(숨쉬기 등)을 쓴다. "Walk"라는 이름과 겹치지 않는 첫 애니메이션을 고른다.
    private func findDefaultSubtreeAnimation(in entity: Entity) -> (entity: Entity, resource: AnimationResource)? {
        guard let resource = entity.availableAnimations.first(where: { $0.name != "Walk" }) else { return nil }
        return (entity, resource)
    }
}
