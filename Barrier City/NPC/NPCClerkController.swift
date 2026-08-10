import Foundation
import Observation
import RealityKit
import simd
import DialogueKit

/// Indoor.usda의 Barista AnimationLibrary에 연결된 코드 실행용 애니메이션 키.
/// 같은 cue가 연속으로 와도 다시 재생할 수 있도록 요청에는 별도 sequence를 사용한다.
enum NPCAnimationCue: String, CaseIterable {
    case idle = "Idle"
    case greet = "Greet"
    case walk = "Walk"

    var repeats: Bool {
        self == .idle || self == .walk
    }
}

struct NPCAnimationRequest: Equatable {
    let sequence: Int
    let cue: NPCAnimationCue
}

enum NPCClerkPhase: String {
    case unavailable = "실외"
    case working = "업무 중"
    case greeting = "인사 중"
    case conversing = "대화 중"
    case completed = "주문 완료"
}

/// Barista 배치와 동선을 한곳에서 조절하는 튜닝값.
enum NPCClerkTuning {
    /// 점원이 돌아다니는 동안에도 사용자를 놓치지 않도록 실제 NPC 위치 기준으로 넉넉히 감지한다.
    static let detectionRadius: Float = 4.0
    /// 진입 반경보다 1m 넓혀 대화 중 경계에서 종료가 반복되지 않게 한다.
    static let conversationExitRadius: Float = detectionRadius + 1.0
    static let moveSpeed: Float = 0.8
    static let turnResponse: Float = 7
    static let arrivalDistance: Float = 0.04
    static let workPauseSeconds: Float = 1.8
    /// BarTable의 고객 쪽 경계에서 직원 구역 안/고객 쪽으로 떨어지는 거리.
    static let staffCounterInset: Float = 1.05
    static let customerStandOff: Float = 0.65

    /// Barista 자체 스케일·축 변환은 Indoor.usda에 작성되어 있어 wrapper는 보정하지 않는다.
    static let baristaScale: Float = 1.0
    static let baristaBaseY: Float = 0
    /// Blender에서 제작된 Barista의 시각적 정면(+Z)을 RealityKit 이동 정면(-Z)에 맞춘다.
    static let baristaForwardYawOffset: Float = .pi

    static let dialogueHeight: Float = 1.55

    static let fallbackStaffHome = SIMD2<Float>(0, 5.2)
    static let fallbackServicePoint = SIMD2<Float>(0, 3.1)
    static let fallbackCustomerPoint = SIMD2<Float>(0, 1.35)
    static let fallbackAreaMin = SIMD2<Float>(-4, 2)
    static let fallbackAreaMax = SIMD2<Float>(3, 6)
}

/// 실내 점원의 배치·이동·근접 감지·애니메이션을 한 상태 머신에서 관리한다.
///
/// 앱은 플레이어 대신 `worldRoot`를 역이동시키므로, 모든 좌표는 화면(world) 좌표가
/// 아니라 `worldRoot` 기준 맵 좌표로 유지한다.
@Observable
@MainActor
final class NPCClerkController {
    private(set) var phase: NPCClerkPhase = .unavailable
    private(set) var availableAnimationNames: [String] = []
    private(set) var lastPlayedAnimation: String = ""
    private(set) var placementSummary: String = ""
    private(set) var isInteractionBubbleVisible = false
    private(set) var isTalkAvailable = false

    let dialogue: NPCDialogueController

    @ObservationIgnored private var locomotionRoot: Entity?
    @ObservationIgnored private var baristaEntity: Entity?
    @ObservationIgnored private var interactionBubble: Entity?
    @ObservationIgnored private var animationPlayback: AnimationPlaybackController?
    @ObservationIgnored private var greetingTask: Task<Void, Never>?

    private var staffHome = NPCClerkTuning.fallbackStaffHome
    private var servicePoint = NPCClerkTuning.fallbackServicePoint
    private var customerPoint = NPCClerkTuning.fallbackCustomerPoint
    private var workWaypoints: [SIMD2<Float>] = []
    private var workWaypointIndex = 0
    private var workPauseRemaining: Float = 0
    private var handledAnimationSequence = 0
    private var handledMissionSequence = 0
    private var hasPlayedGreetingAnimation = false

    init(dialogue: NPCDialogueController) {
        self.dialogue = dialogue
    }

    /// ImmersiveView가 생성될 때 attachment를 맵 루트에 한 번 연결한다.
    func installInteractionBubble(_ panel: Entity, in worldRoot: Entity) {
        panel.removeFromParent()
        panel.isEnabled = false
        panel.scale = SIMD3(repeating: 0.9)
        worldRoot.addChild(panel)
        interactionBubble = panel
    }

    /// 몰입 공간 재진입/종료 시 이전 엔티티와 대화 상태를 제거한다.
    func resetForOutdoor() {
        greetingTask?.cancel()
        greetingTask = nil
        animationPlayback?.stop()
        animationPlayback = nil
        locomotionRoot?.removeFromParent()
        locomotionRoot = nil
        baristaEntity = nil
        interactionBubble?.isEnabled = false
        isInteractionBubbleVisible = false
        isTalkAvailable = false
        phase = .unavailable
        availableAnimationNames = []
        lastPlayedAnimation = ""
        placementSummary = ""
        handledAnimationSequence = 0
        handledMissionSequence = 0
        hasPlayedGreetingAnimation = false
        dialogue.reset()
    }

    /// Indoor의 authoring marker(BarTable/Human/AreaK)로 동선과 계산대 위치를 구성한다.
    func enterIndoor(worldRoot: Entity,
                     indoorMap: Entity,
                     kioskCenter: SIMD2<Float>) async {
        greetingTask?.cancel()
        animationPlayback?.stop()
        locomotionRoot?.removeFromParent()
        dialogue.reset()

        handledAnimationSequence = 0
        handledMissionSequence = 0
        hasPlayedGreetingAnimation = false
        isInteractionBubbleVisible = false
        isTalkAvailable = false
        interactionBubble?.isEnabled = false

        let placement = makePlacement(in: indoorMap,
                                      relativeTo: worldRoot,
                                      kioskCenter: kioskCenter)
        staffHome = placement.staffHome
        servicePoint = placement.servicePoint
        customerPoint = placement.customerPoint
        workWaypoints = placement.workWaypoints
        workWaypointIndex = 0
        workPauseRemaining = NPCClerkTuning.workPauseSeconds
        placementSummary = String(
            format: "대기(%.2f, %.2f) → 계산대(%.2f, %.2f), 고객(%.2f, %.2f)",
            staffHome.x, staffHome.y,
            servicePoint.x, servicePoint.y,
            customerPoint.x, customerPoint.y)

        // Indoor의 Human은 위치 마커로만 사용하고 중복 렌더링은 숨긴다.
        indoorMap.findEntity(named: "Human")?.isEnabled = false

        // Indoor.usda에 배치된 완성형 Barista를 그대로 사용한다. Idle/Walk는
        // 원본 클립의 루트 이동을 제거한 in-place 리소스라 wrapper 이동과 중복되지 않는다.
        guard let barista = indoorMap.findEntity(named: "Barista") else {
            phase = .unavailable
            print("⚠️ Barista를 찾지 못함 — Indoor.usda의 Barista 엔티티 확인")
            return
        }
        barista.removeFromParent()

        // 스켈레톤 애니메이션과 NPC 이동 transform이 충돌하지 않도록 이동·회전은
        // Barista 바깥 wrapper에만 적용한다. Barista의 authored 축/스케일은 유지한다.
        let locomotion = Entity()
        locomotion.name = "NPCClerkLocomotionRoot"
        locomotion.position = [staffHome.x, NPCClerkTuning.baristaBaseY, staffHome.y]
        locomotion.scale = SIMD3(repeating: NPCClerkTuning.baristaScale)
        locomotion.addChild(barista)
        if let bubble = interactionBubble {
            // 월드 좌표를 매 프레임 추종하지 않고 NPC 이동 wrapper에 직접 결합한다.
            // 위치와 회전이 동일한 transform 계층에서 갱신되므로 추종 지연이 없고,
            // 사용자의 시선을 향한 별도 forward/yaw 보정도 적용하지 않는다.
            bubble.removeFromParent()
            locomotion.addChild(bubble)
            bubble.position = [0, NPCClerkTuning.dialogueHeight, 0]
            bubble.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        }
        worldRoot.addChild(locomotion)

        locomotionRoot = locomotion
        baristaEntity = barista
        availableAnimationNames = collectAnimationNames(in: barista).sorted()
        print("NPC 배치: \(placementSummary)")
        print("NPC 애니메이션: \(availableAnimationNames)")
        phase = .working
        setInteractionBubbleVisible(true)
        playAnimation(.idle)
    }

    /// SceneEvents.Update에서 호출한다. Entity.move를 매 프레임 재시작하지 않고
    /// deltaTime 기반으로 직접 보간해 일정한 속도로 움직인다.
    func update(deltaTime rawDeltaTime: Float, appModel: AppModel) {
        guard phase != .unavailable, locomotionRoot != nil else {
            interactionBubble?.isEnabled = false
            isTalkAvailable = false
            return
        }

        let dt = min(max(rawDeltaTime, 0), 1.0 / 15.0)
        let player = SIMD2<Float>(appModel.posX, appModel.posZ)
        // 대화 감지는 계산대의 고정 좌표가 아니라 현재 돌아다니는 NPC의 실제 위치를 쓴다.
        // 이전에는 BarTable에서 계산한 customerPoint가 어긋나면 가까이 가도 인사가 시작되지 않았다.
        let playerDistance = simd_distance(player, currentClerkPosition)
        handleDialogueSignals()

        isTalkAvailable = (phase == .working || phase == .completed)
            && playerDistance <= NPCClerkTuning.detectionRadius

        switch phase {
        case .unavailable:
            break

        case .working:
            updateWorkLoop(deltaTime: dt)

        case .greeting, .conversing:
            if playerDistance > NPCClerkTuning.conversationExitRadius {
                endEncounterForDeparture()
            } else {
                // 위치는 고정하고 몸의 방향만 사용자 쪽으로 돌린다.
                face(point: player, deltaTime: dt)
            }

        case .completed:
            face(point: player, deltaTime: dt)
        }

    }

    /// Barista 위의 공간 버튼에서 호출한다. 자동 근접 인사 대신 사용자의 명시적인
    /// 선택으로만 대화를 시작해 NPC가 갑자기 말을 거는 느낌을 없앤다.
    func startConversation() {
        guard isTalkAvailable else { return }
        beginGreeting()
    }

    /// DEBUG 패널에서 자산 연결을 대화 없이 바로 확인할 때 사용한다.
    func playForTesting(_ cue: NPCAnimationCue) {
        playAnimation(cue, restart: true, allowsGreetingReplay: true)
    }

    // MARK: - Placement

    private struct Placement {
        let staffHome: SIMD2<Float>
        let servicePoint: SIMD2<Float>
        let customerPoint: SIMD2<Float>
        let workWaypoints: [SIMD2<Float>]
    }

    private func makePlacement(in indoorMap: Entity,
                               relativeTo worldRoot: Entity,
                               kioskCenter: SIMD2<Float>) -> Placement {
        var areaMin = NPCClerkTuning.fallbackAreaMin
        var areaMax = NPCClerkTuning.fallbackAreaMax
        if let area = indoorMap.findEntity(named: "AreaK") {
            let bounds = area.visualBounds(relativeTo: worldRoot)
            areaMin = SIMD2(bounds.min.x, bounds.min.z)
            areaMax = SIMD2(bounds.max.x, bounds.max.z)
        }

        var home = NPCClerkTuning.fallbackStaffHome
        if let marker = indoorMap.findEntity(named: "Human") {
            let center = marker.visualBounds(relativeTo: worldRoot).center
            home = SIMD2(center.x, center.z)
        }

        var service = NPCClerkTuning.fallbackServicePoint
        var customer = NPCClerkTuning.fallbackCustomerPoint
        if let bar = indoorMap.findEntity(named: "BarTable") {
            let bounds = bar.visualBounds(relativeTo: worldRoot)
            let minPoint = SIMD2<Float>(bounds.min.x, bounds.min.z)
            let maxPoint = SIMD2<Float>(bounds.max.x, bounds.max.z)
            // L자 BarTable은 bounds 중심→Kiosk 벡터로 면을 고르면 오른쪽 return을
            // 전면 계산대로 오인한다. Kiosk에 가장 가까운 AABB 표면을 먼저 구한다.
            var edge = clamp(kioskCenter, minimum: minPoint, maximum: maxPoint)
            var towardCustomer = kioskCenter - edge
            if simd_length(towardCustomer) < 0.001 {
                // Kiosk가 bounds 안에 들어온 예외에서는 가장 가까운 바깥 면을 선택한다.
                let distances: [(Float, SIMD2<Float>, SIMD2<Float>)] = [
                    (kioskCenter.x - minPoint.x,
                     SIMD2(minPoint.x, kioskCenter.y), SIMD2(-1, 0)),
                    (maxPoint.x - kioskCenter.x,
                     SIMD2(maxPoint.x, kioskCenter.y), SIMD2(1, 0)),
                    (kioskCenter.y - minPoint.y,
                     SIMD2(kioskCenter.x, minPoint.y), SIMD2(0, -1)),
                    (maxPoint.y - kioskCenter.y,
                     SIMD2(kioskCenter.x, maxPoint.y), SIMD2(0, 1)),
                ]
                if let nearest = distances.min(by: { $0.0 < $1.0 }) {
                    edge = nearest.1
                    towardCustomer = nearest.2
                }
            } else {
                towardCustomer = simd_normalize(towardCustomer)
            }
            service = edge - towardCustomer * NPCClerkTuning.staffCounterInset
            customer = edge + towardCustomer * NPCClerkTuning.customerStandOff
        }

        let margin: Float = 0.45
        home = clamp(home, minimum: areaMin + margin, maximum: areaMax - margin)
        service = clamp(service, minimum: areaMin + margin, maximum: areaMax - margin)

        let candidates = [
            home + SIMD2<Float>(-1.35, 0),
            home + SIMD2<Float>(0.95, -0.30),
            home,
        ]
        let waypoints = candidates.map {
            clamp($0, minimum: areaMin + margin, maximum: areaMax - margin)
        }
        return Placement(staffHome: home,
                         servicePoint: service,
                         customerPoint: customer,
                         workWaypoints: waypoints)
    }

    private func clamp(_ value: Float, _ minimum: Float, _ maximum: Float) -> Float {
        guard minimum <= maximum else { return (minimum + maximum) * 0.5 }
        return Swift.max(minimum, Swift.min(maximum, value))
    }

    private func clamp(_ value: SIMD2<Float>,
                       minimum: SIMD2<Float>,
                       maximum: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(clamp(value.x, minimum.x, maximum.x),
              clamp(value.y, minimum.y, maximum.y))
    }

    // MARK: - State machine

    private var currentClerkPosition: SIMD2<Float> {
        guard let root = locomotionRoot else { return staffHome }
        return SIMD2(root.position.x, root.position.z)
    }

    private func updateWorkLoop(deltaTime: Float) {
        guard !workWaypoints.isEmpty else { return }
        if workPauseRemaining > 0 {
            workPauseRemaining = max(0, workPauseRemaining - deltaTime)
            playAnimation(.idle)
            return
        }
        playAnimation(.walk)
        if move(toward: workWaypoints[workWaypointIndex], deltaTime: deltaTime) {
            workWaypointIndex = (workWaypointIndex + 1) % workWaypoints.count
            workPauseRemaining = NPCClerkTuning.workPauseSeconds
            playAnimation(.idle)
        }
    }

    @discardableResult
    private func move(toward target: SIMD2<Float>, deltaTime: Float) -> Bool {
        guard let root = locomotionRoot else { return false }
        let current = SIMD2<Float>(root.position.x, root.position.z)
        let delta = target - current
        let distance = simd_length(delta)
        guard distance > NPCClerkTuning.arrivalDistance else {
            root.position.x = target.x
            root.position.z = target.y
            return true
        }

        let direction = delta / distance
        let step = min(distance, NPCClerkTuning.moveSpeed * deltaTime)
        root.position.x += direction.x * step
        root.position.z += direction.y * step
        face(direction: direction, deltaTime: deltaTime)
        return step >= distance
    }

    private func face(point: SIMD2<Float>, deltaTime: Float) {
        guard let root = locomotionRoot else { return }
        let position = SIMD2<Float>(root.position.x, root.position.z)
        let delta = point - position
        guard simd_length(delta) > 0.001 else { return }
        face(direction: simd_normalize(delta), deltaTime: deltaTime)
    }

    private func face(direction: SIMD2<Float>, deltaTime: Float) {
        guard let root = locomotionRoot else { return }
        // 이동 wrapper의 -Z를 목표 방향으로 맞춘 뒤 Barista의 +Z 정면을 180° 보정한다.
        // 스켈레톤 애니메이션은 자식에만 적용되므로 바깥 wrapper 보정은 유지된다.
        let yaw = atan2(-direction.x, -direction.y)
            + NPCClerkTuning.baristaForwardYawOffset
        let target = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let amount = min(1, NPCClerkTuning.turnResponse * deltaTime)
        root.orientation = simd_slerp(root.orientation, target, amount)
    }

    private func beginGreeting() {
        guard phase == .working || phase == .completed else { return }
        phase = .greeting
        isTalkAvailable = false
        playAnimation(.idle)
        setInteractionBubbleVisible(true)

        // 키오스크 장벽 패널과 대화 패널이 겹치지 않게 현재 키오스크 UI를 닫는다.
        let interactions = InteractionModel.shared
        interactions.dismissedTriggerID = interactions.activeTrigger?.id ?? "kiosk.order"
        interactions.activeTrigger = nil
        interactions.kioskPanelEntity?.isEnabled = false

        greetingTask?.cancel()
        greetingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.dialogue.startEncounter()
            guard !Task.isCancelled, self.phase == .greeting else { return }
            self.phase = .conversing
        }
    }

    private func handleDialogueSignals() {
        if let request = dialogue.animationRequest,
           request.sequence != handledAnimationSequence {
            handledAnimationSequence = request.sequence
            playAnimation(request.cue, restart: true)
        }

        guard dialogue.missionEventSequence != handledMissionSequence else { return }
        handledMissionSequence = dialogue.missionEventSequence
        switch dialogue.lastMissionEvent {
        case .orderPlaced:
            QuestModel.shared.advance(on: .npcHelpDone)
            phase = .completed
            playAnimation(.idle)
        case .exited:
            greetingTask?.cancel()
            greetingTask = nil
            dialogue.cancelEncounter()
            setInteractionBubbleVisible(true)
            phase = .working
            workPauseRemaining = NPCClerkTuning.workPauseSeconds
        case .helpRequested, .none:
            break
        }
    }

    /// 대화 중 사용자가 멀어지면 즉시 마이크를 닫고 말 걸기 상태로 돌아간다.
    private func endEncounterForDeparture() {
        greetingTask?.cancel()
        greetingTask = nil
        dialogue.cancelEncounter()
        setInteractionBubbleVisible(true)
        phase = .working
        workPauseRemaining = NPCClerkTuning.workPauseSeconds
    }

    // MARK: - Animation

    private func playAnimation(_ cue: NPCAnimationCue,
                               restart: Bool = false,
                               allowsGreetingReplay: Bool = false) {
        guard restart || lastPlayedAnimation != cue.rawValue else { return }
        guard cue != .greet || !hasPlayedGreetingAnimation || allowsGreetingReplay else { return }
        guard let barista = baristaEntity,
              let match = findAnimation(named: cue.rawValue, in: barista) else {
            print("⚠️ NPC 애니메이션 '\(cue.rawValue)'을 찾지 못함 — 현재 키: \(availableAnimationNames)")
            return
        }
        animationPlayback?.stop(blendOutDuration: 0.15)
        let resource = cue.repeats ? match.resource.repeat() : match.resource
        animationPlayback = match.entity.playAnimation(resource, transitionDuration: 0.20)
        if cue == .greet, !allowsGreetingReplay { hasPlayedGreetingAnimation = true }
        lastPlayedAnimation = cue.rawValue
    }

    private func findAnimation(named name: String,
                               in entity: Entity) -> (entity: Entity, resource: AnimationResource)? {
        if let library = entity.components[AnimationLibraryComponent.self],
           let resource = library.animations[name] {
            return (entity, resource)
        }
        for child in entity.children {
            if let match = findAnimation(named: name, in: child) { return match }
        }
        return nil
    }

    private func collectAnimationNames(in entity: Entity) -> [String] {
        var names: [String] = []
        if let library = entity.components[AnimationLibraryComponent.self] {
            names.append(contentsOf: library.animations.map(\.key))
        }
        for child in entity.children {
            names.append(contentsOf: collectAnimationNames(in: child))
        }
        return Array(Set(names))
    }

    // MARK: - Spatial interaction bubble

    private func setInteractionBubbleVisible(_ visible: Bool) {
        isInteractionBubbleVisible = visible
        interactionBubble?.isEnabled = visible
    }

}
