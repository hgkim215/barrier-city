//
//  STTTestView.swift
//  WheelchairXR
//
//  T4 STT 단독 테스트 — 누르고 말하면 한국어가 실시간 자막처럼 뜨고, 떼면 확정.
//  ⚠️ 실기(Vision Pro) 필요: 시뮬레이터는 마이크/음성인식 미동작.
//

import SwiftUI
import DialogueKitOpenAI

struct STTTestView: View {
    @State private var stt = SpeechInput()
    @State private var finalText = ""
    @State private var pressing = false
    @State private var errorText = ""
    @State private var roundTrip = ""
    @State private var rtRunning = false

    var body: some View {
        VStack(spacing: 12) {
            Text("STT 테스트").font(.headline)

            // ── 시뮬레이터 OK: TTS로 한국어 음성 생성 → 그 파일을 STT로 인식 ──
            Button(rtRunning ? "처리 중…" : "🔁 TTS→STT 라운드트립 (시뮬 OK)") {
                Task { await runRoundTrip() }
            }
            .disabled(rtRunning)
            if !roundTrip.isEmpty {
                Text(roundTrip).font(.callout).multilineTextAlignment(.center).frame(maxWidth: 420)
            }

            Divider().padding(.vertical, 6)

            Text("라이브 마이크 (실기 전용)").font(.subheadline).foregroundStyle(.secondary)

            Text(stt.isRecording
                 ? "🎤 듣는 중: \(stt.partialText)"
                 : (finalText.isEmpty ? "버튼을 누른 채 말하고 떼세요" : "확정: \(finalText)"))
                .font(.title3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420, minHeight: 60)

            Text(pressing ? "말하는 중… (떼면 종료)" : "🎙️ 누르고 말하기")
                .font(.headline)
                .padding(.horizontal, 24).padding(.vertical, 14)
                .background(pressing ? Color.red.opacity(0.35) : Color.gray.opacity(0.25))
                .clipShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !pressing {
                                pressing = true
                                errorText = ""
                                Task {
                                    do { try await stt.start() }
                                    catch { errorText = error.localizedDescription; pressing = false }
                                }
                            }
                        }
                        .onEnded { _ in
                            pressing = false
                            Task { finalText = await stt.stop() }
                        }
                )

            if !errorText.isEmpty {
                Text("에러: \(errorText)").foregroundStyle(.red).font(.footnote)
            }
        }
        .padding(24)
    }

    // TTS로 한국어 음성 생성 → 임시 wav 저장 → STT 파일 인식 (마이크·실기 불필요)
    @MainActor
    private func runRoundTrip() async {
        rtRunning = true
        roundTrip = "TTS 음성 생성 중…"
        defer { rtRunning = false }
        let phrase = "안녕하세요 아메리카노 한 잔 주세요"
        do {
            var req = URLRequest(url: AppConfig.proxy.ttsURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": "gpt-4o-mini-tts", "voice": "alloy", "input": phrase, "response_format": "wav",
            ])
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                roundTrip = "TTS 실패: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"; return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip.wav")
            try data.write(to: url)
            roundTrip = "STT 인식 중…"
            let recognized = try await stt.transcribeFile(url)
            roundTrip = "원문: \(phrase)\n인식: \(recognized)"
        } catch {
            roundTrip = "에러: \(error.localizedDescription)"
        }
    }
}
