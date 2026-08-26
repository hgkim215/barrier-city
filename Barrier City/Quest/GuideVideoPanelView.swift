import SwiftUI

/// 사용자에게서 멀리, TV처럼 걸리는 안내 영상 패널.
///
/// 텍스트 카드("questHUD")와 별도의 attachment("guideVideo")로 띄운다.
/// 한 attachment 안에 같이 두면 3D 상 거리·각도를 따로 줄 수 없어서,
/// 손 닿는 카드와 멀리 보는 영상을 동시에 만족시킬 수 없다.
///
/// 표시 여부는 엔티티의 isEnabled로 QuestHUDFollower가 제어한다. 여기서는
/// 프레임을 항상 같은 크기로 유지해 단계가 바뀌어도 패널이 흔들리지 않게 한다.
struct GuideVideoPanelView: View {
    var model: GuideFlowModel = .shared

    var body: some View {
        ZStack {
            if case .tutorial(let index) = model.phase,
               GuideContent.tutorials.indices.contains(index) {
                LoopingGuideVideoView(
                    resourceName: GuideContent.tutorials[index].videoResourceName)
                    .frame(width: GuideCardMetrics.videoWidth,
                           height: GuideCardMetrics.videoHeight)
                    .padding(GuideCardMetrics.videoFramePadding)
                    .glassBackgroundEffect(in: .rect(cornerRadius: 48))
            }
        }
        .frame(width: GuideCardMetrics.videoPanelWidth,
               height: GuideCardMetrics.videoPanelHeight)
    }
}
