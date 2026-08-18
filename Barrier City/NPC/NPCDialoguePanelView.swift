import SwiftUI

/// Barista 머리 위를 따라다니는 단일 공간 UI.
/// 대화 전에는 말 걸기 버튼, 대화 중에는 NPC 자막과 현재 듣기 상태를 보여준다.
struct NPCDialoguePanelView: View {
    let controller: NPCDialogueController
    let clerk: NPCClerkController

    var body: some View {
        VStack(spacing: 10) {
            RapportHeartGauge(rapport: controller.rapport)

            Group {
                if showsTalkButton {
                    talkButton
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                } else {
                    subtitleBubble
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
        }
        .frame(width: 420)
        .animation(.easeInOut(duration: 0.2), value: controller.isEncounterActive)
        .animation(.easeInOut(duration: 0.3), value: controller.rapport)
    }

    private var talkButton: some View {
        Button {
            clerk.startConversation()
        } label: {
            Label(clerk.isTalkAvailable ? "말 걸기" : "가까이 가서 말 걸기",
                  systemImage: clerk.isTalkAvailable ? "bubble.left.and.bubble.right.fill" : "figure.walk")
                .font(.title3.bold())
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)
        .disabled(!clerk.isTalkAvailable)
        .accessibilityHint(clerk.isTalkAvailable
            ? "카페 직원과 음성 대화를 시작합니다."
            : "직원에게 조금 더 가까이 이동하세요.")
    }

    private var subtitleBubble: some View {
        VStack(spacing: 10) {
            Label(statusTitle, systemImage: statusIcon)
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if controller.status == .listening {
                Label(
                    controller.realtimeSpeechDetected
                        ? "WebRTC 음성 감지됨"
                        : "WebRTC 음성 입력 대기",
                    systemImage: controller.realtimeSpeechDetected
                        ? "waveform"
                        : "mic.fill"
                )
                    .font(.caption)
                    .foregroundStyle(controller.realtimeSpeechDetected ? .green : .secondary)
            }

            Text(displayedSubtitle)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            userTranscript

#if DEBUG
            Text("주문 흐름 v\(DevelopmentOptions.orderFlowVersion) · 빌드 \(DevelopmentOptions.appBuildNumber)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
#endif
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private var userTranscript: some View {
        let transcript = controller.visibleUserTranscript
        if !transcript.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: controller.userTranscriptIsFinal
                      ? "checkmark.circle.fill"
                      : "waveform")
                    .foregroundStyle(controller.userTranscriptIsFinal ? .green : .orange)

                Text(controller.userTranscriptIsFinal
                     ? "나: \(transcript)"
                     : "인식 중: \(transcript)")
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
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
            return "듣는 중..."
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
}

/// -1...1 관계 점수를 NPC 머리 위의 5칸 하트 게이지로 표시한다.
private struct RapportHeartGauge: View {
    let rapport: Float

    private static let gaugeWidth: CGFloat = 132
    private static let heartCount = 5

    private var progress: CGFloat {
        CGFloat(max(0, min(1, (rapport + 1) * 0.5)))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("호감도")
                .font(.caption.bold())

            ZStack(alignment: .leading) {
                heartRow
                    .foregroundStyle(.white.opacity(0.28))

                heartRow
                    .foregroundStyle(.pink)
                    .frame(width: Self.gaugeWidth * progress, alignment: .leading)
                    .clipped()
            }
            .frame(width: Self.gaugeWidth, height: 24, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassBackgroundEffect(in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("직원 호감도")
        .accessibilityValue("\(Int((progress * 100).rounded()))퍼센트")
    }

    private var heartRow: some View {
        HStack(spacing: 5) {
            ForEach(0..<Self.heartCount, id: \.self) { _ in
                Image(systemName: "heart.fill")
                    .frame(width: 22, height: 22)
            }
        }
        .font(.title3)
    }
}
