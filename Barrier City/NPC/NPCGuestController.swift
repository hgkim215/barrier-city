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
        static let moveSpeed: Float = 0.9
        static let turnResponse: Float = 6
        static let arrivalDistance: Float = 0.05
        static let queueArrivalDistance: Float = 0.12
        static let workPauseRange: ClosedRange<Float> = 1.5...5.0
        static let minimumRoamDistance: Float = 0.8
        /// Blender/RealityKit 축 변환 보정용. 모델의 정면이 다르면 이 값을 조정한다.
        static let forwardYawOffset: Float = .pi
    }

    private(set) var name: String
    private var locomotionRoot: Entity?
    private var modelEntity: Entity?
    private var animationPlayback: AnimationPlaybackController?
    private var currentCue: NPCGuestAnimationCue?
    private var wanderTarget: SIMD2<Float>?
    private var pauseRemaining: Float = 0

    init(name: String) {
        self.name = name
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

        worldRoot.addChild(locomotion)
        locomotionRoot = locomotion
        modelEntity = entity
        wanderTarget = nil
        // 진입 직후 전원이 가만히 서 있다가 한꺼번에 걷기 시작하면 어색하다. 화면이
        // 밝아지는 시점에 이미 걷는 손님이 섞여 있도록 절반은 대기 없이 바로 다음
        // update()에서 목적지를 잡아 걷기 시작하고, 나머지도 대기를 짧게 둔다.
        pauseRemaining = Bool.random() ? 0 : Float.random(in: 0...2.0)
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

    /// queueSlot이 있으면 그 지점으로 이동해 대기하고, 없으면 wanderArea 안에서
    /// exclusions(직원 구역 등)를 피해 자유롭게 걸어 다닌다.
    func update(deltaTime: Float,
               wanderArea: NPCGuestArea,
               exclusions: [NPCGuestArea],
               queueSlot: SIMD2<Float>?,
               facing facingTarget: SIMD2<Float>?) {
        guard locomotionRoot != nil else { return }

        if let queueSlot {
            if move(toward: queueSlot, deltaTime: deltaTime, arrivalDistance: NPCGuestTuning.queueArrivalDistance) {
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
            wanderTarget = randomWanderTarget(in: wanderArea, excluding: exclusions, awayFrom: currentPosition)
        }
        guard let target = wanderTarget else {
            playAnimation(.idle)
            return
        }
        playAnimation(.walk)
        if move(toward: target, deltaTime: deltaTime, arrivalDistance: NPCGuestTuning.arrivalDistance) {
            wanderTarget = nil
            pauseRemaining = Float.random(in: NPCGuestTuning.workPauseRange)
            playAnimation(.idle)
        }
    }

    // MARK: - Movement

    @discardableResult
    private func move(toward target: SIMD2<Float>, deltaTime: Float, arrivalDistance: Float) -> Bool {
        guard let root = locomotionRoot else { return false }
        let current = SIMD2<Float>(root.position.x, root.position.z)
        let delta = target - current
        let distance = simd_length(delta)
        guard distance > arrivalDistance else { return true }

        let direction = delta / distance
        let step = min(distance, NPCGuestTuning.moveSpeed * deltaTime)
        root.position.x += direction.x * step
        root.position.z += direction.y * step
        face(direction: direction, deltaTime: deltaTime)
        return step >= distance
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
                                    awayFrom current: SIMD2<Float>) -> SIMD2<Float>? {
        var fallback: SIMD2<Float>?
        for _ in 0..<12 {
            let candidate = area.point(u: Float.random(in: -1...1), v: Float.random(in: -1...1))
            if exclusions.contains(where: { $0.contains(candidate) }) { continue }
            fallback = candidate
            if simd_distance(candidate, current) >= NPCGuestTuning.minimumRoamDistance {
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
