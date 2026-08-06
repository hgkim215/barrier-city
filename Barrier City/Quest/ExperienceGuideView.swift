import SwiftUI

struct ExperienceGuideView: View {
    let model: GuideFlowModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: GuideFlowModel) {
        self.model = model
    }

    @MainActor
    init() {
        self.init(model: .shared)
    }

    var body: some View {
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
                    allCompleted: false
                )
            case .completionAnnouncement:
                ExperienceCompletionView(onConfirm: model.confirmCompletion)
            case .completed:
                MissionListView(
                    steps: QuestModel.shared.steps,
                    visibleCount: 3,
                    allCompleted: true
                )
            }
        }
        .id(String(describing: model.phase))
        .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        .animation(.easeOut(duration: 0.22), value: model.phase)
    }
}

struct IntroductionCardView: View {
    let onConfirm: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            guideBadge("Barrier City")

            VStack(spacing: 16) {
                Text(GuideContent.introductionTitle)
                    .font(.title2.bold())

                Text(GuideContent.introductionBody)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("확인", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 200, minHeight: 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button("건너뛰기", action: onSkip)
                .buttonStyle(.plain)
        }
        .padding(48)
        .frame(width: 767, height: 396)
        .glassBackgroundEffect()
    }
}

@ViewBuilder
func guideBadge(_ title: String) -> some View {
    Text(title)
        .font(.callout.bold())
        .foregroundStyle(GuideTheme.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .overlay(Capsule().stroke(GuideTheme.accent, lineWidth: 1))
}

#Preview("Introduction") {
    IntroductionCardView(onConfirm: {}, onSkip: {})
        .padding()
}
