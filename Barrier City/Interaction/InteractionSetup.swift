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
        var cafeCenter = SIMD2<Float>.zero
        if let worldRoot = appModel.worldRoot,
           let door = im.visibleMap?.findEntity(named: "Door") {
            let p = door.position(relativeTo: worldRoot)
            center = SIMD2(p.x, p.z)
        }

        if let worldRoot = appModel.worldRoot,
                   let cafe = im.visibleMap?.findEntity(named: "Outdoor") {
                    let bounds = cafe.visualBounds(relativeTo: worldRoot)
                    cafeCenter = SIMD2(bounds.center.x, bounds.center.z)
                }
                let fallbackHalfExtent = InteractionTuning.outdoorGroundPlaneSize * 0.5
                let groundLayout = im.outdoorGroundLayout ?? SceneGroundLayout(
                    minimum: SIMD2(repeating: -fallbackHalfExtent),
                    maximum: SIMD2(repeating: fallbackHalfExtent),
                    height: 0)
                let startPosition = OutdoorSessionStart.positionOutsideCafe(
                    doorCenter: center,
                    cafeCenter: cafeCenter,
                    fallbackDoorCenter: InteractionTuning.doorFallbackCenter,
                    groundMinimum: groundLayout.minimum,
                    groundMaximum: groundLayout.maximum,
                    preferredDistance: InteractionTuning.outdoorSpawnDistanceFromDoor,
                    safetyMargin: InteractionTuning.outdoorSpawnSafetyMargin)

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
            return
        }
        guard !im.isTransitioning else { return }
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
        updatePanel(im)
        app.npcClerk.update(deltaTime: deltaTime, appModel: app)
        app.npcGuests.update(deltaTime: deltaTime,
                             appModel: app,
                             isOrdering: isNearKiosk,
                             kioskCenter: isNearKiosk ? im.activeTrigger?.center : nil)
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
        // 2) 문은 눈앞 고정 좌표, 키오스크는 표면 앞 월드 좌표로 변환한다.
        worldPos = InteractionPanelPlacement.worldPosition(
            worldPos,
            toward: .zero,
            kind: t.kind)
        panel.setPosition(worldPos, relativeTo: nil)
        // 3) 사용자를 향하도록 yaw 빌보드.
        let yaw = atan2(-worldPos.x, -worldPos.z)
        panel.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
    }
}
