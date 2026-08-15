import AVFoundation

/// 충격음 재생기. 오디오 파일 없이 코드로 합성한 짧은 소리를 쓴다.
///  - bump: 단차를 넘을 때 나는 낮은 "쿵"(덜컹).
///  - thunk: 턱/벽에 부딪힐 때 나는 단단한 "턱"(충돌).
/// 충격 세기(intensity 0~1)에 비례해 볼륨을 준다.
@MainActor
final class ImpactAudio {

    static let shared = ImpactAudio()

    private let engine = AVAudioEngine()
    private let bumpPlayer = AVAudioPlayerNode()
    private let thunkPlayer = AVAudioPlayerNode()
    private var bumpBuffer: AVAudioPCMBuffer?
    private var thunkBuffer: AVAudioPCMBuffer?
    private var isPrepared = false
    private var hasAudioSessionClaim = false

    private let sampleRate: Double = 44_100
    private lazy var format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private init() {}

    /// 오디오 세션/엔진 준비. ImmersiveView 등장 시 한 번 호출(중복 호출 안전).
    func prepare() {
        if !isPrepared {
            // 합성 버퍼 생성.
            bumpBuffer  = makeImpact(freq: 70,  duration: 0.22, noiseMix: 0.25, decay: 18)
            thunkBuffer = makeImpact(freq: 130, duration: 0.14, noiseMix: 0.6,  decay: 30)

            engine.attach(bumpPlayer)
            engine.attach(thunkPlayer)
            engine.connect(bumpPlayer,  to: engine.mainMixerNode, format: format)
            engine.connect(thunkPlayer, to: engine.mainMixerNode, format: format)
            isPrepared = true
            AudioSessionCoordinator.shared.registerEffectsLifecycle(
                suspend: { [weak self] in self?.suspendForAudioTransition() },
                resume: { [weak self] in self?.resumeAfterAudioTransition() }
            )
        }

        guard !hasAudioSessionClaim else { return }

        do {
            try AudioSessionCoordinator.shared.acquire(.effects)
            hasAudioSessionClaim = true
        } catch {}
    }

    /// 단차 덜컹 소리.
    func playBump(intensity: Float) {
        play(bumpPlayer, buffer: bumpBuffer, intensity: intensity)
    }

    /// 충돌 소리.
    func playThunk(intensity: Float) {
        play(thunkPlayer, buffer: thunkBuffer, intensity: intensity)
    }

    /// 몰입 공간이 닫히면 엔진과 공유 오디오 세션 사용권을 함께 반환한다.
    func stop() {
        suspendForAudioTransition()
        guard hasAudioSessionClaim else { return }
        hasAudioSessionClaim = false
        AudioSessionCoordinator.shared.release(.effects)
    }

    // MARK: - 내부

    private func play(_ player: AVAudioPlayerNode, buffer: AVAudioPCMBuffer?, intensity: Float) {
        if !hasAudioSessionClaim { prepare() }
        if !engine.isRunning, AudioSessionCoordinator.shared.effectsPlaybackIsActive {
            resumeAfterAudioTransition()
        }
        guard engine.isRunning, let buffer else { return }
        // 너무 작은 충격은 무시(잡소리 방지).
        let vol = max(0, min(1, intensity))
        guard vol > 0.05 else { return }
        player.volume = 0.25 + 0.75 * vol      // 약한 충격도 최소한 들리게
        // 새 충격이 오면 이전 소리를 끊고 다시 재생.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func suspendForAudioTransition() {
        guard isPrepared else { return }
        bumpPlayer.stop()
        thunkPlayer.stop()
        if engine.isRunning { engine.stop() }
    }

    private func resumeAfterAudioTransition() {
        guard isPrepared, !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            bumpPlayer.play()
            thunkPlayer.play()
        } catch {}
    }

    /// 짧은 충격음 한 발을 합성한다.
    /// - freq: 기본 주파수(낮을수록 둔탁)
    /// - duration: 길이(초)
    /// - noiseMix: 잡음 비율(0=순수 톤, 1=순수 잡음). 높을수록 '딱' 단단함.
    /// - decay: 감쇠 속도(클수록 빨리 사라짐)
    private func makeImpact(freq: Float, duration: Float, noiseMix: Float, decay: Float) -> AVAudioPCMBuffer {
        let sr = Float(sampleRate)
        let count = AVAudioFrameCount(sr * duration)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        let samples = buffer.floatChannelData![0]

        var generator = SystemRandomNumberGenerator()
        for i in 0..<Int(count) {
            let t = Float(i) / sr
            let env = expf(-t * decay)                    // 지수 감쇠
            let attack = min(1, t / 0.004)                // 4ms 어택(클릭 방지)
            let tone = sinf(2 * .pi * freq * t)
            let noise = Float.random(in: -1...1, using: &generator)
            let s = ((1 - noiseMix) * tone + noiseMix * noise) * env * attack
            samples[i] = s * 0.9
        }
        return buffer
    }
}
