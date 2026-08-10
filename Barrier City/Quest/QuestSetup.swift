//
//  QuestSetup.swift
//  Barrier City
//
//  퀘스트 HUD 설치 훅. InteractionSetup.install() 끝에서 한 번 호출된다.
//  HUD attachment를 '씬 루트'(worldRoot가 아니라 content)에 붙여 맵과 분리하고,
//  QuestHUDFollower로 매 프레임 head 옆에 lazy-follow 시킨다.
//

import RealityKit
import SwiftUI

@MainActor
enum QuestSetup {
    private static var follower: QuestHUDFollower?
    private static var hudPanel: Entity?
    private static var subscription: EventSubscription?

    static func install(content: RealityViewContent,
                        attachments: RealityViewAttachments,
                        appModel: AppModel) {
        stop()
        GuideFlowModel.shared.reset()

        guard let panel = attachments.entity(for: "questHUD") else {
            print("⚠️ questHUD attachment 없음 — 안내 UI 없이 체험 계속")
            GuideFlowModel.shared.failOpen()
            return
        }
        content.add(panel)   // 씬 루트에 직접(HUD는 맵과 함께 움직이면 안 된다)
        hudPanel = panel

        let f = QuestHUDFollower()
        follower = f
        Task { await f.start() }

        subscription = content.subscribe(to: SceneEvents.Update.self) { event in
            guard let panel = hudPanel, let f = follower else { return }
            f.update(panel: panel,
                     dt: Float(event.deltaTime),
                     placement: GuideFlowModel.shared.placement)
        }
    }

    static func stop() {
        subscription?.cancel()
        subscription = nil
        follower?.stop()
        follower = nil
        hudPanel?.removeFromParent()
        hudPanel = nil
    }
}
