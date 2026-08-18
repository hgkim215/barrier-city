import SwiftUI

/// 실제 NPC Realtime 대화의 상태와 양쪽 transcript를 보여주는 개발용 창.
/// 대화 시작·입력은 공간 NPC와 동일한 WebRTC 세션이 담당한다.
struct DialogueTurnView: View {
    @Bindable private var controller: NPCDialogueController
    private let title: String

    init(
        controller: NPCDialogueController,
        title: String = "AI NPC 대화 테스트"
    ) {
        _controller = Bindable(wrappedValue: controller)
        self.title = title
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.title2.bold())

            Text("상태: \(controller.status.rawValue)   ·   호감도 \(String(format: "%.2f", controller.rapport))   ·   \(controller.tone.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)

            transcriptCard(
                speaker: "🧑‍🍳 직원",
                text: controller.npcSubtitle,
                placeholder: controller.isEncounterActive
                    ? "NPC 응답을 기다리는 중입니다."
                    : "ControlPanel에서 NPC 대화를 시작해 주세요.",
                color: .orange
            )

            transcriptCard(
                speaker: "🙋 나",
                text: controller.visibleUserTranscript,
                placeholder: controller.isEncounterActive
                    ? "Realtime 마이크 입력을 기다리는 중입니다."
                    : "대화가 시작되면 내 발화가 여기에 표시됩니다.",
                color: .blue
            )

            if !controller.lastEvent.isEmpty {
                Text("미션 이벤트: \(controller.lastEvent)")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Label(statusText, systemImage: statusIcon)
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.gray.opacity(0.22))
                .clipShape(Capsule())
        }
        .padding(24)
        .frame(width: 520, minHeight: 360)
    }

    private func transcriptCard(
        speaker: String,
        text: String,
        placeholder: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(speaker)
                .font(.caption.bold())
                .foregroundStyle(color)
            Text(text.isEmpty ? placeholder : text)
                .font(.title3)
                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
        }
        .padding(14)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusText: String {
        switch controller.status {
        case .idle:
            controller.isEncounterActive ? "대화를 기다리는 중" : "대화 세션 종료"
        case .listening: "말씀하세요 · Realtime이 듣고 있어요"
        case .thinking: "답변을 생각하고 있어요"
        case .speaking: "직원이 말하고 있어요"
        }
    }

    private var statusIcon: String {
        switch controller.status {
        case .listening: "waveform"
        case .thinking: "ellipsis.bubble"
        case .speaking: "speaker.wave.2.fill"
        case .idle: controller.isEncounterActive ? "person.wave.2" : "stop.circle"
        }
    }
}
