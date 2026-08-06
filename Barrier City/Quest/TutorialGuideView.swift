import SwiftUI

struct TutorialGuideView: View {
    let step: TutorialGuideStep
    let totalCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            LoopingGuideVideoView(resourceName: step.videoResourceName)
                .frame(width: 383, height: 356)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("건너뛰기", action: onSkip)
                        .buttonStyle(.plain)
                }

                Text("Guide \(step.id + 1) / \(totalCount)")
                    .font(.caption.bold())
                    .foregroundStyle(GuideTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay(Capsule().stroke(GuideTheme.accent, lineWidth: 1))

                Spacer()

                Text(step.title)
                    .font(.title2.bold())

                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)

                Spacer()

                HStack(spacing: 20) {
                    if step.id > 0 {
                        Button(action: onPrevious) {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                    }

                    Button(
                        step.id == totalCount - 1 ? "시작하기" : "다음",
                        action: onNext
                    )
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 200, minHeight: 52)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .padding(20)
        .frame(width: 767, height: 396)
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
    .frame(width: 383, height: 356)
    .padding()
}
