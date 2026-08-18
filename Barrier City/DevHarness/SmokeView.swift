import SwiftUI
import DialogueKit
import DialogueKitOpenAI

/// 앱 ↔ Worker 프록시 ↔ OpenAI `/chat` 스트리밍 연결을 확인하는 개발용 스모크 뷰.
struct SmokeView: View {
    @State private var output = ""
    @State private var running = false

    var body: some View {
        VStack(spacing: 16) {
            Text("AI 연결 스모크 테스트")
                .font(.headline)

            Button(running ? "호출 중…" : "AI 호출 테스트") {
                Task { await runChat() }
            }
            .disabled(running)

            Text(output.isEmpty ? "버튼을 누르면 NPC 인사가 스트리밍됩니다." : output)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
    }

    @MainActor
    private func runChat() async {
        running = true
        output = ""
        defer { running = false }

        let llm = OpenAILLMClient(config: AppConfig.proxy)
        let messages = [
            Message(role: .user, content: "카페 직원처럼 한 문장으로 손님에게 인사해줘")
        ]
        do {
            for try await event in llm.stream(messages: messages) {
                if case .token(let token) = event { output += token }
            }
        } catch {
            output = "대화 에러: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SmokeView()
}
