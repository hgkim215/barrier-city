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
    case orderAccepted = "주문 접수 완료"
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
    /// 한 지점에 도착한 뒤 다음 행동을 시작하기까지 매번 달라지는 대기 시간.
    static let workPauseRange: ClosedRange<Float> = 1.2...4.0
    /// 너무 짧은 이동을 반복하지 않도록 새 목적지와 현재 위치 사이에 두는 최소 거리.
    static let minimumRoamDistance: Float = 0.75
    /// AreaK 경계나 가구에 캐릭터가 겹치지 않도록 안쪽으로 줄이는 여백.
    static let workAreaMargin: Float = 0.45
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
    private(set) var lastPlayedAnimation: String = ""
    private(set) var isInteractionBubbleVisible = false
    private(set) var isTalkAvailable = false

    let dialogue: NPCDialogueController

    @ObservationIgnored private var locomotionRoot: Entity?
    @ObservationIgnored private var baristaEntity: Entity?
    @ObservationIgnored private var interactionBubble: Entity?
    @ObservationIgnored private var animationPlayback: AnimationPlaybackController?
    @ObservationIgnored private var greetingTask: Task<Void, Never>?
    private var isGuideInteractionLocked = false

    private var staffHome = NPCClerkTuning.fallbackStaffHome
    private var servicePoint = NPCClerkTuning.fallbackServicePoint
    private var customerPoint = NPCClerkTuning.fallbackCustomerPoint
    private var workAreaMin = NPCClerkTuning.fallbackAreaMin
    private var workAreaMax = NPCClerkTuning.fallbackAreaMax
    private var workTarget: SIMD2<Float>?
    private var workPauseRemaining: Float = 0
    /// 대화 버튼을 누른 순간의 맵 좌표. 값이 있는 동안 업무 동선보다 우선해 위치를 고정한다.
    private var conversationAnchor: SIMD2<Float>?
    private var handledAnimationSequence = 0
    private var handledMissionSequence = 0
    private var hasPlayedGreetingAnimation = false
    /// 주문 접수 이벤트는 받았지만 NPC의 마지막 음성 세션이 아직 닫히지 않은 상태.
    private var pendingOrderConversationEnd = false
    /// 개발 패널에서 시작한 세션은 사용자가 NPC 반경 밖에 있어도 종료하지 않는다.
    private var isRemoteDevelopmentConversation = false

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

    func setGuideInteractionLocked(_ locked: Bool) {
        isGuideInteractionLocked = locked
        interactionBubble?.isEnabled = isInteractionBubbleVisible
            && !locked
            && GuideFlowModel.shared.allowsNPCOrderConversation
        if locked { isTalkAvailable = false }
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
        interactionBubble = nil
        isInteractionBubbleVisible = false
        isTalkAvailable = false
        isGuideInteractionLocked = false
        phase = .unavailable
        lastPlayedAnimation = ""
        conversationAnchor = nil
        workTarget = nil
        handledAnimationSequence = 0
        handledMissionSequence = 0
        hasPlayedGreetingAnimation = false
        pendingOrderConversationEnd = false
        isRemoteDevelopmentConversation = false
        dialogue.cancelEncounter()
    }

    /// Indoor의 authoring marker(BarTable/AreaK)로 동선과 계산대 위치를 구성한다.
    func enterIndoor(worldRoot: Entity,
                     indoorMap: Entity,
                     kioskCenter: SIMD2<Float>,
                     isTransitionCurrent: @escaping @MainActor () -> Bool) {
        guard isTransitionCurrent() else { return }
        greetingTask?.cancel()
        animationPlayback?.stop()
        locomotionRoot?.removeFromParent()
        dialogue.cancelEncounter()

        handledAnimationSequence = 0
        handledMissionSequence = 0
        hasPlayedGreetingAnimation = false
        pendingOrderConversationEnd = false
        isRemoteDevelopmentConversation = false
        conversationAnchor = nil
        isInteractionBubbleVisible = false
        isTalkAvailable = false
        interactionBubble?.isEnabled = false

        let placement = makePlacement(in: indoorMap,
                                      relativeTo: worldRoot,
                                      kioskCenter: kioskCenter)
        staffHome = placement.staffHome
        servicePoint = placement.servicePoint
        customerPoint = placement.customerPoint
        workAreaMin = placement.workAreaMin
        workAreaMax = placement.workAreaMax
        workTarget = nil
        workPauseRemaining = randomWorkPause()

        // Indoor.usda에 배치된 완성형 Barista를 그대로 사용한다. Idle/Walk는
        // 원본 클립의 루트 이동을 제거한 in-place 리소스라 wrapper 이동과 중복되지 않는다.
        guard let barista = indoorMap.findEntity(named: "Barista") else {
            phase = .unavailable
            return
        }
        guard isTransitionCurrent() else { return }
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
        let player = SIMD2<Float>(appModel.motion.positionX, appModel.motion.positionZ)
        // 대화 감지는 계산대의 고정 좌표가 아니라 현재 돌아다니는 NPC의 실제 위치를 쓴다.
        // 이전에는 BarTable에서 계산한 customerPoint가 어긋나면 가까이 가도 인사가 시작되지 않았다.
        let playerDistance = simd_distance(player, currentClerkPosition)
        handleDialogueSignals()
        finishAcceptedOrderPresentationIfReady()

        // 대화 시작부터 종료 이벤트 처리 전까지는 phase 변화와 무관하게 위치를 잠근다.
        // 비동기 음성 세션이 greeting/conversing 사이를 오가는 동안 업무 동선이 끼어들어
        // 점원이 사용자를 두고 걸어가는 현상을 방지하고, 회전만 사용자 쪽으로 허용한다.
        if let anchor = conversationAnchor {
            if !isRemoteDevelopmentConversation,
               playerDistance > NPCClerkTuning.conversationExitRadius {
                endEncounterForDeparture()
                return
            }
            holdPosition(at: anchor)
            isTalkAvailable = false
            face(point: player, deltaTime: dt)
            return
        }

        isTalkAvailable = (phase == .working || phase == .orderAccepted)
            && playerDistance <= NPCClerkTuning.detectionRadius
            && GuideFlowModel.shared.allowsNPCOrderConversation

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

        case .orderAccepted:
            updateWorkLoop(deltaTime: dt)
        }

    }

    /// Barista 위의 공간 버튼에서 호출한다. 자동 근접 인사 대신 사용자의 명시적인
    /// 선택으로만 대화를 시작해 NPC가 갑자기 말을 거는 느낌을 없앤다.
    func startConversation() {
        guard isTalkAvailable else { return }
        _ = beginGreeting(isRemoteDevelopmentConversation: false)
    }

    /// ControlPanel의 대화 테스트에서 근접 조건만 우회하고 실제 대화 상태 머신을 시작한다.
    /// 카페 씬과 세 번째 미션 활성화 조건은 그대로 요구한다.
    @discardableResult
    func startConversationForDevelopment() -> Bool {
        beginGreeting(isRemoteDevelopmentConversation: true)
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
        let workAreaMin: SIMD2<Float>
        let workAreaMax: SIMD2<Float>
    }

    private func makePlacement(in indoorMap: Entity,
                               relativeTo worldRoot: Entity,
                               kioskCenter: SIMD2<Float>) -> Placement {
        var areaMin = NPCClerkTuning.fallbackAreaMin
        var areaMax = NPCClerkTuning.fallbackAreaMax
        var home = NPCClerkTuning.fallbackStaffHome
        if let area = indoorMap.findEntity(named: "AreaK") {
            let bounds = area.visualBounds(relativeTo: worldRoot)
            areaMin = SIMD2(bounds.min.x, bounds.min.z)
            areaMax = SIMD2(bounds.max.x, bounds.max.z)
            home = SIMD2(bounds.center.x, bounds.center.z)
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

        let insetMin = areaMin + NPCClerkTuning.workAreaMargin
        let insetMax = areaMax - NPCClerkTuning.workAreaMargin
        // 마커가 여백보다 좁은 축에서도 닫힌 난수 범위를 만들 수 있도록 정규화한다.
        let roamMin = SIMD2<Float>(Swift.min(insetMin.x, insetMax.x),
                                   Swift.min(insetMin.y, insetMax.y))
        let roamMax = SIMD2<Float>(Swift.max(insetMin.x, insetMax.x),
                                   Swift.max(insetMin.y, insetMax.y))
        home = clamp(home, minimum: roamMin, maximum: roamMax)
        service = clamp(service, minimum: roamMin, maximum: roamMax)

        return Placement(staffHome: home,
                         servicePoint: service,
                         customerPoint: customer,
                         workAreaMin: roamMin,
                         workAreaMax: roamMax)
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
        if workPauseRemaining > 0 {
            workPauseRemaining = max(0, workPauseRemaining - deltaTime)
            playAnimation(.idle)
            return
        }
        if workTarget == nil {
            workTarget = randomWorkTarget(awayFrom: currentClerkPosition)
        }
        guard let workTarget else {
            playAnimation(.idle)
            return
        }
        playAnimation(.walk)
        if move(toward: workTarget, deltaTime: deltaTime) {
            self.workTarget = nil
            workPauseRemaining = randomWorkPause()
            playAnimation(.idle)
        }
    }

    private func randomWorkTarget(awayFrom current: SIMD2<Float>) -> SIMD2<Float>? {
        guard workAreaMin.x <= workAreaMax.x,
              workAreaMin.y <= workAreaMax.y else { return nil }

        var fallback = current
        // 좁거나 긴 AreaK에서도 무한 반복하지 않도록 유한 횟수 뒤 마지막 후보를 사용한다.
        for _ in 0..<8 {
            let candidate = SIMD2<Float>(
                Float.random(in: workAreaMin.x...workAreaMax.x),
                Float.random(in: workAreaMin.y...workAreaMax.y)
            )
            fallback = candidate
            if simd_distance(candidate, current) >= NPCClerkTuning.minimumRoamDistance {
                return candidate
            }
        }
        return fallback
    }

    private func randomWorkPause() -> Float {
        Float.random(in: NPCClerkTuning.workPauseRange)
    }

    @discardableResult
    private func move(toward target: SIMD2<Float>, deltaTime: Float) -> Bool {
        guard conversationAnchor == nil,
              let root = locomotionRoot else { return false }
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

    private func holdPosition(at anchor: SIMD2<Float>) {
        guard let root = locomotionRoot else { return }
        root.position.x = anchor.x
        root.position.z = anchor.y
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

    @discardableResult
    private func beginGreeting(isRemoteDevelopmentConversation: Bool) -> Bool {
        guard phase == .working || phase == .orderAccepted,
              GuideFlowModel.shared.allowsNPCOrderConversation else { return false }
        // 비동기 startEncounter보다 먼저 잠가 버튼을 누른 바로 그 프레임부터 이동을 막는다.
        self.isRemoteDevelopmentConversation = isRemoteDevelopmentConversation
        conversationAnchor = currentClerkPosition
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
            if self.dialogue.isEncounterActive {
                self.phase = .conversing
            } else {
                self.isRemoteDevelopmentConversation = false
                self.conversationAnchor = nil
                self.phase = .working
                self.workTarget = nil
                self.workPauseRemaining = self.randomWorkPause()
            }
        }
        return true
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
            GuideFlowModel.shared.handleQuestEvent(.npcHelpDone)
            pendingOrderConversationEnd = true
            finishAcceptedOrderPresentationIfReady()
        case .exited:
            pendingOrderConversationEnd = false
            isRemoteDevelopmentConversation = false
            conversationAnchor = nil
            greetingTask?.cancel()
            greetingTask = nil
            dialogue.cancelEncounter()
            setInteractionBubbleVisible(true)
            phase = .working
            workTarget = nil
            workPauseRemaining = randomWorkPause()
        case .helpRequested, .none:
            break
        }
    }

    /// 주문 접수 이벤트는 대화 세션이 닫힌 뒤 전달된다. NPC도 같은 시점에 업무 상태로
    /// 전환하며, 전체 퀘스트 완료는 음료 준비·수령·착석 후속 단계가 별도로 결정한다.
    private func finishAcceptedOrderPresentationIfReady() {
        guard pendingOrderConversationEnd, !dialogue.isEncounterActive else { return }
        pendingOrderConversationEnd = false
        isRemoteDevelopmentConversation = false
        conversationAnchor = nil
        phase = .orderAccepted
        workTarget = nil
        workPauseRemaining = randomWorkPause()
        playAnimation(.idle)
    }

    /// 대화 중 사용자가 멀어지면 즉시 마이크를 닫고 말 걸기 상태로 돌아간다.
    private func endEncounterForDeparture() {
        isRemoteDevelopmentConversation = false
        conversationAnchor = nil
        greetingTask?.cancel()
        greetingTask = nil
        dialogue.cancelEncounter()
        setInteractionBubbleVisible(true)
        phase = .working
        workTarget = nil
        workPauseRemaining = randomWorkPause()
    }

    // MARK: - Animation

    private func playAnimation(_ cue: NPCAnimationCue,
                               restart: Bool = false,
                               allowsGreetingReplay: Bool = false) {
        guard restart || lastPlayedAnimation != cue.rawValue else { return }
        guard cue != .greet || !hasPlayedGreetingAnimation || allowsGreetingReplay else { return }
        guard let barista = baristaEntity,
              let match = findAnimation(named: cue.rawValue, in: barista) else { return }
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

    // MARK: - Spatial interaction bubble

    private func setInteractionBubbleVisible(_ visible: Bool) {
        isInteractionBubbleVisible = visible
        interactionBubble?.isEnabled = visible
            && !isGuideInteractionLocked
            && GuideFlowModel.shared.allowsNPCOrderConversation
    }

}
