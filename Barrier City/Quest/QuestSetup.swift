//
//  QuestSetup.swift
//  Barrier City
//
//  퀘스트 HUD 설치 훅. InteractionSetup.install() 끝에서 한 번 호출된다.
//  HUD attachment를 '씬 루트'(worldRoot가 아니라 content)에 붙여 맵과 분리하고,
//  매 프레임 위치를 갱신한다. (Task 5에서 lazy-follow를 추가; 지금은 고정 배치.)
//

import RealityKit
import SwiftUI

@MainActor
enum QuestSetup {
    private static var hudPanel: Entity?
    private static var subscription: EventSubscription?

    static func install(content: RealityViewContent,
                        attachments: RealityViewAttachments,
                        appModel: AppModel) {
        // 재진입마다 1단계로 리셋(InteractionModel 리셋 패턴과 동일).
        QuestModel.shared.reset()

        guard let panel = attachments.entity(for: "questHUD") else {
            print("⚠️ questHUD attachment 없음 — 퀘스트 HUD 비활성")
            return
        }
        content.add(panel)   // 씬 루트에 직접(HUD는 맵과 함께 움직이면 안 된다)
        hudPanel = panel

        // 일단 원점 앞 고정 배치(Task 5에서 head lazy-follow로 대체).
        panel.setPosition(QuestTuning.fallbackPosition, relativeTo: nil)
        let p = QuestTuning.fallbackPosition
        let yaw = atan2(-p.x, -p.z)   // 원점(사용자)을 향하도록(InteractionSetup 관례)
        panel.setOrientation(simd_quatf(angle: yaw, axis: [0, 1, 0]), relativeTo: nil)

        subscription = content.subscribe(to: SceneEvents.Update.self) { _ in
            // Task 5에서 follower 갱신을 여기에 넣는다. 지금은 고정이라 할 일 없음.
        }
    }
}
