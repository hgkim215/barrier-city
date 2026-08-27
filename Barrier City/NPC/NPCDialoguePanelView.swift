import SwiftUI

/// 카페 공간 UI에서 공통으로 사용하는 따뜻한 크림·에스프레소 색상이다.
private enum CafePalette {
    static let espresso = Color(red: 0.20, green: 0.105, blue: 0.065)
    static let roast = Color(red: 0.34, green: 0.18, blue: 0.10)
    static let caramel = Color(red: 0.82, green: 0.48, blue: 0.22)
    static let cream = Color(red: 1.00, green: 0.94, blue: 0.82)
    static let foam = Color(red: 1.00, green: 0.98, blue: 0.92)
}

/// Barista 머리 위를 따라다니는 단일 공간 UI.
/// 대화 전에는 말 걸기 버튼, 대화 중에는 NPC 자막과 현재 듣기 상태를 보여준다.
/// 장식보다 가독성을 우선하는 단순한 말풍선 스타일을 유지한다.
struct NPCDialoguePanelView: View {
    let controller: NPCDialogueController
    let clerk: NPCClerkController

    var body: some View {
        Group {
            if showsTalkButton {
                talkButton
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            } else {
                subtitleCard
                    .frame(width: 760)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controller.isEncounterActive)
    }

    /// NPC 머리 위에 떠 있는 만큼, 실제 머리 크기와 비슷하게 커야 눈에 잘 띈다 —
    /// subtitleCard(자막 패널)와는 별개로 이 버튼만 크게 잡는다.
    private static let talkButtonSize: CGFloat = 420

    private var talkButton: some View {
        Button {
            clerk.startConversation()
        } label: {
            VStack(spacing: 20) {
                Image(systemName: clerk.isTalkAvailable
                      ? "cup.and.saucer.fill"
                      : "figure.walk")
                    .font(.system(size: 96, weight: .semibold))
                    .foregroundStyle(CafePalette.cream)

                Text(clerk.isTalkAvailable ? "직원과 대화하기" : "직원에게 가까이 가세요")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(CafePalette.foam)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(width: Self.talkButtonSize, height: Self.talkButtonSize)
            .background(CafePalette.espresso,
                        in: RoundedRectangle(cornerRadius: 56, style: .continuous))
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

                if controller.isEncounterActive {
                    endConversationButton
                }
            }

            // 자막 길이가 매 발화마다 달라 패널 높이가 요동쳤다. 최소 높이를 4줄분으로
            // 잡고 그보다 길면 축소해, 말풍선이 제자리에 머무르게 한다.
            Text(displayedSubtitle)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundStyle(CafePalette.espresso)
                .multilineTextAlignment(.leading)
                .lineSpacing(8)
                .lineLimit(4)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)

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

    /// 무응답 타임아웃이나 거리 이탈을 기다리지 않고, 사용자가 언제든 직접 대화를
    /// 끝낼 수 있게 하는 명시적 버튼. 거리로 자동 종료될 때와 같은 정리 경로
    /// (NPCClerkController.endConversation → endEncounterForDeparture)를 탄다.
    private var endConversationButton: some View {
        Button {
            clerk.endConversation()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                Text("대화 종료")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(CafePalette.roast)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(CafePalette.roast.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("대화 종료")
        .accessibilityHint("직원과의 대화를 지금 바로 마칩니다.")
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
        controller.orderReadyAnnouncementPresentation.showsTalkButton(
            isEncounterActive: controller.isEncounterActive,
            clerkPhaseAllowsButton: clerk.phase == .working || clerk.phase == .orderAccepted
        )
    }

    private var displayedSubtitle: String {
        switch controller.status {
        case .speaking:
            return controller.npcSubtitle.isEmpty ? "…" : controller.npcSubtitle
        case .listening:
            return "편하게 말씀해 주세요."
        case .thinking:
            return "잠시만요."
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
