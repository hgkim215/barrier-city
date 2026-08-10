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
    private var playerContinuation: CheckedContinuation<Void, Never>?
    private var synthContinuation: CheckedContinuation<Void, Never>?

    init(config: ProxyConfig, session: URLSession = .shared, mode: VoiceMode = .cloud) {
        self.config = config
        self.session = session
        self.mode = mode
    }

    /// 한 문장을 말한다. 자막을 먼저 갱신하고, 재생이 끝날 때까지 대기(순차 재생 보장).
    func speak(_ sentence: String, subtitle: (String) -> Void) async {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !Task.isCancelled else { return }
        subtitle(trimmed)
        if mode == .lowLatency {
            await speakOnDevice(trimmed)
            return
        }
        do {
            let data = try await fetchTTS(trimmed)
            try Task.checkCancellation()
            try await playData(data)
        } catch is CancellationError {
            return
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
        for sentence in sentences {
            guard !Task.isCancelled else { return }
            await speak(sentence, subtitle: subtitle)
        }
    }

    /// 공간 이탈이나 대화 취소 시 진행 중인 네트워크 후속 재생과 로컬 발화를 즉시 끝낸다.
    func stop() {
        player?.stop()
        synth.stopSpeaking(at: .immediate)
        finishPlayerPlayback()
        finishSynthPlayback()
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
        try AudioSessionCoordinator.shared.acquire(.playback)
        defer { AudioSessionCoordinator.shared.release(.playback) }
        let p = try AVAudioPlayer(data: data)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                playerContinuation = continuation
                let delegate = PlayerDoneDelegate { [weak self] in
                    self?.finishPlayerPlayback()
                }
                playerDelegate = delegate
                p.delegate = delegate
                player = p
                p.prepareToPlay()
                if !p.play() { finishPlayerPlayback() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.player?.stop()
                self?.finishPlayerPlayback()
            }
        }
        try Task.checkCancellation()
    }

    private func speakOnDevice(_ text: String) async {
        do {
            try AudioSessionCoordinator.shared.acquire(.playback)
        } catch {
            return
        }
        defer { AudioSessionCoordinator.shared.release(.playback) }
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                synthContinuation = continuation
                let delegate = SynthDoneDelegate { [weak self] in
                    self?.finishSynthPlayback()
                }
                synthDelegate = delegate
                synth.delegate = delegate
                synth.speak(u)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.synth.stopSpeaking(at: .immediate)
                self?.finishSynthPlayback()
            }
        }
    }

    private func finishPlayerPlayback() {
        guard let continuation = playerContinuation else { return }
        playerContinuation = nil
        player = nil
        playerDelegate = nil
        continuation.resume()
    }

    private func finishSynthPlayback() {
        guard let continuation = synthContinuation else { return }
        synthContinuation = nil
        synthDelegate = nil
        continuation.resume()
    }
}

// AVFoundation은 완료 델리게이트를 임의의 큐에서 호출할 수 있다. 델리게이트 진입점은
// nonisolated로 두고, 실제 VoiceOutput 상태 변경만 MainActor로 전달한다.
nonisolated final class PlayerDoneDelegate: NSObject, AVAudioPlayerDelegate {
    private let onDone: @MainActor @Sendable () -> Void
    init(onDone: @escaping @MainActor @Sendable () -> Void) { self.onDone = onDone }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [onDone] in onDone() }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [onDone] in onDone() }
    }
}

nonisolated final class SynthDoneDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onDone: @MainActor @Sendable () -> Void
    init(onDone: @escaping @MainActor @Sendable () -> Void) { self.onDone = onDone }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [onDone] in onDone() }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [onDone] in onDone() }
    }
}
