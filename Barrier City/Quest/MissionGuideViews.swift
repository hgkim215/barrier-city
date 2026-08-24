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
    let elapsedTime: String
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Image("EndingHeaderGlow")
                .resizable()
                .scaledToFit()
                .frame(width: 726, height: 242)
                .position(x: 444, y: 144)
                .accessibilityHidden(true)

            Image("EndingTimeRing")
                .resizable()
                .scaledToFit()
                .frame(width: 852, height: 852)
                .position(x: 444, y: 327)
                .accessibilityHidden(true)

            Text("오늘의 체험이 끝났습니다")
                .font(.system(size: 36, weight: .heavy, design: .rounded))
                .tracking(1.8)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 2)
                .position(x: 450, y: 83)

            Text("총 미션 완료 시간")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .tracking(1)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.1), radius: 2, y: 2)
                .position(x: 450, y: 203)

            Text(elapsedTime)
                .font(.system(size: 80, weight: .medium, design: .rounded))
                .monospacedDigit()
                .tracking(4)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
                .position(x: 450, y: 270)
                .accessibilityLabel("총 미션 완료 시간 \(elapsedTime)")
                .accessibilityIdentifier("ending-elapsed-time")

            Text("오늘의 경험이 누군가의 일상을 다르게 바라보는 계기가 되었길 바랍니다.\n작은 이해와 관심이 더 많은 사람이 편안하게 살아갈 수 있는 도시를 만듭니다.")
                .font(.system(size: 24, weight: .regular, design: .rounded))
                .lineSpacing(9)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                .frame(width: 716)
                .position(x: 450, y: 447)

            Button(action: onConfirm) {
                Text("확인")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 2)
                    .frame(width: 240, height: 80)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.992, green: 0.851, blue: 0.173),
                                Color(red: 0.996, green: 0.584, blue: 0.039)
                            ],
                            startPoint: .top,
                            endPoint: .bottom),
                        in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.22), lineWidth: 2)
                            .padding(2)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 10)
            }
            .buttonStyle(.plain)
            .position(x: 450, y: 570)
            .accessibilityLabel("체험 종료 후 시작 화면으로 돌아가기")
            .accessibilityIdentifier("ending-confirm-button")

            Text("확인을 누르면 시작 화면으로 돌아갑니다")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color(red: 0.827, green: 0.827, blue: 0.827))
                .position(x: 450, y: 645)
        }
        .frame(width: 900, height: 716)
        .background {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 40, style: .continuous)
                        .fill(Color(red: 0.055, green: 0.063, blue: 0.082).opacity(0.78))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 20, x: 2, y: 4)
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
    ExperienceCompletionView(elapsedTime: "28:48", onConfirm: {})
        .padding()
}
