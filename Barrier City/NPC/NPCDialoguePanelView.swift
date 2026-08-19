import SwiftUI

/// 카페 공간 UI에서 공통으로 사용하는 따뜻한 크림·에스프레소 색상이다.
private enum CafePalette {
    static let espresso = Color(red: 0.20, green: 0.105, blue: 0.065)
    static let roast = Color(red: 0.34, green: 0.18, blue: 0.10)
    static let caramel = Color(red: 0.82, green: 0.48, blue: 0.22)
    static let cream = Color(red: 1.00, green: 0.94, blue: 0.82)
    static let foam = Color(red: 1.00, green: 0.98, blue: 0.92)
    static let berry = Color(red: 0.88, green: 0.30, blue: 0.36)
}

/// Barista 머리 위를 따라다니는 단일 공간 UI.
/// 대화 전에는 말 걸기 버튼, 대화 중에는 NPC 자막과 현재 듣기 상태를 보여준다.
/// 장식보다 가독성을 우선하는 단순한 말풍선 스타일을 유지한다.
struct NPCDialoguePanelView: View {
    let controller: NPCDialogueController
    let clerk: NPCClerkController

    var body: some View {
        VStack(spacing: 20) {
            RapportHeartGauge(rapport: controller.rapport)

            Group {
                if showsTalkButton {
                    talkButton
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                } else {
                    subtitleCard
                        .transition(.scale(scale: 0.97).combined(with: .opacity))
                }
            }
        }
        .frame(width: 760)
        .animation(.easeInOut(duration: 0.2), value: controller.isEncounterActive)
        .animation(.easeInOut(duration: 0.3), value: controller.rapport)
    }

    private var talkButton: some View {
        Button {
            clerk.startConversation()
        } label: {
            HStack(spacing: 20) {
                Image(systemName: clerk.isTalkAvailable
                      ? "cup.and.saucer.fill"
                      : "figure.walk")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(CafePalette.cream)
                    .frame(width: 54)

                Text(clerk.isTalkAvailable ? "직원과 대화하기" : "직원에게 가까이 가세요")
                    .font(.title.bold())
                    .foregroundStyle(CafePalette.foam)

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.title2.bold())
                    .foregroundStyle(CafePalette.cream.opacity(0.82))
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .background(CafePalette.espresso,
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!clerk.isTalkAvailable)
        .opacity(clerk.isTalkAvailable ? 1 : 0.78)
        .accessibilityHint(clerk.isTalkAvailable
            ? "카페 직원과 음성 대화를 시작합니다."
            : "직원에게 조금 더 가까이 이동하세요.")
    }

    private var subtitleCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("직원")
                    .font(.title2.bold())
                    .foregroundStyle(CafePalette.espresso)

                Spacer()

                if controller.status == .listening {
                    ListeningIndicator()
                }
            }

            Text(displayedSubtitle)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundStyle(CafePalette.espresso)
                .multilineTextAlignment(.leading)
                .lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)

            userTranscript

#if DEBUG
            Text("주문 흐름 v\(DevelopmentOptions.orderFlowVersion) · 빌드 \(DevelopmentOptions.appBuildNumber)")
                .font(.caption2.monospaced())
                .foregroundStyle(CafePalette.roast.opacity(0.5))
#endif
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 30)
        .background(CafePalette.foam.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    @ViewBuilder
    private var userTranscript: some View {
        let transcript = controller.visibleUserTranscript
        if !transcript.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text("나")
                    .font(.title3.bold())
                    .foregroundStyle(CafePalette.caramel)
                Text(transcript)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(CafePalette.roast)
                    .multilineTextAlignment(.leading)
                    .lineLimit(5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(controller.userTranscriptIsFinal
                                ? "내 확정 발화"
                                : "내 음성 인식 중")
            .accessibilityValue(transcript)
        }
    }

    private var showsTalkButton: Bool {
        guard !controller.isEncounterActive else { return false }
        return clerk.phase == .working || clerk.phase == .orderAccepted
    }

    private var displayedSubtitle: String {
        switch controller.status {
        case .speaking:
            return controller.npcSubtitle.isEmpty ? "…" : controller.npcSubtitle
        case .listening:
            return "편하게 말씀해 주세요."
        case .thinking:
            return "음… 잠시만요."
        case .idle:
            return controller.npcSubtitle.isEmpty
                ? "편하게 말씀해 주세요."
                : controller.npcSubtitle
        }
    }
}

/// 듣고 있음을 알리는 최소한의 표시. 초록불이 천천히 깜빡이는 것만으로 충분하다.
private struct ListeningIndicator: View {
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 18, height: 18)
            .opacity(isDim ? 0.25 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isDim = true
                }
            }
            .accessibilityLabel("듣고 있어요")
    }
}

/// -1...1 관계 점수를 NPC 머리 위의 5칸 하트 게이지로 표시한다.
private struct RapportHeartGauge: View {
    let rapport: Float

    private static let gaugeWidth: CGFloat = 220
    private static let heartCount = 5

    private var progress: CGFloat {
        CGFloat(max(0, min(1, (rapport + 1) * 0.5)))
    }

    private var percentage: Int {
        Int((progress * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 16) {
            Text("호감도")
                .font(.title3.bold())
                .foregroundStyle(CafePalette.espresso)

            ZStack(alignment: .leading) {
                heartRow
                    .foregroundStyle(CafePalette.roast.opacity(0.18))

                heartRow
                    .foregroundStyle(CafePalette.berry)
                    .frame(width: Self.gaugeWidth * progress, alignment: .leading)
                    .clipped()
            }
            .frame(width: Self.gaugeWidth, height: 36, alignment: .leading)

            Text("\(percentage)%")
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(CafePalette.roast)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(CafePalette.cream.opacity(0.9), in: Capsule())
        .glassBackgroundEffect(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("직원 호감도")
        .accessibilityValue("\(percentage)퍼센트")
    }

    private var heartRow: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.heartCount, id: \.self) { _ in
                Image(systemName: "heart.fill")
                    .frame(width: 36, height: 36)
            }
        }
        .font(.title2)
    }
}
