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
    private static var videoPanel: Entity?
    private static var subscription: EventSubscription?
    private static var startTask: Task<Void, Never>?

    /// 진입 직후 확정한 기준 눈높이. 문 진입 패널이 온보딩과 같은 높이를 쓰려고 읽는다.
    static var baselineEyeHeight: Float? { follower?.baselineEyeHeight }

    static func install(content: RealityViewContent,
                        attachments: RealityViewAttachments,
                        appModel: AppModel) {
        stop()
        // 재진입마다 온보딩과 미션 진행 상태를 함께 초기화한다.
        GuideFlowModel.shared.reset()

        guard let panel = attachments.entity(for: "questHUD") else {
            GuideFlowModel.shared.failOpen()
            return
        }
        content.add(panel)   // 씬 루트에 직접(HUD는 맵과 함께 움직이면 안 된다)
        hudPanel = panel

        // 안내 영상은 멀리 TV처럼 걸리는 별도 패널이라 attachment도 따로 둔다.
        if let video = attachments.entity(for: "guideVideo") {
            video.isEnabled = false
            content.add(video)
            videoPanel = video
        }
        appModel.endingCelebration.attach(to: panel)

        let f = QuestHUDFollower()
        follower = f
        startTask = Task { await f.start(model: appModel) }

        subscription = content.subscribe(to: SceneEvents.Update.self) { event in
            guard let panel = hudPanel, let f = follower else { return }
            f.update(panel: panel,
                     videoPanel: videoPanel,
                     placement: GuideFlowModel.shared.placement,
                     showsVideo: GuideFlowModel.shared.showsGuideVideo,
                     model: appModel)
        }
    }

    /// 몰입 공간과 함께 HUD 구독 및 독립 ARKit 세션을 종료한다.
    static func stop() {
        subscription?.cancel()
        subscription = nil
        startTask?.cancel()
        startTask = nil
        follower?.stop()
        follower = nil
        hudPanel?.removeFromParent()
        hudPanel = nil
        videoPanel?.removeFromParent()
        videoPanel = nil
    }
}
