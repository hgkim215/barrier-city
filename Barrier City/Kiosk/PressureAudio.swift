//
//  PressureAudio.swift
//  Barrier City
//
//  키오스크 뒤 대기줄의 사회적 압박 사운드.
//  - 발소리: ImpactAudio 패턴의 합성음(에셋 불필요, 오프라인 동작)
//  - 한숨·재촉 대사: 프록시 TTS(VoiceOutput) 우선 시도, 실패 시 온디바이스 음성 합성으로
//    폴백(VoiceOutput 내부 처리). 실패해도 대사는 생략되지 않고 다른 목소리로 들린다.
//  강도 단계: 0=무음 → 1(첫 리셋: 발소리+한숨) → 2(결제 실패: 재촉 대사).
//

import AVFoundation
import DialogueKitOpenAI

@MainActor
final class PressureAudio {

    static let shared = PressureAudio()

    /// false면 모든 재생 요청을 무시한다. 단위 테스트가 오디오 엔진·TTS 네트워크
    /// 호출을 일으키지 않도록 끄는 용도(KioskFlowModelTests.setUp).
    static var isEnabled = true

    private let engine = AVAudioEngine()
    private let stepPlayer = AVAudioPlayerNode()
    private var stepBuffer: AVAudioPCMBuffer?
    private var started = false
    private let sampleRate: Double = 44_100
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private let voice = VoiceOutput(config: AppConfig.proxy)

    private(set) var level = 0
    private var sighSpoken = false
    private var lineSpoken = false
    private var stepCooldown: Float = 0
    private var speechTask: Task<Void, Never>?

    private init() {}

    /// 첫 시간 초과 리셋: 압박 시작(발소리 + 한숨 1회).
    func onFirstReset() {
        guard Self.isEnabled, level < 1 else { return }
        level = 1
        prepare()
        if !sighSpoken {
            sighSpoken = true
            enqueueSpeech("하아…")   // 프록시 TTS 실패 시 VoiceOutput이 온디바이스 음성으로 대신 말함
        }
    }

    /// 결제 실패 시작: 재촉 대사 1회.
    func onPaymentStruggle() {
        guard Self.isEnabled else { return }
        level = max(level, 2)
        prepare()
        if !lineSpoken {
            lineSpoken = true
            enqueueSpeech("저기… 얼마나 걸릴까요?")   // 프록시 TTS 실패 시 VoiceOutput이 온디바이스 음성으로 대신 말함
        }
    }

    /// `voice`는 한 번에 한 발화만 처리하도록 설계되어 있으므로(재생 상태를 인스턴스에 저장),
    /// 이전 발화가 끝난 뒤에 다음 발화를 시작하도록 하나의 체인으로 직렬화한다.
    private func enqueueSpeech(_ line: String) {
        let previous = speechTask
        speechTask = Task { @MainActor in
            await previous?.value
            await voice.speak(sentences: [line]) { _ in }
        }
    }

    /// 매 프레임(KioskFlowModel.tick에서 호출). 발소리를 불규칙 간격으로 재생.
    func tick(dt: Float) {
        guard Self.isEnabled, level >= 1, started else { return }
        stepCooldown -= dt
        if stepCooldown <= 0 {
            stepCooldown = Float.random(in: 1.0...2.2) / Float(level)   // 단계↑ → 잦아짐
            playStep()
        }
    }

    func reset() {
        level = 0
        sighSpoken = false
        lineSpoken = false
        stepCooldown = 0
        // speechTask는 일부러 취소하거나 nil로 비우지 않는다.
        // 취소해도 무음이 되지 않는다 — VoiceOutput.speak()이 오류를 모두 잡아서
        // 온디바이스 합성으로 폴백하므로, 취소된 발화도 결국 다른 목소리로 재생된다.
        // 또한 여기서 nil로 비우면 다음 세션의 enqueueSpeech가 이전 발화를 기다리지 않고
        // 바로 시작해, 아직 재생 중인 발화와 겹치며 VoiceOutput의 공유 delegate를 다시 경합시킨다.
        // 참조를 남겨 두면 다음 세션도 이 발화가 끝날 때까지 체인으로 이어서 기다린다.
    }

    // MARK: - 내부(ImpactAudio 패턴)

    private func prepare() {
        guard !started else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        stepBuffer = makeStep()
        engine.attach(stepPlayer)
        engine.connect(stepPlayer, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            stepPlayer.play()
            started = true
        } catch {
            print("PressureAudio 시작 실패: \(error)")
        }
    }

    private func playStep() {
        guard let stepBuffer else { return }
        stepPlayer.volume = 0.35
        stepPlayer.scheduleBuffer(stepBuffer, at: nil, options: .interrupts, completionHandler: nil)
        if !stepPlayer.isPlaying { stepPlayer.play() }
    }

    /// 뒤에서 서성이는 발소리 한 발(낮은 톤 + 잡음, 빠른 감쇠).
    private func makeStep() -> AVAudioPCMBuffer {
        let sr = Float(sampleRate)
        let duration: Float = 0.12
        let count = AVAudioFrameCount(sr * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let samples = buffer.floatChannelData![0]
        var generator = SystemRandomNumberGenerator()
        for i in 0..<Int(count) {
            let t = Float(i) / sr
            let env = expf(-t * 45)
            let attack = min(1, t / 0.003)
            let tone = sinf(2 * .pi * 55 * t)
            let noise = Float.random(in: -1...1, using: &generator)
            samples[i] = (0.6 * tone + 0.4 * noise) * env * attack * 0.8
        }
        return buffer
    }
}
