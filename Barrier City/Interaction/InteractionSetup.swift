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

@MainActor
enum InteractionSetup {

    /// 일어서기 가드(설치 시 시작, 씬 루트의 오버레이를 관리).
    private static var standUpGuard: StandUpGuard?

    /// 직전 프레임에 NPC 대화 트리거가 활성이었는가(활성화 엣지 검출용).
    private static var npcWasActive = false

    /// NPC 트리거가 활성화되는 순간 `.npcHelpDone`을 다시 발행해야 하는가(순수 판정).
    ///
    /// NPC 트리거는 항상 활성이라(fail-open) 사용자가 키오스크보다 먼저 직원에게 주문할 수
    /// 있다. 그때 발행된 `.npcHelpDone`은 퀘스트가 아직 2단계라 버려지는데,
    /// `NPCOrderModel.completed`는 한 번 켜지면 꺼지지 않아 패널이 완료 화면만 보여주고
    /// `release()`·`selectFallback`이 모두 막힌다 — 이벤트를 다시 낼 방법이 없어 최종 단계가
    /// 영영 완료되지 않는다. 그래서 트리거에 다시 다가오는 순간 조건을 확인해 재발행한다.
    nonisolated static func shouldRefireNPCDone(activationEdge: Bool,
                                               completed: Bool,
                                               pendingEvent: QuestEvent?) -> Bool {
        activationEdge && completed && pendingEvent == .npcHelpDone
    }

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
        im.scene = .outdoor
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.isTransitioning = false
        im.transitionError = nil
        KioskFlowModel.shared.reset()
        NPCSetup.reset()
        NPCOrderModel.shared.reset()
        kioskPlacedForTriggerID = nil
        npcWasActive = false

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
            if let npc = attachments.entity(for: "npcOrder") {
                npc.isEnabled = false
                worldRoot.addChild(npc)
                im.npcPanelEntity = npc
            } else {
                print("⚠️ npcOrder attachment 없음 — NPC 대화 패널 비활성")
            }
        } else {
            print("⚠️ worldRoot 없음 — 인터랙션 패널 비활성")
        }

        // 1.5) 일어서기 가드: 오버레이는 씬 루트에(맵과 함께 움직이면 안 된다).
        //     이전 인스턴스를 먼저 멈춘다 — 안 그러면 몰입 공간에 드나들 때마다
        //     ARKitSession이 하나씩 살아남아 전시장처럼 재진입이 잦은 환경에서 누적된다.
        standUpGuard?.stop()
        let guardInstance = StandUpGuard()
        if let overlay = attachments.entity(for: "standUpOverlay") {
            overlay.isEnabled = false
            content.add(overlay)
            guardInstance.overlayEntity = overlay
        } else {
            print("⚠️ standUpOverlay attachment 없음 — 일어서기 안내 비활성")
        }
        standUpGuard = guardInstance
        Task { await guardInstance.start() }

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
        im.triggers = [ProximityTrigger(
            id: "door.enter",
            center: center,
            radius: InteractionTuning.doorTriggerRadius,
            prompt: InteractionTuning.doorPrompt,
            confirmLabel: "예",
            cancelLabel: "아니요")]

        // 3) 매 프레임 근접 판정 구독(구독 객체를 보관해야 해제되지 않는다).
        im.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
            tick(dt: Float(event.deltaTime))
        }

        // 4) [김현기] 퀘스트 가이드 HUD 설치(HUD는 씬 루트에 붙고 head를 따라간다).
        QuestSetup.install(content: content, attachments: attachments, appModel: appModel)
    }

    /// 매 프레임: 판정 → activeTrigger 갱신 → 패널 표시·배치 → 키오스크 리치·타이머.
    private static func tick(dt: Float) {
        guard let app = AppModel.current else { return }
        let im = InteractionModel.shared
        // 일어서기 가드는 트리거·씬 전환과 무관(자기 오버레이만 갱신)하므로 전환 중에도
        // 계속 돌아야 한다 — 실내 로드처럼 여러 프레임 걸리는 전환 동안 멈추면 안 된다.
        standUpGuard?.tick()
        guard !im.isTransitioning else { return }

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
        updatePanel(im)

        // [NPC] 트리거가 활성화되는 순간, 이미 주문을 마쳤는데 퀘스트가 그 단계를
        // 기다리고 있으면(= 키오스크보다 먼저 주문한 경우) 완료 이벤트를 다시 발행한다.
        let npcNowActive = (im.activeTrigger?.kind == .npcDialogue)
        if shouldRefireNPCDone(activationEdge: npcNowActive && !npcWasActive,
                               completed: NPCOrderModel.shared.completed,
                               pendingEvent: QuestModel.shared.currentStep?.completionEvent) {
            QuestModel.shared.advance(on: .npcHelpDone)
        }
        npcWasActive = npcNowActive

        // [키오스크] 활성 여부·리치 판정 갱신 후 상태 머신 진행.
        let kfm = KioskFlowModel.shared
        let kioskNowActive = (im.activeTrigger?.kind == .kioskScreen)
        if kioskNowActive && !kfm.isActive { kfm.resumeAtTrigger() }   // 재진입: 유휴 타이머만 리셋
        kfm.isActive = kioskNowActive
        if kfm.isActive, let panel = im.kioskPanelEntity {
            let world = panel.position(relativeTo: nil)
            let kioskXZ = SIMD2(world.x, world.z)
            func reaches(_ hand: SIMD3<Float>?) -> Bool {
                KioskFlowLogic.canReach(hand: hand, kioskXZ: kioskXZ,
                                        zoneMinY: KioskTuning.upperZoneMinY,
                                        margin: KioskTuning.reachMargin,
                                        maxXZ: KioskTuning.reachMaxXZ)
            }
            kfm.reachableUpper = reaches(app.handWorldLeft) || reaches(app.handWorldRight)
        } else {
            kfm.reachableUpper = false
        }
        // 전환 중이면 위의 `guard !im.isTransitioning`에서 이미 반환됐으므로 여기선 항상 false다.
        // (KioskFlowModel.tick 자체의 !transitioning 검사는 다른 호출자·테스트를 위해 유지)
        kfm.tick(dt: dt, transitioning: false)
    }

    /// 키오스크 화면을 월드에 고정한 트리거 id(활성화 시 1회 배치용).
    private static var kioskPlacedForTriggerID: String?

    /// 활성 트리거의 kind에 맞는 패널만 표시.
    /// 문 패널: 기존 눈높이 빌보드. 키오스크: 활성화 순간 1회 월드 고정(실물 화면처럼
    /// 접근 각도와 무관하게 공간에 붙박이 — 이후 프레임에는 위치를 건드리지 않는다).
    private static func updatePanel(_ im: InteractionModel) {
        let trigger = im.activeTrigger
        showBillboard(im.panelEntity, active: trigger?.kind == .yesNoPrompt,
                      trigger: trigger, forwardOffset: 0)
        showBillboard(im.npcPanelEntity, active: trigger?.kind == .npcDialogue,
                      trigger: trigger, forwardOffset: 0.5)

        let kioskActive = trigger?.kind == .kioskScreen
        if let kiosk = im.kioskPanelEntity {
            kiosk.isEnabled = kioskActive
            if kioskActive, let t = trigger, kioskPlacedForTriggerID != t.id {
                placeKioskFixed(kiosk, trigger: t)
                kioskPlacedForTriggerID = t.id
            }
            if !kioskActive { kioskPlacedForTriggerID = nil }
        }
    }

    /// 키오스크 화면을 트리거 중심 위 화면 높이에 놓고, 사용자(세계 원점) 쪽으로
    /// forwardOffset만큼 당긴 뒤 사용자를 향해 1회 회전(이후 고정).
    private static func placeKioskFixed(_ panel: Entity, trigger t: ProximityTrigger) {
        panel.setPosition([t.center.x, KioskTuning.screenCenterY, t.center.y],
                          relativeTo: panel.parent)
        var worldPos = panel.position(relativeTo: nil)
        let horiz = SIMD2(worldPos.x, worldPos.z)
        let dist = simd_length(horiz)
        if dist > 0.001 {
            let pulled = horiz - (horiz / dist) * InteractionTuning.kioskPanelForwardOffset
            worldPos.x = pulled.x
            worldPos.z = pulled.y
            panel.setPosition(worldPos, relativeTo: nil)
        }
        let yaw = atan2(-worldPos.x, -worldPos.z)
        panel.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
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
