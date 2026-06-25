//
//  SmokeView.swift
//  WheelchairXR
//
//  앱 ↔ Worker 프록시 ↔ OpenAI 전 구간 스모크 테스트.
//  · "AI 호출 테스트" → 대화(/chat) 텍스트 스트리밍
//  · "음성 듣기" → 음성(/tts gpt-4o-mini-tts) 재생  (시뮬레이터에서도 소리 남)
//  T4 STT 붙이기 전, 백엔드 연결만 확인하는 용도.
//

import SwiftUI
import AVFoundation
import DialogueKit
import DialogueKitOpenAI

// AVAudioPlayer는 강참조로 살려둬야 재생이 끊기지 않음 → 보관 객체.
@MainActor
final class AudioBox {
    private var player: AVAudioPlayer?
    func play(_ data: Data) throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        let p = try AVAudioPlayer(data: data)
        p.prepareToPlay()
        p.play()
        player = p   // 유지
    }
}

struct SmokeView: View {
    @State private var output = ""
    @State private var running = false
    @State private var audio = AudioBox()

    var body: some View {
        VStack(spacing: 16) {
            Text("AI 연결 스모크 테스트")
                .font(.headline)

            HStack(spacing: 12) {
                Button(running ? "호출 중…" : "AI 호출 테스트") {
                    Task { await runChat() }
                }
                .disabled(running)

                Button("음성 듣기") {
                    Task { await runTTS() }
                }
                .disabled(running)
            }

            Text(output.isEmpty ? "버튼을 누르면 NPC 인사가 스트리밍/재생됩니다." : output)
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
    }

    // 대화(/chat) — 텍스트 스트리밍
    @MainActor
    private func runChat() async {
        running = true; output = ""
        defer { running = false }
        let llm = OpenAILLMClient(config: AppConfig.proxy)
        let msgs = [Message(role: .user, content: "카페 직원처럼 한 문장으로 손님에게 인사해줘")]
        do {
            for try await ev in llm.stream(messages: msgs) {
                if case .token(let t) = ev { output += t }
            }
        } catch {
            output = "대화 에러: \(error.localizedDescription)"
        }
    }

    // 음성(/tts) — wav 받아서 재생
    @MainActor
    private func runTTS() async {
        running = true; output = "음성 생성 중…"
        defer { running = false }
        var req = URLRequest(url: AppConfig.proxy.ttsURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts",
            "voice": "alloy",
            "input": "안녕하세요, 주문 도와드릴까요?",
            "response_format": "wav",
        ])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                output = "음성 에러: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            try audio.play(data)
            output = "🔊 음성 재생 중… (\(data.count) bytes)"
        } catch {
            output = "음성 에러: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SmokeView()
}
