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

    /// ImmersiveView make 클로저 끝에서 호출. 전제: model.worldRoot와
    /// InteractionModel.shared.visibleMap이 설정된 뒤여야 한다.
    static func install(content: RealityViewContent,
                        attachments: RealityViewAttachments,
                        appModel: AppModel) {
        let im = InteractionModel.shared

        // 1) 패널 attachment를 worldRoot 아래에 배치(초기 숨김) — 맵과 함께 움직인다.
        if let panel = attachments.entity(for: "entryPrompt"), let worldRoot = appModel.worldRoot {
            panel.isEnabled = false
            worldRoot.addChild(panel)
            im.panelEntity = panel
        } else {
            print("⚠️ entryPrompt attachment 또는 worldRoot 없음 — 인터랙션 패널 비활성")
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
        im.triggers = [ProximityTrigger(
            id: "door.enter",
            center: center,
            radius: InteractionTuning.doorTriggerRadius,
            prompt: InteractionTuning.doorPrompt,
            confirmLabel: "예",
            cancelLabel: "아니요")]

        // 3) 매 프레임 근접 판정 구독(구독 객체를 보관해야 해제되지 않는다).
        im.updateSubscription = content.subscribe(to: SceneEvents.Update.self) { _ in
            tick()
        }
    }

    /// 매 프레임: 판정 → activeTrigger 갱신 → 패널 표시·배치·빌보드.
    private static func tick() {
        guard let app = AppModel.current else { return }
        let im = InteractionModel.shared
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
    }

    /// 패널을 트리거 위 눈높이에 놓고, 사용자(세계 원점 부근)를 바라보게 yaw 빌보드.
    private static func updatePanel(_ im: InteractionModel) {
        guard let panel = im.panelEntity else { return }
        guard let trigger = im.activeTrigger else {
            panel.isEnabled = false
            return
        }
        panel.isEnabled = true
        // 위치: 맵 좌표(worldRoot 로컬) — 트리거 중심 위 panelHeight.
        panel.setPosition([trigger.center.x, InteractionTuning.panelHeight, trigger.center.y],
                          relativeTo: panel.parent)
        // 빌보드: 사용자는 항상 세계 원점 부근(세계가 역변환으로 움직이므로).
        // 패널의 세계 위치에서 원점을 향하는 yaw만 적용한다.
        let worldPos = panel.position(relativeTo: nil)
        let yaw = atan2(-worldPos.x, -worldPos.z)
        panel.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
    }
}
