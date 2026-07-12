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

        // 0) 매 진입마다 Outdoor 초기 상태로 리셋.
        //    InteractionModel은 싱글턴이라 '체험 종료' 후에도 상태가 남는다. 첫 입장에서
        //    scene이 .indoor가 된 채 재진입하면 switchToIndoor의 `scene == .outdoor` 가드가
        //    막혀 "예"를 눌러도 전환이 안 되던 버그를 방지한다.
        im.scene = .outdoor
        im.activeTrigger = nil
        im.dismissedTriggerID = nil
        im.isTransitioning = false
        im.transitionError = nil
        im.staffCalled = false

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

    /// 활성 트리거의 kind에 따라 알맞은 패널만 표시·배치한다.
    private static func updatePanel(_ im: InteractionModel) {
        let trigger = im.activeTrigger

        // 문 예/아니요 패널: 눈높이 + 사용자를 향한 yaw 빌보드.
        if let entry = im.panelEntity {
            if let t = trigger, t.kind == .yesNoPrompt {
                entry.isEnabled = true
                entry.setPosition([t.center.x, InteractionTuning.panelHeight, t.center.y],
                                  relativeTo: entry.parent)
                let worldPos = entry.position(relativeTo: nil)
                let yaw = atan2(-worldPos.x, -worldPos.z)
                entry.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)
            } else {
                entry.isEnabled = false
            }
        }

        // 키오스크 화면: 서 있는 눈높이 + 고정 방향(빌보드 안 함 = 높이 장벽 연출).
        // 방향은 맵 로컬(부모=worldRoot) 기준이라 키오스크에 붙박이처럼 고정된다.
        if let kiosk = im.kioskPanelEntity {
            if let t = trigger, t.kind == .kioskScreen {
                kiosk.isEnabled = true
                kiosk.setPosition([t.center.x, InteractionTuning.kioskScreenHeight, t.center.y],
                                  relativeTo: kiosk.parent)
                kiosk.setOrientation(simd_quatf(angle: InteractionTuning.kioskScreenYaw, axis: [0, 1, 0]),
                                     relativeTo: kiosk.parent)
            } else {
                kiosk.isEnabled = false
            }
        }
    }
}
