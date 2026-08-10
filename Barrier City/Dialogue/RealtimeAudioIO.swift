//
//  RealtimeAudioIO.swift
//  Barrier City
//
//  Realtime API가 요구하는 mono PCM16/24kHz 마이크 스트림과
//  서버가 보내는 PCM16/24kHz 음성 재생을 하나의 voice-chat 세션에서 처리한다.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class RealtimeAudioIO {
    enum AudioError: LocalizedError {
        case permissionDenied
        case inputUnavailable
        case converterUnavailable
        case simulatorUnavailable

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "마이크 권한이 필요합니다."
            case .inputUnavailable:
                "현재 오디오 입력을 사용할 수 없습니다."
            case .converterUnavailable:
                "마이크 오디오를 Realtime 형식으로 변환할 수 없습니다."
            case .simulatorUnavailable:
                "visionOS 시뮬레이터에서는 Realtime 마이크를 사용할 수 없습니다."
            }
        }
    }

    static let sampleRate: Double = 24_000

    private lazy var engine = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private lazy var playbackFormat = AVAudioFormat(
        standardFormatWithSampleRate: Self.sampleRate,
        channels: 1
    )!
    private var isInputTapInstalled = false
    private var isPlayerAttached = false
    private var outputStartedAt: ContinuousClock.Instant?
    private var receivedOutputFrames = 0
    private var hasAudioSessionClaim = false
    private let inputLevelSampler = MicrophoneLevelSampler()
    private(set) var isRunning = false

    /// Audio I/O를 시작한다. 콜백은 Core Audio 스레드에서 호출되므로 전달받은 Data를
    /// 즉시 비동기 큐/스트림으로 넘기고 콜백 안에서 네트워크를 기다리면 안 된다.
    func start(onInput: @escaping @Sendable (Data) -> Void,
               onInputLevel: @escaping @Sendable (Float) -> Void) async throws {
#if targetEnvironment(simulator)
        guard DevelopmentOptions.simulatorMicrophoneEnabled else {
            throw AudioError.simulatorUnavailable
        }
#endif
        guard !isRunning else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioError.permissionDenied
        }
        try Task.checkCancellation()

        try AudioSessionCoordinator.shared.acquire(.realtimeConversation)
        hasAudioSessionClaim = true

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            releaseAudioSessionClaim()
            throw AudioError.inputUnavailable
        }
        guard let streamFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: streamFormat) else {
            releaseAudioSessionClaim()
            throw AudioError.converterUnavailable
        }

        if !isPlayerAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
            isPlayerAttached = true
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
            [inputLevelSampler] buffer, _ in
            if let level = inputLevelSampler.consume(buffer) {
                onInputLevel(level)
            }
            guard let data = Self.convertInput(
                buffer,
                using: converter,
                outputFormat: streamFormat
            ), !data.isEmpty else { return }
            onInput(data)
        }
        isInputTapInstalled = true

        engine.prepare()
        do {
            try engine.start()
            player.play()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            isInputTapInstalled = false
            releaseAudioSessionClaim()
            throw error
        }
    }

    /// 서버가 보낸 little-endian PCM16 mono/24kHz chunk를 순서대로 재생한다.
    func enqueueOutput(_ pcm16: Data, beginsResponse: Bool) {
        guard isRunning,
              pcm16.count >= MemoryLayout<Int16>.size,
              let buffer = Self.makePlaybackBuffer(from: pcm16, format: playbackFormat) else {
            return
        }
        if beginsResponse || outputStartedAt == nil {
            outputStartedAt = .now
            receivedOutputFrames = 0
        }
        receivedOutputFrames += Int(buffer.frameLength)
        player.scheduleBuffer(buffer)
        if !player.isPlaying { player.play() }
    }

    /// 사용자가 NPC 발화 중 끼어들면 아직 재생하지 않은 음성까지 즉시 버린다.
    func interruptOutput() -> Int? {
        guard isPlayerAttached else { return nil }
        let playedMilliseconds: Int?
        if let outputStartedAt {
            let elapsed = outputStartedAt.duration(to: .now)
            let elapsedSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
            let receivedSeconds = Double(receivedOutputFrames) / Self.sampleRate
            playedMilliseconds = Int(min(elapsedSeconds, receivedSeconds) * 1_000)
        } else {
            playedMilliseconds = nil
        }
        player.stop()
        outputStartedAt = nil
        receivedOutputFrames = 0
        return playedMilliseconds
    }

    func stop() {
        guard isRunning || isInputTapInstalled || hasAudioSessionClaim else { return }
        if isInputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isInputTapInstalled = false
        }
        if isPlayerAttached { player.stop() }
        if engine.isRunning { engine.stop() }
        isRunning = false
        inputLevelSampler.reset()
        outputStartedAt = nil
        receivedOutputFrames = 0
        releaseAudioSessionClaim()
    }

    private func releaseAudioSessionClaim() {
        guard hasAudioSessionClaim else { return }
        hasAudioSessionClaim = false
        AudioSessionCoordinator.shared.release(.realtimeConversation)
    }

    /// CoreAudio 입력 탭에서 직접 호출된다. RealtimeAudioIO의 MainActor 격리를
    /// 상속하면 오디오 큐에서 swift_task_checkIsolated가 중단시키므로 명시적으로 분리한다.
    nonisolated private static func convertInput(
        _ input: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> Data? {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else { return nil }

        let inputState = ConverterInputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard inputState.claimInput() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        guard conversionError == nil,
              status != .error,
              let samples = output.int16ChannelData?[0] else { return nil }

        return Data(
            bytes: samples,
            count: Int(output.frameLength) * MemoryLayout<Int16>.size
        )
    }

    private static func makePlaybackBuffer(
        from pcm16: Data,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let frameCount = pcm16.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ), let samples = buffer.floatChannelData?[0] else { return nil }

        pcm16.withUnsafeBytes { bytes in
            for index in 0..<frameCount {
                let low = UInt16(bytes[index * 2])
                let high = UInt16(bytes[index * 2 + 1]) << 8
                let sample = Int16(bitPattern: low | high)
                samples[index] = Float(sample) / 32_768
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}

/// AVAudioConverter의 @Sendable 입력 콜백이 같은 변환에서 입력 버퍼를 한 번만 소비하게 한다.
/// 콜백 호출 스레드에 대한 프레임워크 보장이 타입에 표현되지 않아 잠금으로 명시한다.
private nonisolated final class ConverterInputState: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false

    func claimInput() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !supplied else { return false }
        supplied = true
        return true
    }
}
