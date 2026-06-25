//
//  VoiceTestView.swift
//  WheelchairXR
//
//  T5 VoiceOutput 단독 테스트 — 여러 문장을 순차 신경망 TTS로 재생하며 자막 동기.
//  시뮬레이터에서도 소리 남. "폴백 테스트"는 잘못된 URL로 강제 실패 → 온디바이스 음성으로 전환 확인.
//

import SwiftUI
import DialogueKitOpenAI

struct VoiceTestView: View {
    @State private var voice = VoiceOutput(config: AppConfig.proxy)
    @State private var subtitle = ""
    @State private var running = false

    // 잘못된 URL → /tts 실패 유도 → 온디바이스 폴백 검증용
    private let fallbackVoice = VoiceOutput(config: ProxyConfig(base: URL(string: "https://invalid.invalid")!))

    private let sample = ["어서 오세요.", "무엇을 드릴까요?", "아메리카노 나왔습니다, 맛있게 드세요."]

    var body: some View {
        VStack(spacing: 12) {
            Text("VoiceOutput 테스트").font(.headline)

            Text(subtitle.isEmpty ? "버튼을 누르면 NPC가 여러 문장을 순차로 말합니다." : "💬 \(subtitle)")
                .font(.title3).multilineTextAlignment(.center).frame(maxWidth: 420, minHeight: 50)

            HStack(spacing: 12) {
                Button(running ? "재생 중…" : "NPC 응답 재생 (여러 문장)") {
                    Task {
                        running = true; defer { running = false }
                        await voice.speak(sentences: sample) { subtitle = $0 }
                        subtitle = "(끝)"
                    }
                }.disabled(running)

                Button("폴백 테스트") {
                    Task {
                        running = true; defer { running = false }
                        await fallbackVoice.speak("네트워크가 끊겨도 온디바이스 음성으로 말합니다.") { subtitle = $0 }
                        subtitle = "(폴백 끝)"
                    }
                }.disabled(running)
            }
        }
        .padding(24)
    }
}
