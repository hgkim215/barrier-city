import SwiftUI

struct ExperienceGuideView: View {
    let model: GuideFlowModel
    let serving: RainbowSmoothieServingController?
    let elapsedTime: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    init(model: GuideFlowModel = .shared,
         serving: RainbowSmoothieServingController? = nil,
         elapsedTime: String = "00:00") {
        self.model = model
        self.serving = serving
        self.elapsedTime = elapsedTime
    }

    var body: some View {
        let activeServing = serving ?? AppModel.current?.rainbowSmoothieServing
        let remainingSeconds = activeServing?.remainingPreparationSeconds ?? 0

        Group {
            switch model.phase {
            case .introduction:
                IntroductionCardView(
                    onConfirm: model.confirmIntroduction,
                    onSkip: model.skipOnboarding
                )
            case .tutorial(let index):
                TutorialGuideView(
                    step: GuideContent.tutorials[index],
                    totalCount: GuideContent.tutorials.count,
                    onPrevious: model.previousTutorial,
                    onNext: model.nextTutorial,
                    onSkip: model.skipOnboarding
                )
            case .missionAnnouncement(let index):
                MissionAnnouncementView(
                    narrative: GuideContent.missions[index],
                    onConfirm: model.confirmMission
                )
            case .missionActive:
                MissionListView(
                    steps: QuestModel.shared.steps,
                    visibleCount: model.visibleMissionCount,
                    allCompleted: false,
                    remainingPreparationSeconds: remainingSeconds
                )
            case .postOrderPending:
                MissionListView(
                    steps: QuestModel.shared.steps,
                    visibleCount: model.visibleMissionCount,
                    allCompleted: false,
                    remainingPreparationSeconds: remainingSeconds
                )
            case .completionAnnouncement:
                ExperienceCompletionView(
                    elapsedTime: elapsedTime,
                    onConfirm: finishExperience)
            case .completed:
                MissionListView(
                    steps: QuestModel.shared.steps,
                    visibleCount: model.visibleMissionCount,
                    allCompleted: true
                )
            }
        }
        .id(String(describing: model.phase))
        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        .animation(.easeOut(duration: 0.22), value: model.phase)
    }

    private func finishExperience() {
        AppModel.current?.endingCelebration.stop()
        model.confirmCompletion()
        Task { @MainActor in
            await dismissImmersiveSpace()
        }
    }
}

struct IntroductionCardView: View {
    let onConfirm: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            guideBadge("Barrier City")

            VStack(spacing: 20) {
                Text(GuideContent.introductionTitle)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text(GuideContent.introductionBody)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            GuidePrimaryButton(title: "확인", action: onConfirm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("건너뛰기", action: onSkip)
                .font(.title3.weight(.semibold))
                .buttonStyle(.plain)
        }
        .padding(GuideCardMetrics.padding)
        .frame(width: GuideCardMetrics.width, height: GuideCardMetrics.cardHeight)
        .glassBackgroundEffect()
        .onboardingAnchored()
    }
}

/// 온보딩·미션 카드의 주 버튼.
///
/// `.borderedProminent`에 `.font`/`.frame`을 바깥에서 걸면 버튼이 커지지 않는다.
/// 스타일이 라벨 크기 + 자체 padding으로 배경을 그린 뒤 그 결과를 바깥 frame
/// 안에 가운데 정렬할 뿐이라, 여백만 늘고 캡슐은 그대로였다. 그래서 라벨 안쪽에
/// 크기를 주고 배경도 직접 그린다(StartScreenView의 시작 버튼과 같은 방식).
struct GuidePrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 25, weight: .black, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
                .frame(width: 220, height: 64)
                .background(GuideTheme.accentGradient, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.22), lineWidth: 2)
                        .padding(2)
                }
                .shadow(color: .black.opacity(0.25), radius: 10)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

@ViewBuilder
func guideBadge(_ title: String) -> some View {
    Text(title)
        .font(.title3.bold())
        .foregroundStyle(GuideTheme.accent)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .overlay(Capsule().stroke(GuideTheme.accent, lineWidth: 1.5))
}

#Preview("Introduction") {
    IntroductionCardView(onConfirm: {}, onSkip: {})
        .padding()
}
