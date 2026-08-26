import SwiftUI

struct TutorialGuideView: View {
    let step: TutorialGuideStep
    let totalCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: GuideCardMetrics.panelGap) {
            // 영상은 텍스트 카드와 분리된 별도 글래스 패널로 띄운다.
            // 한 카드 안에 좌우로 넣으면 16:9 영상 때문에 카드가 가로로만 길어진다.
            LoopingGuideVideoView(resourceName: step.videoResourceName)
                .frame(width: GuideCardMetrics.videoWidth,
                       height: GuideCardMetrics.videoHeight)
                .padding(GuideCardMetrics.videoFramePadding)
                .glassBackgroundEffect(in: .rect(cornerRadius: 32))

            textCard
        }
        .onboardingAnchored()
    }

    private var textCard: some View {
        VStack(spacing: 0) {
            guideBadge("Guide \(step.id + 1) / \(totalCount)")

            Spacer(minLength: 12)

            Text(step.title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)

            Text(step.detail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 12)

            Spacer(minLength: 12)

            HStack(spacing: 20) {
                if step.id > 0 {
                    Button(action: onPrevious) {
                        Image(systemName: "chevron.left")
                            .font(.title3.bold())
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                }

                GuidePrimaryButton(
                    title: step.id == totalCount - 1 ? "시작하기" : "다음",
                    action: onNext)
            }
        }
        .padding(GuideCardMetrics.padding)
        .frame(width: GuideCardMetrics.width,
               height: GuideCardMetrics.cardHeight)
        .overlay(alignment: .topTrailing) {
            Button("건너뛰기", action: onSkip)
                .font(.title3.weight(.semibold))
                .buttonStyle(.plain)
                .padding(GuideCardMetrics.padding)
        }
        .glassBackgroundEffect()
    }
}

#Preview("Tutorial - Wheel Control") {
    TutorialGuideView(
        step: GuideContent.tutorials[0],
        totalCount: GuideContent.tutorials.count,
        onPrevious: {},
        onNext: {},
        onSkip: {}
    )
    .padding()
}

#Preview("Tutorial - Turning") {
    TutorialGuideView(
        step: GuideContent.tutorials[1],
        totalCount: GuideContent.tutorials.count,
        onPrevious: {},
        onNext: {},
        onSkip: {}
    )
    .padding()
}

#Preview("Tutorial - Straight Drive") {
    TutorialGuideView(
        step: GuideContent.tutorials[2],
        totalCount: GuideContent.tutorials.count,
        onPrevious: {},
        onNext: {},
        onSkip: {}
    )
    .padding()
}

#Preview("Tutorial - Missing Video") {
    LoopingGuideVideoView(
        resourceName: "missing-preview-video",
        placeholderResourceName: nil
    )
    .frame(width: GuideCardMetrics.videoWidth, height: GuideCardMetrics.videoHeight)
    .padding()
}
