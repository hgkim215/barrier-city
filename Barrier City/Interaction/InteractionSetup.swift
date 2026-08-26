//
//  InteractionSetup.swift
//  Barrier City
//
//  ImmersiveView make 클로저 끝에서 한 번 호출되는 설치 함수와,
//  SceneEvents.Update 구독으로 매 프레임 도는 근접 판정(tick).
//
//  RealityKit System 대신 구독을 쓰는 이유: System은 씬 생성 전 registerSystem이
//  필요해 AppModel(이윤서 파일) 수정이 강제되지만, 구독은 이 훅 안에서 완결된다.
//

import RealityKit
import SwiftUI
import simd

extension AppModel: OutdoorSessionResettable {
    var posX: Float {
        get { motion.positionX }
        set { motion.positionX = newValue }
    }

    var posZ: Float {
        get { motion.positionZ }
        set { motion.positionZ = newValue }
    }

    var heading: Float {
        get { motion.heading }
        set { motion.heading = newValue }
    }
}

@MainActor
enum InteractionSetup {

    /// ImmersiveView make 클로저 끝에서 호출. 전제: model.worldRoot와
    /// InteractionModel.shared.visibleMap이 설정된 뒤여야 한다.
    static func install(content: RealityViewContent,
                        attachments: RealityViewAttachments,
                        appModel: AppModel) {
        let im = InteractionModel.shared

        // 0) 매 진입마다 주행과 Outdoor 인터랙션을 새 세션 상태로 리셋.
        appModel.restart()
        //    InteractionModel은 싱글턴이라 '체험 종료' 후에도 상태가 남는다. 첫 입장에서
        //    scene이 .indoor가 된 채 재진입하면 switchToIndoor의 `scene == .outdoor` 가드가
        //    막혀 "예"를 눌러도 전환이 안 되던 버그를 방지한다.
        im.beginImmersiveSession()
        im.scene = .outdoor
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.transitionError = nil
        appModel.rainbowSmoothieServing.resetForOutdoor()
        appModel.npcClerk.tearDownForOutdoor()
        appModel.npcGuests.tearDownForOutdoor()

        SceneFadeOverlay.shared.install(content: content)

        // 1) 문 선택 패널은 사용자 기준 content root에 두어 문과 분리한다.
        if let panel = attachments.entity(for: "entryPrompt") {
            panel.isEnabled = false
            content.add(panel)
            im.panelEntity = panel
        }

        // 키오스크와 NPC attachment는 기존대로 맵과 함께 움직인다.
        if let worldRoot = appModel.worldRoot {
            if let kiosk = attachments.entity(for: "kioskScreen") {
                kiosk.isEnabled = false
                worldRoot.addChild(kiosk)
                im.kioskPanelEntity = kiosk
            }
            if let npcInteraction = attachments.entity(for: "npcInteraction") {
                appModel.npcClerk.installInteractionBubble(npcInteraction, in: worldRoot)
            }
        }

        // 2) 문 트리거 등록: 최신 Outdoor의 Door 프림 좌표를 찾고, 실패 시 authored 폴백 사용.
        var center = InteractionTuning.doorFallbackCenter
        if let worldRoot = appModel.worldRoot,
           let door = im.visibleMap?.findEntity(named: "Door") {
            let p = door.position(relativeTo: worldRoot)
            center = SIMD2(p.x, p.z)
        }

        let fallbackHalfExtent = InteractionTuning.outdoorGroundPlaneSize * 0.5
        let groundLayout = im.outdoorGroundLayout ?? SceneGroundLayout(
            minimum: SIMD2(repeating: -fallbackHalfExtent),
            maximum: SIMD2(repeating: fallbackHalfExtent),
            height: 0)
        // immersive space는 열리는 순간 유저의 실제 위치를 (0,0,0)으로 앵커링한다.
        // 여기서 0이 아닌 위치로 스폰시키면 worldRoot가 그 위치의 역변환만큼 밀려나
        // 첫 진입 시 카페 전체가 유저 기준으로 어긋난 채 나타난다. 문 앞 오프셋
        // 스폰(positionOutsideCafe)은 그래서 첫 진입에는 쓰지 않는다.
        //
        // develop 브랜치의 "도로 스폰 위치"(Road_23/Road_24 중간점, 94fdfd8 이후
        // 294a7d6에서 도입) 기능은 이 (0,0) 고정 버그 수정과 정면으로 충돌해
        // develop → yslee 병합 시 의도적으로 보류했다. 폴백 좌표(roadMidpointFallbackSpawnPosition)를
        // 포함한 관련 상수/헬퍼(OutdoorSessionStart.roadMidpointPosition,
        // InteractionTuning.roadMidpointFallbackSpawnPosition)는 코드에 남겨 뒀으니,
        // 재검토 시 여기서 startPosition만 다시 연결하면 된다.
        let startPosition = InteractionTuning.outdoorSpawnPosition

        OutdoorSessionStart.reset(
            appModel,
            startPosition: startPosition,
            doorCenter: center,
            fallbackDoorCenter: InteractionTuning.doorFallbackCenter)
        
        // 첫 raycast 전에도 휠체어와 보이는 지면이 정확히 맞도록 authored 높이로 시작한다.
        appModel.motion.chairHeight = groundLayout.height
        appModel.motion.groundHeight = groundLayout.height
        im.triggers = [ProximityTrigger(
            id: "door.enter",
            center: center,
            radius: InteractionTuning.doorTriggerRadius,
            prompt: InteractionTuning.doorPrompt,
            confirmLabel: "예",
            cancelLabel: "아니요")]

        // 3) 매 프레임 근접 판정 구독(구독 객체를 보관해야 해제되지 않는다).
        im.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
            tick(deltaTime: Float(event.deltaTime))
        }

        // 4) [김현기] 퀘스트 가이드 HUD 설치(HUD는 씬 루트에 붙고 head를 따라간다).
        QuestSetup.install(content: content, attachments: attachments, appModel: appModel)
    }

    /// 매 프레임: 판정 → activeTrigger 갱신 → 패널 표시·배치·빌보드.
    private static func tick(deltaTime: Float) {
        SceneFadeOverlay.shared.update(deltaTime: deltaTime)
        guard let app = AppModel.current else { return }
        let im = InteractionModel.shared
        let guide = GuideFlowModel.shared
        let isIndoor = im.scene == .indoor
        let isMissionTwoActive = guide.phase == .missionActive(index: 1)

        if guide.isInteractionLocked {
            im.activeTrigger = nil
            im.panelEntity?.isEnabled = false
            im.updateKioskContext(
                isIndoor: isIndoor,
                isNear: false,
                isMissionTwoActive: false,
                isGuideLocked: true)
            updatePanel(im)
            app.npcClerk.setGuideInteractionLocked(true)
            // 퀘스트 확인 패널이 떠 있는 동안(대화 시작은 allowsNPCOrderConversation이
            // 별도로 막는다)에도 NPC는 계속 움직여야 카페가 살아있는 느낌이 든다.
            app.npcClerk.update(deltaTime: deltaTime, appModel: app)
            app.npcGuests.update(deltaTime: deltaTime, appModel: app, isOrdering: false, kioskCenter: nil)
            return
        }
        guard !im.isTransitioning, !im.isBootLoading else { return }
        app.npcClerk.setGuideInteractionLocked(false)

        let verdict = InteractionModel.evaluate(
            playerX: app.motion.positionX, playerZ: app.motion.positionZ,
            triggers: im.triggers,
            activeID: im.activeTrigger?.id,
            dismissedID: im.dismissedTriggerID)

        if verdict.clearDismissed { im.dismissedTriggerID = nil }
        if im.activeTrigger?.id != verdict.showID {
            im.activeTrigger = verdict.showID.flatMap { id in im.triggers.first { $0.id == id } }
            if im.activeTrigger == nil { im.transitionError = nil }   // 닫힐 때 안내 문구도 정리
        }
        let isNearKiosk = im.activeTrigger?.kind == .kioskScreen
        im.updateKioskContext(
            isIndoor: isIndoor,
            isNear: isNearKiosk,
            isMissionTwoActive: isMissionTwoActive,
            isGuideLocked: false)

        if isIndoor,
           im.kioskPanelEntity == nil,
           isMissionTwoActive,
           !im.kioskFailOpenSent {
            im.kioskFailOpenSent = true
            guide.handleQuestEvent(.kioskFailed)
        }

        // 미션 6 (지정 좌석으로 이동) 활성 시 WayPoint 도착 판정
        if isIndoor, QuestModel.shared.currentIndex == 5 {
            let dest = app.waypointPresenter.destinationPosition
            let dx = app.motion.positionX - dest.x
            let dz = app.motion.positionZ - dest.z
            let distance = sqrt(dx * dx + dz * dz)
            if distance <= app.waypointPresenter.arrivalRadius {
                guide.handleQuestEvent(.seatedAtTable)
                app.waypointPresenter.hide()
            }
        }

        updatePanel(im)
        app.npcClerk.update(deltaTime: deltaTime, appModel: app)
        // 대기줄은 키오스크 UI가 열리는 진입 반경(kioskTriggerRadius, 3.0m)이 아니라
        // 유저가 실제로 키오스크 바로 앞에 서 있을 때(guestQueueTriggerRadius)를
        // 기준으로 형성한다 — 같은 반경을 쓰면 유저가 트리거 가장자리에 있을 때 줄이
        // 유저에게서 너무 멀리 떨어져 보인다.
        let playerPosition = SIMD2(app.motion.positionX, app.motion.positionZ)
        let isCloseEnoughForQueue = isNearKiosk
            && im.activeTrigger.map {
                simd_distance(playerPosition, $0.center) <= InteractionTuning.guestQueueTriggerRadius
            } == true
        app.npcGuests.update(deltaTime: deltaTime,
                             appModel: app,
                             isOrdering: isCloseEnoughForQueue,
                             kioskCenter: isCloseEnoughForQueue ? im.activeTrigger?.center : nil)
    }

    /// 활성 트리거의 kind에 맞는 패널만 눈높이 빌보드로 표시한다(문·키오스크 둘 다 사용자를 향함).
    /// 키오스크는 박스에 묻히지 않도록 사용자 쪽으로 당겨(forwardOffset) 표면 앞에 띄운다.
    private static func updatePanel(_ im: InteractionModel) {
        let trigger = im.activeTrigger
        showBillboard(im.panelEntity, active: trigger?.kind == .yesNoPrompt,
                      trigger: trigger)
        if im.kioskUsesBillboardFallback {
            showBillboard(
                im.kioskPanelEntity,
                active: im.kioskMenuVisible && trigger?.kind == .kioskScreen,
                trigger: trigger)
        } else {
            im.kioskPanelEntity?.isEnabled = im.kioskMenuVisible
        }
    }

    /// 문 패널은 사용자 눈앞 고정 좌표, 키오스크 폴백은 트리거 앞에 배치한 뒤
    /// 사용자를 향하도록 yaw 빌보드로 만든다.
    private static func showBillboard(_ panel: Entity?, active: Bool,
                                      trigger: ProximityTrigger?) {
        guard let panel else { return }
        guard active, let t = trigger else {
            if panel.isEnabled { panel.isEnabled = false }
            return
        }
        if !panel.isEnabled { panel.isEnabled = true }
        // 1) 트리거 중심 위 눈높이에 임시 배치하고 월드 위치를 얻는다.
        panel.setPosition([t.center.x, InteractionTuning.panelHeight, t.center.y],
                          relativeTo: panel.parent)
        var worldPos = panel.position(relativeTo: nil)

        // 2) 문 패널은 온보딩/미션 카드와 같은 높이·거리에 둔다.
        //    예전에는 고정 좌표(y 1.35)라 가이드 카드보다 30cm 가까이 높았다.
        //    QuestHUDFollower가 관측한 실제 눈높이를 기준으로 삼아, 앉은 자세에서도
        //    가이드 카드와 같은 자리에 오게 한다. 키오스크는 표면 앞 배치 그대로.
        let eyeHeight = QuestSetup.baselineEyeHeight
            ?? InteractionTuning.doorPromptFallbackEyeHeight
        if t.kind == .yesNoPrompt {
            worldPos = SIMD3(0,
                             eyeHeight + QuestTuning.cardVerticalOffset,
                             -QuestTuning.cardDistance)
        } else {
            worldPos = InteractionPanelPlacement.worldPosition(
                worldPos,
                toward: .zero,
                kind: t.kind)
        }
        panel.setPosition(worldPos, relativeTo: nil)

        // 3) 사용자를 향하도록 yaw 빌보드 + 시선각만큼 상향 틸트.
        let yaw = atan2(-worldPos.x, -worldPos.z)
        let yawQuat = simd_quatf(angle: yaw, axis: [0, 1, 0])
        var pitchAngle: Float = 0
        if t.kind == .yesNoPrompt {
            let horizontal = max(simd_length(SIMD2(worldPos.x, worldPos.z)), 1e-4)
            pitchAngle = -min(atan2(eyeHeight - worldPos.y, horizontal)
                                * QuestTuning.cardPitchRatio,
                              QuestTuning.cardMaxPitch)
        }
        let pitchQuat = simd_quatf(angle: pitchAngle, axis: [1, 0, 0])
        panel.setOrientation(yawQuat * pitchQuat, relativeTo: nil)
    }
}
