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

extension AppModel: OutdoorSessionResettable {}

@MainActor
enum InteractionSetup {

    /// ImmersiveView make 클로저 끝에서 호출. 전제: model.worldRoot와
    /// InteractionModel.shared.visibleMap이 설정된 뒤여야 한다.
    static func install(content: RealityViewContent,
                        attachments: RealityViewAttachments,
                        appModel: AppModel) {
        let im = InteractionModel.shared

        // 0) 매 진입마다 Outdoor 초기 상태로 리셋.
        //    InteractionModel은 싱글턴이라 '체험 종료' 후에도 상태가 남는다. 첫 입장에서
        //    scene이 .indoor가 된 채 재진입하면 switchToIndoor의 `scene == .outdoor` 가드가
        //    막혀 "예"를 눌러도 전환이 안 되던 버그를 방지한다.
        im.beginImmersiveSession()
        im.scene = .outdoor
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.transitionError = nil
        appModel.npcClerk.resetForOutdoor()

        // 1) 패널 attachment들을 worldRoot 아래에 배치(초기 숨김) — 맵과 함께 움직인다.
        if let worldRoot = appModel.worldRoot {
            if let panel = attachments.entity(for: "entryPrompt") {
                panel.isEnabled = false
                worldRoot.addChild(panel)
                im.panelEntity = panel
            } else {
                print("⚠️ entryPrompt attachment 없음 — 문 패널 비활성")
            }
            if let kiosk = attachments.entity(for: "kioskScreen") {
                kiosk.isEnabled = false
                worldRoot.addChild(kiosk)
                im.kioskPanelEntity = kiosk
            } else {
                print("⚠️ kioskScreen attachment 없음 — 키오스크 화면 비활성")
            }
            if let npcDialogue = attachments.entity(for: "npcDialogue") {
                appModel.npcClerk.installDialoguePanel(npcDialogue, in: worldRoot)
            } else {
                print("⚠️ npcDialogue attachment 없음 — 점원 대화 패널 비활성")
            }
        } else {
            print("⚠️ worldRoot 없음 — 인터랙션 패널 비활성")
        }

        // 2) 문 트리거 등록: 로드된 맵에서 DOOR1 프림의 맵 좌표를 찾고, 실패 시 폴백 상수.
        var center = InteractionTuning.doorFallbackCenter
        if let worldRoot = appModel.worldRoot,
           let door = im.visibleMap?.findEntity(named: "DOOR1") {
            let p = door.position(relativeTo: worldRoot)
            center = SIMD2(p.x, p.z)
            print("문 트리거: DOOR1 위치 사용 (\(p.x), \(p.z))")
        } else {
            print("⚠️ DOOR1 프림을 찾지 못해 폴백 좌표 사용: \(center)")
        }
        OutdoorSessionStart.reset(
            appModel,
            startPosition: .zero,
            doorCenter: center,
            fallbackDoorCenter: InteractionTuning.doorFallbackCenter)
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
            playerX: app.posX, playerZ: app.posZ,
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
    }

    /// 활성 트리거의 kind에 맞는 패널만 눈높이 빌보드로 표시한다(문·키오스크 둘 다 사용자를 향함).
    /// 키오스크는 박스에 묻히지 않도록 사용자 쪽으로 당겨(forwardOffset) 표면 앞에 띄운다.
    private static func updatePanel(_ im: InteractionModel) {
        let trigger = im.activeTrigger
        showBillboard(im.panelEntity, active: trigger?.kind == .yesNoPrompt,
                      trigger: trigger, forwardOffset: 0)
        if im.kioskUsesBillboardFallback {
            showBillboard(
                im.kioskPanelEntity,
                active: im.kioskMenuVisible && trigger?.kind == .kioskScreen,
                trigger: trigger,
                forwardOffset: InteractionTuning.kioskPanelForwardOffset)
        } else {
            im.kioskPanelEntity?.isEnabled = im.kioskMenuVisible
        }
    }

    /// 패널을 트리거 중심 위 눈높이(panelHeight)에 놓되, forwardOffset만큼 사용자(세계 원점)
    /// 쪽으로 당긴 뒤 사용자를 향하도록 yaw 빌보드. 빌보드라 접근 각도와 무관하게 정면으로 보인다.
    private static func showBillboard(_ panel: Entity?, active: Bool,
                                      trigger: ProximityTrigger?, forwardOffset: Float) {
        guard let panel else { return }
        guard active, let t = trigger else {
            panel.isEnabled = false
            return
        }
        panel.isEnabled = true
        // 1) 트리거 중심 위 눈높이(맵 로컬)에 놓고 월드 위치를 얻는다.
        panel.setPosition([t.center.x, InteractionTuning.panelHeight, t.center.y],
                          relativeTo: panel.parent)
        var worldPos = panel.position(relativeTo: nil)
        // 2) 사용자(세계 원점)를 향하는 수평 방향으로 forwardOffset만큼 당겨 표면 앞으로.
        let horiz = SIMD2(worldPos.x, worldPos.z)
        let dist = simd_length(horiz)
        if forwardOffset > 0, dist > 0.001 {
            let pulled = horiz - (horiz / dist) * forwardOffset   // 원점 쪽으로 당김
            worldPos.x = pulled.x
            worldPos.z = pulled.y
            panel.setPosition(worldPos, relativeTo: nil)
        }
        // 3) 사용자를 향하도록 yaw 빌보드.
        let yaw = atan2(-worldPos.x, -worldPos.z)
        panel.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
    }
}
