import SwiftUI

struct MissionAnnouncementView: View {
    let narrative: MissionNarrative
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 28) {
                guideBadge("Mission")

                VStack(spacing: 16) {
                    Text(narrative.situation)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)

                    Text(narrative.action)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Button("확인", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(GuideTheme.accent)
                .frame(minWidth: 200, minHeight: 52)
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 32)
        .frame(width: 553)
        .glassBackgroundEffect()
    }
}

struct MissionListView: View {
    let steps: [QuestStep]
    let visibleCount: Int
    let allCompleted: Bool
    var remainingPreparationSeconds: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Mission List")
                .font(.callout.bold())
                .padding(.bottom, 10)

            ForEach(Array(steps.prefix(visibleCount).enumerated()), id: \.element.id) { offset, step in
                let isClear = allCompleted || offset < visibleCount - 1
                let statusLabel: String = {
                    if isClear { return "Clear" }
                    if remainingPreparationSeconds > 0 { return "\(remainingPreparationSeconds)초" }
                    return "Progress"
                }()

                HStack(spacing: 20) {
                    Text("\(offset + 1). \(step.title)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isClear ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(statusLabel)
                        .font(.caption2.bold())
                        .foregroundStyle(isClear ? Color.secondary : GuideTheme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .overlay(
                            Capsule().stroke(
                                isClear ? Color.secondary : GuideTheme.accent,
                                lineWidth: 1
                            )
                        )
                }
                .padding(.vertical, 10)
            }
        }
        .padding(28)
        .frame(width: 400, alignment: .leading)
        .glassBackgroundEffect()
    }
}

struct ExperienceCompletionView: View {
    let onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Text(GuideContent.completionTitle)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(GuideContent.completionBody)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("확인", action: onConfirm)
                .buttonStyle(.borderedProminent)
                .tint(GuideTheme.accent)
                .frame(minWidth: 200, minHeight: 52)
        }
        .padding(48)
        .frame(width: 553)
        .glassBackgroundEffect()
    }
}

#Preview("Mission Announcement - Cafe") {
    MissionAnnouncementView(narrative: GuideContent.missions[0], onConfirm: {})
        .padding()
}

#Preview("Mission Announcement - Kiosk") {
    MissionAnnouncementView(narrative: GuideContent.missions[1], onConfirm: {})
        .padding()
}

#Preview("Mission Announcement - Staff") {
    MissionAnnouncementView(narrative: GuideContent.missions[2], onConfirm: {})
        .padding()
}

#Preview("Mission List - One") {
    MissionListView(steps: QuestModel.shared.steps, visibleCount: 1, allCompleted: false)
        .padding()
}

#Preview("Mission List - Two") {
    MissionListView(steps: QuestModel.shared.steps, visibleCount: 2, allCompleted: false)
        .padding()
}

#Preview("Mission List - Three") {
    MissionListView(steps: QuestModel.shared.steps, visibleCount: 3, allCompleted: false)
        .padding()
}

#Preview("Mission List - Complete") {
    MissionListView(steps: QuestModel.shared.steps, visibleCount: 3, allCompleted: true)
        .padding()
}

#Preview("Experience Completion") {
    ExperienceCompletionView(onConfirm: {})
        .padding()
}
