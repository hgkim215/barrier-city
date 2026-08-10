import SwiftUI

/// Barista 머리 위를 따라다니는 단일 공간 UI.
/// 대화 전에는 말 걸기 버튼, 대화 중에는 NPC 자막과 현재 듣기 상태를 보여준다.
struct NPCDialoguePanelView: View {
    let controller: NPCDialogueController
    let clerk: NPCClerkController

    var body: some View {
        Group {
            if showsTalkButton {
                talkButton
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                subtitleBubble
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(width: 420)
        .animation(.easeInOut(duration: 0.2), value: controller.isEncounterActive)
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

            Text(displayedSubtitle)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if controller.status == .listening,
               !controller.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("나: \(controller.liveText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .glassBackgroundEffect()
    }

    private var showsTalkButton: Bool {
        guard !controller.isEncounterActive else { return false }
        return clerk.phase == .working || clerk.phase == .completed
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
