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
struct NPCDialoguePanelView: View {
    let controller: NPCDialogueController
    let clerk: NPCClerkController

    var body: some View {
        VStack(spacing: 18) {
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
        .frame(width: 640)
        .animation(.easeInOut(duration: 0.2), value: controller.isEncounterActive)
        .animation(.easeInOut(duration: 0.3), value: controller.rapport)
    }

    private var talkButton: some View {
        Button {
            clerk.startConversation()
        } label: {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(CafePalette.cream.opacity(0.18))
                    Image(systemName: clerk.isTalkAvailable
                          ? "cup.and.saucer.fill"
                          : "figure.walk")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(CafePalette.cream)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(clerk.isTalkAvailable ? "직원과 대화하기" : "직원에게 가까이 가세요")
                        .font(.title2.bold())
                    Text(clerk.isTalkAvailable ? "편하게 말을 걸어 보세요" : "대화 가능한 거리로 이동해 주세요")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(CafePalette.cream.opacity(0.76))
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.headline.bold())
                    .foregroundStyle(CafePalette.cream.opacity(0.82))
            }
            .foregroundStyle(CafePalette.foam)
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [CafePalette.roast, CafePalette.espresso],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(CafePalette.cream.opacity(0.34), lineWidth: 1.5)
            }
            .shadow(color: CafePalette.espresso.opacity(0.3), radius: 18, y: 10)
        }
        .buttonStyle(.plain)
        .disabled(!clerk.isTalkAvailable)
        .opacity(clerk.isTalkAvailable ? 1 : 0.78)
        .accessibilityHint(clerk.isTalkAvailable
            ? "카페 직원과 음성 대화를 시작합니다."
            : "직원에게 조금 더 가까이 이동하세요.")
    }

    private var subtitleCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            dialogueHeader

            Divider()
                .overlay(CafePalette.roast.opacity(0.18))

            Text(displayedSubtitle)
                .font(.system(size: 29, weight: .semibold, design: .rounded))
                .foregroundStyle(CafePalette.espresso)
                .multilineTextAlignment(.leading)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)

            if controller.status == .listening {
                listeningIndicator
            }

            userTranscript

#if DEBUG
            Text("주문 흐름 v\(DevelopmentOptions.orderFlowVersion) · 빌드 \(DevelopmentOptions.appBuildNumber)")
                .font(.caption2.monospaced())
                .foregroundStyle(CafePalette.roast.opacity(0.5))
#endif
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [CafePalette.foam.opacity(0.92), CafePalette.cream.opacity(0.78)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(CafePalette.foam.opacity(0.72), lineWidth: 1.5)
        }
        .shadow(color: CafePalette.espresso.opacity(0.24), radius: 22, y: 12)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 30,
                                                     style: .continuous))
    }

    private var dialogueHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(CafePalette.roast)
                Image(systemName: "cup.and.saucer.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(CafePalette.cream)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 2) {
                Text("CAFE STAFF")
                    .font(.caption.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(CafePalette.caramel)
                Label(statusTitle, systemImage: statusIcon)
                    .font(.headline.bold())
                    .foregroundStyle(CafePalette.espresso)
            }

            Spacer()

            Circle()
                .fill(statusAccent)
                .frame(width: 13, height: 13)
                .shadow(color: statusAccent.opacity(0.55), radius: 6)
        }
    }

    private var listeningIndicator: some View {
        Label(
            controller.realtimeSpeechDetected
                ? "음성을 인식하고 있어요"
                : "말씀을 기다리고 있어요",
            systemImage: controller.realtimeSpeechDetected
                ? "waveform"
                : "mic.fill"
        )
        .font(.body.weight(.semibold))
        .foregroundStyle(controller.realtimeSpeechDetected
                         ? Color.green
                         : CafePalette.roast)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            (controller.realtimeSpeechDetected ? Color.green : CafePalette.caramel)
                .opacity(0.12),
            in: Capsule()
        )
    }

    @ViewBuilder
    private var userTranscript: some View {
        let transcript = controller.visibleUserTranscript
        if !transcript.isEmpty {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: controller.userTranscriptIsFinal
                      ? "checkmark.circle.fill"
                      : "waveform")
                    .font(.title3)
                    .foregroundStyle(controller.userTranscriptIsFinal
                                     ? Color.green
                                     : CafePalette.caramel)

                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.userTranscriptIsFinal ? "나" : "인식 중")
                        .font(.caption.bold())
                        .foregroundStyle(CafePalette.caramel)
                    Text(transcript)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(CafePalette.espresso)
                        .multilineTextAlignment(.leading)
                        .lineLimit(5)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CafePalette.roast.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(CafePalette.roast.opacity(0.1), lineWidth: 1)
            }
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

    private var statusTitle: String {
        switch controller.status {
        case .speaking: "직원이 말하는 중"
        case .listening: "말씀하세요"
        case .thinking: "생각하는 중"
        case .idle: "대화 중"
        }
    }

    private var statusIcon: String {
        switch controller.status {
        case .speaking: "speaker.wave.2.fill"
        case .listening: "waveform"
        case .thinking: "ellipsis.bubble.fill"
        case .idle: "bubble.left.fill"
        }
    }

    private var statusAccent: Color {
        switch controller.status {
        case .speaking: CafePalette.caramel
        case .listening: .green
        case .thinking: .orange
        case .idle: CafePalette.roast.opacity(0.55)
        }
    }
}

/// -1...1 관계 점수를 NPC 머리 위의 5칸 하트 게이지로 표시한다.
private struct RapportHeartGauge: View {
    let rapport: Float

    private static let gaugeWidth: CGFloat = 205
    private static let heartCount = 5

    private var progress: CGFloat {
        CGFloat(max(0, min(1, (rapport + 1) * 0.5)))
    }

    private var percentage: Int {
        Int((progress * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "heart.circle.fill")
                    .font(.title2)
                    .foregroundStyle(CafePalette.berry)
                Text("호감도")
                    .font(.headline.bold())
                    .foregroundStyle(CafePalette.espresso)
            }

            ZStack(alignment: .leading) {
                heartRow
                    .foregroundStyle(CafePalette.roast.opacity(0.18))

                heartRow
                    .foregroundStyle(CafePalette.berry)
                    .frame(width: Self.gaugeWidth * progress, alignment: .leading)
                    .clipped()
            }
            .frame(width: Self.gaugeWidth, height: 34, alignment: .leading)

            Text("\(percentage)%")
                .font(.headline.monospacedDigit().bold())
                .foregroundStyle(CafePalette.roast)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(CafePalette.cream.opacity(0.84))
        }
        .overlay {
            Capsule()
                .stroke(CafePalette.foam.opacity(0.78), lineWidth: 1.5)
        }
        .shadow(color: CafePalette.espresso.opacity(0.18), radius: 14, y: 8)
        .glassBackgroundEffect(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("직원 호감도")
        .accessibilityValue("\(percentage)퍼센트")
    }

    private var heartRow: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.heartCount, id: \.self) { _ in
                Image(systemName: "heart.fill")
                    .frame(width: 33, height: 33)
            }
        }
        .font(.title2)
    }
}
