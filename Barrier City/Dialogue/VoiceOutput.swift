//
//  VoiceOutput.swift
//  WheelchairXR
//
//  T5 — NPC 음성 출력. 본편은 지연이 짧은 온디바이스 음성을 사용하고,
//  품질 비교용 cloud 모드는 /tts를 사용한다. 재생과 동시에 자막 콜백.
//  iOS/visionOS 공용(AVFoundation). T6에서 DialogueOrchestrator.spokenSentences를 문장별로 speak.
//

import Foundation
import AVFoundation
import DialogueKitOpenAI

enum VoiceMode { case lowLatency, cloud }

@MainActor
final class VoiceOutput {
    private let config: ProxyConfig
    private let session: URLSession
    private let mode: VoiceMode
    /// Cloud 모드에서는 로컬 voice catalog를 전혀 열지 않도록 실제 폴백 시점까지 지연한다.
    private lazy var synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var playerDelegate: PlayerDoneDelegate?
    private var synthDelegate: SynthDoneDelegate?

    init(config: ProxyConfig, session: URLSession = .shared, mode: VoiceMode = .cloud) {
        self.config = config
        self.session = session
        self.mode = mode
    }

    /// 한 문장을 말한다. 자막을 먼저 갱신하고, 재생이 끝날 때까지 대기(순차 재생 보장).
    func speak(_ sentence: String, subtitle: (String) -> Void) async {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        subtitle(trimmed)
        if mode == .lowLatency {
            await speakOnDevice(trimmed)
            return
        }
        do {
            let data = try await fetchTTS(trimmed)
            try await playData(data)
        } catch {
#if targetEnvironment(simulator)
            // Simulator의 AVSpeech voice 목록 오류를 다시 유발하지 않는다. 자막은 이미
            // 표시됐으므로 네트워크 TTS 실패 시 무음으로 정상 복귀한다.
            return
#else
            await speakOnDevice(trimmed)   // 네트워크/재생 실패 → 온디바이스 폴백
#endif
        }
    }

    /// 여러 문장을 순서대로(겹치지 않게) 말한다.
    func speak(sentences: [String], subtitle: (String) -> Void) async {
        for s in sentences { await speak(s, subtitle: subtitle) }
    }

    // MARK: - 내부

    private func fetchTTS(_ text: String) async throws -> Data {
        var req = URLRequest(url: config.ttsURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts", "voice": "alloy", "input": text, "response_format": "wav",
        ])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func playData(_ data: Data) async throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        let p = try AVAudioPlayer(data: data)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let delegate = PlayerDoneDelegate { cont.resume() }
            self.playerDelegate = delegate
            p.delegate = delegate
            self.player = p
            p.prepareToPlay()
            if !p.play() { cont.resume() }   // 재생 시작 실패 시 즉시 반환
        }
    }

    private func speakOnDevice(_ text: String) async {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let d = SynthDoneDelegate { cont.resume() }
            self.synthDelegate = d
            synth.delegate = d
            synth.speak(u)
        }
    }
}

// 재생 완료를 async로 잇기 위한 델리게이트(강참조로 유지).
final class PlayerDoneDelegate: NSObject, AVAudioPlayerDelegate {
    private let onDone: @Sendable () -> Void
    init(onDone: @escaping @Sendable () -> Void) { self.onDone = onDone }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onDone() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onDone() }
}

final class SynthDoneDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onDone: @Sendable () -> Void
    init(onDone: @escaping @Sendable () -> Void) { self.onDone = onDone }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { onDone() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { onDone() }
}
